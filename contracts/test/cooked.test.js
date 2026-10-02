const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const E = (n) => ethers.parseEther(String(n));
const TARGET = E(10_000); // BDAG raised when the curve sells out (test value)
const FEE = 100n;          // 1%

async function setup({ start = 0n } = {}) {
  const [deployer, alice, bob, carol, feeWallet, attacker] = await ethers.getSigners();
  const wbdag = await (await ethers.getContractFactory("contracts/reef/WBDAG.sol:WBDAG")).deploy();
  const factory = await (await ethers.getContractFactory("ReefFactory")).deploy(deployer.address);
  await factory.setFeeTo(deployer.address); // like live Reef: protocol fee on
  const router = await (await ethers.getContractFactory("ReefRouter")).deploy(await factory.getAddress(), await wbdag.getAddress());
  const now = BigInt((await ethers.provider.getBlock("latest")).timestamp);
  const startTime = start === 0n ? now : now + start;
  const curve = await (await ethers.getContractFactory("CookedCurve")).deploy(
    "Cooked", "COOKED", await factory.getAddress(), await wbdag.getAddress(),
    feeWallet.address, FEE, TARGET, startTime);
  const token = await ethers.getContractAt("CookedToken", await curve.token());
  const pair = await ethers.getContractAt("ReefPair", await curve.pair());
  return { deployer, alice, bob, carol, feeWallet, attacker, wbdag, factory, router, curve, token, pair };
}

const dl = async () => BigInt((await ethers.provider.getBlock("latest")).timestamp) + 3600n;

async function fillCurve(curve, who) {
  // buy with more than enough; overshoot is refunded
  await curve.connect(who).buy(0, await dl(), { value: E(20_000) });
}

describe("$COOKED bonding curve", function () {
  it("deploys with the whole supply on the curve, no owner, pool pre-created", async () => {
    const { curve, token, pair, wbdag } = await setup();
    expect(await token.totalSupply()).to.equal(E(1_000_000_000));
    expect(await token.balanceOf(await curve.getAddress())).to.equal(E(1_000_000_000));
    expect(await token.curve()).to.equal(await curve.getAddress());
    expect(await token.pool()).to.equal(await pair.getAddress());
    const [r0, r1] = await pair.getReserves();
    expect(r0).to.equal(0n); expect(r1).to.equal(0n);
    expect(token.interface.getFunction("owner")).to.equal(null);
    expect(curve.interface.getFunction("owner")).to.equal(null);
    const t0 = await pair.token0(), t1 = await pair.token1();
    expect([t0, t1]).to.have.members([await token.getAddress(), await wbdag.getAddress()]);
  });

  it("price rises with buys and the quote matches the result", async () => {
    const { curve, token, alice, bob } = await setup();
    const p0 = await curve.spotPrice();
    const [q] = await curve.quoteBuy(E(100));
    await curve.connect(alice).buy(q, await dl(), { value: E(100) });
    expect(await token.balanceOf(alice.address)).to.equal(q);
    const p1 = await curve.spotPrice();
    expect(p1).to.be.gt(p0);
    const [q2] = await curve.quoteBuy(E(100));
    expect(q2).to.be.lt(q); // same BDAG buys fewer tokens later
    await curve.connect(bob).buy(q2, await dl(), { value: E(100) });
  });

  it("takes exactly 1% in fees and pays them only to the fee wallet via claimFees", async () => {
    const { curve, alice, feeWallet, bob } = await setup();
    await curve.connect(alice).buy(0, await dl(), { value: E(1000) });
    expect(await curve.feesOwed()).to.equal(E(10));
    expect(await curve.bdagRaised()).to.equal(E(990));
    const before = await ethers.provider.getBalance(feeWallet.address);
    await curve.connect(bob).claimFees(); // anyone can trigger, money goes to the fee wallet
    expect(await ethers.provider.getBalance(feeWallet.address) - before).to.equal(E(10));
    expect(await curve.feesOwed()).to.equal(0n);
  });

  it("sells return BDAG along the curve, minus 1%, and a round trip loses only fees", async () => {
    const { curve, token, alice } = await setup();
    await curve.connect(alice).buy(0, await dl(), { value: E(500) });
    const bal = await token.balanceOf(alice.address);
    await token.connect(alice).approve(await curve.getAddress(), bal);
    const [out] = await curve.quoteSell(bal);
    const before = await ethers.provider.getBalance(alice.address);
    const tx = await curve.connect(alice).sell(bal, out, await dl());
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const got = await ethers.provider.getBalance(alice.address) - before + gas;
    expect(got).to.be.closeTo(out, E("0.001")); // gas reporting on the Berlin test node is slightly off
    // 500 -> 495 net in -> ~495 back gross -> ~490.05 after sell fee
    expect(got).to.be.closeTo(E("490.05"), E("0.001"));
    expect(await curve.tokensSold()).to.equal(0n);
  });

  it("selling everything back can never take more BDAG than the curve holds", async () => {
    const { curve, token, alice, bob, carol } = await setup();
    for (const [w, v] of [[alice, 777], [bob, 1234], [carol, 3]]) await curve.connect(w).buy(0, await dl(), { value: E(v) });
    for (const w of [carol, alice, bob]) {
      const b = await token.balanceOf(w.address);
      await token.connect(w).approve(await curve.getAddress(), b);
      await curve.connect(w).sell(b, 0, await dl());
    }
    expect(await curve.tokensSold()).to.equal(0n);
    const held = await ethers.provider.getBalance(await curve.getAddress());
    expect(held).to.be.gte(await curve.feesOwed()); // curve is never short
    expect(await curve.bdagRaised()).to.be.gte(0n);
  });

  it("slippage, deadline, zero amounts and start time are enforced", async () => {
    const { curve, alice } = await setup({ start: 3600n });
    await expect(curve.connect(alice).buy(0, await dl(), { value: E(1) })).to.be.revertedWithCustomError(curve, "NotStarted");
    await time.increase(3601);
    const [q] = await curve.quoteBuy(E(1));
    await expect(curve.connect(alice).buy(q + 1n, await dl(), { value: E(1) })).to.be.revertedWithCustomError(curve, "Slippage");
    await expect(curve.connect(alice).buy(0, 1, { value: E(1) })).to.be.revertedWithCustomError(curve, "Expired");
    await expect(curve.connect(alice).buy(0, await dl(), { value: 0 })).to.be.revertedWithCustomError(curve, "ZeroAmount");
    await expect(curve.connect(alice).sell(0, 0, await dl())).to.be.revertedWithCustomError(curve, "ZeroAmount");
  });

  it("the last buy is capped at what's left and the excess is refunded", async () => {
    const { curve, token, alice } = await setup();
    const before = await ethers.provider.getBalance(alice.address);
    const tx = await curve.connect(alice).buy(0, await dl(), { value: E(20_000) });
    const rc = await tx.wait();
    const spent = before - await ethers.provider.getBalance(alice.address) - rc.gasUsed * rc.gasPrice;
    expect(await token.balanceOf(alice.address)).to.equal(E(800_000_000));
    expect(await curve.complete()).to.equal(true);
    // spent ~ target / 0.99, the rest came back
    expect(spent).to.be.closeTo(TARGET * 10000n / 9900n, E("0.01"));
    expect(await curve.bdagRaised()).to.be.closeTo(TARGET, E("0.000001"));
    expect(await curve.bdagRaised()).to.be.gte(TARGET);
  });

  it("trading stops once complete; graduation seeds Reef at the curve's final price and burns the LP", async () => {
    const { curve, token, pair, alice, bob, wbdag } = await setup();
    await curve.connect(alice).buy(0, await dl(), { value: E(3000) });
    await fillCurve(curve, bob);
    const finalPrice = await curve.spotPrice();
    await expect(curve.connect(alice).buy(0, await dl(), { value: E(1) })).to.be.revertedWithCustomError(curve, "Closed");
    await token.connect(alice).approve(await curve.getAddress(), E(1));
    await expect(curve.connect(alice).sell(E(1), 0, await dl())).to.be.revertedWithCustomError(curve, "Closed");

    const raised = await curve.bdagRaised();
    await curve.connect(alice).graduate();
    expect(await curve.graduated()).to.equal(true);
    expect(await token.poolOpen()).to.equal(true);

    const [r0, r1] = await pair.getReserves();
    const tokIs0 = (await pair.token0()) === (await token.getAddress());
    const [rTok, rB] = tokIs0 ? [r0, r1] : [r1, r0];
    expect(rTok).to.equal(E(200_000_000));
    expect(rB).to.equal(raised);
    const poolPrice = rB * E(1) / rTok;
    // pool opens within 0.01% of the curve's last price
    expect(poolPrice).to.be.closeTo(finalPrice, finalPrice / 10000n);

    const dead = "0x000000000000000000000000000000000000dEaD";
    const supply = await pair.totalSupply();
    expect(await pair.balanceOf(dead)).to.equal(supply); // all LP burned
    expect(await token.balanceOf(await curve.getAddress())).to.equal(0n);
    expect(await ethers.provider.getBalance(await curve.getAddress())).to.equal(await curve.feesOwed());
    await expect(curve.graduate()).to.be.revertedWithCustomError(curve, "AlreadyGraduated");
    expect(await wbdag.balanceOf(await curve.getAddress())).to.equal(0n);
  });

  it("graduate cannot run early", async () => {
    const { curve, alice } = await setup();
    await curve.connect(alice).buy(0, await dl(), { value: E(5000) });
    await expect(curve.graduate()).to.be.revertedWithCustomError(curve, "NotComplete");
  });

  it("after graduation, trading works on Reef in both directions", async () => {
    const { curve, token, router, wbdag, alice, bob } = await setup();
    await fillCurve(curve, alice);
    await curve.graduate();
    const path = [await wbdag.getAddress(), await token.getAddress()];
    await router.connect(bob).swapExactBDAGForTokens(0, path, bob.address, await dl(), { value: E(10) });
    const got = await token.balanceOf(bob.address);
    expect(got).to.be.gt(0n);
    await token.connect(bob).approve(await router.getAddress(), got);
    await router.connect(bob).swapExactTokensForBDAG(got, 0, [path[1], path[0]], bob.address, await dl());
    expect(await token.balanceOf(bob.address)).to.equal(0n);
  });

  describe("attacks", () => {
    it("nobody can pre-seed the Reef pool with COOKED before graduation", async () => {
      const { curve, token, pair, router, wbdag, attacker } = await setup();
      await curve.connect(attacker).buy(0, await dl(), { value: E(10) });
      const bal = await token.balanceOf(attacker.address);
      await expect(token.connect(attacker).transfer(await pair.getAddress(), 1n)).to.be.revertedWithCustomError(token, "PoolNotOpen");
      await token.connect(attacker).approve(await router.getAddress(), bal);
      await expect(router.connect(attacker).addLiquidityBDAG(await token.getAddress(), bal, 0, 0, attacker.address, await dl(), { value: E(1) })).to.be.reverted;
      await expect(router.connect(attacker).swapExactBDAGForTokens(0, [await wbdag.getAddress(), await token.getAddress()], attacker.address, await dl(), { value: E(1) })).to.be.reverted;
    });

    it("a WBDAG donation + sync on the empty pool can't block graduation", async () => {
      const { curve, wbdag, pair, alice, attacker, token } = await setup();
      await wbdag.connect(attacker).deposit({ value: E(50) });
      await wbdag.connect(attacker).transfer(await pair.getAddress(), E(50));
      await pair.connect(attacker).sync();
      await expect(pair.connect(attacker).mint(attacker.address)).to.be.reverted; // can't mint without COOKED
      await fillCurve(curve, alice);
      await curve.graduate();
      expect(await pair.balanceOf(attacker.address)).to.equal(0n);
      const [r0, r1] = await pair.getReserves();
      const tokIs0 = (await pair.token0()) === (await token.getAddress());
      expect(tokIs0 ? r0 : r1).to.equal(E(200_000_000));
      // the donation just joins the pool (attacker loses it)
      expect(tokIs0 ? r1 : r0).to.equal((await curve.bdagRaised()) + E(50));
    });

    it("reentrancy from a malicious seller is blocked", async () => {
      const { curve } = await setup();
      const R = await (await ethers.getContractFactory("CookedReenter")).deploy(await curve.getAddress());
      await R.attackBuy({ value: E(10) });
      await expect(R.attackSell()).to.be.reverted; // re-entering sell during payout fails
    });

    it("a fee wallet that rejects BDAG can't block trading", async () => {
      const [deployer, alice] = await ethers.getSigners();
      const wbdag = await (await ethers.getContractFactory("contracts/reef/WBDAG.sol:WBDAG")).deploy();
      const factory = await (await ethers.getContractFactory("ReefFactory")).deploy(deployer.address);
      const rej = await (await ethers.getContractFactory("CookedRejecter")).deploy();
      const curve = await (await ethers.getContractFactory("CookedCurve")).deploy(
        "Cooked", "COOKED", await factory.getAddress(), await wbdag.getAddress(), await rej.getAddress(), FEE, TARGET, 0);
      await curve.connect(alice).buy(0, await dl(), { value: E(100) });
      await curve.connect(alice).buy(0, await dl(), { value: E(20_000) });
      await curve.graduate();
      await expect(curve.claimFees()).to.be.reverted; // only the claim fails
    });

    it("fee above 1% or a zero target can't be deployed", async () => {
      const [deployer] = await ethers.getSigners();
      const C = await ethers.getContractFactory("CookedCurve");
      await expect(C.deploy("C", "C", deployer.address, deployer.address, deployer.address, 101, TARGET, 0)).to.be.reverted;
      await expect(C.deploy("C", "C", deployer.address, deployer.address, deployer.address, 100, 0, 0)).to.be.reverted;
    });

    it("many random buys and sells keep the books balanced", async () => {
      const { curve, token, alice, bob, carol } = await setup();
      const ws = [alice, bob, carol];
      let seed = 12345n;
      const rnd = () => { seed = (seed * 1103515245n + 12345n) % 2147483648n; return seed; };
      for (let i = 0; i < 60; i++) {
        const w = ws[Number(rnd() % 3n)];
        if (rnd() % 3n !== 0n) {
          await curve.connect(w).buy(0, await dl(), { value: (rnd() % 400n + 1n) * E("0.5") });
        } else {
          const b = await token.balanceOf(w.address);
          if (b === 0n) continue;
          const amt = b * (rnd() % 100n + 1n) / 100n;
          await token.connect(w).approve(await curve.getAddress(), amt);
          await curve.connect(w).sell(amt, 0, await dl());
        }
        const held = await ethers.provider.getBalance(await curve.getAddress());
        expect(held).to.equal((await curve.bdagRaised()) + (await curve.feesOwed()));
        let sum = 0n; for (const x of ws) sum += await token.balanceOf(x.address);
        expect(sum).to.equal(await curve.tokensSold());
      }
    });
  });
});
