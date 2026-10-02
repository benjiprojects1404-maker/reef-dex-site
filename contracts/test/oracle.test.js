const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const E = (n) => ethers.parseEther(String(n));
const DAY = 24 * 3600;

describe("ReefTWAPOracle (live at 0xa461...FF7b)", function () {
  let owner, user, reef, wbdag, tok, oracle, W, T, deadline;
  const later = async (s) => { await network.provider.send("evm_increaseTime", [s]); await network.provider.send("evm_mine"); };

  beforeEach(async () => {
    [owner, user] = await ethers.getSigners();
    wbdag = await (await ethers.getContractFactory("contracts/reef/WBDAG.sol:WBDAG")).deploy();
    const factory = await (await ethers.getContractFactory("ReefFactory")).deploy(owner.address);
    reef = await (await ethers.getContractFactory("ReefRouter")).deploy(await factory.getAddress(), await wbdag.getAddress());
    tok = await (await ethers.getContractFactory("MockERC20")).deploy("NoCap", "NOCAP", E(10_000_000));
    W = await wbdag.getAddress(); T = await tok.getAddress();
    deadline = () => ethers.provider.getBlock("latest").then((b) => b.timestamp + 3600);
    await tok.approve(await reef.getAddress(), ethers.MaxUint256);
    await reef.addLiquidityBDAG(T, E(1_000_000), 0, 0, owner.address, await deadline(), { value: E(10) });
    oracle = await (await ethers.getContractFactory("ReefTWAPOracle")).deploy(await factory.getAddress(), T, W);
  });

  it("refuses a pair that doesn't exist", async () => {
    const F = await ethers.getContractFactory("ReefFactory");
    const empty = await F.deploy(owner.address);
    await expect((await ethers.getContractFactory("ReefTWAPOracle")).deploy(await empty.getAddress(), T, W)).to.be.revertedWith("ReefTWAPOracle: NO_PAIR");
  });

  it("update() reverts until 24h have passed, then works, then waits again", async () => {
    await expect(oracle.update()).to.be.revertedWith("ReefTWAPOracle: PERIOD_NOT_ELAPSED");
    await later(DAY);
    await oracle.update();
    expect(await oracle.secondsUntilNextUpdate()).to.be.closeTo(BigInt(DAY), 5n);
    await expect(oracle.update()).to.be.revertedWith("ReefTWAPOracle: PERIOD_NOT_ELAPSED");
  });

  it("NOTE O-1: consult() returns 0 before the first update (the code comment says it reverts)", async () => {
    expect(await oracle.consult(T, E(1))).to.equal(0n);
  });

  it("with no trades, the 24h average equals the pool price", async () => {
    await later(DAY); await oracle.update();
    // 10 BDAG : 1,000,000 NOCAP -> 1 NOCAP = 0.00001 BDAG
    expect(await oracle.consult(T, E(1))).to.be.closeTo(E("0.00001"), 10n ** 6n);
    expect(await oracle.consult(W, E(1))).to.be.closeTo(E(100_000), 10n ** 12n);
  });

  it("a price spike in the last minute barely moves the 24h average", async () => {
    await later(DAY - 60);
    await reef.connect(user).swapExactBDAGForTokens(0, [W, T], user.address, await deadline(), { value: E(10) }); // doubles the BDAG side
    await later(60);
    await oracle.update();
    const avg = await oracle.consult(T, E(1));
    // spot is now ~4x; the average should stay within ~1% of the old price
    expect(avg).to.be.lt(E("0.0000101"));
  });

  it("rejects a token that isn't in the pair", async () => {
    await expect(oracle.consult(owner.address, 1)).to.be.revertedWith("ReefTWAPOracle: INVALID_TOKEN");
  });
});
