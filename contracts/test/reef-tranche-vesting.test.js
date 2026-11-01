const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, takeSnapshot } = require("@nomicfoundation/hardhat-network-helpers");

const E18 = 10n ** 18n;
// Solstice1 schedule (deployment values): 9 Nov 2026, 9 Feb, 9 May, 9 Aug, 9 Nov 2027, each at 09:00 UTC+7.
const SOLSTICE1_TIMES = [1794189600, 1802138400, 1809828000, 1817776800, 1825725600];
// Tests run on a schedule relative to the test chain's clock, which other test files move forward.
let TIMES;
const TRANCHE = 2000n * E18;

describe("ReefTrancheVesting", () => {
  // Each test starts from the same chain state (time moves forward inside tests).
  let snap;
  beforeEach(async () => {
    snap = await takeSnapshot();
    const now = await time.latest();
    TIMES = [1, 2, 3, 4, 5].map((i) => now + i * 90 * 86400);
  });
  afterEach(async () => { await snap.restore(); });

  async function setup({ fund = 10000n * E18, times } = {}) {
    times = times || TIMES;
    const [deployer, beneficiary, stranger] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Reef", "REEF", 1_000_000n * E18);
    const V = await ethers.getContractFactory("ReefTrancheVesting");
    const v = await V.deploy(await token.getAddress(), beneficiary.address, TRANCHE, times);
    if (fund > 0n) await token.transfer(await v.getAddress(), fund);
    return { deployer, beneficiary, stranger, token, v, V };
  }

  it("the Solstice1 deployment dates are 9 Nov 2026 to 9 Nov 2027, 09:00 UTC+7", () => {
    const iso = SOLSTICE1_TIMES.map((t) => new Date((t + 7 * 3600) * 1000).toISOString().slice(0, 16));
    expect(iso).to.deep.equal(["2026-11-09T09:00", "2027-02-09T09:00", "2027-05-09T09:00", "2027-08-09T09:00", "2027-11-09T09:00"]);
  });

  it("stores the schedule and the total", async () => {
    const { v, beneficiary } = await setup();
    expect(await v.beneficiary()).to.equal(beneficiary.address);
    expect(await v.tranches()).to.equal(5n);
    expect(await v.totalAmount()).to.equal(10000n * E18);
    expect((await v.unlockTimes()).map(Number)).to.deep.equal(TIMES);
  });

  it("pays nothing before the first date", async () => {
    const { v } = await setup();
    await time.increaseTo(TIMES[0] - 10);
    expect(await v.releasable()).to.equal(0n);
    await expect(v.release()).to.be.revertedWith("nothing to release");
  });

  it("pays each tranche on its date, to the beneficiary, whoever calls", async () => {
    const { v, token, beneficiary, stranger } = await setup();
    await time.increaseTo(TIMES[0]);
    await expect(v.connect(stranger).release()).to.emit(v, "Released").withArgs(TRANCHE, TRANCHE);
    expect(await token.balanceOf(beneficiary.address)).to.equal(TRANCHE);
    expect(await token.balanceOf(stranger.address)).to.equal(0n);
    await expect(v.release()).to.be.revertedWith("nothing to release");
  });

  it("catches up on missed tranches in one call", async () => {
    const { v, token, beneficiary } = await setup();
    await time.increaseTo(TIMES[2] + 100);
    await v.release();
    expect(await token.balanceOf(beneficiary.address)).to.equal(3n * TRANCHE);
  });

  it("pays exactly the total by the last date, then nothing more", async () => {
    const { v, token, beneficiary } = await setup();
    for (const t of TIMES) { await time.increaseTo(t); await v.release(); }
    expect(await token.balanceOf(beneficiary.address)).to.equal(10000n * E18);
    expect(await token.balanceOf(await v.getAddress())).to.equal(0n);
    await time.increase(365 * 86400);
    await expect(v.release()).to.be.revertedWith("nothing to release");
  });

  it("pays what it holds when under-funded, and the rest after a top-up", async () => {
    const { v, token, beneficiary } = await setup({ fund: 1000n * E18 });
    await time.increaseTo(TIMES[0]);
    await v.release();
    expect(await token.balanceOf(beneficiary.address)).to.equal(1000n * E18);
    await token.transfer(await v.getAddress(), 9000n * E18);
    await v.release();
    expect(await token.balanceOf(beneficiary.address)).to.equal(TRANCHE);
  });

  it("never pays more than the schedule, even if over-funded", async () => {
    const { v, token, beneficiary } = await setup({ fund: 12000n * E18 });
    await time.increaseTo(TIMES[4]);
    await v.release();
    expect(await token.balanceOf(beneficiary.address)).to.equal(10000n * E18);
    await expect(v.release()).to.be.revertedWith("nothing to release");
  });

  it("rejects bad constructor inputs", async () => {
    const { V, token, beneficiary } = await setup({ fund: 0n });
    const t = await token.getAddress();
    await expect(V.deploy(ethers.ZeroAddress, beneficiary.address, TRANCHE, TIMES)).to.be.revertedWith("token is zero address");
    await expect(V.deploy(beneficiary.address, beneficiary.address, TRANCHE, TIMES)).to.be.revertedWith("token is not a contract");
    await expect(V.deploy(t, ethers.ZeroAddress, TRANCHE, TIMES)).to.be.revertedWith("beneficiary is zero address");
    await expect(V.deploy(t, beneficiary.address, 0, TIMES)).to.be.revertedWith("tranche amount is zero");
    await expect(V.deploy(t, beneficiary.address, TRANCHE, [])).to.be.revertedWith("1 to 24 tranches");
    await expect(V.deploy(t, beneficiary.address, TRANCHE, [TIMES[1], TIMES[0]])).to.be.revertedWith("unlock times must increase");
    await expect(V.deploy(t, beneficiary.address, TRANCHE, [TIMES[0], TIMES[0]])).to.be.revertedWith("unlock times must increase");
  });
});
