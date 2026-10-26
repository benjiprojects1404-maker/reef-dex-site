#!/usr/bin/env node
// REEF airdrop snapshot: reads Reef's public on-chain events and produces the airdrop list,
// amounts and Merkle proofs. Anyone can run it and should get the same result.
//
//   node scripts/airdrop/snapshot.js [--out scripts/airdrop/out] [--allow-open]
//
// --allow-open lets you do a dry run before the window has closed (the result is NOT final).
// The script only reads the chain. It never signs or sends anything.

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");
const { StandardMerkleTree } = require("@openzeppelin/merkle-tree");
const { RULES, allocate } = require("./rules");

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const OUT = path.resolve(opt("--out", path.join(__dirname, "out")));
const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "config.json"), "utf8"));

const FACTORY_ABI = ["function allPairsLength() view returns (uint256)", "function allPairs(uint256) view returns (address)"];
const PAIR_ABI = ["function token0() view returns (address)", "function token1() view returns (address)"];
const EV = new ethers.Interface([
  "event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to)",
  "event Mint(address indexed sender, uint256 amount0, uint256 amount1)",
]);
const SWAP = EV.getEvent("Swap").topicHash;
const MINT = EV.getEvent("Mint").topicHash;

const log = (...a) => console.error(...a);

async function provider() {
  for (const url of cfg.rpcs) {
    try {
      const p = new ethers.JsonRpcProvider(url, 1404, { staticNetwork: true });
      await p.getBlockNumber();
      log(`RPC: ${url}`);
      return p;
    } catch (e) { log(`RPC failed: ${url} (${e.shortMessage || e.message})`); }
  }
  throw new Error("no RPC reachable");
}

async function retry(fn, tries = 4) {
  for (let i = 0; ; i++) {
    try { return await fn(); } catch (e) { if (i + 1 >= tries) throw e; await new Promise((r) => setTimeout(r, 800 * (i + 1))); }
  }
}

async function pool(items, n, fn) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (next < items.length) { const i = next++; out[i] = await fn(items[i], i); }
  }));
  return out;
}

// First block whose timestamp is >= ts.
async function blockAtOrAfter(p, ts, hi) {
  let lo = 0;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const b = await retry(() => p.getBlock(mid));
    if (b.timestamp >= ts) hi = mid; else lo = mid + 1;
  }
  return lo;
}

// getLogs over a block range, splitting the range when the node refuses a large one.
async function logs(p, address, topic, from, to) {
  try {
    return await retry(() => p.getLogs({ address, topics: [topic], fromBlock: from, toBlock: to }), 2);
  } catch (e) {
    if (to <= from) throw e;
    const mid = Math.floor((from + to) / 2);
    return [...(await logs(p, address, topic, from, mid)), ...(await logs(p, address, topic, mid + 1, to))];
  }
}

async function deployerOf(token) {
  const o = cfg.deployerOverrides[ethers.getAddress(token)] || cfg.deployerOverrides[token.toLowerCase()];
  if (o) return o.toLowerCase();
  try {
    const r = await fetch(`${cfg.explorer}/api/v2/addresses/${token}`);
    if (!r.ok) return null;
    const j = await r.json();
    return j.creator_address_hash ? j.creator_address_hash.toLowerCase() : null;
  } catch (e) { return null; }
}

async function main() {
  const p = await provider();
  const head = await p.getBlockNumber();
  const headTs = (await p.getBlock(head)).timestamp;
  if (headTs < RULES.end && !flag("--allow-open")) throw new Error("The airdrop window has not closed yet. Use --allow-open for a dry run.");
  const startBlock = await blockAtOrAfter(p, RULES.start, head);
  const endBlock = headTs < RULES.end ? head : (await blockAtOrAfter(p, RULES.end, head)) - 1;
  log(`Window blocks ${startBlock}..${endBlock}${headTs < RULES.end ? " (window still open: DRY RUN)" : ""}`);

  // Every Reef pair, in creation order; BDAG pairs only count. Hidden pairs are skipped, as on reefdex.fyi.
  const factory = new ethers.Contract(cfg.factory, FACTORY_ABI, p);
  const n = Number(await factory.allPairsLength());
  const hidden = new Set(cfg.hiddenPairIndexes);
  const wbdag = cfg.wbdag.toLowerCase();
  const pairs = await pool([...Array(n).keys()], 6, async (i) => {
    const a = (await retry(() => factory.allPairs(i))).toLowerCase();
    const c = new ethers.Contract(a, PAIR_ABI, p);
    const [t0, t1] = (await Promise.all([retry(() => c.token0()), retry(() => c.token1())])).map((x) => x.toLowerCase());
    return { index: i, address: a, t0, t1 };
  });
  const firstPairOfToken = {};
  for (const pr of pairs) for (const t of [pr.t0, pr.t1]) if (firstPairOfToken[t] === undefined) firstPairOfToken[t] = pr.address;
  const bdagPairs = {};
  for (const pr of pairs) {
    if (hidden.has(pr.index)) continue;
    if (pr.t0 === wbdag) bdagPairs[pr.address] = { bdagIs0: true, token: pr.t1 };
    else if (pr.t1 === wbdag) bdagPairs[pr.address] = { bdagIs0: false, token: pr.t0 };
  }
  const addrs = Object.keys(bdagPairs);
  log(`${n} pairs, ${addrs.length} counted BDAG pairs`);

  const swaps = [], mints = [];
  for (const a of addrs) {
    swaps.push(...(await logs(p, a, SWAP, startBlock, endBlock)));
    mints.push(...(await logs(p, a, MINT, startBlock, endBlock)));
  }
  log(`${swaps.length} swaps, ${mints.length} liquidity adds in the window`);

  // Credit each action to the wallet that signed the transaction.
  const hashes = [...new Set([...swaps, ...mints].map((l) => l.transactionHash))];
  const from = {};
  await pool(hashes, 8, async (h) => { const t = await retry(() => p.getTransaction(h)); from[h] = t.from.toLowerCase(); });

  // The very first Mint on each pair that had a large enough add in the window (Tier 3 check).
  const firstMint = {};
  const bigMintPairs = [...new Set(mints.filter((l) => {
    const ev = EV.parseLog(l).args, info = bdagPairs[l.address.toLowerCase()];
    return (info.bdagIs0 ? ev.amount0 : ev.amount1) + RULES.tolerance >= RULES.launchMin;
  }).map((l) => l.address.toLowerCase()))];
  for (const a of bigMintPairs) {
    const all = await logs(p, a, MINT, 0, endBlock);
    if (all.length) firstMint[a] = `${all[0].transactionHash}:${all[0].index}`;
  }
  const deployers = {};
  for (const a of bigMintPairs) { const t = bdagPairs[a].token; deployers[t] = await deployerOf(t); }

  const actions = [];
  for (const l of swaps) {
    const info = bdagPairs[l.address.toLowerCase()], ev = EV.parseLog(l).args;
    const bIn = info.bdagIs0 ? ev.amount0In : ev.amount1In, bOut = info.bdagIs0 ? ev.amount0Out : ev.amount1Out;
    actions.push({ wallet: from[l.transactionHash], block: l.blockNumber, logIndex: l.index, tx: l.transactionHash, kind: "swap", bdag: bIn > bOut ? bIn : bOut });
  }
  for (const l of mints) {
    const pa = l.address.toLowerCase(), info = bdagPairs[pa], ev = EV.parseLog(l).args;
    const w = from[l.transactionHash];
    const dep = deployers[info.token];
    actions.push({
      wallet: w, block: l.blockNumber, logIndex: l.index, tx: l.transactionHash, kind: "mint",
      bdag: info.bdagIs0 ? ev.amount0 : ev.amount1,
      firstMintOfPair: firstMint[pa] === `${l.transactionHash}:${l.index}`,
      firstPairOfToken: firstPairOfToken[info.token] === pa,
      walletDeployedToken: dep === undefined ? false : dep === null ? null : dep === w,
    });
  }

  const excluded = new Set(Object.keys(cfg.excludedWallets).map((a) => a.toLowerCase()));
  const res = allocate(actions, excluded);
  const tree = res.entries.length ? StandardMerkleTree.of(res.entries.map((e) => [ethers.getAddress(e.wallet), e.amount.toString()]), ["address", "uint256"]) : null;

  fs.mkdirSync(OUT, { recursive: true });
  const fmt = (wei) => ethers.formatUnits(wei, 18);
  const list = res.entries.map((e, i) => ({
    rank: e.rank, wallet: ethers.getAddress(e.wallet), tier: e.tier, shares: Number(e.shares),
    amount: e.amount.toString(), amountREEF: fmt(e.amount), firstTx: e.firstTx, firstBlock: e.firstBlock,
    proof: tree.getProof(i),
  }));
  const summary = {
    final: headTs >= RULES.end,
    window: { start: RULES.start, end: RULES.end, startBlock, endBlock },
    rules: { swapMinBDAG: fmt(RULES.swapMin), liqMinBDAG: fmt(RULES.liqMin), launchMinBDAG: fmt(RULES.launchMin), toleranceBDAG: fmt(RULES.tolerance), maxWallets: RULES.maxWallets, potREEF: fmt(RULES.pot), perShareCapREEF: fmt(RULES.perShareCap), shares: { 1: 1, 2: 3, 3: 10 }, claimDeadline: RULES.claimDeadline },
    merkleRoot: tree ? tree.root : null,
    perShareREEF: fmt(res.perShare), totalShares: Number(res.totalShares),
    totalAllocated: res.totalAllocated.toString(), totalAllocatedREEF: fmt(res.totalAllocated), unallocatedREEF: fmt(res.unallocated),
    wallets: list.length, qualifiedWallets: res.qualifiedWallets,
    byTier: [1, 2, 3].reduce((o, t) => ({ ...o, [t]: list.filter((e) => e.tier === t).length }), {}),
    excludedTeamWalletsThatQualified: res.excludedHits.map((a) => ethers.getAddress(a)),
    needsReview: res.review,
  };
  fs.writeFileSync(path.join(OUT, "airdrop.json"), JSON.stringify({ ...summary, entries: list }, null, 2));
  fs.writeFileSync(path.join(OUT, "airdrop.csv"), "rank,wallet,tier,shares,amountREEF,firstTx\n" + list.map((e) => [e.rank, e.wallet, e.tier, e.shares, e.amountREEF, e.firstTx].join(",")).join("\n") + "\n");
  if (tree) fs.writeFileSync(path.join(OUT, "tree.json"), JSON.stringify(tree.dump(), null, 2));
  console.log(JSON.stringify(summary, null, 2));
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
