# ReefLocker ("Reef Lock"): internal review

Status: **internal review only, not independently audited.** Written 13 Nov 2026 alongside the contract and its tests.

## What it does

A public time-lock. Anyone can lock any ERC-20 (mainly Reef LP tokens, or team allocations) until a
date between 30 days and 10 years ahead, paying a flat BDAG fee. Only the lock's owner can withdraw,
and only after the unlock date. The owner can push the date later (never earlier) or hand the lock to
another address (for example a multisig). Reef's labels can read `lockedSummary(token)` to show how
much of a pool's LP is locked and until when, without a manual review per project.

## Trust model

| Who | Can | Can't |
|---|---|---|
| Lock owner | withdraw after the date; extend; hand over | withdraw early; shorten; touch other locks |
| Admin (Reef's Safe) | set the fee (max 100,000 BDAG) and the fee recipient; hand over admin (two steps) | touch any locked tokens; pause; upgrade; change any lock |
| Anyone else | create locks; read everything | anything else |

There is no upgrade path, no pause, no admin withdrawal and no `selfdestruct`. Once deployed, the
rules for existing locks can't change.

## Design points

- **Credits what actually arrives.** `lock` measures the balance before and after the transfer, so a
  fee-on-transfer token is credited with the net amount and can't make the locker owe more than it holds.
- **Per-lock accounting.** Each lock records its own amount; `withdraw` pays exactly that and marks it
  withdrawn before transferring (checks-effects-interactions) under `nonReentrant`. `totalLocked`
  tracks the open total per token.
- **Fee forwarding.** The fee is forwarded to the recipient in the same transaction; if the recipient
  refuses BDAG the whole lock reverts, so the locker never holds BDAG.
- **Minimum 30 days.** So that "LP locked" on Reef always means something. Maximum 10 years, to catch
  mistyped dates.
- **Owner can be anyone.** `lock(..., owner_)` lets a deployer lock directly into a multisig's name.

## Known limits (by design, documented for users)

1. **Rebasing tokens are not supported.** If a token's balances shrink on their own, the last locks to
  withdraw could find less than they're owed. Reef LP tokens and normal ERC-20s are unaffected.
2. **`lockedSummary` loops over every lock for a token.** It's a view for off-chain reads. Spamming a
  token with tiny locks costs the fee per lock and at least 30 days of lock-up; if a token ever had
  thousands of locks, a dedicated indexer would read the `Locked`/`Withdrawn` events instead.
3. **Lost owner keys lose the lock.** Nobody, including the admin, can recover tokens for a lock whose
  owner lost access. That is the point of a lock; the site will say so before anyone locks.
4. **`locksForOwner` keeps history.** After a hand-over the id stays in the previous owner's list; the
  current owner is always `getLock(id).owner`.

## Tests

- `test/reef-locker.test.js` (Hardhat, 22 tests): locking, the fee (exact amount, zero fee, refusing
  recipient), date limits, zero values, fee-on-transfer tokens, withdrawal timing and ownership,
  isolation between locks, re-entrancy through a malicious token, extend and hand-over rules,
  `lockedSummary`, and the admin's fee-only powers.
- `test/foundry/ReefLocker.invariant.t.sol` (Foundry invariants): random locks, withdrawals,
  extensions, hand-overs and time jumps. After every step: the locker's balance equals the sum of open
  locks; deposited = open + withdrawn; no withdrawal ever happened early or by a non-owner;
  `lockedSummary` matches; the locker never holds BDAG.

## Before mainnet

- Deploy with the admin and fee recipient set to Reef's Safe, and verify the source on the explorer.
- Pick the launch fee (suggestion: low, e.g. 100 BDAG, to encourage use; it can be changed later).
- Independent review is recommended before promoting it for large locks.
