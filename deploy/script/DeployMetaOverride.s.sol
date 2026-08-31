// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — deploy DuckMetaOverride, a standalone platform-owned
// metadata-override registry (see contracts/common/DuckMetaOverride.sol for
// the full rationale). This does not touch any of the three already-deployed
// family proxies, the locker, or the hook -- it's a brand-new, independent
// contract with no wiring step required afterward.
//
// Usage (recommended -- encrypted local keystore, no plaintext key anywhere):
//   cast wallet import deployer --interactive          # skip if already imported
//   cd deploy
//   DEPLOYER_ADDRESS=0x43977b10095Fc5E153F907fe2E888C083fA4Fb66 \
//     forge script script/DeployMetaOverride.s.sol:DeployMetaOverride --rpc-url ink --account deployer --broadcast -vvvv
//
// After this script logs the deployed address, give it to the assistant so it
// can wire it into subgraph.yaml and both addresses.js/addresses.ts files.

import {Script, console} from "forge-std/Script.sol";
import {DuckMetaOverride} from "common-contracts/DuckMetaOverride.sol";

contract DeployMetaOverride is Script {
    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

        DuckMetaOverride metaOverride = new DuckMetaOverride(deployer);

        vm.stopBroadcast();

        console.log("");
        console.log("=== DuckMetaOverride deployed ===");
        console.log("DuckMetaOverride:", address(metaOverride));
        console.log("Owner:           ", deployer);
    }
}
