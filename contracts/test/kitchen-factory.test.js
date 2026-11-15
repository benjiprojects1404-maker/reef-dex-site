const { expect } = require("chai");
const { ethers } = require("hardhat");

const FEE = ethers.parseEther("5000");
const RESERVED = ["BDAG", "WBDAG", "REEF", "NOCAP", "COOKED", "USDT", "USDC", "ETH", "WETH", "BTC", "WBTC"];

describe("KitchenFactory", function () {
  let factory, admin, treasury, alice, bob;

  beforeEach(async function () {
    [admin, treasury, alice, bob] = await ethers.getSigners();
    factory = await (await ethers.getContractFactory("KitchenFactory")).deploy(admin.address, treasury.address, FEE, RESERVED);
  });

  async function cook(signer, name, symbol, supply, value = FEE) {
    const tx = await factory.connect(signer).cook(name, symbol, supply, { value });
    const rc = await tx.wait();
    const ev = rc.logs.map((l) => { try { return factory.interface.parseLog(l); } catch (e) { return null; } }).find((e) => e && e.name === "TokenCooked");
    return ethers.getContractAt("contracts/kitchen/KitchenFactory.sol:KitchenToken", ev.args.token);
  }

  it("makes a fixed-supply token with the whole supply in the creator's wallet", async function () {
    const t = await cook(alice, "Pan Fried", "PAN", 1_000_000n);
    expect(await t.name()).to.equal("Pan Fried");
    expect(await t.symbol()).to.equal("PAN");
    expect(await t.decimals()).to.equal(18n);
    expect(await t.totalSupply()).to.equal(ethers.parseEther("1000000"));
    expect(await t.balanceOf(alice.address)).to.equal(ethers.parseEther("1000000"));
    expect(await factory.isKitchenToken(await t.getAddress())).to.equal(true);
  });

  it("the token has no owner or admin functions at all", async function () {
    const t = await cook(alice, "Pan Fried", "PAN", 1_000n);
    const fns = Object.values(t.interface.fragments).filter((f) => f.type === "function").map((f) => f.name).sort();
    expect(fns).to.deep.equal(["allowance", "approve", "balanceOf", "decimals", "name", "symbol", "totalSupply", "transfer", "transferFrom"]);
  });

  it("forwards exactly the fee to the treasury and keeps no BDAG", async function () {
    const before = await ethers.provider.getBalance(treasury.address);
    await cook(alice, "Pan Fried", "PAN", 1_000n);
    expect((await ethers.provider.getBalance(treasury.address)) - before).to.equal(FEE);
    expect(await ethers.provider.getBalance(await factory.getAddress())).to.equal(0n);
  });

  it("rejects the wrong fee", async function () {
    await expect(factory.connect(alice).cook("Pan", "PAN", 1n, { value: FEE - 1n })).to.be.revertedWithCustomError(factory, "WrongFee");
    await expect(factory.connect(alice).cook("Pan", "PAN", 1n, { value: FEE + 1n })).to.be.revertedWithCustomError(factory, "WrongFee");
    await expect(factory.connect(alice).cook("Pan", "PAN", 1n)).to.be.revertedWithCustomError(factory, "WrongFee");
  });

  it("reverts the whole thing if the treasury refuses BDAG", async function () {
    const rej = await (await ethers.getContractFactory("MockRejectBDAG")).deploy();
    await factory.setFeeRecipient(await rej.getAddress());
    await expect(factory.connect(alice).cook("Pan", "PAN", 1n, { value: FEE })).to.be.revertedWithCustomError(factory, "FeeTransferFailed");
    expect(await factory.tokenCount()).to.equal(0n);
  });

  it("checks names", async function () {
    for (const bad of ["", " Pan", "Pan ", "x".repeat(33), "Pan\nFried", "Pan\u0000"]) {
      await expect(factory.connect(alice).cook(bad, "PAN", 1n, { value: FEE }), JSON.stringify(bad)).to.be.revertedWithCustomError(factory, "BadName");
    }
    await cook(alice, "x".repeat(32), "OK", 1n);
    await cook(alice, "Crème brûlée 🍮", "CREME", 1n); // UTF-8 is fine
  });

  it("checks tickers: letters and digits, 1-11 long", async function () {
    for (const bad of ["", "PAN PAN", "PAN$", "USDТ", "ABCDEFGHIJKL", "PAN-1", "😀"]) {
      await expect(factory.connect(alice).cook("Pan", bad, 1n, { value: FEE }), bad).to.be.revertedWithCustomError(factory, "BadSymbol");
    }
    await cook(alice, "Pan", "ABCDEFGHIJK", 1n);
    await cook(alice, "Pan", "pan2", 1n);
  });

  it("reserves well-known tickers, in any case", async function () {
    for (const s of ["REEF", "reef", "Usdc", "bdag", "wBTC", "cooked"]) {
      await expect(factory.connect(alice).cook("Fake", s, 1n, { value: FEE }), s).to.be.revertedWithCustomError(factory, "ReservedSymbol");
    }
    expect(await factory.isReserved("usdt")).to.equal(true);
    expect(await factory.isReserved("REEFY")).to.equal(false);
    await cook(alice, "Reefy", "REEFY", 1n);
  });

  it("checks the supply", async function () {
    await expect(factory.connect(alice).cook("Pan", "PAN", 0n, { value: FEE })).to.be.revertedWithCustomError(factory, "BadSupply");
    await expect(factory.connect(alice).cook("Pan", "PAN", 10n ** 15n + 1n, { value: FEE })).to.be.revertedWithCustomError(factory, "BadSupply");
    const t = await cook(alice, "Pan", "PAN", 10n ** 15n);
    expect(await t.totalSupply()).to.equal(10n ** 33n);
  });

  it("lists tokens: count, newest first, and by creator", async function () {
    const a1 = await (await cook(alice, "One", "ONE", 1n)).getAddress();
    const b1 = await (await cook(bob, "Two", "TWO", 1n)).getAddress();
    const a2 = await (await cook(alice, "Three", "THREE", 1n)).getAddress();
    expect(await factory.tokenCount()).to.equal(3n);
    expect(await factory.latest(0, 10)).to.deep.equal([a2, b1, a1]);
    expect(await factory.latest(1, 1)).to.deep.equal([b1]);
    expect(await factory.latest(3, 5)).to.deep.equal([]);
    expect(await factory.tokensByCreator(alice.address)).to.deep.equal([a1, a2]);
    expect(await factory.tokenAt(1)).to.equal(b1);
  });

  it("the same name and ticker can be used twice, but they are different tokens", async function () {
    const x = await (await cook(alice, "Pan", "PAN", 1n)).getAddress();
    const y = await (await cook(bob, "Pan", "PAN", 1n)).getAddress();
    expect(x).to.not.equal(y);
  });

  it("free when the fee is zero", async function () {
    await factory.setFee(0);
    const t = await cook(alice, "Free", "FREE", 1n, 0n);
    expect(await t.totalSupply()).to.equal(ethers.parseEther("1"));
  });

  describe("admin", function () {
    it("only the admin can set the fee, capped at 50,000 BDAG", async function () {
      await expect(factory.connect(alice).setFee(1n)).to.be.revertedWithCustomError(factory, "NotAdmin");
      await expect(factory.setFee(ethers.parseEther("50000") + 1n)).to.be.revertedWithCustomError(factory, "FeeTooHigh");
      await factory.setFee(ethers.parseEther("50000"));
      expect(await factory.fee()).to.equal(ethers.parseEther("50000"));
    });

    it("the constructor also respects the cap and rejects zero addresses", async function () {
      const F = await ethers.getContractFactory("KitchenFactory");
      await expect(F.deploy(admin.address, treasury.address, ethers.parseEther("50001"), [])).to.be.revertedWithCustomError(factory, "FeeTooHigh");
      await expect(F.deploy(ethers.ZeroAddress, treasury.address, 0, [])).to.be.revertedWithCustomError(factory, "ZeroAddress");
      await expect(F.deploy(admin.address, ethers.ZeroAddress, 0, [])).to.be.revertedWithCustomError(factory, "ZeroAddress");
    });

    it("only the admin can change the fee recipient", async function () {
      await expect(factory.connect(alice).setFeeRecipient(alice.address)).to.be.revertedWithCustomError(factory, "NotAdmin");
      await expect(factory.setFeeRecipient(ethers.ZeroAddress)).to.be.revertedWithCustomError(factory, "ZeroAddress");
      await factory.setFeeRecipient(bob.address);
      expect(await factory.feeRecipient()).to.equal(bob.address);
    });

    it("hands over admin in two steps", async function () {
      await expect(factory.connect(alice).transferAdmin(alice.address)).to.be.revertedWithCustomError(factory, "NotAdmin");
      await factory.transferAdmin(bob.address);
      expect(await factory.admin()).to.equal(admin.address);
      await expect(factory.connect(alice).acceptAdmin()).to.be.revertedWithCustomError(factory, "NotAdmin");
      await factory.connect(bob).acceptAdmin();
      expect(await factory.admin()).to.equal(bob.address);
      expect(await factory.pendingAdmin()).to.equal(ethers.ZeroAddress);
      await expect(factory.setFee(1n)).to.be.revertedWithCustomError(factory, "NotAdmin");
    });

    it("the admin can't touch tokens that were made", async function () {
      const t = await cook(alice, "Pan", "PAN", 100n);
      // The factory has no function that calls a token; the token has no owner. Check the factory's surface.
      const fns = Object.values(factory.interface.fragments).filter((f) => f.type === "function" && f.stateMutability !== "view" && f.stateMutability !== "pure").map((f) => f.name).sort();
      expect(fns).to.deep.equal(["acceptAdmin", "cook", "setFee", "setFeeRecipient", "transferAdmin"]);
      expect(await t.balanceOf(alice.address)).to.equal(ethers.parseEther("100"));
    });
  });
});
