// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckMetaOverrideArc
//
// A token's metaURI is baked in immutably at creation (DuckIncubationArc.createToken,
// DuckLauncherArc.launch, DuckRaiseArc.launch all take it as a one-time argument -- the
// token contract itself never exposes a way to change it). If that metadata turns
// out wrong, or a CTO wants their token's presentation corrected, there is no path
// to fix it on the token itself.
//
// This is a standalone, platform-owned registry: the owner can register a token
// with a replacement metaURI, and from that point on every consumer (subgraph ->
// backend -> interface) is expected to treat the override as authoritative and
// stop reading the token's original metaURI -- without ever touching the
// immutable original value on-chain. Registration and every later update are
// owner-only; there is no self-service path for creators/CTOs by design.
//
// Holds no funds and has no dependency on the family contracts, so it doesn't need
// the UUPS-upgradeable + timelock pattern DuckLockerArc/DuckHookV4Arc use for
// higher-risk, fund-touching contracts -- a plain Ownable2Step contract is less
// surface for the same job.

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DuckMetaOverrideArc is Ownable2Step {
    error ZeroAddress();
    error NotRegistered();

    mapping(address => bool)   public isRegistered;
    mapping(address => string) public metaURI;

    event TokenRegistered(address indexed token, string metaURI);
    event MetaURIUpdated(address indexed token, string metaURI);
    event TokenUnregistered(address indexed token);

    constructor(address owner_) Ownable(owner_) {}

    // Registers a token into override mode and sets its replacement metaURI in
    // one call -- the moment this lands, the original creation-time metaURI is
    // no longer authoritative for this token as far as every off-chain consumer
    // is concerned.
    function registerToken(address token, string calldata metaURI_) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isRegistered[token] = true;
        metaURI[token] = metaURI_;
        emit TokenRegistered(token, metaURI_);
    }

    // Updates an already-registered token's override metaURI.
    function updateMetaURI(address token, string calldata metaURI_) external onlyOwner {
        if (!isRegistered[token]) revert NotRegistered();
        metaURI[token] = metaURI_;
        emit MetaURIUpdated(token, metaURI_);
    }

    // Reverts the token back to its original on-chain metaURI. Clears the
    // stored string too, so a stale value can never resurface if the token is
    // registered again later.
    function unregisterToken(address token) external onlyOwner {
        if (!isRegistered[token]) revert NotRegistered();
        isRegistered[token] = false;
        delete metaURI[token];
        emit TokenUnregistered(token);
    }

    function getMetaURI(address token) external view returns (bool overridden, string memory uri) {
        return (isRegistered[token], metaURI[token]);
    }
}
