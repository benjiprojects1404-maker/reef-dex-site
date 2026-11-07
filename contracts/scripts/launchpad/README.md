# Reef Launchpad: deploy and list a sale (beta)

The checklist for setting up one client's sale. The operator signs everything from their own wallet, and no keys go anywhere. A sale is a fresh `ReefLaunchSale` contract per launch; there is no factory.

Reef's standard terms are filled in for you by `sale-config.js`, so they're never typed by hand:

| Setting | Value |
|---|---|
| Router | `0xbd6fbA41Ab84292163A599510a12d6Bf8B7CCc76` |
| Fee | 2% (`feeBps` 200) to the treasury `0xECc48Bca8c28Caa8e980E308DFb08B8dEfE86267` |
| Bond | 1,000 REEF (`0xb7a1e198767bf0fd4C1C3805b9757369e1c3F416`) |
| REEF pool | 20% (`reefSliceBps` 2000), only while REEF/BDAG holds 10,000,000+ BDAG |
| LP lock | 365 days |
| Beta cap | hard cap at most 5,000,000 BDAG (`BETA_MAX_HARDCAP` on the sale page) |

## 0. Before anything is deployed

- [ ] Client has signed the **Reef Launchpad beta: client terms** doc, and the set-up fee (USDT/USDC) is received.
- [ ] **Token check:** standard ERC-20, verified on the explorer, owner renounced or disclosed, and no transfer tax, rebasing, blocklist or pause. Read the source; don't rely on the name.
- [ ] **Nothing distributed:** the project wallet holds the supply, no TOKEN/BDAG or TOKEN/REEF pool exists, and no airdrops have been made. Check the token's holders and `getPair` on the factory for both pairs.
- [ ] **US/UK and vetting:** basic checks on the team and project are done. Nothing about the project makes promises about price or returns.

## 1. Build the settings

```bash
cd contracts
cp scripts/launchpad/sale-config.example.json scripts/launchpad/<project>.json   # fill it in
node scripts/launchpad/sale-config.js scripts/launchpad/<project>.json
```

Fix anything marked ✗. The script runs the contract's own deployment checks plus the beta cap. Copy the one-line tuple it prints.

**Timing:** deploy **at least one day before the sale ends**, and ideally before it starts. The REEF pool needs a day of REEF price history from deployment, or it's skipped at launch.

## 2. Deploy from Remix

1. Open `contracts/contracts/reef/ReefLaunchSale.sol` in Remix (it imports OpenZeppelin `token/ERC20`, `utils/ReentrancyGuard` and `utils/math/Math`).
2. Compiler **0.8.24**, optimizer **on, 200 runs**, EVM **berlin**. These are the same settings as the tests.
3. Deploy with MetaMask on chain 1404, pasting the tuple into the `c` field.
4. Record the sale address.

## 3. Verify and read it back

- [ ] **Verify on the explorer.** Flatten in Remix, then verify with the same compiler settings. A partial match is fine.
- [ ] **Read `terms()` and check every field** against the client terms table, especially the prices, caps, times, project wallet and LP beneficiary.
- [ ] **Read `tokensRequired()`.** It should equal what `sale-config.js` printed.
- [ ] **Read `reefPair()`.** It should be the REEF/BDAG pool `0x1Ea359266c19635c4e92B8dEf5933AbFc6A9182D`. If it's zero, there will be no REEF pool.

## 4. Project deposits

The project sends plain transfers to the sale address:

- [ ] exactly `tokensRequired()` of its token
- [ ] 1,000 REEF for the bond

Then check that `isBonded()` is `true` and that the token's `balanceOf(sale) ≥ tokensRequired()`. Buying stays switched off until both are true.

## 5. List it

Open a PR adding the sale to `launch/sales.json`:

```json
{ "id": "project-slug", "sale": "0xSaleAddress", "name": "Project Name",
  "about": "One or two plain sentences: what the project is. No price talk.",
  "links": [{ "label": "Website", "url": "https://..." }, { "label": "X", "url": "https://x.com/..." }] }
```

- Only `https://` links are shown.
- `"betaCapOverride": true` lets a sale over the 5M cap through. Only add it after an explicit decision.
- Before merging, check the page at `/launch/sale/?id=project-slug` on the branch preview, or straight after merging. It must show no "switched off" warning.

## 6. During and after the sale

| When | Who | What |
|---|---|---|
| Sale ends, or hits the hard cap | Anyone (the page's "Launch the pool" button) | `finalize()`. Check the `Finalized` event, and either `ReefSlice` or `ReefSliceSkipped(reason)`. |
| After launch | Each buyer | `claim()`; no deadline |
| Soft cap missed, or not launched within 7 days of the close | Each buyer | `refund()`; and anyone can call `returnTokens()` to send the project its tokens |
| Refunds open after a missed soft cap | Anyone | `settleBond()` returns the bond |
| Launch blocked after reaching the soft cap | Anyone | `settleBond()` burns the bond |
| LP unlock date (12 months after launch) | Anyone | `withdrawLP()` sends both LPs to the beneficiary; `settleBond()` returns the bond |

Set a reminder for the LP unlock date when the sale launches.

Skip reasons for the REEF pool:

| Reason | Meaning |
|---|---|
| 1 | No REEF/BDAG pool existed when the sale was deployed |
| 2 | The slice is too small, or too small to open a pool |
| 3 | Less than a day has passed since deployment |
| 4 | The REEF/BDAG pool held less than 10M BDAG |
| 5 | The REEF price was more than 5% from its average |
| 6 | The TOKEN/REEF pool was already seeded |

See also `contracts/contracts/reef/ReefLaunchSale.REVIEW.md` for the self-review and known risks.
