const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const E18 = 10n ** 18n;
const DEAD = "0x000000000000000000000000000000000000dEaD";
const DAY = 86400n;

describe("ReefLaunchSale (launchpad v2)", () => {
  let owner, project, lpBen, treasury, a, b, c, wbdag, factory, router, reefBond;
  const BOND = 1_000n * E18;

  beforeEach(async () => {
    [owner, project, lpBen, treasury, a, b, c] = await ethers.getSigners();
    for (const s of [project, a, b, c]) await ethers.provider.send("hardhat_setBalance", [s.address, "0x" + (10n ** 25n).toString(16)]);
    wbdag = await (await ethers.getContractFactory("contracts/reef/WBDAG.sol:WBDAG")).deploy();
    factory = await (await ethers.getContractFactory("ReefFactory")).deploy(owner.address);
    router = await (await ethers.getContractFactory("ReefRouter")).deploy(await factory.getAddress(), await wbdag.getAddress());
    reefBond = await (await ethers.getContractFactory("MockLaunchToken")).connect(project).deploy("Reef", "REEF", 18, 100_000n * E18);
  });

  async function newToken(decimals = 18, supply = 10_000_000n) {
    return (await ethers.getContractFactory("MockLaunchToken")).connect(project).deploy("Launch", "LNCH", decimals, supply * 10n ** BigInt(decimals));
  }

  // Default sale: 100 BDAG per token, pool opens at 150, 2% fee, soft cap 200k, hard cap 1M, 400k per wallet.
  async function newSale(token, over = {}) {
    const now = BigInt(await time.latest());
    const cfg = {
      token: await token.getAddress(), router: await router.getAddress(), projectWallet: project.address,
      lpBeneficiary: lpBen.address, feeRecipient: treasury.address, feeBps: 200n,
      salePrice: 100n * E18, listingPrice: 150n * E18, softCap: 200_000n * E18, hardCap: 1_000_000n * E18,
      maxPerWallet: 400_000n * E18, startTime: now + 100n, endTime: now + 100n + 7n * DAY, lpLockSeconds: 365n * DAY,
      bondToken: await reefBond.getAddress(), bondAmount: BOND,
      reefToken: ethers.ZeroAddress, reefSliceBps: 0n, minReefDepth: 0n, ...over,
    };
    const sale = await (await ethers.getContractFactory("ReefLaunchSale")).deploy(cfg);
    return { sale, cfg };
  }

  async function fund(token, sale) {
    await token.connect(project).transfer(await sale.getAddress(), await sale.tokensRequired());
    if ((await sale.bondAmount()) > 0n) await reefBond.connect(project).transfer(await sale.getAddress(), await sale.bondAmount());
  }
  const pairOf = async (token) => ethers.getContractAt("ReefPair", await factory.getPair(await token.getAddress(), await wbdag.getAddress()));

  describe("settings", () => {
    it("rejects bad settings", async () => {
      const t = await newToken();
      const F = await ethers.getContractFactory("ReefLaunchSale");
      const bad = async (over, msg) => {
        const now = BigInt(await time.latest());
        const cfg = { token: await t.getAddress(), router: await router.getAddress(), projectWallet: project.address, lpBeneficiary: lpBen.address,
          feeRecipient: treasury.address, feeBps: 200n, salePrice: 100n * E18, listingPrice: 150n * E18, softCap: 1n, hardCap: 10n * E18 * 1000n,
          maxPerWallet: E18, startTime: now + 100n, endTime: now + 200n, lpLockSeconds: 180n * DAY,
          bondToken: await reefBond.getAddress(), bondAmount: BOND,
          reefToken: ethers.ZeroAddress, reefSliceBps: 0n, minReefDepth: 0n, ...over };
        await expect(F.deploy(cfg)).to.be.revertedWith(msg);
      };
      await bad({ feeBps: 301n }, "fee above 3%");
      await bad({ feeRecipient: ethers.ZeroAddress }, "fee recipient is zero address");
      await bad({ projectWallet: ethers.ZeroAddress }, "project wallet is zero address");
      await bad({ listingPrice: 99n * E18 }, "listing price below sale price");
      await bad({ softCap: 10n ** 30n }, "bad caps");
      await bad({ softCap: 0n }, "soft cap is zero");
      // a soft-cap raise this small couldn't open a pool (Reef locks the first 1,000 LP units)
      await bad({ softCap: 1_000n, salePrice: E18, listingPrice: E18 }, "soft cap too small to open a pool");
      await bad({ maxPerWallet: 0n }, "per-wallet cap is zero");
      await bad({ lpLockSeconds: 180n * DAY - 1n }, "LP lock must be at least 180 days");
      await bad({ startTime: 1n }, "start time is in the past");
      await bad({ salePrice: 10n ** 40n, listingPrice: 10n ** 40n }, "price too high for the cap");
      await bad({ bondToken: ethers.ZeroAddress }, "bond token is zero address");
      await bad({ bondToken: await t.getAddress() }, "bond token is the sale token");
      await bad({ reefToken: await reefBond.getAddress(), reefSliceBps: 5001n }, "REEF slice above 50%");
      await bad({ reefToken: await t.getAddress(), reefSliceBps: 2000n }, "bad REEF token");
      await bad({ reefToken: ethers.ZeroAddress, reefSliceBps: 2000n }, "bad REEF token");
    });

    it("publishes every term, and the 2% fee, in one call", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      const terms = await sale.terms();
      expect(terms.feeBps).to.equal(200n);
      expect(terms.hardCap).to.equal(cfg.hardCap);
      expect(terms.feeRecipient).to.equal(treasury.address);
      expect(terms.bondToken).to.equal(await reefBond.getAddress());
      expect(terms.bondAmount).to.equal(BOND);
      expect(await sale.MAX_FEE_BPS()).to.equal(300n);
      // 10,000 tokens for buyers + 980,000 BDAG / 150 for the pool
      expect(await sale.tokensRequired()).to.equal(10_000n * E18 + (980_000n * E18 * E18) / (150n * E18));
    });
  });

  describe("buying", () => {
    it("takes no BDAG until fully funded, and enforces the window and caps", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await expect(sale.connect(a).buy({ value: E18 })).to.be.revertedWith("sale not started");
      await time.increaseTo(cfg.startTime);
      await expect(sale.connect(a).buy({ value: E18 })).to.be.revertedWith("sale not funded");
      await t.connect(project).transfer(await sale.getAddress(), (await sale.tokensRequired()) - 1n);
      await expect(sale.connect(a).buy({ value: E18 })).to.be.revertedWith("sale not funded");
      await t.connect(project).transfer(await sale.getAddress(), 1n);
      await expect(sale.connect(a).buy({ value: E18 })).to.be.revertedWith("project bond not posted");
      await reefBond.connect(project).transfer(await sale.getAddress(), BOND);
      expect(await sale.isBonded()).to.equal(true);
      await expect(sale.connect(a).buy({ value: 0 })).to.be.revertedWith("send some BDAG");
      await sale.connect(a).buy({ value: 400_000n * E18 });
      await expect(sale.connect(a).buy({ value: 1n })).to.be.revertedWith("exceeds per-wallet cap");
      await sale.connect(b).buy({ value: 400_000n * E18 });
      await expect(sale.connect(c).buy({ value: 200_000n * E18 + 1n })).to.be.revertedWith("exceeds hard cap");
      await time.increaseTo(cfg.endTime + 1n);
      await expect(sale.connect(c).buy({ value: E18 })).to.be.revertedWith("sale ended");
    });
  });

  describe("finalize", () => {
    it("takes the 2% fee, seeds the pool at the listing price, burns the rest and locks the LP", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      await sale.connect(b).buy({ value: 150_000n * E18 });
      await expect(sale.finalize()).to.be.revertedWith("sale still running");
      await time.increaseTo(cfg.endTime + 1n);

      const deadBefore = await t.balanceOf(DEAD);
      const raised = 450_000n * E18, fee = 9_000n * E18, paired = raised - fee;
      const forPool = (paired * E18) / cfg.listingPrice, owed = (raised * E18) / cfg.salePrice;
      await expect(sale.connect(c).finalize()).to.emit(sale, "Finalized"); // anyone can call it

      expect(await wbdag.balanceOf(treasury.address)).to.equal(fee);
      const pair = await pairOf(t);
      const [r0, r1] = await pair.getReserves();
      const tokenIs0 = (await pair.token0()) === (await t.getAddress());
      expect(tokenIs0 ? r0 : r1).to.equal(forPool);
      expect(tokenIs0 ? r1 : r0).to.equal(paired);
      expect(await ethers.provider.getBalance(await sale.getAddress())).to.equal(0n);
      // only buyers' tokens stay; the unsold share and the unused pool tokens are burned
      expect(await t.balanceOf(await sale.getAddress())).to.equal(owed);
      expect((await t.balanceOf(DEAD)) - deadBefore).to.equal((await sale.tokensRequired()) - forPool - owed);
      expect(await pair.balanceOf(await sale.getAddress())).to.be.gt(0n);
      expect(await sale.lpUnlockTime()).to.equal(BigInt(await time.latest()) + cfg.lpLockSeconds);

      await expect(sale.finalize()).to.be.revertedWith("already finalized");
      await sale.connect(a).claim();
      await sale.connect(b).claim();
      expect(await t.balanceOf(a.address)).to.equal(3_000n * E18);
      expect(await t.balanceOf(b.address)).to.equal(1_500n * E18);
      await expect(sale.connect(a).claim()).to.be.revertedWith("already settled");
      await expect(sale.connect(c).claim()).to.be.revertedWith("nothing to claim");
      await expect(sale.connect(a).refund()).to.be.revertedWith("refunds not open");
      expect(await t.balanceOf(await sale.getAddress())).to.equal(0n);
    });

    it("can finalize early once the hard cap is reached, and the pool trades through the router", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t, { maxPerWallet: 1_000_000n * E18 });
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 1_000_000n * E18 });
      await sale.finalize();
      expect(await t.balanceOf(await sale.getAddress())).to.equal(10_000n * E18); // every sale token was sold
      const path = [await wbdag.getAddress(), await t.getAddress()];
      await router.connect(c).swapExactBDAGForTokens(0, path, c.address, BigInt(await time.latest()) + 600n, { value: 1_000n * E18 });
      expect(await t.balanceOf(c.address)).to.be.gt(0n);
    });

    it("works with 6-decimal tokens and fractional prices", async () => {
      const t = await newToken(6);
      // 0.25 BDAG per token in the sale, 0.4 at listing
      const { sale, cfg } = await newSale(t, { salePrice: E18 / 4n, listingPrice: (4n * E18) / 10n, softCap: E18, hardCap: 100_000n * E18 });
      await fund(t, sale);
      expect(await sale.tokensRequired()).to.equal(400_000n * 10n ** 6n + 245_000n * 10n ** 6n);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 10n * E18 + 3n }); // odd wei rounds down in the buyer's claim
      await time.increaseTo(cfg.endTime + 1n);
      await sale.finalize();
      await sale.connect(a).claim();
      expect(await t.balanceOf(a.address)).to.equal(40n * 10n ** 6n);
    });

    it("still launches if someone loaded the pair with dust or WBDAG first", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await factory.createPair(await t.getAddress(), await wbdag.getAddress());
      const pair = await pairOf(t);
      await wbdag.connect(c).deposit({ value: 5n * E18 });
      await wbdag.connect(c).transfer(await pair.getAddress(), 5n * E18);
      await t.connect(project).transfer(await pair.getAddress(), 1n * E18); // well under 1% of the pool tokens
      await pair.sync();
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      await time.increaseTo(cfg.endTime + 1n);
      await sale.finalize();
      expect(await sale.finalized()).to.equal(true);
    });

    it("refuses a pair that already has liquidity or is loaded with tokens, and refunds open later", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      await t.connect(project).approve(await router.getAddress(), ethers.MaxUint256);
      await router.connect(project).addLiquidityBDAG(await t.getAddress(), 100n * E18, 0, 0, project.address, BigInt(await time.latest()) + 600n, { value: 100n * E18 });
      await time.increaseTo(cfg.endTime + 1n);
      await expect(sale.finalize()).to.be.revertedWith("pool already has liquidity");
      expect(await sale.refundsOpen()).to.equal(false);
      await time.increaseTo(cfg.endTime + 7n * DAY + 1n);
      const before = await ethers.provider.getBalance(a.address);
      await sale.connect(a).refund();
      expect(await ethers.provider.getBalance(a.address)).to.be.gt(before + 299_999n * E18);
      await expect(sale.finalize()).to.be.revertedWith("refunds have started");
    });

    it("refuses a pair pre-loaded with more than 1% of the pool tokens (it would lower the opening price)", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await factory.createPair(await t.getAddress(), await wbdag.getAddress());
      await t.connect(project).transfer(await (await pairOf(t)).getAddress(), 100n * E18);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 }); // about 1,960 pool tokens, so 1% is about 19.6
      await time.increaseTo(cfg.endTime + 1n);
      await expect(sale.finalize()).to.be.revertedWith("pool pre-loaded with tokens");
    });

    it("refuses tokens that take a fee on transfer", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      await t.setFeeBps(100n);
      await time.increaseTo(cfg.endTime + 1n);
      await expect(sale.finalize()).to.be.revertedWith("token takes a fee on transfer");
    });

    it("a zero fee is allowed and sends nothing to the treasury", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t, { feeBps: 0n });
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      await time.increaseTo(cfg.endTime + 1n);
      await sale.finalize();
      expect(await wbdag.balanceOf(treasury.address)).to.equal(0n);
    });
  });

  describe("failed sales", () => {
    it("under the soft cap: refunds open at the end, finalize is blocked, the project gets its tokens back", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 150_000n * E18 });
      await sale.connect(b).buy({ value: 40_000n * E18 });
      expect(await sale.refundsOpen()).to.equal(false);
      await expect(sale.connect(a).refund()).to.be.revertedWith("refunds not open");
      await expect(sale.returnTokens()).to.be.revertedWith("refunds not open");
      await time.increaseTo(cfg.endTime + 1n);
      await expect(sale.finalize()).to.be.revertedWith("soft cap not reached");
      expect(await sale.refundsOpen()).to.equal(true);
      expect(await sale.claimable(a.address)).to.equal(15_000n * E18 / 10n);

      const projectBefore = await t.balanceOf(project.address);
      const held = await t.balanceOf(await sale.getAddress());
      await sale.connect(c).returnTokens(); // anyone can trigger it; tokens only go to the project
      expect((await t.balanceOf(project.address)) - projectBefore).to.equal(held);
      await expect(sale.returnTokens()).to.be.revertedWith("already returned");
      expect(await sale.claimable(a.address)).to.equal(0n);

      await sale.connect(a).refund();
      await sale.connect(b).refund();
      await expect(sale.connect(a).refund()).to.be.revertedWith("already settled");
      await expect(sale.connect(c).refund()).to.be.revertedWith("nothing to refund");
      expect(await ethers.provider.getBalance(await sale.getAddress())).to.equal(0n);
      await expect(sale.connect(a).claim()).to.be.revertedWith("not finalized yet");
    });

    it("a sale with no buyers can hand the tokens back straight after the end", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await time.increaseTo(cfg.endTime + 1n);
      await expect(sale.finalize()).to.be.revertedWith("soft cap not reached");
      await sale.returnTokens();
      expect(await t.balanceOf(await sale.getAddress())).to.equal(0n);
    });

    it("one buyer who can't receive BDAG doesn't block anyone else's refund", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      const rej = await (await ethers.getContractFactory("RejectingBuyer")).deploy();
      await time.increaseTo(cfg.startTime);
      await rej.buy(await sale.getAddress(), { value: 10n * E18 });
      await sale.connect(a).buy({ value: 10n * E18 });
      await time.increaseTo(cfg.endTime + 1n);
      await expect(rej.refund(await sale.getAddress())).to.be.revertedWith("refund failed");
      await sale.connect(a).refund();
      expect(await ethers.provider.getBalance(await sale.getAddress())).to.equal(10n * E18);
    });
  });

  describe("project bond", () => {
    const outcome = { locked: 0n, returned: 1n, burned: 2n };

    it("after a good launch, is held until the LP unlocks, then goes back to the project", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      expect(await sale.bondOutcome()).to.equal(outcome.locked);
      await expect(sale.settleBond()).to.be.revertedWith("bond still locked");
      await time.increaseTo(cfg.endTime + 1n);
      await sale.finalize();
      await expect(sale.settleBond()).to.be.revertedWith("bond still locked");
      await time.increaseTo(await sale.lpUnlockTime());
      expect(await sale.bondOutcome()).to.equal(outcome.returned);
      const before = await reefBond.balanceOf(project.address);
      await expect(sale.connect(c).settleBond()).to.emit(sale, "BondReturned").withArgs(project.address, BOND);
      expect((await reefBond.balanceOf(project.address)) - before).to.equal(BOND);
      await expect(sale.settleBond()).to.be.revertedWith("bond already settled");
    });

    it("if the soft cap is simply missed, goes back to the project when the sale ends", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 100_000n * E18 });
      await time.increaseTo(cfg.endTime + 1n);
      expect(await sale.bondOutcome()).to.equal(outcome.returned);
      await sale.settleBond();
      expect(await reefBond.balanceOf(await sale.getAddress())).to.equal(0n);
    });

    it("is burned if buyers reached the soft cap but the launch was blocked and they had to refund", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      // the project seeds its own pool first, so the launch can't open at the sale's price
      await t.connect(project).approve(await router.getAddress(), ethers.MaxUint256);
      await router.connect(project).addLiquidityBDAG(await t.getAddress(), 100n * E18, 0, 0, project.address, BigInt(await time.latest()) + 600n, { value: 100n * E18 });
      await time.increaseTo(cfg.endTime + 1n);
      await expect(sale.finalize()).to.be.revertedWith("pool already has liquidity");
      expect(await sale.bondOutcome()).to.equal(outcome.locked); // still inside the 7-day finalize window
      await time.increaseTo(cfg.endTime + 7n * DAY + 1n);
      expect(await sale.bondOutcome()).to.equal(outcome.burned);
      const deadBefore = await reefBond.balanceOf(DEAD);
      await expect(sale.connect(c).settleBond()).to.emit(sale, "BondBurned").withArgs(BOND);
      expect((await reefBond.balanceOf(DEAD)) - deadBefore).to.equal(BOND);
      await sale.connect(a).refund(); // buyers still get their BDAG back
    });

    it("a sale can run with no bond", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t, { bondToken: ethers.ZeroAddress, bondAmount: 0n });
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      await expect(sale.settleBond()).to.be.revertedWith("no bond");
    });
  });

  describe("TOKEN/REEF routing pool (20% slice)", () => {
    const deadline = async () => BigInt(await time.latest()) + 600n;
    // REEF/BDAG pool at 220 BDAG per REEF: 2.2M BDAG with 10,000 REEF
    async function seedReefPool() {
      await reefBond.connect(project).approve(await router.getAddress(), ethers.MaxUint256);
      await router.connect(project).addLiquidityBDAG(await reefBond.getAddress(), 10_000n * E18, 0, 0, project.address, await deadline(), { value: 2_200_000n * E18 });
    }
    const sliceCfg = async (over = {}) => ({ reefToken: await reefBond.getAddress(), reefSliceBps: 2000n, minReefDepth: 1_000_000n * E18, ...over });
    const reserveOf = async (pair, tokenAddr) => {
      const [r0, r1] = await pair.getReserves();
      return (await pair.token0()) === tokenAddr ? r0 : r1;
    };
    const getOut = (inp, rIn, rOut) => (inp * 997n * rOut) / (rIn * 1000n + inp * 997n);
    async function runSale(over, beforeFinalize) {
      const t = await newToken();
      const { sale, cfg } = await newSale(t, await sliceCfg(over));
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      await time.increaseTo(cfg.endTime + 1n);
      if (beforeFinalize) await beforeFinalize(t);
      const tx = await sale.finalize();
      return { t, sale, cfg, tx };
    }

    it("buys REEF with 20% of the pooled BDAG and opens TOKEN/REEF at the listing price; both LPs locked", async () => {
      await seedReefPool();
      const reefPool = await ethers.getContractAt("ReefPair", await factory.getPair(await reefBond.getAddress(), await wbdag.getAddress()));
      const rB = await reserveOf(reefPool, await wbdag.getAddress()), rR = await reserveOf(reefPool, await reefBond.getAddress());
      const pooled = 294_000n * E18, slice = 58_800n * E18; // 300k raised, 2% fee, 20% of the rest
      const out = getOut(slice, rB, rR);
      const { t, sale, tx } = await runSale();
      const tokensSlice = (slice * E18) / (150n * E18);
      await expect(tx).to.emit(sale, "ReefSlice");
      const tp = await ethers.getContractAt("ReefPair", await factory.getPair(await t.getAddress(), await reefBond.getAddress()));
      expect(await reserveOf(tp, await reefBond.getAddress())).to.equal(out);
      expect(await reserveOf(tp, await t.getAddress())).to.equal(tokensSlice);
      const main = await pairOf(t);
      expect(await reserveOf(main, await wbdag.getAddress())).to.equal(pooled - slice);
      expect(await reserveOf(main, await t.getAddress())).to.equal(((pooled - slice) * E18) / (150n * E18));
      expect(await reefBond.balanceOf(await sale.getAddress())).to.equal(BOND); // the bond is untouched
      expect(await wbdag.balanceOf(treasury.address)).to.equal(6_000n * E18);
      expect(await sale.reefLpToken()).to.equal(await tp.getAddress());

      await time.increaseTo(await sale.lpUnlockTime());
      const lpMain = await main.balanceOf(await sale.getAddress()), lpReef = await tp.balanceOf(await sale.getAddress());
      expect(lpReef).to.be.gt(0n);
      await sale.withdrawLP();
      expect(await main.balanceOf(lpBen.address)).to.equal(lpMain);
      expect(await tp.balanceOf(lpBen.address)).to.equal(lpReef);
      // buyers still claim in full
      await sale.connect(a).claim();
      expect(await t.balanceOf(a.address)).to.equal(3_000n * E18);
      // and the router can route TOKEN -> REEF -> BDAG
      const path = [await t.getAddress(), await reefBond.getAddress(), await wbdag.getAddress()];
      await t.connect(a).approve(await router.getAddress(), ethers.MaxUint256);
      const amounts = await router.getAmountsOut(10n * E18, path);
      expect(amounts[2]).to.be.gt(0n);
    });

    it("is skipped when the REEF/BDAG pool is under the minimum depth", async () => {
      await seedReefPool();
      const { t, sale, tx } = await runSale({ minReefDepth: 3_000_000n * E18 });
      await expect(tx).to.emit(sale, "ReefSliceSkipped").withArgs(4);
      expect(await reserveOf(await pairOf(t), await wbdag.getAddress())).to.equal(294_000n * E18);
      expect(await sale.reefLpToken()).to.equal(ethers.ZeroAddress);
    });

    it("is skipped, not reverted, if someone pushes the REEF price just before finalize", async () => {
      await seedReefPool();
      const { sale, tx } = await runSale({}, async () => {
        await router.connect(c).swapExactBDAGForTokens(0, [await wbdag.getAddress(), await reefBond.getAddress()], c.address, await deadline(), { value: 300_000n * E18 });
      });
      await expect(tx).to.emit(sale, "ReefSliceSkipped").withArgs(5);
      expect(await sale.finalized()).to.equal(true);
    });

    it("is skipped if less than a day has passed since the sale was deployed", async () => {
      await seedReefPool();
      const now = BigInt(await time.latest());
      const { sale, tx } = await runSale({ endTime: now + 3_700n });
      await expect(tx).to.emit(sale, "ReefSliceSkipped").withArgs(3);
    });

    it("is skipped if there was no REEF/BDAG pool when the sale was deployed", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t, await sliceCfg());
      expect(await sale.reefPair()).to.equal(ethers.ZeroAddress);
      await seedReefPool(); // created after deployment: too late to have an average price
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      await time.increaseTo(cfg.endTime + 1n);
      await expect(sale.finalize()).to.emit(sale, "ReefSliceSkipped").withArgs(1);
    });

    it("is skipped if the TOKEN/REEF pool was pre-loaded with tokens", async () => {
      await seedReefPool();
      const { sale, tx } = await runSale({}, async (t) => {
        await factory.createPair(await t.getAddress(), await reefBond.getAddress());
        await t.connect(project).transfer(await factory.getPair(await t.getAddress(), await reefBond.getAddress()), 100n * E18);
      });
      await expect(tx).to.emit(sale, "ReefSliceSkipped").withArgs(6);
    });
  });

  describe("LP lock", () => {
    it("releases the LP to the beneficiary only after the lock", async () => {
      const t = await newToken();
      const { sale, cfg } = await newSale(t);
      await fund(t, sale);
      await time.increaseTo(cfg.startTime);
      await sale.connect(a).buy({ value: 300_000n * E18 });
      await expect(sale.withdrawLP()).to.be.revertedWith("not finalized yet");
      await time.increaseTo(cfg.endTime + 1n);
      await sale.finalize();
      await expect(sale.withdrawLP()).to.be.revertedWith("LP still locked");
      expect(await sale.lpTimeRemaining()).to.be.gt(364n * DAY);
      await time.increaseTo(await sale.lpUnlockTime());
      const pair = await pairOf(t);
      const lp = await pair.balanceOf(await sale.getAddress());
      await sale.connect(c).withdrawLP();
      expect(await pair.balanceOf(lpBen.address)).to.equal(lp);
      await expect(sale.withdrawLP()).to.be.revertedWith("no LP to withdraw");
    });
  });
});
