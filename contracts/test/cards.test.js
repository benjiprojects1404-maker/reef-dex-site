const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, mine } = require("@nomicfoundation/hardhat-network-helpers");

const E = (n) => ethers.parseEther(String(n));
const DEAD = "0x000000000000000000000000000000000000dEaD";

async function setup({ price = E(100_000), revealIn = 30 * 86400 } = {}) {
  const [deployer, alice, bob, carol] = await ethers.getSigners();
  for (const s of [deployer, alice, bob, carol]) await ethers.provider.send("hardhat_setBalance", [s.address, "0x" + E(5_000_000).toString(16)]);
  const wbdag = await (await ethers.getContractFactory("contracts/reef/WBDAG.sol:WBDAG")).deploy();
  const factory = await (await ethers.getContractFactory("ReefFactory")).deploy(deployer.address);
  await factory.setFeeTo(deployer.address);
  const router = await (await ethers.getContractFactory("ReefRouter")).deploy(await factory.getAddress(), await wbdag.getAddress());
  const Mock = await ethers.getContractFactory("MockERC20");
  const cooked = await Mock.deploy("Cooked", "COOKED", E(1_000_000_000));
  const nocap = await Mock.deploy("NoCap", "NOCAP", E(1_000_000_000));
  const dl = BigInt((await ethers.provider.getBlock("latest")).timestamp) + 10n ** 6n;
  // pools sized like the live ones: COOKED 369.2M / 181k BDAG, NOCAP 919.9M / 10,003 BDAG
  for (const [t, amt, bdag] of [[cooked, E(369_200_000), E(181_000)], [nocap, E(919_900_000), E(10_003)]]) {
    await t.approve(await router.getAddress(), amt);
    await router.addLiquidityBDAG(await t.getAddress(), amt, 0, 0, deployer.address, dl, { value: bdag });
  }
  const roy = await (await ethers.getContractFactory("CardRoyaltyRouter")).deploy(
    await router.getAddress(), await factory.getAddress(), await wbdag.getAddress(),
    await cooked.getAddress(), await nocap.getAddress(), E(1));
  const now = BigInt((await ethers.provider.getBlock("latest")).timestamp);
  const provenance = ethers.keccak256(ethers.toUtf8Bytes("card list v1"));
  const cards = await (await ethers.getContractFactory("ReefCards")).deploy({
    router: await router.getAddress(), factory: await factory.getAddress(), wbdag: await wbdag.getAddress(),
    cooked: await cooked.getAddress(), nocap: await nocap.getAddress(), price, provenance,
    revealAfter: now + BigInt(revealIn), royaltyReceiver: await roy.getAddress(), baseURI: "ipfs://cards/" });
  await cards.setSaleOpen(true);
  const pairOf = async (t) => ethers.getContractAt("ReefPair", await factory.getPair(await t.getAddress(), await wbdag.getAddress()));
  return { deployer, alice, bob, carol, wbdag, factory, router, cooked, nocap, cards, roy, pairOf, price, dl };
}

async function poolState(pair, wbdag) {
  const [r0, r1] = await pair.getReserves();
  const wIs0 = (await pair.token0()) === (await wbdag.getAddress());
  const b = wIs0 ? r0 : r1, t = wIs0 ? r1 : r0;
  return { b, t, price: (b * 10n ** 18n) / t, dead: await pair.balanceOf(DEAD) };
}

describe("ReefCards", function () {
  it("a 100k BDAG NOCAP mint puts all of it into the NOCAP pool and burns the LP", async () => {
    const { alice, cards, nocap, wbdag, pairOf, price, dl } = await setup();
    const pair = await pairOf(nocap);
    const before = await poolState(pair, wbdag);
    await expect(cards.connect(alice).mint(1, 0, dl, { value: price })).to.emit(cards, "CardMinted");
    const after = await poolState(pair, wbdag);
    expect(await cards.ownerOf(76)).to.equal(alice.address);
    const dust = await ethers.provider.getBalance(await cards.getAddress());
    expect(after.b - before.b + dust).to.equal(price);      // every BDAG is in the pool or pool-bound dust
    expect(dust).to.be.lt(E(0.001));
    expect(after.dead).to.be.gt(before.dead);                // LP burned
    const left = await nocap.balanceOf(await cards.getAddress());
    expect(left * 10_000n).to.be.lt(after.t);                // leftover token dust < 0.01% of pool
    const ratio = Number(after.price) / Number(before.price);
    expect(ratio).to.be.gt(9).and.lt(13);                    // ~11x on the first NOCAP mint
  });

  it("a COOKED mint moves the COOKED price far less", async () => {
    const { alice, cards, cooked, wbdag, pairOf, price, dl } = await setup();
    const pair = await pairOf(cooked);
    const before = await poolState(pair, wbdag);
    await cards.connect(alice).mint(0, 0, dl, { value: price });
    const after = await poolState(pair, wbdag);
    expect(await cards.ownerOf(1)).to.equal(alice.address);
    const dust = await ethers.provider.getBalance(await cards.getAddress());
    expect(after.b - before.b + dust).to.equal(price);
    expect(Number(after.price) / Number(before.price)).to.be.lt(1.6);
  });

  it("enforces price, sale switch, brand and the 2-per-wallet limit", async () => {
    const { alice, cards, price, dl } = await setup();
    await expect(cards.connect(alice).mint(0, 0, dl, { value: price - 1n })).to.be.revertedWith("wrong price");
    await expect(cards.connect(alice).mint(2, 0, dl, { value: price })).to.be.revertedWith("bad brand");
    await cards.setSaleOpen(false);
    await expect(cards.connect(alice).mint(0, 0, dl, { value: price })).to.be.revertedWith("sale closed");
    await cards.setSaleOpen(true);
    await cards.connect(alice).mint(0, 0, dl, { value: price });
    await cards.connect(alice).mint(1, 0, dl, { value: price });
    await expect(cards.connect(alice).mint(0, 0, dl, { value: price })).to.be.revertedWith("wallet limit");
  });

  it("reverts the whole mint if the swap would come out worse than the quoted minimum", async () => {
    const { alice, cards, nocap, wbdag, pairOf, price, dl } = await setup();
    const pair = await pairOf(nocap);
    const before = await poolState(pair, wbdag);
    await expect(cards.connect(alice).mint(1, E(10n ** 12n), dl, { value: price })).to.be.revertedWith("ReefRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    const after = await poolState(pair, wbdag);
    expect(after.b).to.equal(before.b);
    expect(await cards.totalMinted()).to.equal(0n);
  });

  it("only owner can run admin functions; there is no way to withdraw", async () => {
    const { alice, cards } = await setup();
    await expect(cards.connect(alice).setSaleOpen(false)).to.be.revertedWithCustomError(cards, "OwnableUnauthorizedAccount");
    await expect(cards.connect(alice).setBaseURI("x")).to.be.revertedWithCustomError(cards, "OwnableUnauthorizedAccount");
    const fns = cards.interface.fragments.filter((f) => f.type === "function").map((f) => f.name);
    expect(fns.some((n) => /withdraw|rescue|transferBDAG/i.test(n))).to.equal(false);
  });

  it("sells out at 75 per brand, then reveals a fair permutation", async function () {
    this.timeout(300000);
    const { deployer, cards, price, dl } = await setup({ price: E(10) });
    expect(await cards.tokenURI(1).catch(() => "none")).to.equal("none");
    const wallets = [];
    for (let i = 0; i < 75; i++) {
      const w = ethers.Wallet.createRandom().connect(ethers.provider);
      await deployer.sendTransaction({ to: w.address, value: E(25) });
      wallets.push(w);
    }
    for (const w of wallets) {
      await cards.connect(w).mint(0, 0, dl, { value: price });
      await cards.connect(w).mint(1, 0, dl, { value: price });
    }
    expect(await cards.totalMinted()).to.equal(150n);
    await expect(cards.connect(deployer).mint(0, 0, dl, { value: price })).to.be.revertedWith("sold out");
    expect(await cards.tokenURI(5)).to.equal("ipfs://cards/cooked-hidden.json");
    expect(await cards.tokenURI(100)).to.equal("ipfs://cards/nocap-hidden.json");
    expect(await cards.startingIndexBlock()).to.not.equal(0n);
    await expect(cards.freezeMetadata()).to.be.revertedWith("reveal first");
    await mine(1);
    await cards.connect(wallets[3]).reveal();          // anyone can reveal
    const seen = new Set();
    for (let id = 1; id <= 150; id++) {
      const c = Number(await cards.cardOf(id));
      if (id <= 75) expect(c).to.be.within(1, 75); else expect(c).to.be.within(76, 150);
      seen.add(c);
    }
    expect(seen.size).to.equal(150);                   // each card exactly once
    const c1 = await cards.cardOf(1);
    expect(await cards.tokenURI(1)).to.equal(`ipfs://cards/${c1}.json`);
    await cards.freezeMetadata();
    await expect(cards.setBaseURI("x")).to.be.revertedWith("frozen");
  });

  it("reveal can be triggered after revealAfter even if not sold out", async () => {
    const { alice, cards, price, dl } = await setup({ revealIn: 3600 });
    await cards.connect(alice).mint(0, 0, dl, { value: price });
    await expect(cards.reveal()).to.be.revertedWith("not ready");
    await expect(cards.setStartingIndexBlock()).to.be.revertedWith("too early");
    await time.increase(3601);
    await cards.connect(alice).setStartingIndexBlock();
    await mine(1);
    await cards.reveal();
    await expect(cards.reveal()).to.be.revertedWith("already revealed");
    expect(Number(await cards.cardOf(1))).to.be.within(1, 75);
  });

  it("5% royalty goes to the router, which adds it to both pools and burns the LP", async () => {
    const { deployer, cards, roy, wbdag, cooked, nocap, pairOf, dl } = await setup();
    const [recv, amt] = await cards.royaltyInfo(1, E(1000));
    expect(recv).to.equal(await roy.getAddress());
    expect(amt).to.equal(E(50));
    await deployer.sendTransaction({ to: await roy.getAddress(), value: E(30) });
    await wbdag.deposit({ value: E(20) });
    await wbdag.transfer(await roy.getAddress(), E(20));          // royalties paid in WBDAG are handled too
    const pc = await pairOf(cooked), pn = await pairOf(nocap);
    const bc = await poolState(pc, wbdag), bn = await poolState(pn, wbdag);
    await roy.flush(0, 0, dl);
    const ac = await poolState(pc, wbdag), an = await poolState(pn, wbdag);
    const dust = await ethers.provider.getBalance(await roy.getAddress());
    expect(ac.b - bc.b + (an.b - bn.b) + dust).to.equal(E(50));
    expect(dust).to.be.lt(E(0.001));
    expect(ac.dead).to.be.gt(bc.dead);
    expect(an.dead).to.be.gt(bn.dead);
    await expect(roy.flush(0, 0, dl)).to.be.revertedWith("below minimum");
  });
});
