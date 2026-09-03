// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckIncubationTypes
struct FeeSplit {
    address wallet;
    uint16  bps;
}

struct TokenConfig {
    address   token;
    address   creator;
    address   quoteToken; // address(0) = native currency, else a whitelisted ERC20

    uint256 totalSupply;
    uint256 liquidityTokens;
    uint256 bcTokensTotal;
    uint256 bcTokensSold;

    uint256 virtualQuote;
    uint256 k;
    uint256 raisedQuote;
    uint256 migrationTarget;

    address pair;   // the V4 PoolManager, once migrated (single shared singleton)
    bytes32 poolId;

    uint256 accruedFee; // 1% curve-trading fee, accrued per-trade, claimable only after migration
    uint256 hookFeeBps; // creator-chosen post-migration sell-fee rate; 0 = hook default (2%)

    bool    antibotEnabled;
    uint256 creationBlock;
    uint256 tradingBlock;

    bool migrated;
    bool migrationPending; // set when migration-cap buy commits but auto-migration reverts
}
