// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — deploy the new DuckLocker implementation (token-side LP
// fee parked into a single-sided V3 position instead of burned outright,
// see DuckLocker.sol's PARK_TICK_OFFSET/parkTokenSide) and queue the
// upgrade on the live proxy.
//
// DuckLocker's upgrade authority is timelocked (TIMELOCK_DELAY = 48 hours):
// this script only calls proposeUpgrade, which starts that clock. The
// upgrade does NOT take effect here -- a second, separate transaction
// (upgradeToAndCall, see below) has to be sent at least 48 hours after this
// one to actually swap the implementation. Until that second call, the live
// proxy keeps running its current implementation exactly as before,
// unaffected by this script.
//
// Usage (recommended -- encrypted local keystore, no plaintext key anywhere):
//   cast wallet import deployer --interactive          # skip if already imported
//   cd deploy
//   DEPLOYER_ADDRESS=0x43977b10095Fc5E153F907fe2E888C083fA4Fb66 \
//     forge script script/UpgradeLocker.s.sol:UpgradeLocker --rpc-url ink --account deployer --broadcast -vvvv
//
// After this script logs the new implementation address, wait 48+ hours,
// then run (from the same directory, same signer):
//   cast send 0x74738a87e4D4E0eB2706724a9314d1b4452ecdFE \
//     "upgradeToAndCall(address,bytes)" <NEW_IMPL_FROM_THIS_SCRIPT> 0x \
//     --rpc-url ink --account deployer
//
// Once that succeeds, the new feature is still OFF until explicitly wired
// up (matches every other opt-in setting on this contract -- platformToken,
// etc.). Turn it on with:
//   cast send 0x74738a87e4D4E0eB2706724a9314d1b4452ecdFE \
//     "setV3PositionManager(address)" 0xC0836E5B058BBE22ae2266e1AC488A1A0fD8DCE8 \
//     --rpc-url ink --account deployer
//   cast send 0x74738a87e4D4E0eB2706724a9314d1b4452ecdFE \
//     "setV4StateView(address)" 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990 \
//     --rpc-url ink --account deployer

import {Script, console} from "forge-std/Script.sol";
import {DuckLocker} from "duck-launcher-contracts/DuckLocker.sol";

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

        DuckLocker newImpl = new DuckLocker();
        console.log("New DuckLocker implementation:", address(newImpl));

        DuckLocker(payable(DUCK_LOCKER_PROXY)).proposeUpgrade(address(newImpl));
        console.log("proposeUpgrade queued -- executable via upgradeToAndCall after the 48h timelock");

        vm.stopBroadcast();
    }
}
