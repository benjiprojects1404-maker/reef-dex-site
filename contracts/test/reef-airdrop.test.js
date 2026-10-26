const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");
const { StandardMerkleTree } = require("@openzeppelin/merkle-tree");
const { RULES, tierOf, allocate } = require("../scripts/airdrop/rules");

const E18 = 10n ** 18n;
const DEAD = "0x000000000000000000000000000000000000dEaD";
const addr = (i) => "0x" + (i + 1).toString(16).padStart(40, "0");
const swap = (w, block, bdag, logIndex = 0) => ({ wallet: w, block, logIndex, tx: `0xs${block}${logIndex}`, kind: "swap", bdag });
const mint = (w, block, bdag, o = {}) => ({ wallet: w, block, logIndex: 0, tx: `0xm${block}`, kind: "mint", bdag, firstMintOfPair: false, firstPairOfToken: false, walletDeployedToken: false, ...o });

describe("REEF airdrop rules", () => {
  it("tiers follow the published minimums, with the 0.001 BDAG tolerance", () => {
    const tol = RULES.tolerance;
    expect(tierOf(swap("a", 1, 1000n * E18)).tier).to.equal(1);
    expect(tierOf(swap("a", 1, 1000n * E18 - tol)).tier).to.equal(1);
    expect(tierOf(swap("a", 1, 1000n * E18 - tol - 1n)).tier).to.equal(0);
    expect(tierOf(mint("a", 1, 5000n * E18 - tol)).tier).to.equal(2);
    expect(tierOf(mint("a", 1, 4999n * E18)).tier).to.equal(0);
  });

  it("Tier 3 needs the pair's first liquidity, the token's first pair, 25,000 BDAG and the deployer", () => {
    const launch = { firstMintOfPair: true, firstPairOfToken: true, walletDeployedToken: true };
    expect(tierOf(mint("a", 1, 25000n * E18, launch)).tier).to.equal(3);
    expect(tierOf(mint("a", 1, 25000n * E18, { ...launch, walletDeployedToken: false })).tier).to.equal(2);
    expect(tierOf(mint("a", 1, 25000n * E18, { ...launch, firstMintOfPair: false })).tier).to.equal(2);
    expect(tierOf(mint("a", 1, 25000n * E18, { ...launch, firstPairOfToken: false })).tier).to.equal(2);
    expect(tierOf(mint("a", 1, 24000n * E18, launch)).tier).to.equal(2);
    const unknown = tierOf(mint("a", 1, 25000n * E18, { ...launch, walletDeployedToken: null }));
    expect(unknown.tier).to.equal(2);
    expect(unknown.review).to.be.a("string");
  });

  it("ranks by first qualifying action, keeps each wallet's highest tier, and excludes team wallets", () => {
    const acts = [
      swap("0xB", 10, 500n * E18), // below minimum: does not set B's place
      swap("0xA", 11, 1000n * E18),
      swap("0xB", 12, 1000n * E18),
      mint("0xA", 20, 6000n * E18), // A upgrades to Tier 2 but keeps its place
      swap("0xTEAM", 5, 9000n * E18),
    ];
    const r = allocate(acts, new Set(["0xteam"]));
    expect(r.entries.map((e) => [e.wallet, e.tier])).to.deep.equal([["0xa", 2], ["0xb", 1]]);
    expect(r.excludedHits).to.deep.equal(["0xteam"]);
    expect(r.perShare).to.equal(RULES.perShareCap); // few shares: capped at 2,100 per share
    expect(r.entries[0].amount).to.equal(3n * 2100n * E18);
    expect(r.unallocated).to.equal(RULES.pot - 4n * 2100n * E18);
  });

  it("caps the list at 1,000 wallets and never pays out more than the pot", () => {
    const acts = [];
    for (let i = 0; i < 1200; i++) acts.push(i % 3 === 0 ? mint(addr(i), i + 1, 5000n * E18) : swap(addr(i), i + 1, 1000n * E18));
    const r = allocate(acts);
    expect(r.entries.length).to.equal(1000);
    expect(r.qualifiedWallets).to.equal(1200);
    expect(r.entries[999].wallet).to.equal(addr(999).toLowerCase());
    expect(r.totalAllocated <= RULES.pot).to.equal(true);
    expect(r.perShare < RULES.perShareCap).to.equal(true); // many shares: the pot is split
    expect(r.entries.every((e) => e.amount === e.shares * r.perShare)).to.equal(true);
  });

  it("1,000 Tier-1 wallets get 2,100 REEF each", () => {
    const acts = Array.from({ length: 1000 }, (_, i) => swap(addr(i), i + 1, 1000n * E18));
    const r = allocate(acts);
    expect(r.perShare).to.equal(2100n * E18);
    expect(r.totalAllocated).to.equal(RULES.pot);
  });
});

describe("ReefAirdrop", () => {
  async function deploy() {
    const [deployer, alice, bob, carol, helper] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Reef", "REEF", 0);
    const presale = await (await ethers.getContractFactory("MockPresaleState")).deploy();
    const list = [[alice.address, (2100n * E18).toString()], [bob.address, (6300n * E18).toString()]];
    const tree = StandardMerkleTree.of(list, ["address", "uint256"]);
    const total = 8400n * E18;
    const deadline = (await time.latest()) + 30 * 86400;
    const drop = await (await ethers.getContractFactory("ReefAirdrop")).deploy(await token.getAddress(), await presale.getAddress(), tree.root, total, deadline);
    await token.mint(await drop.getAddress(), 2_100_000n * E18);
    const proof = (i) => tree.getProof(i);
    return { token, presale, drop, tree, alice, bob, carol, helper, deadline, proof };
  }

  it("matches OpenZeppelin's StandardMerkleTree leaves", async () => {
    const { drop, alice, proof } = await deploy();
    expect(await drop.isValid(alice.address, 2100n * E18, proof(0))).to.equal(true);
    expect(await drop.isValid(alice.address, 2101n * E18, proof(0))).to.equal(false);
  });

  it("stays shut until the pool is live", async () => {
    const { drop, alice, proof } = await deploy();
    expect(await drop.claimsOpen()).to.equal(false);
    await expect(drop.claim(alice.address, 2100n * E18, proof(0))).to.be.revertedWith("pool not live yet");
  });

  it("pays each listed wallet once, to itself, even when someone else submits", async () => {
    const { drop, token, presale, alice, helper, proof } = await deploy();
    await presale.setFinalized(true);
    await expect(drop.connect(helper).claim(alice.address, 2100n * E18, proof(0))).to.emit(drop, "Claimed").withArgs(alice.address, 2100n * E18);
    expect(await token.balanceOf(alice.address)).to.equal(2100n * E18);
    expect(await token.balanceOf(helper.address)).to.equal(0n);
    await expect(drop.claim(alice.address, 2100n * E18, proof(0))).to.be.revertedWith("already claimed");
  });

  it("rejects wallets, amounts and proofs that are not on the list", async () => {
    const { drop, presale, alice, bob, carol, proof } = await deploy();
    await presale.setFinalized(true);
    await expect(drop.claim(carol.address, 2100n * E18, proof(0))).to.be.revertedWith("not on the list");
    await expect(drop.claim(alice.address, 6300n * E18, proof(1))).to.be.revertedWith("not on the list");
    await expect(drop.claim(bob.address, 6300n * E18, proof(0))).to.be.revertedWith("not on the list");
  });

  it("burns only the REEF nobody on the list can claim, and only to the dead address", async () => {
    const { drop, token, presale, alice, bob, proof } = await deploy();
    await drop.burnUnallocated();
    expect(await token.balanceOf(DEAD)).to.equal(2_100_000n * E18 - 8400n * E18);
    expect(await token.balanceOf(await drop.getAddress())).to.equal(8400n * E18);
    await expect(drop.burnUnallocated()).to.be.revertedWith("nothing to burn");
    await presale.setFinalized(true);
    await drop.claim(alice.address, 2100n * E18, proof(0));
    await drop.claim(bob.address, 6300n * E18, proof(1));
    expect(await token.balanceOf(await drop.getAddress())).to.equal(0n);
  });

  it("closes at the deadline and then sends everything left to the dead address", async () => {
    const { drop, token, presale, alice, bob, deadline, proof } = await deploy();
    await presale.setFinalized(true);
    await drop.claim(alice.address, 2100n * E18, proof(0));
    await expect(drop.burnExpired()).to.be.revertedWith("claims still open");
    await time.increaseTo(deadline);
    expect(await drop.claimsOpen()).to.equal(false);
    await expect(drop.claim(bob.address, 6300n * E18, proof(1))).to.be.revertedWith("claims closed");
    const left = await token.balanceOf(await drop.getAddress());
    await expect(drop.burnExpired()).to.emit(drop, "Burned").withArgs(left, true);
    expect(await token.balanceOf(DEAD)).to.equal(left);
    expect(await token.balanceOf(await drop.getAddress())).to.equal(0n);
  });

  it("rejects bad constructor input", async () => {
    const F = await ethers.getContractFactory("ReefAirdrop");
    const now = await time.latest();
    const t = "0x0000000000000000000000000000000000000001";
    await expect(F.deploy(ethers.ZeroAddress, t, ethers.ZeroHash.replace(/0$/, "1"), 1, now + 100)).to.be.revertedWith("zero address");
    await expect(F.deploy(t, t, ethers.ZeroHash, 1, now + 100)).to.be.revertedWith("empty root");
    await expect(F.deploy(t, t, ethers.ZeroHash.replace(/0$/, "1"), 0, now + 100)).to.be.revertedWith("nothing allocated");
    await expect(F.deploy(t, t, ethers.ZeroHash.replace(/0$/, "1"), 1, now)).to.be.revertedWith("deadline passed");
  });
});
