# KitchenFactory ("The Kitchen"): internal review

Status: **internal review only, not independently audited.** Written 15 Nov 2026 with the contract and its tests.

## What it does

Anyone pays a flat BDAG fee (5,000 at launch) and gets a new `KitchenToken`: a plain OpenZeppelin ERC-20
with 18 decimals whose whole supply is minted once to the caller. The factory records every token it made
(`isKitchenToken`, `latest`, `tokensByCreator`) and forwards the fee in the same transaction.

## Trust model

| Who | Can | Can't |
|---|---|---|
| Token creator | receives the whole supply; does anything any holder can | mint more, tax, pause, block, upgrade (the token has no such functions) |
| Factory admin (Reef multisig) | set the fee (max 50,000 BDAG) and its recipient; hand over admin in two steps | touch any token or any balance; change reserved tickers |
| Anyone | make tokens; read everything | anything else |

## Design points

- **Safe by construction.** `KitchenToken` exposes only the nine standard ERC-20 functions (tested), so every
  token made here is clean on Reef's safety report: no owner, no mint, no tax, no blocklist.
- **No funds held.** Fee forwarded in the same transaction; a recipient that refuses BDAG makes `cook` revert.
- **Tickers:** 1-11 ASCII letters/digits only, so look-alike characters (Cyrillic "Т" in "USDТ") are refused;
  well-known tickers are reserved in any letter case. Names: 1-32 bytes of UTF-8, no control characters, not
  blank at either end.
- **Supply:** 1 to 1 quadrillion whole tokens.

## Known limits

1. Duplicate names/tickers are allowed (other than reserved ones). Two "PAN" tokens are different
   addresses; sites should always show the address.
2. A creator still holds the whole supply and can sell it. The site points to Reef Lock and the safety report;
   the contract can't prevent dumping.
3. Reserved tickers are fixed at deploy.

## Tests

`test/kitchen-factory.test.js` (17): token supply and surface, fee forwarding and refusal, name/ticker/supply
rules, reserved tickers in any case, listing views, zero fee, and every admin path.
