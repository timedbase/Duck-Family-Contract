// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — deploy the new DuckLockerArc implementation (a V4-
// launched token's token-side LP fee parked into a single-sided V3 position
// instead of burned outright, see DuckLocker.sol's PARK_TICK_OFFSET/
// parkTokenSide) and queue the upgrade on the live proxy.
//
// IMPORTANT: the upgrade authority check that runs here is whatever is
// CURRENTLY live on the proxy -- not the new implementation being deployed.
// The currently-live DuckLockerArc still requires the old two-step flow
// (proposeUpgrade, then a 48h wait, then upgradeToAndCall) even though the
// NEW implementation being proposed here no longer has that requirement
// once it's actually active (its source no longer even declares
// proposeUpgrade -- hence the separate minimal interface below, targeting
// the proxy directly rather than the new DuckLockerArc type). So this
// script only calls proposeUpgrade; a separate upgradeToAndCall call at
// least 48 hours later is what actually swaps the implementation (see
// below) -- attempting that call any sooner, or skipping proposeUpgrade,
// reverts with PendingValueMismatch().
//
// Usage (recommended -- encrypted local keystore, no plaintext key anywhere):
//   cast wallet import deployer --interactive          # skip if already imported
//   cd deploy-arc
//   DEPLOYER_ADDRESS=0x43977b10095Fc5E153F907fe2E888C083fA4Fb66 \
//     forge script script/UpgradeLocker.s.sol:UpgradeLocker --rpc-url arc --account deployer --broadcast -vvvv
//
// After this script logs the new implementation address, wait 48+ hours,
// then run (same signer):
//   cast send 0x74738a87e4D4E0eB2706724a9314d1b4452ecdFE \
//     "upgradeToAndCall(address,bytes)" <NEW_IMPL_FROM_THIS_SCRIPT> 0x \
//     --rpc-url https://rpc.arc-scan.org --private-key "$PRIVATE_KEY"
//
// Once that succeeds, the new implementation's own upgrade authority has no
// timelock any more (removed at the owner's request) -- but the feature
// itself is still OFF until wired up, same as every other opt-in setting on
// this contract (no separate StateView setting needed on Arc -- see
// DuckLockerArc.sol's parkTokenSide comment):
//   cast send 0x74738a87e4D4E0eB2706724a9314d1b4452ecdFE \
//     "setV3PositionManager(address)" 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377 \
//     --rpc-url https://rpc.arc-scan.org --private-key "$PRIVATE_KEY"

import {Script, console} from "forge-std/Script.sol";
import {DuckLockerArc} from "duck-launcher-contracts/DuckLocker.sol";

// The new DuckLockerArc source no longer declares proposeUpgrade (removed
// along with the timelock) -- but the proxy is still running the OLD
// implementation, which does, until the upgrade below actually lands. This
// targets the proxy directly with just that one selector rather than the
// new DuckLockerArc type, since Solidity typechecks calls against the type
// used at the call site, not whatever's actually deployed.
interface IPendingUpgradeableLocker {
    function proposeUpgrade(address newImpl) external;
}

contract UpgradeLocker is Script {
    address constant DUCK_LOCKER_PROXY = 0x74738a87e4D4E0eB2706724a9314d1b4452ecdFE;

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

        IPendingUpgradeableLocker(DUCK_LOCKER_PROXY).proposeUpgrade(address(newImpl));
        console.log("proposeUpgrade queued -- run upgradeToAndCall after the 48h timelock (see header comment)");

        vm.stopBroadcast();
    }
}
