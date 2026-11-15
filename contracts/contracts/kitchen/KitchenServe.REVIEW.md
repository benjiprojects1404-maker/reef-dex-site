# KitchenServe ("The Kitchen" v2): internal review

Status: **internal review only, not independently audited.** Written 15 Nov 2026 with the contract and its tests.

## What it does

One transaction: makes a plain fixed-supply `KitchenToken` (same token as v1), puts `poolPercent` (10-100%) of
the supply plus every BDAG sent above the fee into a new TOKEN/BDAG pool on Reef through Reef's router, sends the
LP tokens to `0x…dEaD`, sends the rest of the supply to the creator and the fee to the treasury. Every Kitchen
token therefore trades on Reef from its first block, and that starting liquidity can never be removed.

## Trust model

| Who | Can | Can't |
|---|---|---|
| Creator | chooses supply, pool share and starting liquidity (so the starting price); receives the rest of the supply | pull the starting liquidity (LP burned); mint, tax, pause or block (the token has no such functions) |
| Admin (Reef multisig) | set the fee (max 50,000 BDAG), the minimum liquidity (max 1,000,000 BDAG) and the fee recipient; two-step hand-over | touch any token, pool or balance; change reserved tickers |

## Design points

- **Atomic.** Token, pool, LP burn, payouts and fee all happen in one call or not at all (a refusing fee
  recipient reverts everything; tested).
- **No front-running the pool.** The token is created inside the call, so nobody can make its pair first; the
  router adds exactly the desired amounts to the brand-new pair.
- **Holds nothing.** Remaining tokens go to the creator; any BDAG refund from the router (not expected for a new
  pair) goes to the creator; the contract only accepts BDAG from the router. Balances checked to be zero in tests.
- **Same token rules as v1:** ticker letters/digits only, reserved tickers in any case, 1-32 byte names with no
  control characters, 1 to 1 quadrillion supply.
- **ReentrancyGuard** on `cook` (it calls the router and sends BDAG).

## Known limits

1. The creator still holds the part of the supply not in the pool and can sell it. The site shows each token's
   pool share, and 100% is allowed for a pure fair launch.
2. The starting price is whatever the creator sets; the site shows it before they confirm.
3. Reef-only at the start, not forever: anyone can later add the token to other DEXs.

## Tests

`test/kitchen-serve.test.js` (15), against a local Reef (WBDAG, factory, router): pool creation and amounts,
LP 100% at the dead address, 100% pool share, fee forwarding, immediate swap on Reef, the token's surface,
minimum liquidity, pool share bounds, name/ticker/supply rules, refusing treasury, direct BDAG refused, listing
views, and every admin path. The full Reef suite (183 tests) passes.
