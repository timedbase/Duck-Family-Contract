// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — fresh redeploy of DuckIncubation + DuckRaise on Ink
// (57073).
//
// Both existing proxies (curve: 0x5c4f0938FC434b60b57209BbC971544b73876675,
// raise: 0x39D17950BaaD5737d08b027F0494E2C261B37Cf2) have never had a real
// token/campaign go through them (confirmed against the live subgraph), so
// this deploys brand new proxies from the size-fixed source instead of a
// timelocked in-place upgrade -- simpler, and there's no live state to
// preserve. Reuses every already-deployed shared piece unchanged: WETH, the
// V4 PositionManager/PoolManager/Permit2, the CURRENT hook
// (0x067A168D...), DuckLocker, and both families' own token
// implementations.
//
// The old proxies' launcher authorization on DuckLocker/DuckHookV4 is
// revoked at the end of this same script, so they can never register
// anything on the shared infrastructure again.
//
// The 15-address quote-token whitelist DuckIncubation used to seed inside
// initialize() itself is deliberately NOT baked into the new implementation
// (that duplication is what pushed it over EIP-170's 24,576-byte size
// limit) -- this script seeds the two Ink actually has verified liquidity
// for (USDC/USDT0) directly via the already-existing setQuoteTokenAllowed/
// setRoutes owner functions instead. Add the rest with addQuoteToken calls
// afterward if you want the full historical list back.
//
// After this script: update subgraph.yaml's DuckIncubation/DuckRaise
// addresses + startBlock (to this deploy's block) and redeploy the
// subgraph, then update backend/interface's hardcoded curve/raise
// addresses to match.
//
// Usage (recommended -- encrypted local keystore, no plaintext key anywhere):
//   cast wallet import deployer --interactive          # skip if already imported
//   cd deploy
//   DEPLOYER_ADDRESS=0x43977b10095Fc5E153F907fe2E888C083fA4Fb66 \
//     forge script script/DeployIncubationRaiseV2.s.sol:DeployIncubationRaiseV2 --rpc-url ink --account deployer --broadcast -vvvv
//
// Usage (raw key via env var -- only if you already manage it that way):
//   PRIVATE_KEY=0x... \
//     forge script script/DeployIncubationRaiseV2.s.sol:DeployIncubationRaiseV2 --rpc-url ink --broadcast -vvvv

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckIncubation} from "duck-incubation-contracts/DuckIncubation.sol";
import {DuckRaise} from "duckraise-contracts/DuckRaise.sol";
import {Route, RouteShape} from "common-contracts/LaunchRouting.sol";

interface IDuckLockerAuth {
    function addLauncher(address launcher_) external;
    function removeLauncher(address launcher_) external;
}

interface IDuckHookV4Auth {
    function addLauncher(address launcher_) external;
    function removeLauncher(address launcher_) external;
}

contract DeployIncubationRaiseV2 is Script {
    // ── Verified, currently-live Ink chain (57073) shared infrastructure,
    // read directly off the existing proxies before writing this script ──
    address constant WETH                  = 0x4200000000000000000000000000000000000006;
    address constant V4_POOL_MANAGER       = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant V4_POSITION_MANAGER   = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant PERMIT2               = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant HOOK                  = 0x067A168DA351d40e086B974F16F94CB0f3dF00c4;
    address constant PLATFORM_WALLET       = 0x586Eb3db5866D76D752916396D63352DB29a47Bd;
    address constant LOCKER                = 0x74738a87e4D4E0eB2706724a9314d1b4452ecdFE;
    address constant INCUBATION_TOKEN_IMPL = 0xeEe2e78E82d75DF85b691CFAed1C28A0Df7f8A43;
    address constant RAISE_TOKEN_IMPL      = 0x2561AaCAeeD852477eA547831A1e55F20B67f382;

    // Never-used, being deauthorized once the new ones are live.
    address constant OLD_CURVE = 0x5c4f0938FC434b60b57209BbC971544b73876675;
    address constant OLD_RAISE = 0x39D17950BaaD5737d08b027F0494E2C261B37Cf2;

    address constant USDC  = 0x2D270e6886d130D724215A266106e6832161EAEd;
    address constant USDT0 = 0x0200C29006150606B650577BBE7B6248F58470c1;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

        // ── DuckIncubation (bonding curve), fresh proxy ──────────────────
        DuckIncubation curveImpl = new DuckIncubation();
        ERC1967Proxy curveProxy = new ERC1967Proxy(
            address(curveImpl),
            abi.encodeCall(DuckIncubation.initialize, (
                WETH, V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2, HOOK,
                PLATFORM_WALLET, INCUBATION_TOKEN_IMPL, LOCKER
            ))
        );
        DuckIncubation curve = DuckIncubation(payable(address(curveProxy)));
        console.log("DuckIncubation impl:  ", address(curveImpl));
        console.log("DuckIncubation proxy: ", address(curve));

        // ── DuckRaise (crowdfunding), fresh proxy ────────────────────────
        DuckRaise raiseImpl = new DuckRaise();
        ERC1967Proxy raiseProxy = new ERC1967Proxy(
            address(raiseImpl),
            abi.encodeCall(DuckRaise.initialize, (
                WETH, RAISE_TOKEN_IMPL, LOCKER,
                V4_POOL_MANAGER, V4_POSITION_MANAGER, PERMIT2, HOOK, PLATFORM_WALLET
            ))
        );
        DuckRaise raise = DuckRaise(payable(address(raiseProxy)));
        console.log("DuckRaise impl:  ", address(raiseImpl));
        console.log("DuckRaise proxy: ", address(raise));

        // ── Seed the two quote assets with real, verified Ink liquidity
        // (see file header -- the rest of the old 15-address list can be
        // added back with individual addQuoteToken calls if wanted) ──────
        curve.setQuoteTokenAllowed(USDC, true);
        curve.setQuoteTokenAllowed(USDT0, true);

        Route[] memory r = new Route[](1);
        r[0] = Route({
            shape: RouteShape.V4_STYLE, enabled: true, router: address(0), routerNoDeadline: false,
            path: new address[](0), fees: new uint24[](0), routers: new address[](0),
            singleton: V4_POOL_MANAGER, hook: address(0), fee: 3000, tickSpacing: 60
        });
        curve.setRoutes(USDC, r);
        curve.setRoutes(USDT0, r);

        raise.setQuoteAssetAllowed(USDC, true);
        raise.setQuoteAssetAllowed(USDT0, true);
        raise.setRoutes(USDC, r);
        raise.setRoutes(USDT0, r);

        // ── Cross-contract authorization: new proxies in, old ones out ───
        IDuckLockerAuth(LOCKER).addLauncher(address(curve));
        IDuckLockerAuth(LOCKER).addLauncher(address(raise));
        IDuckLockerAuth(LOCKER).removeLauncher(OLD_CURVE);
        IDuckLockerAuth(LOCKER).removeLauncher(OLD_RAISE);

        IDuckHookV4Auth(HOOK).addLauncher(address(curve));
        IDuckHookV4Auth(HOOK).addLauncher(address(raise));
        IDuckHookV4Auth(HOOK).removeLauncher(OLD_CURVE);
        IDuckHookV4Auth(HOOK).removeLauncher(OLD_RAISE);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Redeployment complete ===");
        console.log("New DuckIncubation:", address(curve));
        console.log("New DuckRaise:     ", address(raise));
        console.log("Old curve/raise proxies deauthorized on locker + hook.");
    }
}
