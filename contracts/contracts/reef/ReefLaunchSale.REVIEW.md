# ReefLaunchSale: self-review (beta)

**Status:** unaudited. This is the builder's own review, written on 7 Nov 2026 against `ReefLaunchSale.sol` as merged in PRs #85–#87 plus the fixes in this PR. It is **not** an independent audit. Reef Launchpad runs as a capped beta (see "Beta limits") until an independent review is funded.

**Scope:** `contracts/reef/ReefLaunchSale.sol` (about 360 lines of code). It calls Reef's live factory, pair and WBDAG contracts, which are outside this review.

## What the contract promises

1. BDAG paid in can only leave in three ways: into the launch pools, as the disclosed fee (at most 3%; 2% for Reef launches), or back to the buyer as a refund.
2. Once a sale reaches its soft cap, anyone can launch it after the close (or straight away at the hard cap). Both pools open at the listed price.
3. After a launch, every buyer can claim exactly `contributed × 10^decimals / salePrice` tokens, with no deadline.
4. If the sale fails, every buyer can refund exactly what they paid, and the project gets all of its tokens back.
5. The project bond is burned only if buyers reached the soft cap but the pool never opened. Otherwise it goes back to the project.
6. The LP tokens stay in the contract until the lock ends, then can only go to the named beneficiary.
7. No owner, no admin functions, no upgrades, no pause. Every setting is fixed at deployment and readable with `terms()`.

## How it was checked

| Check | Result |
|---|---|
| Hardhat unit tests (`test/reef-launch-sale.test.js`, 25 tests) against the real Reef factory, router and pair | Pass |
| Foundry stateful fuzzing (`test/foundry/ReefLaunchSale.invariant.t.sol`): 10 invariants × 256 runs × 100 random calls. The calls are buys, time passing, REEF price pushes in both directions, finalize, claims, refunds, returnTokens, settleBond and withdrawLP across five buyers | Pass. Every outcome was reached at least once: launch with and without the REEF pool, claims, refunds, bond returned, bond burned |
| Foundry whole-sale fuzzing across 6–18 decimals, prices of 0.001–1,000 BDAG, listing premiums of 0–200%, hard caps of 10k–5M BDAG, and both success and failure paths | Pass |
| End-to-end browser test of the sale page on a local chain (buy → launch → claim, and a failed sale → refund → return tokens → return bond) | Pass |

The invariants checked after every random call:
- BDAG held equals BDAG paid minus refunds before a launch, and is zero after.
- The treasury holds exactly `totalRaised × feeBps / 10000` after a launch, and nothing before.
- After a launch, the token balance covers every unclaimed buyer.
- Before the sale resolves, the deposit covers every claim plus the pool at the hard cap.
- A sale is never both launched and refunding.
- Every claim and refund paid exactly the right amount, once.
- Finalize never reverts when its conditions are met, even with the REEF price pushed just before.
- Both pools open at the listing price, and the REEF slice is exactly `reefSliceBps` of the pooled BDAG.
- The bond is burned only when the launch was blocked; otherwise all of it goes back.

### Found and fixed during this review

- **Small pools could block a launch.** Reef pools permanently lock the first 1,000 LP units. If a raise was small enough that either pool fell under that, finalize reverted. Buyers then fell back to refunds, and the project's bond was burned through no fault of its own. Found by the whole-sale fuzz test.
  - **Fix:** the contract now refuses to deploy unless a raise at the soft cap can open the TOKEN/BDAG pool. That means the soft cap must be above zero. The REEF slice now skips itself if its pool would be too small, in the same way as its other skip cases.

## Checklist

| Area | Finding |
|---|---|
| **Access control** | No owner or privileged role. Anyone can call `finalize`, `returnTokens`, `settleBond` and `withdrawLP`. Each one can only send funds to fixed addresses (pools, treasury, project wallet, LP beneficiary, dead address) or to the caller's own claim or refund. |
| **Reentrancy** | Every function that moves value is `nonReentrant`. State is updated before external transfers (`settled`, `finalized`, `refunding`, `bondSettled`). Refunds use `call`; a buyer whose wallet rejects BDAG only blocks their own refund (tested). |
| **Arithmetic and rounding** | Solidity 0.8 checked maths. Every division rounds down in the contract's favour, so claims never exceed the deposit. Dust of at most 1 token unit per buyer can remain after everyone claims (fuzzed). The price accumulator uses `unchecked` subtraction, the same way Uniswap V2 oracles do. |
| **Token behaviour** | Fee-on-transfer tokens are refused at finalize (the balance delta is checked for both pools). Rebasing tokens, tokens with blocklists or pauses, and tokens with hooks are **not** handled. A token that blocks the sale contract could stop claims. Mitigation: vetting; standard ERC-20 only. |
| **Price manipulation** | The REEF purchase is checked against REEF's average price since deployment (at least 1 day; normally the whole sale window). If the price is pushed more than 5% away, the slice is skipped rather than reverted. Pushing a long average costs far more than it could gain. The slice is also skipped below `minReefDepth` (10M BDAG for Reef launches). |
| **Blocking a launch** | A TOKEN/BDAG pool that already has liquidity, or holds more than 1% of the pool's tokens, makes finalize revert. Refunds then follow and the bond is burned. Only people holding the sale token can do this before launch, which normally means only the project (see Known risks). Dust and WBDAG donations can't block a launch. |
| **Timing** | Uses `block.timestamp` for the window, the 7-day refund delay and the LP lock. Validators can only nudge timestamps by seconds, which doesn't matter at these scales. The price accumulator uses `uint32` time like Uniswap V2, which works until 2106. |
| **Front-running** | Finalize can be front-run, but the outcome is the same whoever calls it. Buys can't be front-run in a harmful way because the price is fixed. |
| **Denial of service** | No loops over buyers. Claims and refunds are pull-based and per buyer. |
| **Forced BDAG** | BDAG force-sent to the contract (for example via `selfdestruct`) stays stuck there. Finalize only uses `totalRaised`, so no promise above is affected. |
| **Settings validation** | Zero addresses, a fee above 3%, a listing price below the sale price, bad caps, a zero soft cap, a soft cap too small to open a pool, a start time in the past, a lock under 180 days, the bond or REEF token equal to the sale token, and a slice above 50% are all rejected at deployment. |
| **Events** | Every state change emits an event. Slice skips emit `ReefSliceSkipped(reason)`. |
| **Upgrades** | None. A bug fix means a new contract for future sales. Live sales keep their contract. |

## Known risks (not fixed by code)

1. **The project, or anyone it gave tokens to before launch, can block the launch** by seeding a TOKEN/BDAG pool or pre-loading the pair. Buyers get refunds and the project's bond is burned. That is the bond's purpose, but a third party holding tokens could do it to an honest project. Vetting rule: the project must not distribute any sale tokens before launch.
2. **Unusual tokens** (rebasing, blocklists, pauses, hooks) are out of scope. Vetting rule: standard, ownerless or renounced ERC-20 only, checked before listing.
3. **There is no independent audit.** The tests show the promises hold across a very large number of random cases. They don't prove there is no bug the tests didn't think to look for.
4. **The `TOKEN/REEF` pool moves with REEF's price as well as the token's.** This is disclosed on the sale page.

## Beta limits until an independent review

- Each sale's hard cap is limited to **5,000,000 BDAG**. The sale page refuses to list anything larger unless that one listing is explicitly overridden after review. The limit is one number on the sale page (`BETA_MAX_HARDCAP`) and can be changed in a one-line update.
- The first launches are only Build & Launch service clients who accept the unaudited-beta terms in writing. The US/UK exclusion and basic vetting stay in place.
- The 2% fees from the first launches go towards an independent review, after which the cap can be lifted.
