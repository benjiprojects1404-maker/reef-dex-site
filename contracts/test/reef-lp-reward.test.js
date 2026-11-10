const { expect } = require("chai");
const { LP_RULES, timeWeights, allocateLp, ZERO } = require("../scripts/airdrop/lp-rules");

const E18 = 10n ** 18n;
const A = "0xaaaa", B = "0xbbbb", C = "0xcccc";

describe("REEF/BDAG LP reward rules", () => {
  const S = 1000, E = 2000; // a 1,000-second window

  it("weights a balance held for the whole window by balance x duration", () => {
    const w = timeWeights(new Map([[A, 10n]]), [], S, E);
    expect(w.get(A)).to.equal(10n * 1000n);
  });

  it("counts liquidity added late for only the time it was held", () => {
    const w = timeWeights(new Map([[A, 10n]]), [{ from: ZERO, to: B, value: 10n, ts: 1900 }], S, E);
    expect(w.get(A)).to.equal(10_000n);
    expect(w.get(B)).to.equal(1_000n); // 100 seconds, so 10x less than A
  });

  it("moves weight with transfers and stops counting removed liquidity", () => {
    const w = timeWeights(new Map([[A, 10n]]), [
      { from: A, to: C, value: 4n, ts: 1500 },   // A sends 4 LP to C halfway
      { from: C, to: ZERO, value: 4n, ts: 1750 }, // C burns them (removes liquidity)
    ], S, E);
    expect(w.get(A)).to.equal(10n * 500n + 6n * 500n);
    expect(w.get(C)).to.equal(4n * 250n);
  });

  it("rejects transfers outside the window and negative balances", () => {
    expect(() => timeWeights(new Map(), [{ from: ZERO, to: A, value: 1n, ts: E }], S, E)).to.throw("outside the window");
    expect(() => timeWeights(new Map(), [{ from: A, to: B, value: 1n, ts: 1500 }], S, E)).to.throw("negative");
  });

  it("splits the pot pro rata and never allocates more than the pot", () => {
    const r = allocateLp(new Map([[A, 1n], [B, 1n], [C, 1n]]), 1000n * E18, 10_000n, 0n);
    expect(r.amounts.get(A)).to.equal(r.amounts.get(B));
    expect(r.total <= 1000n * E18).to.equal(true);
    expect(1000n * E18 - r.total < 3n).to.equal(true); // only rounding dust left over
  });

  it("caps a dominant wallet at 25% and shares the excess among the rest", () => {
    const D = "0xdddd", F = "0xffff";
    const r = allocateLp(new Map([[A, 90n], [B, 25n], [C, 25n], [D, 25n], [F, 25n]]), 1000n * E18, 2_500n, 0n);
    expect(r.amounts.get(A)).to.equal(250n * E18);
    expect(r.capped).to.deep.equal([A]);
    for (const w of [B, C, D, F]) expect(r.amounts.get(w)).to.equal(1875n * E18 / 10n); // 750 shared 4 ways
    expect(r.total).to.equal(1000n * E18);
  });

  it("leaves the excess unallocated when every wallet is capped", () => {
    const r = allocateLp(new Map([[A, 90n], [B, 6n], [C, 4n]]), 1000n * E18, 2_500n, 0n);
    expect(r.total).to.equal(750n * E18); // 3 wallets x 25%; the other 250 is simply not sent
  });

  it("drops payouts under the minimum", () => {
    const r = allocateLp(new Map([[A, 1_000_000n], [B, 1n]]), 1000n * E18, 10_000n, 1n * E18);
    expect(r.amounts.has(B)).to.equal(false);
    expect(r.dropped).to.deep.equal([B]);
  });

  it("uses an 8-week window, a 5,000 REEF pot and a claim deadline after the window", () => {
    expect(LP_RULES.end - LP_RULES.start).to.equal(8 * 7 * 24 * 3600);
    expect(LP_RULES.pot).to.equal(5_000n * E18);
    expect(LP_RULES.claimDeadline > LP_RULES.end).to.equal(true);
  });
});
