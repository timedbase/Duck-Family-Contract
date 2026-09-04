// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — deploy the new DuckLockerArc implementation (a V4-
// launched token's token-side LP fee parked into a single-sided V3 position
// instead of burned outright, see DuckLocker.sol's PARK_TICK_OFFSET/
// parkTokenSide), upgrade the live proxy to it, and wire up the new
// feature -- all in one broadcast.
//
// DuckLockerArc's upgrade authority used to be timelocked (48h between
// proposeUpgrade and the upgrade taking effect) -- removed at the owner's
// explicit request, so upgradeToAndCall now takes effect immediately, same
// as every other onlyOwner action on this contract. There is no separate
// proposeUpgrade step anymore; this script does the whole thing in one go.
//
// Usage (recommended -- encrypted local keystore, no plaintext key anywhere):
//   cast wallet import deployer --interactive          # skip if already imported
//   cd deploy-arc
//   DEPLOYER_ADDRESS=0x43977b10095Fc5E153F907fe2E888C083fA4Fb66 \
//     forge script script/UpgradeLocker.s.sol:UpgradeLocker --rpc-url arc --account deployer --broadcast -vvvv

import {Script, console} from "forge-std/Script.sol";
import {DuckLockerArc} from "duck-launcher-contracts/DuckLocker.sol";

contract UpgradeLocker is Script {
    address constant DUCK_LOCKER_PROXY   = 0x74738a87e4D4E0eB2706724a9314d1b4452ecdFE;
    address constant V3_POSITION_MANAGER = 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

        DuckLockerArc newImpl = new DuckLockerArc();
        console.log("New DuckLockerArc implementation:", address(newImpl));

        DuckLockerArc locker = DuckLockerArc(payable(DUCK_LOCKER_PROXY));
        locker.upgradeToAndCall(address(newImpl), "");
        console.log("Upgrade complete");

        // No separate StateView setting needed on Arc -- see
        // DuckLockerArc.sol's parkTokenSide comment.
        locker.setV3PositionManager(V3_POSITION_MANAGER);
        console.log("Park-into-V3 feature wired up and live");

        vm.stopBroadcast();
    }
}
