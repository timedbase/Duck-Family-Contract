# duckfun.family — Contracts

Solidity contracts for duckfun.family, a launchpad on Ink chain (chain ID 57073) built on real,
verified Uniswap V4 infrastructure. Three independent launcher families share one LP-lock vault
and one anti-MEV/fee/CTO hook:

- **DuckIncubation** — single-contract bonding-curve launchpad. No on-chain price oracle: start
  and migration targets are raw quote-asset amounts the creator picks directly, since V4 has no
  built-in TWAP. Migrates into a fresh V4 pool once the curve hits its target.
- **DuckLauncher** — instant DEX launch. Every launch creates a real V4 pool and mints a full-range
  LP position in one transaction, gated by the shared hook from block one.
- **DuckRaise** — permissionless crowdfund launcher. A campaign's token deploys immediately at
  creation (not at resolution); a campaign that clears its native-ETH goal by its deadline seeds a
  two-sided V4 pool from the raised funds, a campaign that misses it unlocks refunds instead.

## Layout

| Path | Contract | Role |
|---|---|---|
| `duck-incubation/DuckIncubation.sol` | `DuckIncubation` | Bonding-curve launchpad |
| `duck-incubation/DuckIncubationToken.sol` | `DuckIncubationToken` | EIP-1167 clone template for curve tokens |
| `duck-launcher/DuckLauncherUpgradeable.sol` | `DuckLauncher` | Instant DEX launcher |
| `duck-launcher/DuckLauncherToken.sol` | `DuckLauncherToken` | EIP-1167 clone template for instant-launch tokens |
| `duck-launcher/DuckLocker.sol` | `DuckLocker` | Shared permanent LP-position vault for all three families |
| `duck-launcher/DuckHookV4.sol` | `DuckHookV4` | Shared Uniswap V4 hook — anti-MEV, sell-fee skim, paid CTO |
| `duckraise/DuckRaise.sol` | `DuckRaise` | Crowdfund launcher |
| `duckraise/DuckRaiseToken.sol` | `DuckRaiseToken` | EIP-1167 clone template for campaign tokens |
| `common/LaunchRouting.sol` | `LaunchRouting` (abstract) | Shared bounded-fallback instant-buy routing engine |
| `common/V4Math.sol` | `V4Math` | Shared V4 TickMath/LiquidityAmounts port |
| `common/V4Minting.sol` | `V4Minting` | Shared V4 pool-init + full-range mint |
| `common/DuckIncubationMigration.sol` | `DuckIncubationMigration` | DuckIncubation's migration path (external library) |
| `common/DuckIncubationBuying.sol` | `DuckIncubationBuying` | DuckIncubation's buy/sell settlement (external library) |
| `deploy/` | — | Foundry project: deploy scripts, fork tests, deployment records |

`V4Math`/`V4Minting`/`DuckIncubationMigration`/`DuckIncubationBuying` are deployed as real external
libraries (not inlined) purely to keep `DuckIncubation`, `DuckLauncher`, and `DuckRaise` under
EIP-170's 24,576-byte contract size limit.

## Build & test

All Foundry tooling lives under `deploy/`:

```bash
cd deploy
git submodule update --init --recursive   # forge-std, openzeppelin-contracts-upgradeable
forge build
forge test                                # fork tests run against live Ink mainnet state
```

`deploy/test/*.fork.t.sol` fork-test the full lifecycle of each family (create/buy/sell/migrate,
launch/instant-buy, campaign create/contribute/finalize/claim/refund) against Ink's real deployed
Uniswap V4 infrastructure and real USDC/USDT0 liquidity — not mocks.

## Deployment

Live Ink mainnet addresses and the verified third-party infrastructure they wire into are recorded
in [`deploy/deployments/ink.json`](deploy/deployments/ink.json). Every contract listed there is
verified on the [Ink Blockscout explorer](https://explorer.inkonchain.com).
