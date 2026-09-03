// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {DuckHookV4Arc as DuckHookV4} from "duck-launcher-contracts/DuckHookV4.sol";

// Thin, one-time-use CREATE2 relay. Broadcasting `new DuckHookV4{salt}(...)`
// directly from an EOA routes through the canonical CREATE2 deployer proxy,
// which would then permanently own the hook. Routing through this factory
// makes the factory the deployer at construction time, then hands ownership
// back to the real deployer atomically in the same transaction. The salt is
// mined off-chain against this factory's own address, so the factory must
// be deployed (plain CREATE) before mining.
contract DuckHookFactory {
    function deploy(
        bytes32 salt,
        address poolManager_,
        address newOwner_
    ) external returns (address hook) {
        hook = address(new DuckHookV4{salt: salt}(poolManager_));
        DuckHookV4(payable(hook)).transferOwnership(newOwner_);
    }
}
