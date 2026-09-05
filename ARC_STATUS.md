# Arc deployment status (2026-09-05)

**Decision: Arc is being dropped entirely.** Not immediately — the existing live
contracts below are untouched and kept exactly as-is for now, pending a new
direction that hasn't been detailed here yet. This file exists so nothing about
Arc's current state gets lost in that transition.

## Live deployment (chain id 5042)

| Contract | Address |
|---|---|
| DuckIncubationArc (proxy) | `0x5c4f0938FC434b60b57209BbC971544b73876675` |
| DuckLauncherArc (proxy) | `0x2A84711A5c0Ee62118CEee1A37C0dA46a6980353` |
| DuckRaiseArc (proxy) | `0x9AE7383af6ea77037c09459a9aF8f4AEC038f083` |
| DuckLockerArc (proxy, shared) | `0x74738a87e4D4E0eB2706724a9314d1b4452ecdFE` |
| DuckHookV4Arc | `0x5C53161656C8b13883b2CD9936Acf6FcA56100c4` |
| DuckHookFactory | `0x6A07B7de1F57fB3bb43592711d9b78Eb3D927978` |
| DuckIncubationTokenArc impl | `0xeEe2e78E82d75DF85b691CFAed1C28A0Df7f8A43` |
| DuckLauncherTokenArc impl | `0x4deba89765cFB2A9aC906828d91602c87100a9EA` |
| DuckRaiseTokenArc impl | `0x2561AaCAeeD852477eA547831A1e55F20B67f382` |

Owner (all governance-controlled contracts): `0x43977b10095Fc5E153F907fe2E888C083fA4Fb66`
Platform wallet: `0x586Eb3db5866D76D752916396D63352DB29a47Bd`

Real, verified infra used:
- V4: PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, PositionManager `0x6049c9a0e26405C0985f9E3685C87d0aE917f82B`, Permit2 (canonical `0x000000...78BA3`)
- V3 (DuckLauncherArc-only): PositionManager `0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377`, SwapRouter02 `0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77`
- Native USDC ERC20 mirror (seeded as DuckLauncherArc's only quote token via `addQuoteToken`): `0x3600000000000000000000000000000000000000`, 6 decimals

**Real usage as of this date: zero.** `DuckLockerArc.tokenCount() == 0` — no token has
ever actually been registered/launched against this deployment. Nothing to migrate
or orphan if Arc is dropped.

## This session's Arc-specific work

- Ported the "park token-side LP fee into a single-sided V3 position instead of
  burning it" feature from Ink's `DuckLocker.sol` to `DuckLockerArc`
  (`duck-launcher-arc/DuckLocker.sol`). Reads the live V4 pool price via Uniswap's
  own `v4-core` `StateLibrary` (pinned dependency, `v4.0.0` @ `e50237c...`) directly
  off the real PoolManager, since Arc has no separate StateView periphery contract
  the way Ink does.
- Added Arc's first-ever fork test suite: `deploy-arc/test/DuckLocker.fork.t.sol`,
  14 tests, all passing against the live Arc fork (repeated runs confirmed stable).
- Removed the 48h upgrade timelock from both `DuckLocker.sol` (Ink) and
  `DuckLockerArc` at the owner's explicit request — `upgradeToAndCall` is now
  instant, no `proposeUpgrade`/wait step, for *future* upgrades once this one lands.

## Pending, left as-is per explicit instruction ("leave it queued, decide later")

`DuckLockerArc`'s live proxy has an **already-queued upgrade** (still on the OLD,
timelocked implementation, since it hasn't executed yet):

- New implementation deployed: `0x2E74B9fa78eC89BCdc982ac74F1E631a44b47Df7`
- `proposeUpgrade` called (tx `0x0c3ce970b69d087b148c601b1a1aababca0c3460f18ddc3236e79468d15bfbe2`, block 19110060)
- Timelock unlocks: **2026-09-06 11:22:54 UTC**
- Not executed. Do not run `upgradeToAndCall` or `cancelAction` on this without
  explicit direction — it was deliberately left queued rather than cancelled.

(Ink's equivalent upgrade was queued independently in the same session — new impl
`0x4F5Ebe3C7A61aB47d6d3F0Ef0bc10A5D35A3890D`, unlocks 2026-09-06 11:20:18 UTC. **Ink
is not part of the Arc drop decision** — that one is expected to proceed normally.)

## Known bug found on Arc, not fixed (moot if Arc is dropped, recorded for completeness)

`common-arc/DuckIncubationMigration.sol`'s `_mintV4` (used by `DuckIncubationArc`'s
bonding-curve migration) and `duckraise-arc/DuckRaise.sol`'s finalize path both
unconditionally call `IWETH9Mig(cfg.weth).deposit{value: ...}()` for a
native(USDC)-quoted token. Arc's deployed `weth_` param is `NATIVE_ERC20_MIRROR`
(`0x3600...`), which is not a working WETH-shaped contract — confirmed via a real
revert on the live Arc fork while writing this session's fork tests. Effect: any
native-quoted bonding-curve token or crowdraise on Arc can never successfully
migrate/finalize (fails silently via a `MigrationFailed` event — no funds lost, but
the token is permanently stuck with no real pool). Never fixed this session.
