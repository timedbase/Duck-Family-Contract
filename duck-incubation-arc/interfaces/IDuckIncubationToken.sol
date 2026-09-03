// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — IDuckIncubationToken

interface IDuckIncubationToken {
    // Called by DuckIncubationArc at migration to lift the launch-phase
    // transfer restriction.
    function postMigrateSetup() external;

    function metaURI() external view returns (string memory);
    function setMetaURI(string calldata uri_) external;

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
