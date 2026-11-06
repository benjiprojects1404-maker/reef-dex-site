#!/usr/bin/env node
// REEF airdrop, second round: COOKED x NOCAP card mints from Fri 6 Nov 2026 09:00 to Sat 14 Nov 2026 09:00 (UTC+7).
// Reads ReefCards' public CardMinted events and produces the second-round list, amounts and Merkle proofs,
// in the same format as snapshot.js, so deploy-args.js can check it.
//
//   node scripts/airdrop/card-round.js [--main scripts/airdrop/out/airdrop.json] [--out scripts/airdrop/out-cards] [--rpc <url>] [--allow-open]
//
// Rules (as published on reefdex.fyi/reef/#airdrop):
//   - Each card mint in the window counts as Tier 2 (3 shares), credited to the wallet that signed the mint.
//   - Only wallets NOT already on the main-round list, and not team wallets (config.json excludedWallets).
//   - One spot per wallet. Ranked by first qualifying mint. Same 2,100 REEF per-share cap: 6,300 REEF each.
//   - Paid from the 472,500 REEF hold-back (75 wallets at most); whatever isn't allocated is burned.
// Run it once per RPC (--rpc) and compare the Merkle roots. It only reads the chain.

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");
const { StandardMerkleTree } = require("@openzeppelin/merkle-tree");
const { RULES } = require("./rules");

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "config.json"), "utf8"));
const MAIN = path.resolve(opt("--main", path.join(__dirname, "out", "airdrop.json")));
const OUT = path.resolve(opt("--out", path.join(__dirname, "out-cards")));

const CARDS = cfg.cards || "0xc30918566EE9dA799622E14B14133a21652e4062";
const START = RULES.end;                                  // Fri 6 Nov 2026 09:00 UTC+7
const END = Math.floor(Date.UTC(2026, 10, 14, 2) / 1000); // Sat 14 Nov 2026 09:00 UTC+7
const SHARES = 3n;
const PER_WALLET = RULES.perShareCap * SHARES;            // 6,300 REEF
const POT = 472500n * 10n ** 18n;                         // card-round hold-back
const MAX_WALLETS = Number(POT / PER_WALLET);             // 75

const EV = new ethers.Interface(["event CardMinted(address indexed to, uint256 indexed tokenId, uint8 brand, uint256 bdagIn, uint256 liquidityBurned)"]);
const TOPIC = EV.getEvent("CardMinted").topicHash;
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
  try {
    return await retry(() => p.getLogs({ address: CARDS, topics: [TOPIC], fromBlock: from, toBlock: to }), 2);
  } catch (e) {
    if (to <= from) throw e;
    const mid = Math.floor((from + to) / 2);
    return [...(await logs(p, from, mid)), ...(await logs(p, mid + 1, to))];
  }
}

(async () => {
  const main = JSON.parse(fs.readFileSync(MAIN, "utf8"));
  if (!main.final) throw new Error(`${MAIN} is not the final main-round list`);
  const onMain = new Set(main.entries.map((e) => e.wallet.toLowerCase()));
  const team = new Set(Object.keys(cfg.excludedWallets).map((a) => a.toLowerCase()));

  const p = await provider();
  const head = await p.getBlock("latest");
  const open = head.timestamp < END;
  if (open && !args.includes("--allow-open")) throw new Error("the card window is still open (until Sat 14 Nov 09:00 UTC+7); use --allow-open for a dry run");
  const startBlock = await blockAtOrAfter(p, START, head.number);
  const endBlock = open ? head.number : (await blockAtOrAfter(p, END, head.number)) - 1;
  log(`Window blocks ${startBlock}..${endBlock}${open ? " (window still open: DRY RUN)" : ""}`);

  const raw = (await logs(p, startBlock, endBlock)).sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
  log(`${raw.length} card mints in the window`);

  const first = new Map(); // signer -> first mint
  const skippedMain = new Set(), skippedTeam = new Set(), needsReview = [];
  for (const l of raw) {
    const ev = EV.parseLog(l);
    const tx = await retry(() => p.getTransaction(l.transactionHash));
    const signer = tx.from.toLowerCase();
    if (ev.args.to.toLowerCase() !== signer) needsReview.push({ wallet: ethers.getAddress(signer), tx: l.transactionHash, note: `card minted to ${ev.args.to}, not to the signer; credited to the signer` });
    if (onMain.has(signer)) { skippedMain.add(signer); continue; }
    if (team.has(signer)) { skippedTeam.add(signer); continue; }
    if (!first.has(signer)) first.set(signer, { block: l.blockNumber, tx: l.transactionHash, tokenId: ev.args.tokenId.toString() });
  }

  const ranked = [...first.entries()].sort((a, b) => a[1].block - b[1].block);
  const inList = ranked.slice(0, MAX_WALLETS);
  const overCap = ranked.slice(MAX_WALLETS).map(([w]) => ethers.getAddress(w));
  const total = PER_WALLET * BigInt(inList.length);

  const tree = inList.length ? StandardMerkleTree.of(inList.map(([w]) => [ethers.getAddress(w), PER_WALLET.toString()]), ["address", "uint256"]) : null;
  const entries = inList.map(([w, f], i) => ({
    rank: i + 1, wallet: ethers.getAddress(w), tier: 2, shares: 3,
    amount: PER_WALLET.toString(), amountREEF: fmt(PER_WALLET), firstTx: f.tx, firstBlock: f.block,
    proof: tree.getProof(i),
  }));
  const summary = {
    round: "COOKED x NOCAP cards, second round",
    final: !open,
    window: { start: START, end: END, startBlock, endBlock },
    rules: { tier: 2, shares: 3, perWalletREEF: fmt(PER_WALLET), maxWallets: MAX_WALLETS, potREEF: fmt(POT), claimDeadline: RULES.claimDeadline },
    pot: POT.toString(),
    merkleRoot: tree ? tree.root : null,
    totalAllocated: total.toString(), totalAllocatedREEF: fmt(total), unallocatedREEF: fmt(POT - total),
    wallets: entries.length, cardMints: raw.length,
    alreadyOnMainList: [...skippedMain].map((a) => ethers.getAddress(a)),
    excludedTeamWalletsThatMinted: [...skippedTeam].map((a) => ethers.getAddress(a)),
    overCap, needsReview,
  };
  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(path.join(OUT, "airdrop.json"), JSON.stringify({ ...summary, entries }, null, 2));
  fs.writeFileSync(path.join(OUT, "airdrop.csv"), "rank,wallet,tier,shares,amountREEF,firstTx\n" + entries.map((e) => [e.rank, e.wallet, e.tier, e.shares, e.amountREEF, e.firstTx].join(",")).join("\n") + "\n");
  console.log(JSON.stringify(summary, null, 2));
})().catch((e) => { console.error("ERROR: " + (e.shortMessage || e.message)); process.exit(1); });
