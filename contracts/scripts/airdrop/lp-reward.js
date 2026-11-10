#!/usr/bin/env node
// REEF/BDAG LP reward: reads the pool's LP Transfer events and produces the list, amounts and Merkle proofs
// in the same format as snapshot.js, so deploy-args.js can check it and ReefAirdrop can pay it.
// Rules: lp-rules.js. Read-only: it never signs or sends anything.
//
//   node scripts/airdrop/lp-reward.js [--out scripts/airdrop/out-lp] [--rpc <url>] [--allow-open]
//
// --allow-open gives a dry run while the window is still open (weights are counted up to the latest block).
// Run it once per RPC (--rpc) and compare the Merkle roots.

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");
const { StandardMerkleTree } = require("@openzeppelin/merkle-tree");
const { patternMatcher } = require("./rules");
const { LP_RULES, timeWeights, allocateLp, ZERO } = require("./lp-rules");

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "config.json"), "utf8"));
const OUT = path.resolve(opt("--out", path.join(__dirname, "out-lp")));
const PAIR = LP_RULES.pair;
// The pool was created at presale finalize on 6 Nov 2026; scanning from 6 Nov 07:00 (UTC+7) catches every LP transfer.
const SCAN_FROM_TS = 1793923200;

const EV = new ethers.Interface(["event Transfer(address indexed from, address indexed to, uint256 value)"]);
const TOPIC = EV.getEvent("Transfer").topicHash;
const log = (...a) => console.error(...a);
const fmt = (w) => ethers.formatUnits(w, 18);

async function retry(fn, tries = 4) {
  for (let i = 0; ; i++) {
    try { return await fn(); } catch (e) { if (i + 1 >= tries) throw e; await new Promise((r) => setTimeout(r, 800 * (i + 1))); }
  }
}
async function provider() {
  const only = opt("--rpc");
  for (const url of only ? [only] : cfg.rpcs) {
    try {
      const p = new ethers.JsonRpcProvider(url, 1404, { staticNetwork: true });
      await p.getBlockNumber();
      log(`RPC: ${url}`);
      return p;
    } catch (e) { log(`RPC failed: ${url} (${e.shortMessage || e.message})`); }
  }
  throw new Error("no RPC reachable");
}
async function blockAtOrAfter(p, ts, hi) {
  let lo = 0;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const b = await retry(() => p.getBlock(mid));
    if (!b) throw new Error(`RPC has no block ${mid}; use a full-history RPC`);
    if (b.timestamp >= ts) hi = mid; else lo = mid + 1;
  }
  return lo;
}
async function logs(p, from, to) {
  if (from > to) return [];
  try {
    return await retry(() => p.getLogs({ address: PAIR, topics: [TOPIC], fromBlock: from, toBlock: to }), 2);
  } catch (e) {
    if (to <= from) throw e;
    const mid = Math.floor((from + to) / 2);
    return [...(await logs(p, from, mid)), ...(await logs(p, mid + 1, to))];
  }
}

(async () => {
  const p = await provider();
  const head = await p.getBlock("latest");
  if (head.timestamp < LP_RULES.start) throw new Error("the LP reward window hasn't started yet (Mon 16 Nov 2026 09:00 UTC+7)");
  const open = head.timestamp < LP_RULES.end;
  if (open && !args.includes("--allow-open")) throw new Error("the window is still open (until Mon 11 Jan 2027 09:00 UTC+7); use --allow-open for a dry run");
  const end = open ? head.timestamp : LP_RULES.end;

  const scanFrom = await blockAtOrAfter(p, SCAN_FROM_TS, head.number);
  const startBlock = await blockAtOrAfter(p, LP_RULES.start, head.number);
  const endBlock = open ? head.number : (await blockAtOrAfter(p, LP_RULES.end, head.number)) - 1;
  log(`Scanning LP transfers from block ${scanFrom}; window blocks ${startBlock}..${endBlock}${open ? " (DRY RUN, window open)" : ""}`);

  const raw = (await logs(p, scanFrom, endBlock)).sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
  const tsOf = new Map();
  for (const n of [...new Set(raw.map((l) => l.blockNumber))]) tsOf.set(n, (await retry(() => p.getBlock(n))).timestamp);
  const parsed = raw.map((l) => {
    const ev = EV.parseLog(l);
    return { from: ev.args.from.toLowerCase(), to: ev.args.to.toLowerCase(), value: ev.args.value, ts: tsOf.get(l.blockNumber), block: l.blockNumber, tx: l.transactionHash };
  });

  // Opening balances at the start of the window.
  const opening = new Map();
  for (const t of parsed.filter((t) => t.block < startBlock)) {
    if (t.from !== ZERO) opening.set(t.from, (opening.get(t.from) || 0n) - t.value);
    if (t.to !== ZERO) opening.set(t.to, (opening.get(t.to) || 0n) + t.value);
  }
  const inWindow = parsed.filter((t) => t.block >= startBlock);
  const weights = timeWeights(opening, inWindow, LP_RULES.start, end);

  // Eligibility: not a team wallet, not the lock/presale, not the dead address, not a contract.
  const team = new Set(Object.keys(cfg.excludedWallets).map((a) => a.toLowerCase()));
  const isPattern = patternMatcher(Object.keys(cfg.excludedWalletPatterns || {}).filter((k) => !k.startsWith("_")));
  const never = new Set([cfg.presale.toLowerCase(), PAIR.toLowerCase(), "0x000000000000000000000000000000000000dead", ZERO]);
  const eligible = new Map();
  const excluded = { team: [], lockedOrBurned: [], contracts: [] };
  for (const [w, wt] of weights) {
    if (wt === 0n) continue;
    const addr = ethers.getAddress(w);
    if (never.has(w)) { excluded.lockedOrBurned.push(addr); continue; }
    if (team.has(w) || isPattern(w)) { excluded.team.push(addr); continue; }
    if ((await retry(() => p.getCode(addr))) !== "0x") { excluded.contracts.push(addr); continue; }
    eligible.set(addr, wt);
  }

  const { amounts, total, capped, dropped } = allocateLp(eligible, LP_RULES.pot, LP_RULES.capBps, LP_RULES.minPayout);
  const W = [...eligible.values()].reduce((s, v) => s + v, 0n);
  const ranked = [...amounts.entries()].sort((a, b) => (b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0));
  const tree = ranked.length ? StandardMerkleTree.of(ranked.map(([w, v]) => [w, v.toString()]), ["address", "uint256"]) : null;
  const entries = ranked.map(([w, v], i) => ({
    rank: i + 1, wallet: w, amount: v.toString(), amountREEF: fmt(v),
    sharePct: Number((eligible.get(w) * 1_000_000n) / W) / 10_000,
    proof: tree.getProof(i),
  }));
  const summary = {
    round: "REEF/BDAG LP reward",
    final: !open,
    window: { start: LP_RULES.start, end: LP_RULES.end, countedUntil: end, startBlock, endBlock },
    rules: { potREEF: fmt(LP_RULES.pot), capPct: Number(LP_RULES.capBps) / 100, minPayoutREEF: fmt(LP_RULES.minPayout), claimDeadline: LP_RULES.claimDeadline },
    pot: LP_RULES.pot.toString(),
    claimDeadline: LP_RULES.claimDeadline,
    unallocated: "not sent (stays with the sender, nothing to burn)",
    merkleRoot: tree ? tree.root : null,
    totalAllocated: total.toString(), totalAllocatedREEF: fmt(total), unallocatedREEF: fmt(LP_RULES.pot - total),
    wallets: entries.length, lpTransfersScanned: parsed.length,
    capped, droppedUnderMinimum: dropped, excluded,
  };
  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(path.join(OUT, "airdrop.json"), JSON.stringify({ ...summary, entries }, null, 2));
  fs.writeFileSync(path.join(OUT, "airdrop.csv"), "rank,wallet,sharePct,amountREEF\n" + entries.map((e) => [e.rank, e.wallet, e.sharePct, e.amountREEF].join(",")).join("\n") + "\n");
  console.log(JSON.stringify(summary, null, 2));
})().catch((e) => { console.error("ERROR: " + (e.shortMessage || e.message)); process.exit(1); });
