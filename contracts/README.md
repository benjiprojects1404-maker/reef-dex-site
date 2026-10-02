# Reef, Nodal, Handshake and $COOKED: contract source and tests

The Solidity source for the live contracts behind reefdex.fyi, nodaldex.fyi, handshakeotc.fyi and cookedmeme.fyi,
with one shared test suite. Everything here is beta software and has **not** had an independent audit.

## Live contracts (BlockDAG, chain ID 1404)

Each address below was checked on 2 Oct 2026: the code on chain is byte-for-byte the code these files compile to
(ignoring only the compiler's metadata stamp, and immutable values such as addresses set at deployment).

| Contract | Address | Source |
|---|---|---|
| ReefFactory | `0x9603042044b6B1A1637c508F731ba01219142239` | `contracts/reef/ReefFactory.sol` |
| ReefRouter | `0xbd6fbA41Ab84292163A599510a12d6Bf8B7CCc76` | `contracts/reef/ReefRouter.sol` |
| WBDAG | `0x62ba5c4F067989a7f6644488C875bEa69Bfa1FBA` | `contracts/reef/WBDAG.sol` |
| Admin multisig (2-of-2) | `0x4E2401bFD24c66166fABF9Cc5cD5B6B2c5c860fc` | `contracts/reef/ReefAdminMultisig.sol` |
| NodalRouter | `0xA06f8a856896aA1836f04F758C1E5Ac5dbe24672` | `contracts/nodal/NodalRouter.sol` |
| NodalReefAdapter | `0x4b60D344eDA7E3D859739B5AbC1176d756E22d56` | `contracts/nodal/NodalReefAdapter.sol` |
| Handshake OTCEscrow | `0xD907701A2D96f7D0E7596b02737C9F36446cf5CA` | `contracts/handshake/OTCEscrow.sol` |
| $COOKED curve | `0xD8a25883dd2576cB7eE7803e23f0309F56bAbA2B` | `contracts/cooked/CookedCurve.sol` (also in the cooked-site repo) |
| $COOKED token | `0xd95C548B144682f4EF49728944505D8506861B1B` | `contracts/cooked/CookedToken.sol` |

Read from chain the same day: Reef's `feeToSetter`, NodalRouter's `owner` and the escrow's `owner` are all the admin
multisig. Reef's `feeTo` (protocol-fee treasury) is `0xECc48Bca8c28Caa8e980E308DFb08B8dEfE86267`.

Reef pools (pairs) are created by the Factory from `contracts/reef/ReefPair.sol`.

Not included: the NOCAP/BDAG TWAP oracle and the NOCAP LP lock.

`contracts/reef/ReefAdminMultisigV2.sol` is **not deployed**. It's a proposed replacement that fixes finding M-1
below, for use when the admin moves from 2-of-2 to 2-of-3.

## Compiler settings

Solidity **0.8.24**, optimizer **on, 200 runs**, EVM version **berlin** (BlockDAG doesn't support newer opcodes).
Reef was built with `metadata.bytecodeHash: "none"`. Nodal, Handshake and $COOKED were deployed from Remix with the
default metadata hash; that only changes the metadata stamp at the end of the bytecode.

## Run the tests

```bash
npm install
npx hardhat test      # 58 passing
```

The tests run the real contracts together: Reef pools, Nodal routing through the adapter into Reef, the
$COOKED curve graduating into Reef, the Handshake escrow, and the multisig administering Reef. Test-only helper
contracts are `contracts/reef/mocks/`, `contracts/handshake/HandshakeTestTokens.sol` and `contracts/cooked/test/`.

## Known findings (free pre-audit review, 2 Oct 2026)

No critical or high findings. Every finding below has a test that reproduces it.

| ID | Contract | Severity | Finding |
|---|---|---|---|
| M-1 | Admin multisig | Medium | A removed owner's earlier approvals still count, so after removing an owner a pending transaction can pass with fewer current owners than the threshold. No exposure today: the 2-of-2 can't remove an owner, and no multisig transactions exist yet. Fixed in `ReefAdminMultisigV2.sol`. |
| L-1 | Handshake | Low | If the fee recipient can't receive BDAG, every fill fails (cancels still work). Keep the fee recipient a plain wallet. |
| L-2 | Handshake | Low | A transfer-tax token on the wanted side pays the maker less than asked. |
| L-3 | Handshake | Low | A token that blocks or pauses the escrow freezes that token's offers until it unblocks. |
| L-4 | Reef | Low | Transfer-tax tokens can be bought but not sold: the router has no fee-on-transfer swap functions. |
| L-5 | Nodal | Low | The owner can point a source at any contract; users are protected by their minimum-output check. |
| L-6 | Admin multisig | Low | A transaction whose inner call failed stays executable by anyone until an owner revokes it. |

Reef's contracts are Uniswap V2 ported to Solidity 0.8 and renamed (ETH → BDAG). The only logic differences: the
first 1,000 LP units are locked at `0xdead` instead of the zero address, the pair init-code hash is computed rather
than hard-coded, and the router leaves out the fee-on-transfer and `removeLiquidityETHWithPermit` functions.

## Reporting a vulnerability

Please report privately rather than in a public issue: DM [@benji107](https://x.com/benji107) on X, or for Handshake
email security@handshakeotc.fyi.

## License

MIT.
