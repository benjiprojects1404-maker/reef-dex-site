# The Kitchen: deploy `KitchenFactory` from Remix

`KitchenFactory_flat.sol` is `contracts/kitchen/KitchenFactory.sol` with OpenZeppelin inlined, ready to paste.
You sign the deploy from your own wallet; no keys go anywhere.

## 1. Compile

1. remix.ethereum.org → new file `KitchenFactory_flat.sol` → paste the whole file.
2. Solidity compiler: **0.8.24**, Advanced: **optimizer on, 200 runs, EVM version berlin**. Compile.
3. Contract to deploy: **KitchenFactory** (not KitchenToken).

## 2. Deploy (Environment: Injected Provider, your wallet on BlockDAG, chain 1404)

Constructor arguments, in order:

| Argument | Value |
|---|---|
| `admin_` | `0x4E2401bFD24c66166fABF9Cc5cD5B6B2c5c860fc` (Reef admin multisig, 2-of-3) |
| `feeRecipient_` | `0xECc48Bca8c28Caa8e980E308DFb08B8dEfE86267` (Reef treasury) |
| `fee_` | `5000000000000000000000` (5,000 BDAG) |
| `reserved` | `["BDAG","WBDAG","REEF","NOCAP","COOKED","USDT","USDC","ETH","WETH","BTC","WBTC"]` |

The admin can only change the fee (never above 50,000 BDAG) and where it goes, through the multisig.
The reserved tickers are fixed at deploy and can't be changed later, so check the list before you press Deploy.

## 3. Verify and check

1. Explorer → the new address → Verify: single file, the same flat source, 0.8.24, optimizer 200, berlin,
   and the constructor arguments above (ABI-encoded; Remix shows them under the deploy transaction's input).
2. From `contracts/`: `node scripts/kitchen/check-kitchen.js <factory address>`. Read-only: it checks the
   admin, fee, fee recipient, fee cap and every reserved ticker, and exits 0 when all is right.
3. Send the address so it goes into The Kitchen site's config.

## Deployed

| | |
|---|---|
| KitchenFactory | `0x0E331686ee029EfafFC3a5cFda0ee3c7006F8A98` (chain 1404, 15 Nov 2026, from the COOKED_Main wallet) |
| Compiler | Solidity 0.8.24, **optimizer off**, EVM berlin (Remix ignored the optimizer setting in the link; verify with these) |
| Checked on-chain | admin = Reef multisig, fee 5,000 BDAG to the Reef treasury, cap 50,000 BDAG, all 11 tickers reserved, no admin hand-over pending |
| Code check | Runtime code identical to this flat source compiled with the settings above, apart from the IPFS metadata stamp inside the embedded `KitchenToken` code (which changes with the file name and comments) |
