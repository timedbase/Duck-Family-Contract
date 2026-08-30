// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — deploy a REPLACEMENT DuckHookV4 with the exact-output
// sell-fee fix, and wire it into all three families going forward.
//
// This does NOT touch the three already-deployed family proxies' other
// config, and it does NOT (can't) change the hook any already-created V4
// pool uses -- a pool's hook is fixed forever at pool creation. Only pools
// registered after this script's follow-up wiring step (below) will use the
// new hook and get the fixed fee logic. Every already-live pool keeps using
// the old hook (0xA547E097bCcA60737b8264C4dDB9bC3bE74880C4) permanently.
//
// Usage (recommended -- encrypted local keystore, no plaintext key anywhere):
//   cast wallet import deployer --interactive          # skip if already imported
//   cd deploy
//   DEPLOYER_ADDRESS=0x43977b10095Fc5E153F907fe2E888C083fA4Fb66 \
//     forge script script/DeployNewHook.s.sol:DeployNewHook --rpc-url ink --account deployer --broadcast -vvvv
//
// After this script logs the new hook address, wire it into all three
// families with the owner-only cast send commands printed at the end of
// this file's comment block (or see the assistant's chat message).

import {Script, console} from "forge-std/Script.sol";
import {DuckHookV4} from "duck-launcher-contracts/DuckHookV4.sol";
import {DuckHookFactory} from "./DuckHookFactory.sol";

contract DeployNewHook is Script {
    address constant V4_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    // The three already-deployed family proxies -- unchanged, just need
    // hook.addLauncher() on the NEW hook so they're allowed to register
    // pools against it once wired.
    address constant DUCK_INCUBATION = 0x5c4f0938FC434b60b57209BbC971544b73876675;
    address constant DUCK_LAUNCHER   = 0x2A84711A5c0Ee62118CEee1A37C0dA46a6980353;
    address constant DUCK_RAISE      = 0x39D17950BaaD5737d08b027F0494E2C261B37Cf2;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

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

        hook.addLauncher(DUCK_INCUBATION);
        hook.addLauncher(DUCK_LAUNCHER);
        hook.addLauncher(DUCK_RAISE);
        // Old hook's platformWallet() is currently unset (address(0)) --
        // matching that here. Call hook.setPlatformWallet(...) yourself
        // afterward if you want to set one on the new hook.

        vm.stopBroadcast();

        console.log("");
        console.log("=== New DuckHookV4 deployed ===");
        console.log("DuckHookFactory: ", address(hookFactory));
        console.log("DuckHookV4 (new):", hookAddr);
        console.log("Owner:           ", deployer);
        console.log("");
        console.log("Old hook (still used by every existing pool):");
        console.log("0xA547E097bCcA60737b8264C4dDB9bC3bE74880C4");
    }

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
