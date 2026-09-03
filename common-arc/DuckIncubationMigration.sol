// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckIncubationMigration

import {TokenConfig} from "./DuckIncubationTypes.sol";
import {V4Minting} from "./V4Minting.sol";
import {Route, RouteShape} from "./LaunchRouting.sol";

interface IDuckIncubationTokenMig {
    function balanceOf(address account) external view returns (uint256);
    function postMigrateSetup() external;
}

interface IERC20BalanceMig {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ILockerMig {
    function registerPosition(
        address token, uint256 tokenId, address token0, address token1,
        bytes32 poolId, address hook, address positionManager
    ) external;
}

interface IWETH9Mig {
    function deposit() external payable;
}

library DuckIncubationMigration {
    error LiquidityReserveViolation();
    error InsufficientContractBalance();
    error LockerNotSet();
    error HookNotSet();
    error AntibotBlocksOutOfRange();
    error TransferFailed();
    error NativeTransferFailed();

    uint256 private constant ANTIBOT_MIN_BLOCKS = 10;
    uint256 private constant ANTIBOT_MAX_BLOCKS = 199;

    function registerToken(
        TokenConfig storage tc,
        address[] storage allTokens,
        mapping(address => address[]) storage tokensByCreator,
        address token_,
        address creator_,
        address quoteToken_,
        uint256 supply,
        uint256 liqTokens,
        uint256 bcTokens,
        uint256 virtualQuote_,
        uint256 migrationTarget_,
        bool enableAntibot_,
        uint256 antibotBlocks_,
        uint256 hookFeeBps_
    ) external returns (uint256 tradingBlock_) {
        uint256 antibotBlocks = 0;
        if (enableAntibot_) {
            if (antibotBlocks_ < ANTIBOT_MIN_BLOCKS || antibotBlocks_ > ANTIBOT_MAX_BLOCKS)
                revert AntibotBlocksOutOfRange();
            antibotBlocks = antibotBlocks_;
        }

        tc.token           = token_;
        tc.creator         = creator_;
        tc.quoteToken      = quoteToken_;
        tc.totalSupply     = supply;
        tc.liquidityTokens = liqTokens;
        tc.bcTokensTotal   = bcTokens;
        tc.bcTokensSold    = 0;
        tc.virtualQuote    = virtualQuote_;
        tc.k               = virtualQuote_ * bcTokens;
        tc.raisedQuote     = 0;
        tc.accruedFee      = 0;
        tc.hookFeeBps      = hookFeeBps_;
        tc.migrationTarget = migrationTarget_;
        tc.antibotEnabled  = enableAntibot_;
        tc.creationBlock   = block.number;
        tc.tradingBlock    = block.number + antibotBlocks;
        tc.migrated        = false;

        allTokens.push(token_);
        tokensByCreator[creator_].push(token_);
        tradingBlock_ = tc.tradingBlock;
    }

    struct MigrationConfig {
        address locker;
        address hook;
        address weth;
        address positionManager;
        address permit2;
        address singleton;
        uint24  fee;
        int24   tickSpacing;
    }

    // Returns the updated _totalRaisedETH aggregate (unchanged if this
    // token's quote asset is an ERC20) alongside the migrated pool's id.
    function migrate(
        TokenConfig storage tc,
        address token_,
        uint256 totalRaisedETH,
        mapping(address => uint256) storage totalRaisedERC,
        MigrationConfig calldata cfg
    ) external returns (uint256 newTotalRaisedETH, bytes32 poolId) {
        tc.migrated          = true;
        tc.migrationPending  = false;

        uint256 migrationAmount = tc.raisedQuote;
        uint256 liqTokens       = tc.liquidityTokens;

        if (IDuckIncubationTokenMig(token_).balanceOf(address(this)) < liqTokens)
            revert LiquidityReserveViolation();

        newTotalRaisedETH = totalRaisedETH;
        if (tc.quoteToken == address(0)) {
            if (migrationAmount > address(this).balance) revert InsufficientContractBalance();
            newTotalRaisedETH = migrationAmount >= totalRaisedETH ? 0 : totalRaisedETH - migrationAmount;
        } else {
            if (migrationAmount > IERC20BalanceMig(tc.quoteToken).balanceOf(address(this))) revert InsufficientContractBalance();
            uint256 agg = totalRaisedERC[tc.quoteToken];
            totalRaisedERC[tc.quoteToken] = migrationAmount >= agg ? 0 : agg - migrationAmount;
        }

        poolId = _mintV4(tc, token_, migrationAmount, liqTokens, cfg);

        IDuckIncubationTokenMig(token_).postMigrateSetup();
        tc.raisedQuote = 0;
    }

    function seedDefaultQuoteTokens(mapping(address => bool) storage quoteTokenAllowed)
        external returns (address[15] memory defaults)
    {
        defaults = [
            0x2D270e6886d130D724215A266106e6832161EAEd, // USDC
            0x71052BAe71C25C78E37fD12E5ff1101A71d9018F, // LINK
            0x0200C29006150606B650577BBE7B6248F58470c1, // USD₮0
            0xe343167631d89B6Ffc58B88d6b7fB0228795491D, // USDG
            0x142cdc44890978B506e745bB3Bd11607B7f7faEf, // PYUSD
            0xc3eACf0612346366Db554C991D7858716db09f58, // RSETH
            0xF50258D3c1dd88946C567920B986A12e65b50dAc, // XAUT0
            0xc845b2894dBddd03858fd2D643B4eF725fE0849d, // NVDAX
            0xb63EFBc28860c8097e341DE1fCF59456161E9D98, // SNDKX
            0x53Ad50D3B6FCaCB8965d3A49cB722917C7DAE1F3, // ACRED
            0x6F75AC3b1b6Fbe8Bb5F948e25aF03620f26Ae838, // XLEX
            0xeFD30445A4ec1f4b3E0a6f4d9bDbd215F805047F, // MRNAX
            0xBca703C64f616A17b4f2763F34f93400Dbe20F17, // ETNX
            0x7636244Bab612264e1B2dFd4bA6E26d0311b1Eb7, // CEGX
            0x06A0138F8c3e5110fd98e34a4473Fb08F1304b87  // MOOX
        ];
        for (uint256 i; i < defaults.length; ++i) {
            quoteTokenAllowed[defaults[i]] = true;
        }
    }

    // USDC/USDT0 are the only two of the 15 default quote tokens with real
    // verified Ink liquidity (native-ETH-paired V4 pool, fee=3000/
    // spacing=60/no hook) -- seeds buyWithNative's routes for them.
    function seedDefaultRoutes(mapping(address => Route[]) storage routes, address v4Singleton_)
        external returns (address usdc, address usdt0)
    {
        usdc  = 0x2D270e6886d130D724215A266106e6832161EAEd;
        usdt0 = 0x0200C29006150606B650577BBE7B6248F58470c1;

        Route memory r = Route({
            shape:            RouteShape.V4_STYLE,
            enabled:          true,
            router:           address(0),
            routerNoDeadline: false,
            path:             new address[](0),
            fees:             new uint24[](0),
            routers:          new address[](0),
            singleton:        v4Singleton_,
            hook:             address(0),
            fee:              3000,
            tickSpacing:      60
        });

        delete routes[usdc];
        routes[usdc].push(r);
        delete routes[usdt0];
        routes[usdt0].push(r);
    }

    // Fallback for when a V4 pool has already been initialized at the
    // predicted pool key -- the owner receives the raised quote and
    // liquidity tokens to provision liquidity manually.
    function emergencyMigrate(
        TokenConfig storage tc,
        address token_,
        address to,
        uint256 totalRaisedETH,
        mapping(address => uint256) storage totalRaisedERC
    ) external returns (uint256 newTotalRaisedETH, uint256 migrationAmount, uint256 liqTokens) {
        tc.migrated         = true;
        tc.migrationPending = false;

        migrationAmount = tc.raisedQuote;
        liqTokens       = tc.liquidityTokens;
        address quote_  = tc.quoteToken;

        // Mirror the sell-path InsufficientPoolQuote guard: never send more than
        // the contract actually holds, even if accounting somehow drifts.
        if (quote_ == address(0)) {
            if (migrationAmount > address(this).balance) revert InsufficientContractBalance();
            newTotalRaisedETH = migrationAmount >= totalRaisedETH ? 0 : totalRaisedETH - migrationAmount;
        } else {
            if (migrationAmount > IERC20BalanceMig(quote_).balanceOf(address(this))) revert InsufficientContractBalance();
            newTotalRaisedETH = totalRaisedETH;
            uint256 agg = totalRaisedERC[quote_];
            totalRaisedERC[quote_] = migrationAmount >= agg ? 0 : agg - migrationAmount;
        }
        tc.raisedQuote = 0;

        IDuckIncubationTokenMig(token_).postMigrateSetup();

        if (liqTokens > 0) {
            if (!IERC20BalanceMig(token_).transfer(to, liqTokens)) revert TransferFailed();
        }
        _payQuote(quote_, to, migrationAmount);
    }

    function _payQuote(address quoteToken_, address to, uint256 amount) private {
        if (amount == 0) return;
        if (quoteToken_ == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            if (!IERC20BalanceMig(quoteToken_).transfer(to, amount)) revert TransferFailed();
        }
    }

    function _mintV4(
        TokenConfig storage tc, address token_, uint256 migrationAmount, uint256 liqTokens,
        MigrationConfig calldata cfg
    ) private returns (bytes32 poolId) {
        if (cfg.locker == address(0)) revert LockerNotSet();
        if (cfg.hook   == address(0)) revert HookNotSet();

        address quote_ = tc.quoteToken;
        if (quote_ == address(0)) {
            quote_ = cfg.weth;
            IWETH9Mig(cfg.weth).deposit{value: migrationAmount}();
        }

        (address token0, address token1, uint256 amount0, uint256 amount1) = token_ < quote_
            ? (token_, quote_, liqTokens,       migrationAmount)
            : (quote_, token_, migrationAmount, liqTokens);

        uint256 tokenId;
        (poolId, tokenId) = V4Minting.initAndMintFullRange(V4Minting.MintParams({
            positionManager: cfg.positionManager,
            permit2:         cfg.permit2,
            hook:            cfg.hook,
            token:           token_,
            token0:          token0,
            token1:          token1,
            amount0:         amount0,
            amount1:         amount1,
            recipient:       cfg.locker,
            creator:         tc.creator,
            hookFeeBps:      tc.hookFeeBps,
            fee:             cfg.fee,
            tickSpacing:     cfg.tickSpacing
        }));

        ILockerMig(cfg.locker).registerPosition(token_, tokenId, token0, token1, poolId, cfg.hook, cfg.positionManager);

        tc.pair   = cfg.singleton;
        tc.poolId = poolId;
    }
}
