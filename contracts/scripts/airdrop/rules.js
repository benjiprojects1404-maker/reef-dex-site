// REEF airdrop rules, exactly as published on https://reefdex.fyi/reef/#airdrop.
// Pure functions only (no network), so the allocation can be unit-tested and recomputed by anyone.

const E18 = 10n ** 18n;

const RULES = {
  // Window: Wed 7 Oct 2026 09:00 to Fri 6 Nov 2026 09:00 (UTC+7). Start inclusive, end exclusive.
  start: 1791338400,
  end: 1793930400,
  swapMin: 1_000n * E18, // Tier 1: a swap moving at least 1,000 BDAG
  liqMin: 5_000n * E18, // Tier 2: adding at least 5,000 BDAG of liquidity in one go
  launchMin: 25_000n * E18, // Tier 3: own token's first Reef pair with at least 25,000 BDAG
  // Router maths can land a few wei under a round number, so anything within 0.001 BDAG counts
  // (same tolerance as the airdrop check on reefdex.fyi).
  tolerance: 10n ** 15n,
  maxWallets: 1000,
  pot: 2_100_000n * E18,
  perShareCap: 2_100n * E18,
  shares: { 1: 1n, 2: 3n, 3: 10n },
  // Claims close Thu 4 Feb 2027 09:00 (UTC+7).
  claimDeadline: 1801706400,
};

const meets = (amount, min) => amount + RULES.tolerance >= min;

/**
 * Tier for one on-chain action.
 * action = {
 *   wallet, block, logIndex, tx, kind: "swap" | "mint", bdag: bigint (BDAG side, wei),
 *   // mints only:
 *   firstMintOfPair: bool,      // the very first liquidity ever added to this pair
 *   firstPairOfToken: bool,     // this pair is the token's first pair on Reef
 *   walletDeployedToken: true | false | null  // null = deployer could not be confirmed
 * }
 * Returns { tier, review } where review is a note when a human must confirm Tier 3.
 */
function tierOf(a) {
  if (a.kind === "swap") return { tier: meets(a.bdag, RULES.swapMin) ? 1 : 0, review: null };
  if (a.kind !== "mint") throw new Error(`unknown action kind ${a.kind}`);
  const tier2 = meets(a.bdag, RULES.liqMin) ? 2 : 0;
  const launchShape = a.firstMintOfPair && a.firstPairOfToken && meets(a.bdag, RULES.launchMin);
  if (!launchShape) return { tier: tier2, review: null };
  if (a.walletDeployedToken === true) return { tier: 3, review: null };
  if (a.walletDeployedToken === false) return { tier: tier2, review: null };
  return { tier: tier2, review: "Tier 3 shape, but the token's deployer could not be confirmed; counted as Tier 2 until confirmed" };
}

const order = (a, b) => (a.block - b.block) || (a.logIndex - b.logIndex);

/**
 * actions: every Swap/Mint on Reef BDAG pairs inside the window, credited to the wallet that signed the tx.
 * excluded: Set of lower-case team wallets, or a function (wallet) => bool.
 */
function allocate(actions, excluded = new Set()) {
  const isExcluded = typeof excluded === "function" ? excluded : (w) => excluded.has(w);
  const byWallet = new Map();
  const review = [];
  for (const a of [...actions].sort(order)) {
    const w = a.wallet.toLowerCase();
    const { tier, review: note } = tierOf(a);
    if (note) review.push({ wallet: w, tx: a.tx, note });
    if (!tier) continue;
    const cur = byWallet.get(w);
    if (!cur) byWallet.set(w, { wallet: w, tier, first: a });
    else if (tier > cur.tier) cur.tier = tier;
  }
  const excludedHits = [];
  const ranked = [];
  for (const v of [...byWallet.values()].sort((x, y) => order(x.first, y.first))) {
    if (isExcluded(v.wallet)) excludedHits.push(v.wallet);
    else ranked.push(v);
  }
  const winners = ranked.slice(0, RULES.maxWallets);
  const totalShares = winners.reduce((s, v) => s + RULES.shares[v.tier], 0n);
  const perShare = totalShares === 0n ? 0n : (RULES.pot / totalShares < RULES.perShareCap ? RULES.pot / totalShares : RULES.perShareCap);
  const entries = winners.map((v, i) => ({
    rank: i + 1,
    wallet: v.wallet,
    tier: v.tier,
    shares: RULES.shares[v.tier],
    amount: RULES.shares[v.tier] * perShare,
    firstTx: v.first.tx,
    firstBlock: v.first.block,
  }));
  const totalAllocated = entries.reduce((s, e) => s + e.amount, 0n);
  return {
    entries,
    perShare,
    totalShares,
    totalAllocated,
    unallocated: RULES.pot - totalAllocated,
    qualifiedWallets: ranked.length,
    excludedHits,
    review,
  };
}

// "0xabcd...1234" style patterns (start and end of an address, as wallet apps show them).
function patternMatcher(patterns) {
  const list = patterns.map((p) => {
    const [a, b] = p.toLowerCase().split("...");
    if (!a || !b || !a.startsWith("0x") || a.length < 6 || b.length < 2) throw new Error(`bad wallet pattern ${p}`);
    return [a, b];
  });
  return (w) => list.some(([a, b]) => w.startsWith(a) && w.endsWith(b));
}

module.exports = { RULES, meets, tierOf, allocate, patternMatcher };
