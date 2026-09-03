// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — full production deploy to Arc (chain id 5042).
//
// Deploys, in order: the three token implementations, DuckLockerArc (shared
// across all three launcher families), the CREATE2 hook factory + the one
// canonical DuckHookV4Arc (V4 only -- DuckIncubationArc/DuckRaiseArc use it;
// DuckLauncherArc also gets a V3 dex option wired in separately), then
// DuckIncubationArc, DuckLauncherArc and DuckRaiseArc themselves -- wiring
// every cross-contract authorization (locker.addLauncher, hook.addLauncher)
// at the end.
//
// ── Arc is NOT a copy-paste of the Ink deploy ───────────────────────────────
// Arc's native gas token is USDC itself (18-decimal native precision,
// distinct from the 6-decimal ERC-20 USDC interface) -- there is no WETH on
// Arc, and Circle's own docs confirm the ERC-20 interface has no deposit()/
// withdraw(), it's a plain view over the same native balance. The `weth_`
// constructor param below is only ever read by LaunchRouting's V3_STYLE/
// UNIVERSAL_ROUTER_STYLE native->quote-token swap fallback (see
// common-arc/LaunchRouting.sol) -- inert unless a route of that shape is
// later configured via setRoutes, which this script does NOT do (no
// verified Arc-chain route data exists yet). NATIVE_ERC20_MIRROR below is
// passed only to satisfy that constructor's non-zero check; do not assume
// it is a working WETH-shaped contract without testing that specific route
// shape against it first.
//
// Also NOT ported: the Ink deploy's default quote-token/route seeding (15
// Ink-chain token addresses) -- DuckIncubationArc/DuckLauncherArc/
// DuckRaiseArc all seed nothing beyond native by default on Arc. Add real,
// verified Arc-chain quote assets via addQuoteToken/setQuoteAssetAllowed/
// setRoutes once identified.
//
// Usage (recommended -- encrypted local keystore, no plaintext key anywhere):
//   cast wallet import deployer --interactive          # one-time, prompts for the key + a password
//   cd deploy-arc
//   DEPLOYER_ADDRESS=0x... PLATFORM_WALLET=0x... \
//     forge script script/Deploy.s.sol:Deploy --rpc-url arc --account deployer --broadcast -vvvv
//   (forge prompts for the keystore password at broadcast time)
//
// Usage (raw key via env var -- only if you already manage it that way):
//   PRIVATE_KEY=0x... PLATFORM_WALLET=0x... \
//     forge script script/Deploy.s.sol:Deploy --rpc-url arc --broadcast -vvvv
//
// PLATFORM_WALLET defaults to the deployer address if unset -- that's fine
// for a first deploy but should almost certainly be a treasury/multisig
// before real funds start flowing through claimCurveFee/claimFees. Contract
// ownership (curve/launcher/raise/locker, plus the hook via its factory) is
// left with the deployer key too -- transferring that to a safer address is
// a separate, deliberate step this script does not take for you.

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckIncubationArc} from "duck-incubation-contracts/DuckIncubation.sol";
import {DuckIncubationTokenArc} from "duck-incubation-contracts/DuckIncubationToken.sol";
import {DuckLauncherArc} from "duck-launcher-contracts/DuckLauncherUpgradeable.sol";
import {DuckLauncherTokenArc} from "duck-launcher-contracts/DuckLauncherToken.sol";
import {DuckLockerArc} from "duck-launcher-contracts/DuckLocker.sol";
import {DuckHookV4Arc} from "duck-launcher-contracts/DuckHookV4.sol";
import {DuckRaiseArc} from "duckraise-contracts/DuckRaise.sol";
import {DuckRaiseTokenArc} from "duckraise-contracts/DuckRaiseToken.sol";
import {DuckHookFactory} from "./DuckHookFactory.sol";

contract Deploy is Script {
    // ── Verified Arc (chain id 5042) infrastructure -- from Uniswap's own
    // sdks repo (sdks/sdk-core/src/addresses.ts, ARC_ADDRESSES), cross-checked
    // live: Permit2 bytecode confirmed present at the canonical address on
    // this chain. ─────────────────────────────────────────────────────────
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    address constant PERMIT2              = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // V3 -- only DuckLauncherArc offers this venue.
    address constant V3_POSITION_MANAGER  = 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377;
    address constant V3_SWAP_ROUTER02     = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    // See the file header -- unverified as a working WETH-shaped contract,
    // only ever read by an inert routing fallback with no route configured
    // against it here.
    address constant NATIVE_ERC20_MIRROR  = 0x3600000000000000000000000000000000000000;

    function run() external {
        // Two supported signer sources: a raw PRIVATE_KEY (vm.addr derives the
        // address locally), or DEPLOYER_ADDRESS paired with --account/--ledger
        // at the CLI (forge resolves the actual signer at broadcast time; the
        // script never sees a key). Prefer the latter.
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        address platformWallet = vm.envOr("PLATFORM_WALLET", deployer);
        if (platformWallet == deployer) {
            console.log("WARNING: PLATFORM_WALLET not set, defaulting to the deployer address.");
            console.log("Move fee collection to a treasury/multisig before real funds flow through this.");
        }

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

        // ── Token implementations (CREATE2-cloned per launch, never used directly) ──
        DuckIncubationTokenArc incubationTokenImpl = new DuckIncubationTokenArc();
        DuckLauncherTokenArc   launcherTokenImpl   = new DuckLauncherTokenArc();
        DuckRaiseTokenArc      raiseTokenImpl      = new DuckRaiseTokenArc();
        console.log("DuckIncubationTokenArc impl:", address(incubationTokenImpl));
        console.log("DuckLauncherTokenArc impl:  ", address(launcherTokenImpl));
        console.log("DuckRaiseTokenArc impl:     ", address(raiseTokenImpl));

        // ── DuckLockerArc (shared across all three families) ────────────────
        DuckLockerArc lockerImpl = new DuckLockerArc();
        ERC1967Proxy lockerProxy = new ERC1967Proxy(
            address(lockerImpl),
            abi.encodeCall(DuckLockerArc.initialize, (platformWallet))
        );
        DuckLockerArc locker = DuckLockerArc(payable(address(lockerProxy)));
        console.log("DuckLockerArc impl:  ", address(lockerImpl));
        console.log("DuckLockerArc proxy: ", address(locker));

        // ── Shared DuckHookV4Arc, deployed via CREATE2 factory so the
        // resulting address satisfies V4's permission-bit requirement ───────
        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(DuckHookV4Arc).creationCode,
            abi.encode(V4_POOL_MANAGER)
        ));
        (bytes32 hookSalt, address predictedHook) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(hookSalt, V4_POOL_MANAGER, deployer);
        require(hookAddr == predictedHook, "hook address mismatch");
        require(uint160(hookAddr) & 0x3FFF == 0xC4, "bad hook permission bits");
        DuckHookV4Arc hook = DuckHookV4Arc(payable(hookAddr));
        console.log("DuckHookFactory:  ", address(hookFactory));
        console.log("DuckHookV4Arc:    ", hookAddr);

        // ── DuckIncubationArc (bonding curve, V4 only) ───────────────────────
        DuckIncubationArc curveImpl = new DuckIncubationArc();
        ERC1967Proxy curveProxy = new ERC1967Proxy(
            address(curveImpl),
            abi.encodeCall(DuckIncubationArc.initialize, (
                NATIVE_ERC20_MIRROR, V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2,
                address(0), // hook wired below via setDexConfig
                platformWallet, address(incubationTokenImpl), address(locker)
            ))
        );
        DuckIncubationArc curve = DuckIncubationArc(payable(address(curveProxy)));
        curve.setDexConfig(V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2, hookAddr);
        console.log("DuckIncubationArc impl:  ", address(curveImpl));
        console.log("DuckIncubationArc proxy: ", address(curve));

        // ── DuckLauncherArc (instant launch, V4 by default + a V3 option) ────
        DuckLauncherArc launcherImpl = new DuckLauncherArc();
        ERC1967Proxy launcherProxy = new ERC1967Proxy(
            address(launcherImpl),
            abi.encodeCall(DuckLauncherArc.initialize, (
                NATIVE_ERC20_MIRROR, address(launcherTokenImpl), address(locker), platformWallet,
                V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2, hookAddr
            ))
        );
        DuckLauncherArc launcher = DuckLauncherArc(payable(address(launcherProxy)));
        launcher.addDexV3(V3_POSITION_MANAGER, V3_SWAP_ROUTER02);
        console.log("DuckLauncherArc impl:  ", address(launcherImpl));
        console.log("DuckLauncherArc proxy: ", address(launcher));

        // ── DuckRaiseArc (crowdfunding, V4 only) ─────────────────────────────
        DuckRaiseArc raiseImpl = new DuckRaiseArc();
        ERC1967Proxy raiseProxy = new ERC1967Proxy(
            address(raiseImpl),
            abi.encodeCall(DuckRaiseArc.initialize, (
                NATIVE_ERC20_MIRROR, address(raiseTokenImpl), address(locker),
                V4_POOL_MANAGER, V4_POSITION_MANAGER, PERMIT2, hookAddr, platformWallet
            ))
        );
        DuckRaiseArc raise = DuckRaiseArc(payable(address(raiseProxy)));
        console.log("DuckRaiseArc impl:  ", address(raiseImpl));
        console.log("DuckRaiseArc proxy: ", address(raise));

        // ── Cross-contract authorization ─────────────────────────────────────
        locker.addLauncher(address(curve));
        locker.addLauncher(address(launcher));
        locker.addLauncher(address(raise));

        hook.addLauncher(address(curve));
        hook.addLauncher(address(launcher));
        hook.addLauncher(address(raise));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("Owner (all governance-controlled contracts):", deployer);
        console.log("Platform wallet (fee recipient):             ", platformWallet);
    }

    // Identical mining approach to the fork tests: increment a nonce, predict
    // the CREATE2 address off the factory's own (now-known, on-chain) address,
    // accept the first one satisfying V4's permission-bit mask. Pure local
    // computation -- runs during script simulation, not as a broadcast tx.
    function _mineHookSalt(address factory, bytes32 initCodeHash)
        internal pure returns (bytes32 salt, address predicted)
    {
        for (uint256 nonce = 0; nonce < 200_000; nonce++) {
            salt = bytes32(nonce);
            predicted = _computeCreate2Address(salt, initCodeHash, factory);
            if (uint160(predicted) & 0x3FFF == 0xC4) return (salt, predicted);
        }
        revert("hook salt not found");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer_)
        internal pure returns (address addr)
    {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer_))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            addr := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
