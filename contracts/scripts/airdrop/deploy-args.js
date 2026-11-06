#!/usr/bin/env node
// Checks out/airdrop.json and prints the exact ReefAirdrop constructor arguments and transfers.
// Read-only: it never signs or sends anything.
//
//   node scripts/airdrop/deploy-args.js [--file scripts/airdrop/out/airdrop.json]
//   (card round: --file scripts/airdrop/out-cards/airdrop.json; the burn line then uses that round's 472,500 pot)
//
// It refuses to print anything if:
//   - the snapshot isn't final,
//   - the amounts don't add up to totalAllocated,
//   - the Merkle root or any proof doesn't match the entries.
// Copy the printed values; don't type them by hand.

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");
const { StandardMerkleTree } = require("@openzeppelin/merkle-tree");
const { RULES } = require("./rules");

const args = process.argv.slice(2);
const i = args.indexOf("--file");
const file = path.resolve(i >= 0 ? args[i + 1] : path.join(__dirname, "out", "airdrop.json"));
const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "config.json"), "utf8"));
const out = JSON.parse(fs.readFileSync(file, "utf8"));

const fail = (m) => { console.error(`STOP: ${m}`); process.exit(1); };

if (!out.final) fail("this snapshot is a dry run (final: false). Re-run snapshot.js after the window closes.");
if (!out.entries || !out.entries.length) fail("no entries in the list.");

const sum = out.entries.reduce((s, e) => s + BigInt(e.amount), 0n);
if (sum !== BigInt(out.totalAllocated)) fail(`entries add up to ${sum}, but totalAllocated says ${out.totalAllocated}.`);
const pot = out.pot ? BigInt(out.pot) : RULES.pot; // card round: its own 472,500 hold-back
if (sum > pot) fail(`allocated more than the ${ethers.formatUnits(pot, 18)} REEF pot.`);

const seen = new Set();
for (const e of out.entries) {
  const w = ethers.getAddress(e.wallet);
  if (seen.has(w)) fail(`${w} is listed twice.`);
  seen.add(w);
}

const tree = StandardMerkleTree.of(out.entries.map((e) => [ethers.getAddress(e.wallet), e.amount]), ["address", "uint256"]);
if (tree.root !== out.merkleRoot) fail(`Merkle root in the file (${out.merkleRoot}) doesn't match the entries (${tree.root}).`);
out.entries.forEach((e, n) => {
  if (!StandardMerkleTree.verify(tree.root, ["address", "uint256"], [ethers.getAddress(e.wallet), e.amount], e.proof)) fail(`proof for ${e.wallet} (rank ${e.rank}) doesn't verify.`);
  if (JSON.stringify(e.proof) !== JSON.stringify(tree.getProof(n))) fail(`proof for ${e.wallet} isn't the one this tree produces.`);
});

const reviews = (out.needsReview || []).length;
const removed = (out.liquidityRemoved || []).length;
const fmt = (wei) => ethers.formatUnits(wei, 18);
const burn = pot - sum;

console.log(`Checked ${out.entries.length} wallets, ${fmt(sum)} REEF. Root and every proof match.`);
if (reviews || removed) console.log(`NOTE: ${reviews} needsReview item(s), ${removed} liquidityRemoved item(s). Resolve them before deploying.`);
console.log("");
console.log("ReefAirdrop constructor arguments:");
console.log(`  _token          ${cfg.reefToken}`);
console.log(`  _presale        ${cfg.presale}`);
console.log(`  _merkleRoot     ${tree.root}`);
console.log(`  _totalAllocated ${sum.toString()}   (${fmt(sum)} REEF)`);
console.log(`  _claimDeadline  ${RULES.claimDeadline}`);
console.log("");
console.log("Then, from the airdrop holder:");
console.log(`  1. send exactly ${sum.toString()} wei (${fmt(sum)} REEF) to the deployed ReefAirdrop`);
console.log(`  2. send ${burn.toString()} wei (${fmt(burn)} REEF) to 0x000000000000000000000000000000000000dEaD`);
console.log("");
console.log("After deploying, check on the explorer that totalAllocated() and merkleRoot() show the values above.");
