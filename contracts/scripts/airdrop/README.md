# REEF airdrop: snapshot and claim

Implements the rules published at https://reefdex.fyi/reef/#airdrop.

| File | What it does |
|---|---|
| `rules.js` | The rules as pure code: tiers, 0.001 BDAG tolerance, ranking, the 1,000-wallet cap, share maths. |
| `snapshot.js` | Reads Reef's public events and writes the list, amounts and Merkle proofs to `out/`. Read-only: it never signs anything. |
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
3. Review `out/airdrop.json`, in particular `excludedTeamWalletsThatQualified` and `needsReview`.
4. Publish `out/` together with this folder.
5. Deploy `ReefAirdrop` with these constructor arguments:
   - REEF `0xb7a1e198767bf0fd4C1C3805b9757369e1c3F416`
   - presale `0x030d2466f634022FB93fbdF475ea81faFf2525a0`
   - `merkleRoot` and `totalAllocated` from `out/airdrop.json`
   - `claimDeadline` `1801706400` (4 Feb 2027 09:00 UTC+7)
6. Verify the source, then send 2,100,000 REEF from the airdrop holder to the contract. Anyone can then call `burnUnallocated()` to burn the part nobody on the list can claim.
7. Claims open once the presale is finalized. After the deadline, anyone can call `burnExpired()`.

## Dry run, 26 Oct 2026 (window still open, not final)

- **Activity so far:** 53 swaps and 23 liquidity adds on the two counted BDAG pairs.
- **Qualifying wallets:** 14 (8 at Tier 1, 6 at Tier 2, none at Tier 3), at 2,100 REEF per share.
- **Allocated so far:** 54,600 REEF.
