const { expect } = require("chai");
const { ethers } = require("hardhat");
const E = (n) => ethers.parseEther(String(n));
const ZERO = ethers.ZeroAddress;

describe("Handshake OTCEscrow (v3, the live contract's source)", function () {
  let owner, maker, taker, other, feeWallet, esc, tok, E_ADDR, T_ADDR;

  beforeEach(async () => {
    [owner, maker, taker, other, feeWallet] = await ethers.getSigners();
    esc = await (await ethers.getContractFactory("contracts/handshake/OTCEscrow.sol:OTCEscrow")).deploy(feeWallet.address);
    tok = await (await ethers.getContractFactory("HsToken")).deploy("Test", "TST");
    E_ADDR = await esc.getAddress(); T_ADDR = await tok.getAddress();
    for (const s of [maker, taker, other]) {
      await tok.mint(s.address, E(1_000_000));
      await tok.connect(s).approve(E_ADDR, ethers.MaxUint256);
    }
  });

  const bal = (a) => ethers.provider.getBalance(a);
  async function gasOf(txp) { const tx = await txp; const r = await tx.wait(); return r.gasUsed * tx.gasPrice; } // berlin: receipt has no effective gas price

  describe("happy paths", () => {
    it("maker gives BDAG, taker pays token: both sides settle, 0.25% fee from the BDAG side", async () => {
      await esc.connect(maker).createOfferGivingNative(T_ADDR, E(500), ZERO, { value: E(10) });
      const t0 = await bal(taker.address), f0 = await bal(feeWallet.address), m0 = await tok.balanceOf(maker.address);
      const gas = await gasOf(esc.connect(taker).fillOfferGivingToken(1));
      expect(await bal(taker.address)).to.equal(t0 + E(10) - E(10) * 25n / 10000n - gas);
      expect(await bal(feeWallet.address)).to.equal(f0 + E(10) * 25n / 10000n);
      expect(await tok.balanceOf(maker.address)).to.equal(m0 + E(500));
      expect(await bal(E_ADDR)).to.equal(0n);
      expect((await esc.getOffer(1)).status).to.equal(2n); // Filled
    });

    it("maker gives token, taker pays BDAG: maker gets BDAG minus fee, taker gets tokens", async () => {
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(500), E(10), ZERO);
      expect(await tok.balanceOf(E_ADDR)).to.equal(E(500));
      const m0 = await bal(maker.address), k0 = await tok.balanceOf(taker.address);
      await esc.connect(taker).fillOfferGivingNative(1, { value: E(10) });
      expect(await bal(maker.address)).to.equal(m0 + E(10) - E(10) * 25n / 10000n);
      expect(await tok.balanceOf(taker.address)).to.equal(k0 + E(500));
      expect(await tok.balanceOf(E_ADDR)).to.equal(0n);
    });

    it("cancel refunds exactly what was locked, for both offer types", async () => {
      await esc.connect(maker).createOfferGivingNative(T_ADDR, E(1), ZERO, { value: E(3) });
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(7), E(1), ZERO);
      const tk0 = await tok.balanceOf(maker.address);
      await esc.connect(maker).cancelOffer(2);
      expect(await tok.balanceOf(maker.address)).to.equal(tk0 + E(7));
      const b0 = await bal(maker.address);
      const gas = await gasOf(esc.connect(maker).cancelOffer(1));
      expect(await bal(maker.address)).to.equal(b0 + E(3) - gas);
      expect(await bal(E_ADDR)).to.equal(0n);
      expect(await tok.balanceOf(E_ADDR)).to.equal(0n);
    });

    it("works with USDT-style tokens that return nothing", async () => {
      await tok.setReturnsNothing(true);
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(5), E(1), ZERO);
      await esc.connect(taker).fillOfferGivingNative(1, { value: E(1) });
      expect(await tok.balanceOf(taker.address)).to.equal(E(1_000_000) + E(5));
    });
  });

  describe("access and state rules", () => {
    it("a private offer can only be filled by the named taker", async () => {
      await esc.connect(maker).createOfferGivingNative(T_ADDR, E(1), taker.address, { value: E(1) });
      await expect(esc.connect(other).fillOfferGivingToken(1)).to.be.revertedWith("not your offer to fill");
      await esc.connect(taker).fillOfferGivingToken(1);
    });

    it("only the maker can cancel, and nothing can be filled or cancelled twice", async () => {
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(5), E(1), ZERO);
      await expect(esc.connect(other).cancelOffer(1)).to.be.revertedWith("not your offer");
      await esc.connect(taker).fillOfferGivingNative(1, { value: E(1) });
      await expect(esc.connect(taker).fillOfferGivingNative(1, { value: E(1) })).to.be.revertedWith("not open");
      await expect(esc.connect(maker).cancelOffer(1)).to.be.revertedWith("not open");
    });

    it("using the wrong fill function, or the wrong BDAG amount, reverts", async () => {
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(5), E(1), ZERO);
      await expect(esc.connect(taker).fillOfferGivingToken(1)).to.be.revertedWith("wrong fill function for this offer");
      await expect(esc.connect(taker).fillOfferGivingNative(1, { value: E(1) + 1n })).to.be.revertedWith("wrong BDAG amount");
      await expect(esc.connect(taker).fillOfferGivingNative(1, { value: E(1) - 1n })).to.be.revertedWith("wrong BDAG amount");
      await expect(esc.connect(taker).fillOfferGivingNative(99, { value: 0 })).to.be.revertedWith("not open");
    });

    it("rejects a token address with no code (the v3 critical fix)", async () => {
      await expect(esc.connect(maker).createOfferGivingNative(other.address, E(1), ZERO, { value: E(1) })).to.be.revertedWith("token has no code");
      await expect(esc.connect(maker).createOfferGivingToken(other.address, E(1), E(1), ZERO)).to.be.revertedWith("token has no code");
    });

    it("rejects a transfer-tax token on the locked side (the v3 medium fix)", async () => {
      await tok.setFee(100); // 1%
      await expect(esc.connect(maker).createOfferGivingToken(T_ADDR, E(100), E(1), ZERO))
        .to.be.revertedWith("token took a transfer fee or rebased - unsupported");
    });
  });

  describe("owner powers are limited", () => {
    it("pause blocks new offers only; open offers can still be filled and cancelled", async () => {
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(5), E(1), ZERO);
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(5), E(1), ZERO);
      await esc.setPaused(true);
      await expect(esc.connect(maker).createOfferGivingNative(T_ADDR, E(1), ZERO, { value: E(1) })).to.be.revertedWith("offers paused");
      await esc.connect(taker).fillOfferGivingNative(1, { value: E(1) });
      await esc.connect(maker).cancelOffer(2);
    });

    it("a fee change never affects offers already open (fee is snapshotted)", async () => {
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(5), E(100), ZERO);
      await esc.setFeeBps(300);
      const f0 = await bal(feeWallet.address);
      await esc.connect(taker).fillOfferGivingNative(1, { value: E(100) });
      expect(await bal(feeWallet.address)).to.equal(f0 + E(100) * 25n / 10000n);
    });

    it("fee is hard-capped at 3%, and only the owner can change settings", async () => {
      await expect(esc.setFeeBps(301)).to.be.revertedWith("fee too high");
      for (const call of [
        esc.connect(other).setFeeBps(10), esc.connect(other).setPaused(true),
        esc.connect(other).setFeeRecipient(other.address), esc.connect(other).setMaxOfferAmount(ZERO, 1),
        esc.connect(other).transferOwnership(other.address),
      ]) await expect(call).to.be.revertedWith("not owner");
    });

    it("per-offer caps apply to BDAG and to each token separately", async () => {
      await esc.setMaxOfferAmount(ZERO, E(100));
      await esc.setMaxOfferAmount(T_ADDR, E(1000));
      await expect(esc.connect(maker).createOfferGivingNative(T_ADDR, E(1), ZERO, { value: E(101) })).to.be.revertedWith("exceeds per-offer cap");
      await esc.connect(maker).createOfferGivingNative(T_ADDR, E(1), ZERO, { value: E(100) });
      await expect(esc.connect(maker).createOfferGivingToken(T_ADDR, E(1001), E(1), ZERO)).to.be.revertedWith("exceeds per-offer cap");
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(1000), E(1), ZERO);
    });

    it("the contract has no function that lets the owner move a live offer's funds", async () => {
      const fns = esc.interface.fragments.filter((f) => f.type === "function" && f.stateMutability !== "view" && f.stateMutability !== "pure").map((f) => f.name).sort();
      expect(fns).to.deep.equal([
        "cancelOffer", "createOfferGivingNative", "createOfferGivingToken", "fillOfferGivingNative", "fillOfferGivingToken",
        "setFeeBps", "setFeeRecipient", "setMaxOfferAmount", "setPaused", "transferOwnership",
      ]);
    });
  });

  describe("attacks and edge cases", () => {
    it("re-entering cancel from inside a token transfer is blocked", async () => {
      const r = await (await ethers.getContractFactory("HsReenterToken")).deploy();
      const R = await r.getAddress();
      await r.mint(maker.address, E(10)); await r.connect(maker).approve(E_ADDR, ethers.MaxUint256);
      await esc.connect(maker).createOfferGivingToken(R, E(10), E(1), ZERO);
      await r.arm(E_ADDR, 1, 1);
      // The inner cancel hits the "reentrancy" guard; the escrow then reports the failed token call.
      await expect(esc.connect(maker).cancelOffer(1)).to.be.revertedWith("token transfer failed");
      expect((await esc.getOffer(1)).status).to.equal(1n); // still Open, nothing paid twice
      expect(await r.balanceOf(E_ADDR)).to.equal(E(10));
    });

    it("re-entering a fill from inside the taker's token payment is blocked", async () => {
      const r = await (await ethers.getContractFactory("HsReenterToken")).deploy();
      const R = await r.getAddress();
      await r.mint(taker.address, E(10)); await r.connect(taker).approve(E_ADDR, ethers.MaxUint256);
      await esc.connect(maker).createOfferGivingNative(R, E(1), ZERO, { value: E(5) });
      await r.arm(E_ADDR, 1, 2);
      await expect(esc.connect(taker).fillOfferGivingToken(1)).to.be.revertedWith("token transferFrom failed");
      expect(await bal(E_ADDR)).to.equal(E(5));
    });

    it("FINDING L-1: a fee wallet that refuses BDAG stops every fill (cancels still work)", async () => {
      const rej = await (await ethers.getContractFactory("HsRejecter")).deploy();
      await esc.setFeeRecipient(await rej.getAddress());
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(5), E(1), ZERO);
      await expect(esc.connect(taker).fillOfferGivingNative(1, { value: E(1) })).to.be.revertedWith("native transfer failed");
      await esc.connect(maker).cancelOffer(1); // maker can still get out
    });

    it("FINDING L-2: a transfer-tax token on the wanted side short-changes the maker", async () => {
      await esc.connect(maker).createOfferGivingNative(T_ADDR, E(100), ZERO, { value: E(1) });
      await tok.setFee(500); // 5% tax switched on after the offer was made
      const m0 = await tok.balanceOf(maker.address);
      await esc.connect(taker).fillOfferGivingToken(1);
      expect(await tok.balanceOf(maker.address)).to.equal(m0 + E(95)); // asked for 100
    });

    it("FINDING L-3: if the token blocks the escrow, a token offer can't be cancelled or filled", async () => {
      await esc.connect(maker).createOfferGivingToken(T_ADDR, E(5), E(1), ZERO);
      await tok.setBlocked(E_ADDR, true);
      await expect(esc.connect(maker).cancelOffer(1)).to.be.revertedWith("token transfer failed");
      await expect(esc.connect(taker).fillOfferGivingNative(1, { value: E(1) })).to.be.revertedWith("token transfer failed");
      await tok.setBlocked(E_ADDR, false);
      await esc.connect(maker).cancelOffer(1); // recovers if the token unblocks
    });

    it("a maker contract that refuses BDAG can't receive a fill, but can still cancel", async () => {
      const rej = await (await ethers.getContractFactory("HsRejecter")).deploy();
      const RJ = await rej.getAddress();
      await tok.mint(RJ, E(10));
      await rej.exec(T_ADDR, 0, tok.interface.encodeFunctionData("approve", [E_ADDR, ethers.MaxUint256]));
      await rej.exec(E_ADDR, 0, esc.interface.encodeFunctionData("createOfferGivingToken", [T_ADDR, E(10), E(1), ZERO]));
      await expect(esc.connect(taker).fillOfferGivingNative(1, { value: E(1) })).to.be.revertedWith("native transfer failed");
      await rej.exec(E_ADDR, 0, esc.interface.encodeFunctionData("cancelOffer", [1]));
      expect(await tok.balanceOf(RJ)).to.equal(E(10));
    });

    it("many random offers, fills and cancels never leave the escrow short", async () => {
      const signers = [maker, taker, other];
      const open = new Map(); // id -> offer
      let lockedBdag = 0n, lockedTok = 0n, id = 0;
      let seed = 42;
      const rnd = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
      for (let i = 0; i < 80; i++) {
        const act = rnd(3);
        if (act === 0 || open.size === 0) {
          const m = signers[rnd(3)];
          const amt = E(1 + rnd(20)), want = E(1 + rnd(20));
          if (rnd(2)) { await esc.connect(m).createOfferGivingNative(T_ADDR, want, ZERO, { value: amt }); lockedBdag += amt; open.set(++id, { m, native: true, amt, want }); }
          else { await esc.connect(m).createOfferGivingToken(T_ADDR, amt, want, ZERO); lockedTok += amt; open.set(++id, { m, native: false, amt, want }); }
        } else {
          const keys = [...open.keys()]; const k = keys[rnd(keys.length)]; const o = open.get(k);
          if (act === 1) { await esc.connect(o.m).cancelOffer(k); }
          else {
            const t = signers[rnd(3)];
            if (o.native) await esc.connect(t).fillOfferGivingToken(k); else await esc.connect(t).fillOfferGivingNative(k, { value: o.want });
          }
          if (o.native) lockedBdag -= o.amt; else lockedTok -= o.amt;
          open.delete(k);
        }
        expect(await bal(E_ADDR)).to.equal(lockedBdag);
        expect(await tok.balanceOf(E_ADDR)).to.equal(lockedTok);
      }
    });
  });
});
