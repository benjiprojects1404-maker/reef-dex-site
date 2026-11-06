# Contracts deployed from Remix

These were compiled and deployed in Remix with Solidity 0.8.20, separately from the rest of
Reef (Hardhat/Foundry, 0.8.24). They sit outside `contracts/` so the 0.8.24 builds don't
try to compile them.

| Contract | Address | Schedule (as published) |
|---|---|---|
| `ReefVesting.sol`: dev vesting | `0x5468821749B936ffa6C3aF840841058b026E288f` | 12-month cliff, 36 months |
| `ReefVesting.sol`: treasury vesting | `0x8750aC546e0B6234B292F3830958F780E3e304BD` | 6-month cliff, 36 months |
| `ReefVesting.sol`: liquidity vesting | `0xa3892120BC98e3AFB95730D9Dc37572e1D1A3455` | 6-month cliff, 36 months (deployed 6 Nov 2026) |
| `ReefVesting.sol`: marketing vesting | `0xF821AFc03d2aCcdad3Ebfb9b16E8847EeA4eBC46` | 6-month cliff, 36 months (deployed 6 Nov 2026) |

## Launch-day locks (6 Nov 2026)

Deployed from Remix with the same source, **Solidity 0.8.20, optimizer on (200 runs), EVM berlin**, and verified on the explorer
(partial match: flattening changes only the metadata stamp). Checked on-chain the same day: runtime code identical to the
treasury vesting apart from the trailing metadata hash.

| | Liquidity vesting | Marketing vesting |
|---|---|---|
| REEF locked | 9,295,376.908 (the liquidity wallet's whole balance after `finalize()`) | 940,000 (100,000 kept unlocked) |
| Beneficiary | `0xa07C0993E37e50E6DD4Cfd0F190A4c976b273418` (liquidity wallet) | `0xaFb7f412dE83978188fAc2248e3A5f9A71dCf386` (marketing wallet) |
| Start | 6 Nov 2026 02:57:59 UTC | 6 Nov 2026 03:04:54 UTC |
| Cliff ends | 5 May 2027 02:57:59 UTC (180 days) | 5 May 2027 03:04:54 UTC (180 days) |
| Fully vested | 5 Nov 2029 02:57:59 UTC (1,095 days) | 5 Nov 2029 03:04:54 UTC (1,095 days) |

## Check the source matches the chain

From `contracts/`:

```bash
node scripts/vesting/verify-vesting.js
```

It compiles this source under every setting Remix could have used (OpenZeppelin 4.9.6 or
5.0.0-5.7.0, optimizer on/off, EVM shanghai/paris/london/berlin), compares the result with
the code deployed at each address (ignoring only the trailing metadata hash, which changes
with comments), and prints each contract's beneficiary, cliff and end dates and REEF
balance as read from chain. It only reads; it sends nothing. Exit code 0 means every
address matched.

## Result (4 Nov 2026)

Both addresses match this source exactly (same 1,179-byte runtime code), compiled with
**Solidity 0.8.20, OpenZeppelin 5.6.x or 5.7.0, optimizer on with 200 runs, EVM paris**
(london/berlin/istanbul give byte-identical code). Read from chain:

| | Dev vesting | Treasury vesting |
|---|---|---|
| REEF held | 2,100,000 | 5,250,000 |
| Beneficiary | `0x2226d86703BDCdf1029C4a9fb0a0851A999A3E94` | `0x6dA9bdb6522678Ee7FD7eea184B3744CFD9e91C8` |
| Start | 29 Sep 2026 01:53 UTC | 29 Sep 2026 05:12 UTC |
| Cliff ends (nothing before) | 29 Sep 2027 01:53 UTC | 28 Mar 2027 05:12 UTC (180 days) |
| Fully vested | 28 Sep 2029 01:53 UTC | 28 Sep 2029 05:12 UTC |
| Released so far | 0 | 0 |

From the cliff, REEF vests in a straight line to 100% at the end date; there is no lump sum
at the cliff.
