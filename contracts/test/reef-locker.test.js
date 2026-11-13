const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, takeSnapshot } = require("@nomicfoundation/hardhat-network-helpers");

const E18 = 10n ** 18n;
const DAY = 86400;
const FEE = 100n * E18; // 100 BDAG per lock in these tests

describe("ReefLocker", () => {
  let snap;
  beforeEach(async () => { snap = await takeSnapshot(); });
  afterEach(async () => { await snap.restore(); });

  async function setup({ fee = FEE } = {}) {
    const [admin, alice, bob, treasury, stranger] = await ethers.getSigners();
    const L = await ethers.getContractFactory("ReefLocker");
    const locker = await L.deploy(admin.address, treasury.address, fee);
    const lp = await (await ethers.getContractFactory("MockERC20")).deploy("Reef LP", "REEF-LP", 0n);
    await lp.mint(alice.address, 1_000n * E18);
    await lp.connect(alice).approve(await locker.getAddress(), ethers.MaxUint256);
    return { admin, alice, bob, treasury, stranger, L, locker, lp };
  }
  const inDays = async (d) => BigInt((await time.latest()) + d * DAY);

  // ------------------------------------------------------------ creating locks

  it("locks tokens, records the lock and pays the fee to the fee recipient", async () => {
    const { locker, lp, alice, treasury } = await setup();
    const until = await inDays(90);
    const before = await ethers.provider.getBalance(treasury.address);
    await expect(locker.connect(alice).lock(await lp.getAddress(), 500n * E18, until, alice.address, { value: FEE }))
      .to.emit(locker, "Locked").withArgs(0n, await lp.getAddress(), alice.address, 500n * E18, until);
    const l = await locker.getLock(0);
    expect(l.owner).to.equal(alice.address);
    expect(l.amount).to.equal(500n * E18);
    expect(l.unlockTime).to.equal(until);
    expect(l.withdrawn).to.equal(false);
    expect(await lp.balanceOf(await locker.getAddress())).to.equal(500n * E18);
    expect(await locker.totalLocked(await lp.getAddress())).to.equal(500n * E18);
    expect(await ethers.provider.getBalance(treasury.address) - before).to.equal(FEE);
    expect(await locker.locksForToken(await lp.getAddress())).to.deep.equal([0n]);
    expect(await locker.locksForOwner(alice.address)).to.deep.equal([0n]);
  });

  it("can lock on behalf of another owner (e.g. a multisig)", async () => {
    const { locker, lp, alice, bob } = await setup();
    await locker.connect(alice).lock(await lp.getAddress(), 1n * E18, await inDays(31), bob.address, { value: FEE });
    expect((await locker.getLock(0)).owner).to.equal(bob.address);
  });

  it("requires exactly the fee", async () => {
    const { locker, lp, alice } = await setup();
    const until = await inDays(60);
    await expect(locker.connect(alice).lock(await lp.getAddress(), E18, until, alice.address, { value: FEE - 1n })).to.be.revertedWithCustomError(locker, "WrongFee");
    await expect(locker.connect(alice).lock(await lp.getAddress(), E18, until, alice.address, { value: FEE + 1n })).to.be.revertedWithCustomError(locker, "WrongFee");
  });

  it("works with a zero fee", async () => {
    const { locker, lp, alice } = await setup({ fee: 0n });
    await locker.connect(alice).lock(await lp.getAddress(), E18, await inDays(30) + 60n, alice.address);
    expect(await locker.lockCount()).to.equal(1n);
  });

  it("enforces 30 days minimum and 10 years maximum", async () => {
    const { locker, lp, alice } = await setup();
    const a = await lp.getAddress();
    await expect(locker.connect(alice).lock(a, E18, await inDays(29), alice.address, { value: FEE })).to.be.revertedWithCustomError(locker, "BadUnlockTime");
    await expect(locker.connect(alice).lock(a, E18, await inDays(3651), alice.address, { value: FEE })).to.be.revertedWithCustomError(locker, "BadUnlockTime");
    await expect(locker.connect(alice).lock(a, E18, await inDays(3649), alice.address, { value: FEE })).to.emit(locker, "Locked");
  });

  it("rejects zero amounts and zero addresses", async () => {
    const { locker, lp, alice } = await setup();
    const until = await inDays(60);
    await expect(locker.connect(alice).lock(await lp.getAddress(), 0n, until, alice.address, { value: FEE })).to.be.revertedWithCustomError(locker, "ZeroAmount");
    await expect(locker.connect(alice).lock(ethers.ZeroAddress, E18, until, alice.address, { value: FEE })).to.be.revertedWithCustomError(locker, "ZeroAddress");
    await expect(locker.connect(alice).lock(await lp.getAddress(), E18, until, ethers.ZeroAddress, { value: FEE })).to.be.revertedWithCustomError(locker, "ZeroAddress");
  });

  it("credits a fee-on-transfer token with what actually arrived", async () => {
    const { locker, alice } = await setup();
    const fee = await (await ethers.getContractFactory("MockFeeToken")).deploy();
    await fee.mint(alice.address, 1000n * E18);
    await fee.connect(alice).approve(await locker.getAddress(), ethers.MaxUint256);
    await locker.connect(alice).lock(await fee.getAddress(), 100n * E18, await inDays(60), alice.address, { value: FEE });
    expect((await locker.getLock(0)).amount).to.equal(99n * E18);
    expect(await locker.totalLocked(await fee.getAddress())).to.equal(99n * E18);
    expect(await fee.balanceOf(await locker.getAddress())).to.equal(99n * E18);
  });

  it("reverts, keeping nothing, if the fee recipient refuses BDAG", async () => {
    const [admin, alice] = await ethers.getSigners();
    const reject = await (await ethers.getContractFactory("MockRejectBDAG")).deploy();
    const locker = await (await ethers.getContractFactory("ReefLocker")).deploy(admin.address, await reject.getAddress(), FEE);
    const lp = await (await ethers.getContractFactory("MockERC20")).deploy("LP", "LP", 0n);
    await lp.mint(alice.address, E18);
    await lp.connect(alice).approve(await locker.getAddress(), E18);
    await expect(locker.connect(alice).lock(await lp.getAddress(), E18, await inDays(60), alice.address, { value: FEE })).to.be.revertedWithCustomError(locker, "FeeTransferFailed");
    expect(await lp.balanceOf(alice.address)).to.equal(E18);
    expect(await locker.lockCount()).to.equal(0n);
  });

  // ------------------------------------------------------------ withdrawing

  it("nobody can withdraw before the unlock date, not even the owner", async () => {
    const { locker, lp, alice, admin } = await setup();
    await locker.connect(alice).lock(await lp.getAddress(), 10n * E18, await inDays(90), alice.address, { value: FEE });
    await time.increase(89 * DAY);
    await expect(locker.connect(alice).withdraw(0)).to.be.revertedWithCustomError(locker, "StillLocked");
    await expect(locker.connect(admin).withdraw(0)).to.be.revertedWithCustomError(locker, "NotLockOwner");
  });

  it("the owner withdraws after the unlock date, once", async () => {
    const { locker, lp, alice } = await setup();
    await locker.connect(alice).lock(await lp.getAddress(), 10n * E18, await inDays(90), alice.address, { value: FEE });
    await time.increase(90 * DAY);
    await expect(locker.connect(alice).withdraw(0)).to.emit(locker, "Withdrawn").withArgs(0n, alice.address, 10n * E18);
    expect(await lp.balanceOf(alice.address)).to.equal(1_000n * E18);
    expect(await locker.totalLocked(await lp.getAddress())).to.equal(0n);
    await expect(locker.connect(alice).withdraw(0)).to.be.revertedWithCustomError(locker, "AlreadyWithdrawn");
  });

  it("only the lock owner can withdraw, even after the date", async () => {
    const { locker, lp, alice, stranger, admin } = await setup();
    await locker.connect(alice).lock(await lp.getAddress(), 10n * E18, await inDays(30) + 10n, alice.address, { value: FEE });
    await time.increase(31 * DAY);
    await expect(locker.connect(stranger).withdraw(0)).to.be.revertedWithCustomError(locker, "NotLockOwner");
    await expect(locker.connect(admin).withdraw(0)).to.be.revertedWithCustomError(locker, "NotLockOwner");
  });

  it("one lock can't touch another lock's tokens", async () => {
    const { locker, lp, alice, bob } = await setup();
    await lp.mint(bob.address, 100n * E18);
    await lp.connect(bob).approve(await locker.getAddress(), ethers.MaxUint256);
    await locker.connect(alice).lock(await lp.getAddress(), 10n * E18, await inDays(30) + 10n, alice.address, { value: FEE });
    await locker.connect(bob).lock(await lp.getAddress(), 50n * E18, await inDays(365), bob.address, { value: FEE });
    await time.increase(31 * DAY);
    await locker.connect(alice).withdraw(0);
    expect(await lp.balanceOf(await locker.getAddress())).to.equal(50n * E18);
    expect(await locker.totalLocked(await lp.getAddress())).to.equal(50n * E18);
    await expect(locker.connect(alice).withdraw(1)).to.be.revertedWithCustomError(locker, "NotLockOwner");
  });

  it("withdraw can't be re-entered by a malicious token", async () => {
    const { locker, alice } = await setup();
    const evil = await (await ethers.getContractFactory("MockReentrantToken")).deploy();
    await evil.mint(alice.address, 100n * E18);
    await evil.connect(alice).approve(await locker.getAddress(), ethers.MaxUint256);
    await locker.connect(alice).lock(await evil.getAddress(), 10n * E18, await inDays(31), alice.address, { value: FEE });
    await locker.connect(alice).lock(await evil.getAddress(), 10n * E18, await inDays(31), alice.address, { value: FEE });
    await time.increase(32 * DAY);
    await evil.arm(await locker.getAddress(), 1);
    await expect(locker.connect(alice).withdraw(0)).to.be.reverted;
    expect((await locker.getLock(0)).withdrawn).to.equal(false);
    expect((await locker.getLock(1)).withdrawn).to.equal(false);
  });

  it("unknown lock ids revert", async () => {
    const { locker, alice } = await setup();
    await expect(locker.connect(alice).withdraw(7)).to.be.revertedWithCustomError(locker, "NoSuchLock");
    await expect(locker.getLock(0)).to.be.revertedWithCustomError(locker, "NoSuchLock");
  });

  // ------------------------------------------------------------ extend and hand over

  it("the owner can extend a lock, never shorten it", async () => {
    const { locker, lp, alice, stranger } = await setup();
    const until = await inDays(60);
    await locker.connect(alice).lock(await lp.getAddress(), E18, until, alice.address, { value: FEE });
    await expect(locker.connect(alice).extend(0, until - 1n)).to.be.revertedWithCustomError(locker, "BadUnlockTime");
    await expect(locker.connect(alice).extend(0, until)).to.be.revertedWithCustomError(locker, "BadUnlockTime");
    await expect(locker.connect(stranger).extend(0, until + 100n)).to.be.revertedWithCustomError(locker, "NotLockOwner");
    await expect(locker.connect(alice).extend(0, until + 30n * BigInt(DAY))).to.emit(locker, "Extended").withArgs(0n, until, until + 30n * BigInt(DAY));
    await time.increase(61 * DAY);
    await expect(locker.connect(alice).withdraw(0)).to.be.revertedWithCustomError(locker, "StillLocked");
  });

  it("extending is capped at 10 years from now", async () => {
    const { locker, lp, alice } = await setup();
    await locker.connect(alice).lock(await lp.getAddress(), E18, await inDays(60), alice.address, { value: FEE });
    await expect(locker.connect(alice).extend(0, await inDays(3651))).to.be.revertedWithCustomError(locker, "BadUnlockTime");
  });

  it("the owner can hand the lock to someone else, who then controls it", async () => {
    const { locker, lp, alice, bob } = await setup();
    await locker.connect(alice).lock(await lp.getAddress(), 5n * E18, await inDays(31), alice.address, { value: FEE });
    await expect(locker.connect(bob).transferLockOwnership(0, bob.address)).to.be.revertedWithCustomError(locker, "NotLockOwner");
    await expect(locker.connect(alice).transferLockOwnership(0, ethers.ZeroAddress)).to.be.revertedWithCustomError(locker, "ZeroAddress");
    await expect(locker.connect(alice).transferLockOwnership(0, bob.address)).to.emit(locker, "LockOwnerChanged").withArgs(0n, alice.address, bob.address);
    expect(await locker.locksForOwner(bob.address)).to.deep.equal([0n]);
    await time.increase(32 * DAY);
    await expect(locker.connect(alice).withdraw(0)).to.be.revertedWithCustomError(locker, "NotLockOwner");
    await locker.connect(bob).withdraw(0);
    expect(await lp.balanceOf(bob.address)).to.equal(5n * E18);
  });

  it("a withdrawn lock can't be extended or handed over", async () => {
    const { locker, lp, alice, bob } = await setup();
    await locker.connect(alice).lock(await lp.getAddress(), E18, await inDays(31), alice.address, { value: FEE });
    await time.increase(32 * DAY);
    await locker.connect(alice).withdraw(0);
    await expect(locker.connect(alice).extend(0, await inDays(60))).to.be.revertedWithCustomError(locker, "AlreadyWithdrawn");
    await expect(locker.connect(alice).transferLockOwnership(0, bob.address)).to.be.revertedWithCustomError(locker, "AlreadyWithdrawn");
  });

  // ------------------------------------------------------------ labels view

  it("lockedSummary reports open amount, earliest unlock and count", async () => {
    const { locker, lp, alice } = await setup();
    const a = await lp.getAddress();
    const t1 = await inDays(31), t2 = await inDays(400);
    await locker.connect(alice).lock(a, 10n * E18, t2, alice.address, { value: FEE });
    await locker.connect(alice).lock(a, 20n * E18, t1, alice.address, { value: FEE });
    let s = await locker.lockedSummary(a);
    expect(s.amount).to.equal(30n * E18);
    expect(s.earliestUnlock).to.equal(t1);
    expect(s.openLocks).to.equal(2n);
    await time.increase(32 * DAY);
    await locker.connect(alice).withdraw(1);
    s = await locker.lockedSummary(a);
    expect(s.amount).to.equal(10n * E18);
    expect(s.earliestUnlock).to.equal(t2);
    expect(s.openLocks).to.equal(1n);
  });

  // ------------------------------------------------------------ admin can only touch the fee

  it("only the admin sets the fee (capped) and the recipient", async () => {
    const { locker, admin, stranger, bob } = await setup();
    await expect(locker.connect(stranger).setFee(1n)).to.be.revertedWithCustomError(locker, "NotAdmin");
    await expect(locker.connect(stranger).setFeeRecipient(bob.address)).to.be.revertedWithCustomError(locker, "NotAdmin");
    await expect(locker.connect(admin).setFee(10_001n * E18)).to.be.revertedWithCustomError(locker, "FeeTooHigh");
    await expect(locker.connect(admin).setFee(50n * E18)).to.emit(locker, "FeeChanged").withArgs(50n * E18);
    await expect(locker.connect(admin).setFeeRecipient(ethers.ZeroAddress)).to.be.revertedWithCustomError(locker, "ZeroAddress");
    await locker.connect(admin).setFeeRecipient(bob.address);
    expect(await locker.feeRecipient()).to.equal(bob.address);
  });

  it("admin handover takes two steps", async () => {
    const { locker, admin, bob, stranger } = await setup();
    await locker.connect(admin).transferAdmin(bob.address);
    expect(await locker.admin()).to.equal(admin.address);
    await expect(locker.connect(stranger).acceptAdmin()).to.be.revertedWithCustomError(locker, "NotAdmin");
    await expect(locker.connect(bob).acceptAdmin()).to.emit(locker, "AdminChanged").withArgs(bob.address);
    expect(await locker.admin()).to.equal(bob.address);
    expect(await locker.pendingAdmin()).to.equal(ethers.ZeroAddress);
  });

  it("the constructor rejects zero addresses and a fee over the cap", async () => {
    const [a] = await ethers.getSigners();
    const L = await ethers.getContractFactory("ReefLocker");
    await expect(L.deploy(ethers.ZeroAddress, a.address, 0n)).to.be.revertedWithCustomError(L, "ZeroAddress");
    await expect(L.deploy(a.address, ethers.ZeroAddress, 0n)).to.be.revertedWithCustomError(L, "ZeroAddress");
    await expect(L.deploy(a.address, a.address, 10_001n * E18)).to.be.revertedWithCustomError(L, "FeeTooHigh");
  });
});
