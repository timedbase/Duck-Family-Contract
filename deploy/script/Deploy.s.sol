// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — full production deploy to Ink chain (57073).
//
// Deploys, in order: the three token implementations, DuckLocker (shared
// across all three launcher families), the CREATE2 hook factory + the one
// canonical DuckHookV4 (also shared), then DuckIncubation, DuckLauncher and
// DuckRaise themselves -- wiring every cross-contract authorization
// (locker.addLauncher, hook.addLauncher) at the end.
//
// Usage (recommended -- encrypted local keystore, no plaintext key anywhere):
//   cast wallet import deployer --interactive          # one-time, prompts for the key + a password
//   cd deploy
//   DEPLOYER_ADDRESS=0x... PLATFORM_WALLET=0x... \
//     forge script script/Deploy.s.sol:Deploy --rpc-url ink --account deployer --broadcast -vvvv
//   (forge prompts for the keystore password at broadcast time)
//
// Usage (raw key via env var -- only if you already manage it that way):
//   PRIVATE_KEY=0x... PLATFORM_WALLET=0x... \
//     forge script script/Deploy.s.sol:Deploy --rpc-url ink --broadcast -vvvv
//
// PLATFORM_WALLET defaults to the deployer address if unset -- that's fine
// for a first deploy but should almost certainly be a treasury/multisig
// before real funds start flowing through claimCurveFee/claimFees. Contract
// ownership (curve/launcher/raise/locker, plus the hook via its factory) is
// left with the deployer key too -- transferring that to a safer address is
// a separate, deliberate step this script does not take for you.

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckIncubation} from "duck-incubation-contracts/DuckIncubation.sol";
import {DuckIncubationToken} from "duck-incubation-contracts/DuckIncubationToken.sol";
import {DuckLauncher} from "duck-launcher-contracts/DuckLauncherUpgradeable.sol";
import {DuckLauncherToken} from "duck-launcher-contracts/DuckLauncherToken.sol";
import {DuckLocker} from "duck-launcher-contracts/DuckLocker.sol";
import {DuckHookV4} from "duck-launcher-contracts/DuckHookV4.sol";
import {DuckRaise} from "duckraise-contracts/DuckRaise.sol";
import {DuckRaiseToken} from "duckraise-contracts/DuckRaiseToken.sol";
import {DuckHookFactory} from "./DuckHookFactory.sol";

contract Deploy is Script {
    // ── Verified Ink chain (57073) infrastructure ───────────────────────────
    address constant WETH                = 0x4200000000000000000000000000000000000006;
    address constant V4_POOL_MANAGER     = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant V4_POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant PERMIT2             = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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
        DuckIncubationToken incubationTokenImpl = new DuckIncubationToken();
        DuckLauncherToken   launcherTokenImpl   = new DuckLauncherToken();
        DuckRaiseToken      raiseTokenImpl      = new DuckRaiseToken();
        console.log("DuckIncubationToken impl:", address(incubationTokenImpl));
        console.log("DuckLauncherToken impl:  ", address(launcherTokenImpl));
        console.log("DuckRaiseToken impl:     ", address(raiseTokenImpl));

        // ── DuckLocker (shared across all three families) ───────────────────
        DuckLocker lockerImpl = new DuckLocker();
        ERC1967Proxy lockerProxy = new ERC1967Proxy(
            address(lockerImpl),
            abi.encodeCall(DuckLocker.initialize, (platformWallet))
        );
        DuckLocker locker = DuckLocker(payable(address(lockerProxy)));
        console.log("DuckLocker impl:  ", address(lockerImpl));
        console.log("DuckLocker proxy: ", address(locker));

        // ── Shared DuckHookV4, deployed via CREATE2 factory so the resulting
        // address satisfies V4's permission-bit requirement ──────────────────
        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(DuckHookV4).creationCode,
            abi.encode(V4_POOL_MANAGER)
        ));
        (bytes32 hookSalt, address predictedHook) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(hookSalt, V4_POOL_MANAGER, deployer);
        require(hookAddr == predictedHook, "hook address mismatch");
        require(uint160(hookAddr) & 0x3FFF == 0xC4, "bad hook permission bits");
        DuckHookV4 hook = DuckHookV4(payable(hookAddr));
        console.log("DuckHookFactory:  ", address(hookFactory));
        console.log("DuckHookV4:       ", hookAddr);

        // ── DuckIncubation (bonding curve) ───────────────────────────────────
        DuckIncubation curveImpl = new DuckIncubation();
        ERC1967Proxy curveProxy = new ERC1967Proxy(
            address(curveImpl),
            abi.encodeCall(DuckIncubation.initialize, (
                WETH, V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2,
                address(0), // hook wired below via setDexConfig
                platformWallet, address(incubationTokenImpl), address(locker)
            ))
        );
        DuckIncubation curve = DuckIncubation(payable(address(curveProxy)));
        curve.setDexConfig(V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2, hookAddr);
        console.log("DuckIncubation impl:  ", address(curveImpl));
        console.log("DuckIncubation proxy: ", address(curve));

        // ── DuckLauncher (instant launch) ────────────────────────────────────
        DuckLauncher launcherImpl = new DuckLauncher();
        ERC1967Proxy launcherProxy = new ERC1967Proxy(
            address(launcherImpl),
            abi.encodeCall(DuckLauncher.initialize, (
                WETH, address(launcherTokenImpl), address(locker), platformWallet,
                V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2, hookAddr
            ))
        );
        DuckLauncher launcher = DuckLauncher(payable(address(launcherProxy)));
        console.log("DuckLauncher impl:  ", address(launcherImpl));
        console.log("DuckLauncher proxy: ", address(launcher));

        // ── DuckRaise (crowdfunding) ──────────────────────────────────────────
        DuckRaise raiseImpl = new DuckRaise();
        ERC1967Proxy raiseProxy = new ERC1967Proxy(
            address(raiseImpl),
            abi.encodeCall(DuckRaise.initialize, (
                WETH, address(raiseTokenImpl), address(locker),
                V4_POOL_MANAGER, V4_POSITION_MANAGER, PERMIT2, hookAddr, platformWallet
            ))
        );
        DuckRaise raise = DuckRaise(payable(address(raiseProxy)));
        console.log("DuckRaise impl:  ", address(raiseImpl));
        console.log("DuckRaise proxy: ", address(raise));

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
