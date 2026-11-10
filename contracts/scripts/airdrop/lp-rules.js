// REEF/BDAG LP reward: rules as pure functions (no network), so anyone can unit-test and recompute them.
//
// Shape (draft, "considered, not promised" until announced):
//   - A fixed pot of REEF, paid once at the end through the same claim contract as the airdrop (ReefAirdrop).
//   - LPs keep their LP tokens in their own wallets. Nothing is staked or held by a new contract.
//   - Each eligible wallet earns in proportion to (LP balance x seconds held) across the window,
//     so adding liquidity just before the end earns almost nothing.
//   - Locked LP, contracts and team wallets are not eligible.
//   - No wallet gets more than `capBps` of the pot; anything over the cap is shared among the rest.
//   - Payouts under `minPayout` are dropped (not worth the gas to claim); what isn't allocated is
//     simply never sent to the claim contract.

const E18 = 10n ** 18n;

const LP_RULES = {
  pair: "0x1Ea359266c19635c4e92B8dEf5933AbFc6A9182D", // REEF/BDAG on Reef
  // Window: Mon 16 Nov 2026 09:00 to Mon 11 Jan 2027 09:00 (UTC+7), 8 weeks. Start inclusive, end exclusive.
  start: 1794794400,
  end: 1799632800,
  pot: 5_000n * E18,
  capBps: 2_500n, // no wallet gets more than 25% of the pot
  minPayout: 1n * E18, // payouts under 1 REEF are dropped
  // Claims close Thu 15 Apr 2027 09:00 (UTC+7).
  claimDeadline: 1807754400,
};

/**
 * Time-weighted LP holdings over [start, end).
 * opening: Map(wallet -> balance at `start`), wallets lower-cased, balances bigint.
 * transfers: [{ from, to, value: bigint, ts }] inside the window, sorted by block then log index.
 * Returns Map(wallet -> bigint weight in LP-wei x seconds).
 */
function timeWeights(opening, transfers, start, end) {
  const bal = new Map(opening);
  const since = new Map(); // wallet -> timestamp its current balance started counting
  const weight = new Map();
  const touch = (w, ts) => {
    const b = bal.get(w) || 0n;
    const t0 = since.has(w) ? since.get(w) : start;
    if (b > 0n && ts > t0) weight.set(w, (weight.get(w) || 0n) + b * BigInt(ts - t0));
    since.set(w, ts);
  };
  for (const t of transfers) {
    if (t.ts < start || t.ts >= end) throw new Error(`transfer at ${t.ts} is outside the window`);
    const ts = t.ts;
    if (t.from !== ZERO) { touch(t.from, ts); bal.set(t.from, (bal.get(t.from) || 0n) - t.value); }
    if (t.to !== ZERO) { touch(t.to, ts); bal.set(t.to, (bal.get(t.to) || 0n) + t.value); }
    if ((bal.get(t.from) || 0n) < 0n) throw new Error(`negative LP balance for ${t.from}`);
  }
  for (const w of bal.keys()) touch(w, end);
  return weight;
}

/**
 * Splits `pot` by weight, with a per-wallet cap (water-filling: capped wallets are fixed at the cap and the
 * rest is re-shared), then drops payouts under `minPayout`. Integer maths, rounding down; dust stays unallocated.
 * weights: Map(wallet -> bigint), already filtered to eligible wallets.
 * Returns { amounts: Map(wallet -> bigint), total, capped: [wallets], dropped: [wallets] }.
 */
function allocateLp(weights, pot, capBps, minPayout) {
  const cap = (pot * capBps) / 10_000n;
  const amounts = new Map();
  const capped = [];
  let open = [...weights.entries()].filter(([, w]) => w > 0n);
  let remaining = pot;
  for (;;) {
    const W = open.reduce((s, [, w]) => s + w, 0n);
    if (W === 0n) break;
    const over = open.filter(([, w]) => (remaining * w) / W > cap);
    if (!over.length) {
      for (const [a, w] of open) amounts.set(a, (remaining * w) / W);
      break;
    }
    for (const [a] of over) { amounts.set(a, cap); capped.push(a); remaining -= cap; }
    const overSet = new Set(over.map(([a]) => a));
    open = open.filter(([a]) => !overSet.has(a));
  }
  const dropped = [];
  for (const [a, v] of [...amounts]) if (v < minPayout) { amounts.delete(a); dropped.push(a); }
  const total = [...amounts.values()].reduce((s, v) => s + v, 0n);
  if (total > pot) throw new Error("allocated more than the pot");
  return { amounts, total, capped, dropped };
}

const ZERO = "0x0000000000000000000000000000000000000000";

module.exports = { LP_RULES, timeWeights, allocateLp, ZERO };
