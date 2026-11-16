# Reef Lock: deploy `ReefLocker`

`ReefLocker_flat.sol` is `contracts/reef/ReefLocker.sol` with OpenZeppelin 5.0.2 inlined (pragmas pinned to 0.8.24).

## Settings

| Argument | Value |
|---|---|
| `admin_` | `0x4E2401bFD24c66166fABF9Cc5cD5B6B2c5c860fc` (Reef admin multisig, 2-of-3) |
| `feeRecipient_` | `0xECc48Bca8c28Caa8e980E308DFb08B8dEfE86267` (Reef treasury) |
| `fee_` | `100000000000000000000` (100 BDAG per lock) |

The admin can only change the fee (max 100,000 BDAG) and where it goes, and hand admin over in two steps. It
can't touch any lock.

## 1. Deploy (one button, no Remix)

Remix compiles for a newer EVM on chain 1404 (`invalid opcode: PUSH0`), so the deploy data is pre-built:
solc 0.8.24, EVM **berlin**, optimizer **off**, from `ReefLocker_standard_input.json`.

1. Open **reefdex.fyi/deploy-lock/** in the browser with MetaMask, on BlockDAG (1404).
2. Connect, then **Dry run**. If it says OK, **Deploy**. Expected gas about 2,450,000 (limit 3,500,000).
3. Copy the address it prints.

Deploy data: 11,724 bytes, keccak `0xa0b2e289b1d4575da83a22ea0e304729d4061fab3e091e4b7e7e84e613a1d087`
(the page refuses to run if this doesn't match).

Checked before release: no PUSH0 in the runtime; the exact deploy bytes deployed on a local berlin chain,
set admin/fee recipient/fee correctly, locked a token, sent 100 BDAG to the treasury, refused an early
withdrawal and paid out after the date; `test/reef-locker.test.js` 22 passing.

## 2. Verify on the explorer

Use **Standard JSON input** with `ReefLocker_standard_input.json` (the file name inside is
`ReefLocker_flat.sol`, which the metadata hash depends on), compiler 0.8.24, contract `ReefLocker`.
Constructor arguments (ABI-encoded):

```
0000000000000000000000004e2401bfd24c66166fabf9cc5cd5b6b2c5c860fc000000000000000000000000ecc48bca8c28caa8e980e308dfb08b8defe862670000000000000000000000000000000000000000000000056bc75e2d63100000
```

## Deployed

| | |
|---|---|
| ReefLocker | `0xd999d2e6efc1d30143e23c3cc736adedff95c2a1` (chain 1404, 16 Nov 2026, from the COOKED_Main wallet, 2,448,917 gas) |
| Deploy tx | `0x5ed669351a83d1de8f8f051c694277d86386fea60fa4493eb0328065055f6215` |
| Checked on-chain | runtime code hash `0xa72ace87…1dbe` = the reviewed build; admin = Reef multisig; fee recipient = Reef treasury; fee 100 BDAG; no admin hand-over pending; 0 locks |
| Verified | full match on explorer.east.bdag-us.org (Standard JSON, 0.8.24, berlin, optimizer off) |

The temporary `deploy-lock/` page has been removed. The site's Lock page is `/lock/`.
