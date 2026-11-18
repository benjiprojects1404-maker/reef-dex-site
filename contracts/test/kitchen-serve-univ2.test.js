const { expect } = require("chai");
const { ethers } = require("hardhat");

// The real Uniswap V2 contracts (same code as on Base), from @uniswap/v2-core and @uniswap/v2-periphery.
const FACTORY = require("@uniswap/v2-core/build/UniswapV2Factory.json");
const PAIR = require("@uniswap/v2-core/build/UniswapV2Pair.json");
const ROUTER = require("@uniswap/v2-periphery/build/UniswapV2Router02.json");
const WETH9 = require("@uniswap/v2-periphery/build/WETH9.json");

const E = (n) => ethers.parseEther(String(n));
const FEE = E("0.002");
const MIN = E("0.01");
const RESERVED = ["ETH", "WETH", "USDC", "USDT", "BTC", "WBTC", "CBBTC", "BASE", "REEF", "COOKED"];
const DEAD = "0x000000000000000000000000000000000000dEaD";
const TOKEN = "contracts/kitchen/KitchenServeUniV2.sol:KitchenToken";

describe("KitchenServeUniV2 (The Kitchen on Base / Uniswap V2)", function () {
  let kitchen, router, factory, weth, admin, treasury, alice, bob;

  beforeEach(async function () {
    [admin, treasury, alice, bob] = await ethers.getSigners();
    weth = await new ethers.ContractFactory(WETH9.abi, WETH9.bytecode, admin).deploy();
    factory = await new ethers.ContractFactory(FACTORY.abi, FACTORY.bytecode, admin).deploy(admin.address);
    router = await new ethers.ContractFactory(ROUTER.abi, ROUTER.bytecode, admin).deploy(await factory.getAddress(), await weth.getAddress());
    kitchen = await (await ethers.getContractFactory("KitchenServeUniV2")).deploy(await router.getAddress(), admin.address, treasury.address, FEE, MIN, RESERVED);
  });

  async function cook(signer, name, symbol, supply, pct, liq = MIN, value) {
    const tx = await kitchen.connect(signer).cook(name, symbol, supply, pct, { value: value ?? FEE + liq });
    const rc = await tx.wait();
    const ev = rc.logs.map((l) => { try { return kitchen.interface.parseLog(l); } catch (e) { return null; } }).find((e) => e && e.name === "TokenServed");
    return { token: await ethers.getContractAt(TOKEN, ev.args.token), pair: new ethers.Contract(ev.args.pair, PAIR.abi, admin), ev, rc };
  }

  it("makes the token and its Uniswap V2 pool, burns the LP and sends the rest to the creator", async function () {
    const before = await ethers.provider.getBalance(treasury.address);
    const { token, pair, ev } = await cook(alice, "Midnight Pancake", "PANCAKE", 1_000_000n, 40, E("0.5"));
    const t = await token.getAddress();
    expect(await factory.getPair(t, await weth.getAddress())).to.equal(await pair.getAddress());
    expect(await kitchen.pairOf(t)).to.equal(await pair.getAddress());
    expect(await token.balanceOf(await pair.getAddress())).to.equal(E(400000));
    expect(await weth.balanceOf(await pair.getAddress())).to.equal(E("0.5"));
    expect(await token.balanceOf(alice.address)).to.equal(E(600000));
    // LP burned: Uniswap locks its first 1,000 units at address(0); every other LP unit is at 0x…dEaD.
    const lp = await pair.totalSupply();
    expect(await pair.balanceOf(DEAD)).to.equal(lp - 1000n);
    expect(await pair.balanceOf(ethers.ZeroAddress)).to.equal(1000n);
    expect(await pair.balanceOf(alice.address)).to.equal(0n);
    // fee to the treasury; Kitchen keeps nothing
    expect((await ethers.provider.getBalance(treasury.address)) - before).to.equal(FEE);
    expect(await ethers.provider.getBalance(await kitchen.getAddress())).to.equal(0n);
    expect(await token.balanceOf(await kitchen.getAddress())).to.equal(0n);
    expect(ev.args.creator).to.equal(alice.address);
    expect(ev.args.poolETH).to.equal(E("0.5"));
  });

  it("the token is plain: fixed supply, 18 decimals, no owner", async function () {
    const { token } = await cook(alice, "Plain", "PLN", 5000n, 100);
    expect(await token.totalSupply()).to.equal(E(5000));
    expect(await token.decimals()).to.equal(18n);
    expect(token.interface.getFunction("owner")).to.equal(null);
    expect(token.interface.getFunction("mint")).to.equal(null);
  });

  it("trades on Uniswap straight away (buy and sell through the router)", async function () {
    const { token } = await cook(alice, "Tradeable", "TRD", 1_000_000n, 50, E(1));
    const t = await token.getAddress(), w = await weth.getAddress();
    const deadline = (await ethers.provider.getBlock("latest")).timestamp + 600;
    await router.connect(bob).swapExactETHForTokens(0, [w, t], bob.address, deadline, { value: E("0.1") });
    const got = await token.balanceOf(bob.address);
    expect(got).to.be.gt(0n);
    await token.connect(bob).approve(await router.getAddress(), got);
    await router.connect(bob).swapExactTokensForETH(got, 0, [t, w], bob.address, deadline);
    expect(await token.balanceOf(bob.address)).to.equal(0n);
  });

  it("needs the fee plus at least the minimum liquidity", async function () {
    await expect(kitchen.connect(alice).cook("A", "AAA", 1000n, 50, { value: FEE })).to.be.revertedWithCustomError(kitchen, "NotEnoughETH");
    await expect(kitchen.connect(alice).cook("A", "AAA", 1000n, 50, { value: FEE + MIN - 1n })).to.be.revertedWithCustomError(kitchen, "NotEnoughETH");
    await cook(alice, "A", "AAA", 1000n, 50, MIN);
  });

  it("checks names, tickers (incl. reserved, any case), supply and pool share", async function () {
    const v = { value: FEE + MIN };
    await expect(kitchen.connect(alice).cook("", "AAA", 1000n, 50, v)).to.be.revertedWithCustomError(kitchen, "BadName");
    await expect(kitchen.connect(alice).cook(" lead", "AAA", 1000n, 50, v)).to.be.revertedWithCustomError(kitchen, "BadName");
    await expect(kitchen.connect(alice).cook("x".repeat(33), "AAA", 1000n, 50, v)).to.be.revertedWithCustomError(kitchen, "BadName");
    await expect(kitchen.connect(alice).cook("Name", "A-B", 1000n, 50, v)).to.be.revertedWithCustomError(kitchen, "BadSymbol");
    await expect(kitchen.connect(alice).cook("Name", "ABCDEFGHIJKL", 1000n, 50, v)).to.be.revertedWithCustomError(kitchen, "BadSymbol");
    await expect(kitchen.connect(alice).cook("Name", "weth", 1000n, 50, v)).to.be.revertedWithCustomError(kitchen, "ReservedSymbol");
    await expect(kitchen.connect(alice).cook("Name", "Usdc", 1000n, 50, v)).to.be.revertedWithCustomError(kitchen, "ReservedSymbol");
    await expect(kitchen.connect(alice).cook("Name", "AAA", 0n, 50, v)).to.be.revertedWithCustomError(kitchen, "BadSupply");
    await expect(kitchen.connect(alice).cook("Name", "AAA", 10n ** 15n + 1n, 50, v)).to.be.revertedWithCustomError(kitchen, "BadSupply");
    await expect(kitchen.connect(alice).cook("Name", "AAA", 1000n, 9, v)).to.be.revertedWithCustomError(kitchen, "BadPoolShare");
    await expect(kitchen.connect(alice).cook("Name", "AAA", 1000n, 101, v)).to.be.revertedWithCustomError(kitchen, "BadPoolShare");
    expect(await kitchen.isReserved("cbBTC")).to.equal(true);
  });

  it("works even if someone created the pair for the next token's address in advance", async function () {
    const next = ethers.getCreateAddress({ from: await kitchen.getAddress(), nonce: 1 });
    await factory.createPair(next, await weth.getAddress());
    const { token, pair } = await cook(alice, "Early Bird", "EARLY", 1000n, 50, E(1));
    expect(await token.getAddress()).to.equal(next);
    expect(await weth.balanceOf(await pair.getAddress())).to.equal(E(1));
  });

  it("lists tokens newest first and by creator", async function () {
    await cook(alice, "One", "ONE", 1000n, 50);
    await cook(bob, "Two", "TWO", 1000n, 50);
    await cook(alice, "Three", "THREE", 1000n, 50);
    expect(await kitchen.tokenCount()).to.equal(3n);
    const latest = await kitchen.latest(0, 2);
    expect(latest.length).to.equal(2);
    expect(latest[0]).to.equal(await kitchen.tokenAt(2));
    expect((await kitchen.tokensByCreator(alice.address)).length).to.equal(2);
  });

  it("admin can only change the fee (capped), the minimum (capped) and the recipient, and hands over in two steps", async function () {
    await expect(kitchen.connect(bob).setFee(1n)).to.be.revertedWithCustomError(kitchen, "NotAdmin");
    await expect(kitchen.setFee(E("1.000000000000000001"))).to.be.revertedWithCustomError(kitchen, "FeeTooHigh");
    await expect(kitchen.setMinLiquidity(E(101))).to.be.revertedWithCustomError(kitchen, "MinTooHigh");
    await kitchen.setFee(0n);
    await cook(alice, "Free", "FREE", 1000n, 50, MIN, MIN);
    await kitchen.transferAdmin(bob.address);
    expect(await kitchen.admin()).to.equal(admin.address);
    await expect(kitchen.connect(alice).acceptAdmin()).to.be.revertedWithCustomError(kitchen, "NotAdmin");
    await kitchen.connect(bob).acceptAdmin();
    expect(await kitchen.admin()).to.equal(bob.address);
  });

  it("refuses ETH sent directly", async function () {
    await expect(alice.sendTransaction({ to: await kitchen.getAddress(), value: 1n })).to.be.revertedWithCustomError(kitchen, "NotRouter");
  });
});
