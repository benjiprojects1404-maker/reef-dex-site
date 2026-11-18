# The Kitchen on Base: deploy `KitchenServeUniV2`

`KitchenServeUniV2_flat.sol` is `contracts/kitchen/KitchenServeUniV2.sol` with OpenZeppelin 5.0.2 inlined. It's the
same recipe as The Kitchen on BlockDAG, pointed at **Uniswap V2 on Base**: one transaction makes the token and its
TOKEN/ETH Uniswap V2 pool, burns the LP (to `0x…dEaD`; Uniswap itself locks the first 1,000 LP units at
`address(0)`), and sends the rest of the supply to the creator.

## Settings (decide before deploying)

| Argument | Value |
|---|---|
| `router_` | `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24` (Uniswap V2 Router02 on Base, from Uniswap's docs) |
| `admin_` | **TBD**: a Safe on Base (recommended) or a hardware wallet |
| `feeRecipient_` | **TBD**: your Base treasury address |
| `fee_` | **TBD** in wei, e.g. `2000000000000000` = 0.002 ETH. Hard cap in the contract: 1 ETH |
| `minLiquidity_` | **TBD** in wei, e.g. `10000000000000000` = 0.01 ETH. Hard cap: 100 ETH |
| `reserved` | `["ETH","WETH","USDC","USDT","BTC","WBTC","CBBTC","BASE","REEF","COOKED"]` (any case is refused) |

The router's `WETH()` and `factory()` are read in the constructor, so only the router address needs to be right.
The admin can only change the fee, the minimum and where the fee goes, and hand admin over in two steps.

## Deploy

Base supports the latest EVM, so Remix works as normal (no berlin workaround needed, though a berlin build also
runs fine): compiler **0.8.24**, optimizer **on, 200 runs**, contract `KitchenServeUniV2`. Deploy from MetaMask on
**Base (chain 8453)**. Then verify on basescan.org with the same settings.

## Tested

`test/kitchen-serve-univ2.test.js` (9 tests) runs against the **real Uniswap V2 contracts** (`@uniswap/v2-core`,
`@uniswap/v2-periphery`, the same code as on Base): token and pool made in one transaction, LP burned, rest to the
creator, fee to the treasury, Kitchen keeps nothing, buy and sell through the router straight away, input checks,
reserved tickers, a pair created in advance for the next token's address, listing views, admin limits.
