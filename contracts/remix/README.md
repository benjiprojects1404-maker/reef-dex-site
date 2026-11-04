# Contracts deployed from Remix

These were compiled and deployed in Remix with Solidity 0.8.20, separately from the rest of
Reef (Hardhat/Foundry, 0.8.24). They sit outside `contracts/` so the 0.8.24 builds don't
try to compile them.

| Contract | Address | Schedule (as published) |
|---|---|---|
| `ReefVesting.sol`: dev vesting | `0x5468821749B936ffa6C3aF840841058b026E288f` | 12-month cliff, 36 months |
| `ReefVesting.sol`: treasury vesting | `0x8750aC546e0B6234B292F3830958F780E3e304BD` | 6-month cliff, 36 months |

## Check the source matches the chain

From `contracts/`:

```bash
node scripts/vesting/verify-vesting.js
```

It compiles this source under every setting Remix could have used (OpenZeppelin 4.9.6 or
5.0.0-5.4.0, optimizer on/off, EVM shanghai/paris/london/berlin), compares the result with
the code deployed at each address (ignoring only the trailing metadata hash, which changes
with comments), and prints each contract's beneficiary, cliff and end dates and REEF
balance as read from chain. It only reads; it sends nothing. Exit code 0 means every
address matched.
