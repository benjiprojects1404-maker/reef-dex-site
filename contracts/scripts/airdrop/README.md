# REEF airdrop: snapshot and claim

Implements the rules published at https://reefdex.fyi/reef/#airdrop.

| File | What it does |
|---|---|
| `rules.js` | The rules as pure code: tiers, 0.001 BDAG tolerance, ranking, the 1,000-wallet cap, share maths. |
| `snapshot.js` | Reads Reef's public events and writes the list, amounts and Merkle proofs to `out/`. Read-only: it never signs anything. |
| `lp-rules.js`, `lp-reward.js` | The REEF/BDAG LP reward (below): its rules as pure code, and the snapshot that produces its list. |
| `config.json` | RPCs, addresses, hidden pairs and **team wallets to exclude**. |
| `../../contracts/reef/ReefAirdrop.sol` | The claim contract. No owner. |
| `../../test/reef-airdrop.test.js` | Tests for the rules and the contract. |

## Rules as implemented

- **Window:** 7 Oct 2026 09:00 to 6 Nov 2026 09:00 (UTC+7), by block timestamp. The start is inclusive and the end is exclusive.
- **Pairs:** only Reef pairs with BDAG (WBDAG) on one side count. Pair index 1 is skipped, as on the site's airdrop check.
- **Who gets credit:** each action counts for the wallet that signed the transaction (`tx.from`).
- **Tier 1 (1 share):** a swap moving 1,000+ BDAG on the BDAG side.
- **Tier 2 (3 shares):** a single Mint (one liquidity add) with 5,000+ BDAG.
- **Tier 3 (10 shares):** a Mint with 25,000+ BDAG where all three of these hold:
  - it is the pair's very first liquidity;
  - the pair is the token's first Reef pair;
  - the signer deployed the token.

  The deployer comes from the explorer API, or from `deployerOverrides`. If the deployer can't be confirmed, the wallet is counted as Tier 2 and listed under `needsReview`.
- **Tolerance:** amounts within 0.001 BDAG of a minimum count.
- **Ranking:** wallets are ranked by their first qualifying action (block, then log index). Each keeps its highest tier. Team wallets are removed, then the first 1,000 are kept.
- **Amounts:**
  - The share value is the smaller of 2,100 REEF and 2,100,000 ÷ total shares.
  - Each wallet gets its number of shares × the share value.
  - Anything left over is burned.

## After the sale closes (6 Nov, 09:00 UTC+7)

1. Add every team wallet to `config.json` → `excludedWallets`.
2. `cd contracts && node scripts/airdrop/snapshot.js`. It refuses to run before the window closes unless you pass `--allow-open` for a dry run.
3. Review `out/airdrop.json`, in particular `excludedTeamWalletsThatQualified`, `needsReview` and `liquidityRemoved` (listed wallets that later took out liquidity they were credited for adding).
4. Publish `out/` together with this folder.
5. `node scripts/airdrop/deploy-args.js`. It checks that the amounts add up to `totalAllocated` and that the root and every proof match, then prints the constructor arguments and the two transfers. Copy them; don't type them by hand.
6. Deploy `ReefAirdrop` with the printed arguments (REEF `0xb7a1e198767bf0fd4C1C3805b9757369e1c3F416`, presale `0x030d2466f634022FB93fbdF475ea81faFf2525a0`, `merkleRoot`, `totalAllocated`, `claimDeadline` `1801706400` = 4 Feb 2027 09:00 UTC+7). Verify the source and check `totalAllocated()` and `merkleRoot()` on the explorer.
7. From the airdrop holder, send **exactly `totalAllocated`** to the contract, and send the rest of the 2,100,000 REEF straight to `0x000000000000000000000000000000000000dEaD`. The contract has no "burn the surplus" function, because a surplus worked out from a mistyped `totalAllocated` could include REEF that listed wallets are owed.
8. Claims open once the presale is finalized. After the deadline, anyone can call `burnExpired()`.

## Dry run, 26 Oct 2026 (window still open, not final)

- **Activity so far:** 53 swaps and 23 liquidity adds on the two counted BDAG pairs.
- **Qualifying wallets:** 14 (8 at Tier 1, 6 at Tier 2, none at Tier 3), at 2,100 REEF per share.
- **Allocated so far:** 54,600 REEF.

## REEF/BDAG LP reward (draft, not announced)

A small, time-limited reward for people who provide liquidity to the REEF/BDAG pool. Nothing is staked:
LPs keep their LP tokens in their own wallets, and the reward is paid once at the end through a fresh
deployment of the same `ReefAirdrop` claim contract (no new contract code).

- **Window:** Mon 16 Nov 2026 09:00 to Mon 11 Jan 2027 09:00 (UTC+7), 8 weeks.
- **Pot:** 5,000 REEF, from the REEF marketing wallet.
- **How it's shared:** in proportion to LP balance x time held across the window (from the pool's LP `Transfer`
  events), so adding liquidity just before the end earns almost nothing, and removing it stops the clock.
- **Not eligible:** the locked launch liquidity (presale contract), contracts, the dead address, and every
  team wallet in `config.json`.
- **Cap:** no wallet gets more than 25% of the pot; the excess is shared among the others. Payouts under
  1 REEF are dropped. Anything not allocated is simply never sent (nothing to burn).
- **Claims:** close Thu 15 Apr 2027 09:00 (UTC+7); after that, anyone can call `burnExpired()`.

After the window closes:

1. `cd contracts && node scripts/airdrop/lp-reward.js` (once per RPC with `--rpc`; the roots must match).
2. Review `out-lp/airdrop.json`: `excluded`, `capped`, `droppedUnderMinimum`.
3. `node scripts/airdrop/deploy-args.js --file scripts/airdrop/out-lp/airdrop.json`.
4. Deploy `ReefAirdrop` with the printed arguments, then send exactly `totalAllocated` from the marketing wallet.
