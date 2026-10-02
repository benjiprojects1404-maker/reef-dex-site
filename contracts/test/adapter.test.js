const { expect } = require("chai");
const { ethers } = require("hardhat");
const E = (n) => ethers.parseEther(String(n));

describe("NodalRouter -> NodalReefAdapter -> Reef (real contracts)", function () {
  let owner, user, treasury, wbdag, factory, reef, nodal, adapter, nocap, usdx, SRC, deadline;

  beforeEach(async () => {
    [owner, user, treasury] = await ethers.getSigners();
    wbdag = await (await ethers.getContractFactory("contracts/reef/WBDAG.sol:WBDAG")).deploy();
    factory = await (await ethers.getContractFactory("ReefFactory")).deploy(owner.address);
    reef = await (await ethers.getContractFactory("ReefRouter")).deploy(await factory.getAddress(), await wbdag.getAddress());
    const M = await ethers.getContractFactory("MockERC20");
    nocap = await M.deploy("NoCap", "NOCAP", E(10_000_000));
    usdx = await M.deploy("USD X", "USDX", E(10_000_000));
    nodal = await (await ethers.getContractFactory("NodalRouter")).deploy(treasury.address);
    adapter = await (await ethers.getContractFactory("NodalReefAdapter")).deploy(await reef.getAddress());
    deadline = (await ethers.provider.getBlock("latest")).timestamp + 3600;

    // Seed Reef pools: NOCAP/BDAG and NOCAP/USDX
    const r = await reef.getAddress();
    await nocap.approve(r, ethers.MaxUint256); await usdx.approve(r, ethers.MaxUint256);
    await reef.addLiquidityBDAG(await nocap.getAddress(), E(1_000_000), 0, 0, owner.address, deadline, { value: E(1000) });
    await reef.addLiquidity(await nocap.getAddress(), await usdx.getAddress(), E(1_000_000), E(500_000), 0, 0, owner.address, deadline);

    SRC = ethers.encodeBytes32String("reef");
    await nodal.registerSource(SRC, await adapter.getAddress(), "Reef");

    await nocap.mint(user.address, E(100_000)); await usdx.mint(user.address, E(100_000));
    await nocap.connect(user).approve(await nodal.getAddress(), ethers.MaxUint256);
    await usdx.connect(user).approve(await nodal.getAddress(), ethers.MaxUint256);
  });

  async function adapterIsEmpty() {
    const a = await adapter.getAddress();
    expect(await ethers.provider.getBalance(a)).to.equal(0n);
    for (const t of [nocap, usdx, wbdag]) expect(await t.balanceOf(a)).to.equal(0n);
    const n = await nodal.getAddress();
    expect(await ethers.provider.getBalance(n)).to.equal(0n);
    for (const t of [nocap, usdx, wbdag]) expect(await t.balanceOf(n)).to.equal(0n);
  }

  it("quoteAll through the adapter matches Reef's own quote, minus 0.15%", async () => {
    const path = [await wbdag.getAddress(), await nocap.getAddress()];
    const direct = await reef.getAmountsOut(E(10), path);
    const [ids, gross, fees, net] = await nodal.quoteAll(E(10), path);
    expect(ids[0]).to.equal(SRC);
    expect(gross[0]).to.equal(direct[1]);
    expect(fees[0]).to.equal(direct[1] * 15n / 10000n);
    expect(net[0]).to.equal(gross[0] - fees[0]);
  });

  it("BDAG -> NOCAP (the call that fails without the adapter)", async () => {
    const path = [await wbdag.getAddress(), await nocap.getAddress()];
    const [, g, f, n] = await nodal.quoteAll(E(10), path);
    const before = await nocap.balanceOf(user.address);
    const tb = await nocap.balanceOf(treasury.address);
    await nodal.connect(user).swapExactBDAGForTokens(SRC, n[0], path, deadline, { value: E(10) });
    expect((await nocap.balanceOf(user.address)) - before).to.equal(n[0]);
    expect((await nocap.balanceOf(treasury.address)) - tb).to.equal(f[0]);
    await adapterIsEmpty();
  });

  it("NOCAP -> BDAG", async () => {
    const path = [await nocap.getAddress(), await wbdag.getAddress()];
    const [, g, f, n] = await nodal.quoteAll(E(5000), path);
    const tb = await ethers.provider.getBalance(treasury.address);
    const ub = await ethers.provider.getBalance(user.address);
    const tx = await nodal.connect(user).swapExactTokensForBDAG(SRC, E(5000), n[0], path, deadline);
    const rc = await tx.wait();
    const gas = rc.gasUsed * tx.gasPrice;
    expect((await ethers.provider.getBalance(user.address)) - ub + gas).to.equal(n[0]);
    const ev = rc.logs.map(l => { try { return nodal.interface.parseLog(l); } catch { return null; } }).find(e => e && e.name === "SwapExecuted");
    expect(ev.args.netAmountOut).to.equal(n[0]);
    expect((await ethers.provider.getBalance(treasury.address)) - tb).to.equal(f[0]);
    await adapterIsEmpty();
  });

  it("NOCAP -> USDX (token to token)", async () => {
    const path = [await nocap.getAddress(), await usdx.getAddress()];
    const [, , f, n] = await nodal.quoteAll(E(2000), path);
    const before = await usdx.balanceOf(user.address);
    await nodal.connect(user).swapExactTokensForTokens(SRC, E(2000), n[0], path, deadline);
    expect((await usdx.balanceOf(user.address)) - before).to.equal(n[0]);
    expect(await usdx.balanceOf(treasury.address)).to.equal(f[0]);
    await adapterIsEmpty();
  });

  it("multi-hop BDAG -> NOCAP -> USDX", async () => {
    const path = [await wbdag.getAddress(), await nocap.getAddress(), await usdx.getAddress()];
    const [, , , n] = await nodal.quoteAll(E(3), path);
    const before = await usdx.balanceOf(user.address);
    await nodal.connect(user).swapExactBDAGForTokens(SRC, n[0], path, deadline, { value: E(3) });
    expect((await usdx.balanceOf(user.address)) - before).to.equal(n[0]);
    await adapterIsEmpty();
  });

  it("reverts with 'slippage' if the minimum isn't met, and nothing moves", async () => {
    const path = [await wbdag.getAddress(), await nocap.getAddress()];
    const [, , , n] = await nodal.quoteAll(E(10), path);
    await expect(nodal.connect(user).swapExactBDAGForTokens(SRC, n[0] + 1n, path, deadline, { value: E(10) }))
      .to.be.revertedWith("slippage");
    await adapterIsEmpty();
  });

  it("reverts on an expired deadline", async () => {
    const path = [await nocap.getAddress(), await usdx.getAddress()];
    await expect(nodal.connect(user).swapExactTokensForTokens(SRC, E(1), 0, path, 1)).to.be.reverted;
  });

  it("a wrong path (BDAG swap not starting with WBDAG) reverts safely", async () => {
    const path = [await nocap.getAddress(), await usdx.getAddress()];
    await expect(nodal.connect(user).swapExactBDAGForTokens(SRC, 0, path, deadline, { value: E(1) })).to.be.reverted;
    await adapterIsEmpty();
  });

  it("adapter rejects direct BDAG and exposes Reef's WBDAG", async () => {
    await expect(owner.sendTransaction({ to: await adapter.getAddress(), value: 1 })).to.be.revertedWith("no direct BDAG");
    expect(await adapter.WBDAG()).to.equal(await wbdag.getAddress());
    expect(await adapter.reef()).to.equal(await reef.getAddress());
  });

  it("control: registering Reef's router directly breaks BDAG swaps (why the adapter exists)", async () => {
    const DIRECT = ethers.encodeBytes32String("reef-direct");
    await nodal.registerSource(DIRECT, await reef.getAddress(), "Reef direct");
    const path = [await wbdag.getAddress(), await nocap.getAddress()];
    await expect(nodal.connect(user).swapExactBDAGForTokens(DIRECT, 0, path, deadline, { value: E(1) })).to.be.reverted;
  });
});
