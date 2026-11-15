# The Kitchen v2: deploy `KitchenServe` from Remix (cook AND serve on Reef)

v2 makes the token and its TOKEN/BDAG pool on Reef in one transaction, with the LP burned. It replaces the v1
`KitchenFactory` on the site. `KitchenServe_flat.sol` is `contracts/kitchen/KitchenServe.sol` with OpenZeppelin
inlined, ready to paste.

## 1. Compile

1. Remix → new file `KitchenServe_flat.sol` → paste the whole file (use GitHub's Raw view).
2. Solidity compiler **0.8.24**, Advanced: EVM version **berlin**. Leave the optimizer **off** (that's what Remix
   used for v1, and it keeps the explorer verification simple).
3. Contract to deploy: **KitchenServe** (not KitchenToken).

## 2. Deploy (Injected Provider, BlockDAG chain 1404, Value 0, "Verify Contract on Explorers" off)

| Argument | Value |
|---|---|
| `router_` | `0xbd6fbA41Ab84292163A599510a12d6Bf8B7CCc76` (Reef router; WBDAG and the Reef factory are read from it) |
| `admin_` | `0x4E2401bFD24c66166fABF9Cc5cD5B6B2c5c860fc` (Reef admin multisig, 2-of-3) |
| `feeRecipient_` | `0xECc48Bca8c28Caa8e980E308DFb08B8dEfE86267` (Reef treasury) |
| `fee_` | `5000000000000000000000` (5,000 BDAG) |
| `minLiquidity_` | `10000000000000000000000` (10,000 BDAG minimum in each new pool) |
| `reserved` | `["BDAG","WBDAG","REEF","NOCAP","COOKED","USDT","USDC","ETH","WETH","BTC","WBTC"]` |

The admin can only change the fee (max 50,000 BDAG), the minimum liquidity (max 1,000,000 BDAG) and where the
fee goes, through the multisig. Reserved tickers are fixed at deploy.

## 3. Verify and check

1. Explorer → Verify & publish → Solidity single file: the same flat source, 0.8.24, optimizer off, berlin.
2. Send the address: it gets checked on-chain and goes into the site's config.

## Deployed (v2)

| | |
|---|---|
| KitchenServe | `0xF30f5E4f46AcAE803815B82CfEC5CD8Fc77eF394` (chain 1404, 15 Nov 2026, from the COOKED_Main wallet, 4,318,975 gas) |
| Compiler | Solidity 0.8.24, **optimizer off**, EVM **berlin** |
| How | Remix kept compiling for a newer EVM (its config file ignored the berlin setting, so deploys failed with `invalid opcode: PUSH0`). The deploy data was built with solc 0.8.24 from `KitchenServe_flat.sol` (berlin, no optimizer), dry-run on BlockDAG, then sent from MetaMask. Deploy data keccak `0xb60a6731031746959e74e117f96720ff553e6664126ee6a4e86f163acfdc5141`. |
| Checked on-chain | router/factory/WBDAG = Reef's; admin = Reef multisig; fee 5,000 BDAG to the Reef treasury; minimum liquidity 10,000 BDAG; all 11 tickers reserved; no admin hand-over pending; runtime 17,814 bytes |

**Remix tip for chain 1404:** BlockDAG doesn't support `PUSH0` (Shanghai). Always compile for EVM berlin, and if
Remix shows "Use configuration file", check `remix.config.json` says `"evmVersion": "berlin"`.

---

# v1 (retired from the site): `KitchenFactory`

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
