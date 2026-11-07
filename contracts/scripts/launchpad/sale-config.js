#!/usr/bin/env node
// Builds the ReefLaunchSale constructor tuple for Remix from a project's plain numbers,
// with Reef's standard terms filled in and every beta rule checked first.
//   node scripts/launchpad/sale-config.js scripts/launchpad/<project>.json
// Prints: the checks, the tuple to paste into Remix's "c" field, and what the project must deposit.
// Reads nothing from the chain and sends nothing.
const fs = require("fs");
const { parseUnits, formatUnits, getAddress } = require("ethers");

const STANDARD = {
  router: "0xbd6fbA41Ab84292163A599510a12d6Bf8B7CCc76",
  feeRecipient: "0xECc48Bca8c28Caa8e980E308DFb08B8dEfE86267",
  feeBps: 200n,
  reef: "0xb7a1e198767bf0fd4C1C3805b9757369e1c3F416",
  bondAmount: 1000n * 10n ** 18n,
  reefSliceBps: 2000n,
  minReefDepth: 10_000_000n * 10n ** 18n,
  lpLockSeconds: 365n * 86400n,
};
const BETA_MAX_HARDCAP = 5_000_000n * 10n ** 18n; // keep in step with launch/sale/index.html
const MIN_POOL_LIQUIDITY = 1000n;

const file = process.argv[2];
if (!file) { console.error("usage: node scripts/launchpad/sale-config.js <config.json>"); process.exit(1); }
const c = JSON.parse(fs.readFileSync(file, "utf8"));
const errors = [], notes = [];
const addr = (k) => { try { const a = getAddress(c[k]); if (/^0x0{40}$/i.test(a)) throw 0; return a; } catch (e) { errors.push(`${k} is not a valid address`); return c[k]; } };
const bdag = (k) => { try { return parseUnits(String(c[k]), 18); } catch (e) { errors.push(`${k} is not a number`); return 0n; } };
const ts = (s) => { const t = Date.parse(String(s).replace(" ", "T") + ":00+07:00"); if (Number.isNaN(t)) errors.push(`bad time "${s}"`); return BigInt(Math.floor(t / 1000)); };
const isqrt = (n) => { if (n < 2n) return n; let x = n, y = (x + 1n) / 2n; while (y < x) { x = y; y = (x + n / x) / 2n; } return x; };

const token = addr("token"), projectWallet = addr("projectWallet"), lpBeneficiary = addr("lpBeneficiary");
const dec = BigInt(c.tokenDecimals ?? 18), unit = 10n ** dec;
const salePrice = bdag("salePriceBDAG"), listingPrice = bdag("listingPriceBDAG");
const softCap = bdag("softCapBDAG"), hardCap = bdag("hardCapBDAG"), maxPerWallet = bdag("maxPerWalletBDAG");
const startTime = ts(c.start), endTime = ts(c.end);
const now = BigInt(Math.floor(Date.now() / 1000));

// Same rules as the contract's constructor, plus the beta cap and timing advice.
if (salePrice <= 0n) errors.push("sale price must be above zero");
if (listingPrice < salePrice) errors.push("pool opening price must be at least the sale price");
if (softCap <= 0n) errors.push("soft cap must be above zero");
if (softCap > hardCap) errors.push("soft cap is above the hard cap");
if (hardCap > BETA_MAX_HARDCAP) errors.push(`hard cap is above the 5,000,000 BDAG beta limit`);
if (maxPerWallet <= 0n) errors.push("per-wallet cap must be above zero");
if (endTime <= startTime) errors.push("end must be after start");
if (startTime <= now) errors.push("start time is in the past");
else if (startTime - now < 86400n) notes.push("start is under a day away: deploy now, and note the REEF pool needs a day of price history before launch (it is skipped otherwise)");
if ([token, projectWallet, lpBeneficiary].some((a) => a && a.toLowerCase && a.toLowerCase() === STANDARD.reef.toLowerCase())) errors.push("REEF can't be the sale token or a wallet here");

const tokensFor = (b) => (salePrice ? (b * unit) / salePrice : 0n);
const fee = (b) => (b * STANDARD.feeBps) / 10000n;
const tokensForPool = (b) => (listingPrice ? ((b - fee(b)) * unit) / listingPrice : 0n);
if (salePrice && listingPrice) {
  if (tokensFor(hardCap) === 0n || tokensForPool(hardCap) === 0n) errors.push("price too high for the cap (rounds to zero tokens)");
  const pooledAtSoft = softCap - fee(softCap);
  const mainAtSoft = pooledAtSoft - (pooledAtSoft * STANDARD.reefSliceBps) / 10000n;
  if (isqrt(((mainAtSoft * unit) / listingPrice) * mainAtSoft) <= MIN_POOL_LIQUIDITY) errors.push("soft cap too small to open a pool; raise it");
}

console.log(`\nChecks for ${file}`);
for (const e of errors) console.log("  ✗ " + e);
for (const n of notes) console.log("  ! " + n);
if (errors.length) { console.log("\nFix the above; nothing printed for Remix.\n"); process.exit(1); }
console.log("  ✓ matches Reef's standard terms and the beta cap");

const tuple = [token, STANDARD.router, projectWallet, lpBeneficiary, STANDARD.feeRecipient, STANDARD.feeBps,
  salePrice, listingPrice, softCap, hardCap, maxPerWallet, startTime, endTime, STANDARD.lpLockSeconds,
  STANDARD.reef, STANDARD.bondAmount, STANDARD.reef, STANDARD.reefSliceBps, STANDARD.minReefDepth];
const required = tokensFor(hardCap) + tokensForPool(hardCap);
console.log("\nPaste into Remix's constructor field \"c\" (one line):\n");
console.log("[" + tuple.map((v) => (typeof v === "bigint" ? `"${v}"` : `"${v}"`)).join(",") + "]");
console.log(`\nAfter deploying, the project sends the sale contract (plain transfers):`);
console.log(`  ${formatUnits(required, dec)} tokens  (= ${required} base units; also shown by tokensRequired())`);
console.log(`  1000 REEF bond  (token ${STANDARD.reef})`);
console.log(`\nSale window: ${c.start} to ${c.end} (UTC+7)  =  ${startTime} to ${endTime}`);
console.log(`At the hard cap: ${formatUnits(tokensFor(hardCap), dec)} tokens to buyers, ${formatUnits(fee(hardCap), 18)} BDAG fee.\n`);
