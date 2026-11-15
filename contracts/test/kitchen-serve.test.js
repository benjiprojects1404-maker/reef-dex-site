const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(String(n));
const FEE = E(5000);
const MIN = E(10000);
const RESERVED = ["BDAG", "WBDAG", "REEF", "NOCAP", "COOKED", "USDT", "USDC", "ETH", "WETH", "BTC", "WBTC"];
const DEAD = "0x000000000000000000000000000000000000dEaD";
const TOKEN = "contracts/kitchen/KitchenServe.sol:KitchenToken";

describe("KitchenServe (cook and serve on Reef)", function () {
  let kitchen, router, factory, wbdag, admin, treasury, alice, bob;

  beforeEach(async function () {
    [admin, treasury, alice, bob] = await ethers.getSigners();
    wbdag = await (await ethers.getContractFactory("contracts/reef/WBDAG.sol:WBDAG")).deploy();
    factory = await (await ethers.getContractFactory("ReefFactory")).deploy(admin.address);
    router = await (await ethers.getContractFactory("ReefRouter")).deploy(await factory.getAddress(), await wbdag.getAddress());
    kitchen = await (await ethers.getContractFactory("KitchenServe")).deploy(await router.getAddress(), admin.address, treasury.address, FEE, MIN, RESERVED);
  });

  async function cook(signer, name, symbol, supply, pct, liq = MIN, value) {
    const tx = await kitchen.connect(signer).cook(name, symbol, supply, pct, { value: value ?? FEE + liq });
    const rc = await tx.wait();
    const ev = rc.logs.map((l) => { try { return kitchen.interface.parseLog(l); } catch (e) { return null; } }).find((e) => e && e.name === "TokenServed");
    return { token: await ethers.getContractAt(TOKEN, ev.args.token), pair: await ethers.getContractAt("ReefPair", ev.args.pair), ev, rc };
  }

  it("makes the token, its Reef pool and burns the LP, all in one transaction", async function () {
    const { token, pair, ev } = await cook(alice, "Midnight Pancake", "PANCAKE", 1_000_000n, 40, E(20000));
    const t = await token.getAddress();
    expect(await factory.getPair(t, await wbdag.getAddress())).to.equal(await pair.getAddress());
    expect(await kitchen.pairOf(t)).to.equal(await pair.getAddress());
    // 40% of the supply and 20,000 BDAG in the pool
    expect(await token.balanceOf(await pair.getAddress())).to.equal(E(400000));
    expect(await wbdag.balanceOf(await pair.getAddress())).to.equal(E(20000));
    // the rest to the creator
    expect(await token.balanceOf(alice.address)).to.equal(E(600000));
    // LP burned: Reef locks its permanent minimum at the dead address too, so ALL of the LP sits there
    const lpSupply = await pair.totalSupply();
    expect(await pair.balanceOf(DEAD)).to.equal(lpSupply);
    expect(await pair.balanceOf(alice.address)).to.equal(0n);
    expect(await pair.balanceOf(await kitchen.getAddress())).to.equal(0n);
    expect(ev.args.poolTokens).to.equal(E(400000));
    expect(ev.args.poolBDAG).to.equal(E(20000));
  });

  it("100% to the pool leaves the creator nothing (a pure fair launch)", async function () {
    const { token, pair } = await cook(alice, "Fair", "FAIR", 1000n, 100);
    expect(await token.balanceOf(alice.address)).to.equal(0n);
    expect(await token.balanceOf(await pair.getAddress())).to.equal(E(1000));
  });

  it("sends exactly the fee to the treasury and keeps no BDAG or tokens", async function () {
    const before = await ethers.provider.getBalance(treasury.address);
    const { token } = await cook(alice, "Pan", "PAN", 1000n, 50);
    expect((await ethers.provider.getBalance(treasury.address)) - before).to.equal(FEE);
    expect(await ethers.provider.getBalance(await kitchen.getAddress())).to.equal(0n);
    expect(await token.balanceOf(await kitchen.getAddress())).to.equal(0n);
  });

  it("the token can be traded on Reef straight away", async function () {
    const { token } = await cook(alice, "Pan", "PAN", 1_000_000n, 50, E(10000));
    const t = await token.getAddress();
    const path = [await wbdag.getAddress(), t];
    await router.connect(bob).swapExactBDAGForTokens(0, path, bob.address, (await ethers.provider.getBlock("latest")).timestamp + 600, { value: E(100) });
    expect(await token.balanceOf(bob.address)).to.be.gt(0n);
  });

  it("the token has only the standard ERC-20 functions", async function () {
    const { token } = await cook(alice, "Pan", "PAN", 1000n, 50);
    const fns = Object.values(token.interface.fragments).filter((f) => f.type === "function").map((f) => f.name).sort();
    expect(fns).to.deep.equal(["allowance", "approve", "balanceOf", "decimals", "name", "symbol", "totalSupply", "transfer", "transferFrom"]);
  });

  it("needs the fee plus at least the minimum liquidity", async function () {
    await expect(kitchen.connect(alice).cook("Pan", "PAN", 1000n, 50, { value: FEE })).to.be.revertedWithCustomError(kitchen, "NotEnoughBDAG");
    await expect(kitchen.connect(alice).cook("Pan", "PAN", 1000n, 50, { value: FEE + MIN - 1n })).to.be.revertedWithCustomError(kitchen, "NotEnoughBDAG");
    await expect(kitchen.connect(alice).cook("Pan", "PAN", 1000n, 50, { value: FEE - 1n })).to.be.revertedWithCustomError(kitchen, "NotEnoughBDAG");
    await cook(alice, "Pan", "PAN", 1000n, 50, MIN);
  });

  it("with no minimum, still needs some liquidity", async function () {
    await kitchen.setMinLiquidity(0);
    await expect(kitchen.connect(alice).cook("Pan", "PAN", 1000n, 50, { value: FEE })).to.be.revertedWithCustomError(kitchen, "NotEnoughBDAG");
    await cook(alice, "Pan", "PAN", 1000n, 50, E(1));
  });

  it("pool share must be 10-100%", async function () {
    for (const p of [0n, 9n, 101n]) {
      await expect(kitchen.connect(alice).cook("Pan", "PAN", 1000n, p, { value: FEE + MIN })).to.be.revertedWithCustomError(kitchen, "BadPoolShare");
    }
    await cook(alice, "Pan", "PAN", 1000n, 10);
  });

  it("checks names, tickers, reserved tickers and supply like v1", async function () {
    await expect(kitchen.connect(alice).cook(" Pan", "PAN", 1n, 50, { value: FEE + MIN })).to.be.revertedWithCustomError(kitchen, "BadName");
    await expect(kitchen.connect(alice).cook("Pan", "USDТ", 1n, 50, { value: FEE + MIN })).to.be.revertedWithCustomError(kitchen, "BadSymbol");
    await expect(kitchen.connect(alice).cook("Pan", "reef", 1n, 50, { value: FEE + MIN })).to.be.revertedWithCustomError(kitchen, "ReservedSymbol");
    await expect(kitchen.connect(alice).cook("Pan", "PAN", 0n, 50, { value: FEE + MIN })).to.be.revertedWithCustomError(kitchen, "BadSupply");
    await expect(kitchen.connect(alice).cook("Pan", "PAN", 10n ** 15n + 1n, 50, { value: FEE + MIN })).to.be.revertedWithCustomError(kitchen, "BadSupply");
    expect(await kitchen.isReserved("usdc")).to.equal(true);
  });

  it("reverts everything if the treasury refuses BDAG", async function () {
    const rej = await (await ethers.getContractFactory("MockRejectBDAG")).deploy();
    await kitchen.setFeeRecipient(await rej.getAddress());
    await expect(kitchen.connect(alice).cook("Pan", "PAN", 1000n, 50, { value: FEE + MIN })).to.be.revertedWithCustomError(kitchen, "TransferFailed");
    expect(await kitchen.tokenCount()).to.equal(0n);
  });

  it("refuses BDAG sent directly (only the router may refund)", async function () {
    await expect(alice.sendTransaction({ to: await kitchen.getAddress(), value: 1n })).to.be.revertedWithCustomError(kitchen, "NotRouter");
  });

  it("lists tokens newest first and by creator", async function () {
    const a = await (await cook(alice, "One", "ONE", 1000n, 50)).token.getAddress();
    const b = await (await cook(bob, "Two", "TWO", 1000n, 50)).token.getAddress();
    expect(await kitchen.tokenCount()).to.equal(2n);
    expect(await kitchen.latest(0, 5)).to.deep.equal([b, a]);
    expect(await kitchen.tokensByCreator(alice.address)).to.deep.equal([a]);
    expect(await kitchen.isKitchenToken(a)).to.equal(true);
  });

  describe("admin", function () {
    it("fee and minimum are capped and admin-only", async function () {
      await expect(kitchen.connect(alice).setFee(1n)).to.be.revertedWithCustomError(kitchen, "NotAdmin");
      await expect(kitchen.connect(alice).setMinLiquidity(1n)).to.be.revertedWithCustomError(kitchen, "NotAdmin");
      await expect(kitchen.setFee(E(50000) + 1n)).to.be.revertedWithCustomError(kitchen, "FeeTooHigh");
      await expect(kitchen.setMinLiquidity(E(1000000) + 1n)).to.be.revertedWithCustomError(kitchen, "MinTooHigh");
      await kitchen.setFee(0); await kitchen.setMinLiquidity(E(50000));
      expect(await kitchen.fee()).to.equal(0n);
      expect(await kitchen.minLiquidity()).to.equal(E(50000));
    });

    it("constructor checks", async function () {
      const F = await ethers.getContractFactory("KitchenServe");
      const r = await router.getAddress();
      await expect(F.deploy(ethers.ZeroAddress, admin.address, treasury.address, 0, 0, [])).to.be.reverted;
      await expect(F.deploy(r, ethers.ZeroAddress, treasury.address, 0, 0, [])).to.be.revertedWithCustomError(kitchen, "ZeroAddress");
      await expect(F.deploy(r, admin.address, ethers.ZeroAddress, 0, 0, [])).to.be.revertedWithCustomError(kitchen, "ZeroAddress");
      await expect(F.deploy(r, admin.address, treasury.address, E(50001), 0, [])).to.be.revertedWithCustomError(kitchen, "FeeTooHigh");
      await expect(F.deploy(r, admin.address, treasury.address, 0, E(1000001), [])).to.be.revertedWithCustomError(kitchen, "MinTooHigh");
      expect(await kitchen.wbdag()).to.equal(await wbdag.getAddress());
      expect(await kitchen.pairFactory()).to.equal(await factory.getAddress());
    });

    it("two-step admin hand-over, and no power over tokens", async function () {
      await kitchen.transferAdmin(bob.address);
      await kitchen.connect(bob).acceptAdmin();
      expect(await kitchen.admin()).to.equal(bob.address);
      const fns = Object.values(kitchen.interface.fragments).filter((f) => f.type === "function" && !["view", "pure"].includes(f.stateMutability)).map((f) => f.name).sort();
      expect(fns).to.deep.equal(["acceptAdmin", "cook", "setFee", "setFeeRecipient", "setMinLiquidity", "transferAdmin"]);
    });
  });
});
