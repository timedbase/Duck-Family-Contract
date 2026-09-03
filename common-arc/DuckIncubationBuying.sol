// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckIncubationBuying

import {TokenConfig, FeeSplit} from "./DuckIncubationTypes.sol";

interface IDuckIncubationTokenBuy {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC20TransferBuy {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ILaunchpadSelfBuy {
    function _tryMigrateExternal(address token_) external;
}

library DuckIncubationBuying {
    error ZeroAmount();
    error SlippageTooFewTokens();
    error LiquidityReserveViolation();
    error InsufficientPoolQuote();
    error SlippageTooLittleQuote();
    error NativeTransferFailed();
    error TransferFailed();
    error NotCreator();
    error TooManyFeeSplits();
    error InvalidFeeSplitBps();
    error ZeroAddress();
    error ActivePool();
    error CloneFailed();
    error VanityAddressRequired();

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant BPS_DENOM      = 10_000;
    uint256 private constant CURVE_FEE_BPS  =    100; // 1%, fixed -- matches DuckIncubationArc.claimCurveFee

    function executeBuy(
        TokenConfig storage tc,
        address token_,
        address buyer,
        uint256 quoteIn,
        uint256 minOut,
        bool skipAntibot,
        uint256 totalRaisedETH,
        mapping(address => uint256) storage totalRaisedERC,
        uint256 totalAccruedFeeETH,
        mapping(address => uint256) storage totalAccruedFeeERC
    ) external returns (
        uint256 newTotalRaisedETH,
        uint256 newTotalAccruedFeeETH,
        uint256 tokensOut,
        uint256 netQuoteIn,
        uint256 tokensToDead,
        bool migrationAttemptFailed
    ) {
        uint256 fee;
        uint256 refund;
        (tokensOut, fee, netQuoteIn, refund) = _calcBuy(tc, quoteIn, minOut);

        newTotalRaisedETH = totalRaisedETH;
        if (tc.quoteToken == address(0)) newTotalRaisedETH += netQuoteIn - fee;
        else                             totalRaisedERC[tc.quoteToken] += netQuoteIn - fee;

        newTotalAccruedFeeETH = totalAccruedFeeETH;
        if (fee > 0) {
            tc.accruedFee += fee;
            if (tc.quoteToken == address(0)) newTotalAccruedFeeETH += fee;
            else                             totalAccruedFeeERC[tc.quoteToken] += fee;
        }

        address quoteToken_ = tc.quoteToken;
        (tokensToDead, migrationAttemptFailed) = _finalizeBuy(tc, token_, buyer, skipAntibot, tokensOut, refund, quoteToken_);
    }

    function executeSell(
        TokenConfig storage tc,
        address seller,
        uint256 amountIn,
        uint256 minQuoteOut,
        uint256 totalRaisedETH,
        mapping(address => uint256) storage totalRaisedERC,
        uint256 totalAccruedFeeETH,
        mapping(address => uint256) storage totalAccruedFeeERC
    ) external returns (
        uint256 newTotalRaisedETH,
        uint256 newTotalAccruedFeeETH,
        uint256 netQuote,
        uint256 raisedAfter
    ) {
        uint256 poolQuote    = tc.virtualQuote + tc.raisedQuote;
        uint256 newPoolToks  = tc.bcTokensTotal - tc.bcTokensSold + amountIn;
        uint256 newPoolQuote = (tc.k + newPoolToks - 1) / newPoolToks;
        uint256 grossQuote   = poolQuote > newPoolQuote ? poolQuote - newPoolQuote : 0;
        if (grossQuote > tc.raisedQuote) revert InsufficientPoolQuote();
        uint256 fee = (grossQuote * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
        netQuote = grossQuote - fee;
        if (netQuote < minQuoteOut) revert SlippageTooLittleQuote();
        tc.raisedQuote  -= grossQuote;
        tc.bcTokensSold -= amountIn;

        newTotalRaisedETH = totalRaisedETH;
        if (tc.quoteToken == address(0)) {
            newTotalRaisedETH = grossQuote >= totalRaisedETH ? 0 : totalRaisedETH - grossQuote;
        } else {
            uint256 agg = totalRaisedERC[tc.quoteToken];
            totalRaisedERC[tc.quoteToken] = grossQuote >= agg ? 0 : agg - grossQuote;
        }

        raisedAfter = tc.raisedQuote;

        _payQuote(tc.quoteToken, seller, netQuote);

        newTotalAccruedFeeETH = totalAccruedFeeETH;
        if (fee > 0) {
            tc.accruedFee += fee;
            if (tc.quoteToken == address(0)) newTotalAccruedFeeETH += fee;
            else                             totalAccruedFeeERC[tc.quoteToken] += fee;
        }
    }

    function _calcBuy(
        TokenConfig storage tc, uint256 quoteIn, uint256 minOut
    ) private returns (uint256 tokensOut, uint256 fee, uint256 netQuoteIn, uint256 refund) {
        uint256 poolQuote  = tc.virtualQuote + tc.raisedQuote;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        // Ceiling division ensures net amount covers the migration target after fee deduction.
        uint256 grossNeeded = ((tc.migrationTarget - tc.raisedQuote) * BPS_DENOM
                + (BPS_DENOM - CURVE_FEE_BPS) - 1)
              / (BPS_DENOM - CURVE_FEE_BPS);
        uint256 netQuote;

        if (quoteIn >= grossNeeded) {
            // Migration-cap: sell all remaining BC tokens and refund excess quote asset.
            refund     = quoteIn - grossNeeded;
            fee        = (grossNeeded * CURVE_FEE_BPS) / BPS_DENOM;
            netQuote   = grossNeeded - fee;
            tokensOut  = poolTokens;
            netQuoteIn = grossNeeded;
        } else {
            fee        = (quoteIn * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
            netQuote   = quoteIn - fee;
            tokensOut  = poolTokens - ((tc.k + poolQuote + netQuote - 1) / (poolQuote + netQuote));
            netQuoteIn = quoteIn;
        }

        if (tokensOut == 0)         revert ZeroAmount();
        if (tokensOut < minOut)     revert SlippageTooFewTokens();
        if (tokensOut > poolTokens) revert LiquidityReserveViolation();

        tc.raisedQuote  += netQuote;
        tc.bcTokensSold += tokensOut;
        // netQuoteIn - fee == netQuote; returned this way so the caller doesn't
        // need a fifth return value just to thread netQuote through as well.
    }

    function _finalizeBuy(
        TokenConfig storage tc, address token_, address buyer, bool skipAntibot,
        uint256 tokensOut, uint256 refund, address quoteToken_
    ) private returns (uint256 tokensToDead, bool migrationAttemptFailed) {
        if (!skipAntibot && tc.antibotEnabled && block.number < tc.tradingBlock) {
            uint256 remaining   = tc.tradingBlock - block.number;
            uint256 totalBlocks = tc.tradingBlock - tc.creationBlock;
            // Ceiling keeps the penalty from rounding down at the boundary block.
            uint256 penaltyBPS  = (remaining * BPS_DENOM + totalBlocks - 1) / totalBlocks;
            if (penaltyBPS > BPS_DENOM) penaltyBPS = BPS_DENOM;
            tokensToDead = (tokensOut * penaltyBPS) / BPS_DENOM;
        }

        if (tokensToDead > 0)               IDuckIncubationTokenBuy(token_).transfer(DEAD, tokensToDead);
        if (tokensOut - tokensToDead > 0)   IDuckIncubationTokenBuy(token_).transfer(buyer, tokensOut - tokensToDead);

        if (refund > 0) _payQuote(quoteToken_, buyer, refund);

        if (!tc.migrated && tc.raisedQuote >= tc.migrationTarget) {
            // Try migration in the same tx. If it reverts (e.g. pool pre-initialized
            // by an attacker), the buy still commits and migrationPending is set so
            // that migrate() or emergencyMigrate() can be called in a separate tx.
            try ILaunchpadSelfBuy(address(this))._tryMigrateExternal(token_) {
                // migrated successfully in same tx
            } catch {
                tc.migrationPending = true;
                migrationAttemptFailed = true;
            }
        }
    }

    function cloneCreate2(address implementation, address deployer, bytes32 userSalt)
        external returns (address instance)
    {
        bytes32 salt = keccak256(abi.encode(deployer, userSalt));
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,         0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0))              revert CloneFailed();
        if (uint16(uint160(instance)) != 0x8888) revert VanityAddressRequired();
    }

    // Flags a buy-and-burn instead of paying the platform directly when
    // quoted in platformToken -- left to the caller since it needs
    // LaunchRouting's inherited _executeV4Swap, which a library can't call.
    function settleCurveFee(
        TokenConfig storage tc, address creator_, uint256 amount,
        uint256 totalAccruedFeeETH, mapping(address => uint256) storage totalAccruedFeeERC,
        FeeSplit[] storage feeSplits, address platformToken_, address platformWallet_
    ) external returns (uint256 newTotalAccruedFeeETH, uint256 creatorCut, uint256 platformCut, bool needsBuyAndBurn) {
        newTotalAccruedFeeETH = totalAccruedFeeETH;
        if (tc.quoteToken == address(0)) {
            newTotalAccruedFeeETH = amount >= totalAccruedFeeETH ? 0 : totalAccruedFeeETH - amount;
        } else {
            uint256 agg = totalAccruedFeeERC[tc.quoteToken];
            totalAccruedFeeERC[tc.quoteToken] = amount >= agg ? 0 : agg - amount;
        }

        creatorCut  = amount / 2;
        platformCut = amount - creatorCut;

        if (feeSplits.length == 0) {
            _payQuote(tc.quoteToken, creator_, creatorCut);
        } else {
            uint256 len = feeSplits.length;
            uint256 remaining = creatorCut;
            for (uint256 i; i < len; ++i) {
                uint256 cut = i == len - 1 ? remaining : (creatorCut * feeSplits[i].bps) / BPS_DENOM;
                remaining -= cut;
                _payQuote(tc.quoteToken, feeSplits[i].wallet, cut);
            }
        }

        if (platformToken_ != address(0) && tc.quoteToken == platformToken_) {
            needsBuyAndBurn = true;
        } else {
            _payQuote(tc.quoteToken, platformWallet_, platformCut);
        }
    }

    // Read-only mirrors of _calcBuy/executeSell's pricing math, extracted so
    // DuckIncubationArc's own getAmountOut/getAmountOutSell can call this
    // instead of reimplementing the same formula a second time (duplicating
    // it pushed the caller over EIP-170's 24,576-byte contract size limit).
    function previewBuy(
        uint256 migrationTarget, uint256 raisedQuote, uint256 virtualQuote,
        uint256 bcTokensTotal, uint256 bcTokensSold, uint256 k, uint256 quoteIn
    ) external pure returns (uint256 tokensOut, uint256 feeQuote) {
        uint256 poolQuote   = virtualQuote + raisedQuote;
        uint256 poolTokens  = bcTokensTotal - bcTokensSold;
        uint256 grossNeeded = ((migrationTarget - raisedQuote) * BPS_DENOM + (BPS_DENOM - CURVE_FEE_BPS) - 1)
              / (BPS_DENOM - CURVE_FEE_BPS);

        if (quoteIn >= grossNeeded) {
            feeQuote  = (grossNeeded * CURVE_FEE_BPS) / BPS_DENOM;
            tokensOut = poolTokens;
        } else {
            feeQuote         = (quoteIn * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
            uint256 netQuote = quoteIn - feeQuote;
            tokensOut = poolTokens - ((k + poolQuote + netQuote - 1) / (poolQuote + netQuote));
        }
    }

    function previewSell(
        uint256 raisedQuote, uint256 virtualQuote, uint256 bcTokensTotal, uint256 bcTokensSold,
        uint256 k, uint256 tokensIn
    ) external pure returns (uint256 quoteOut, uint256 feeQuote) {
        uint256 poolQuote    = virtualQuote + raisedQuote;
        uint256 poolToks     = bcTokensTotal - bcTokensSold;
        uint256 newPoolToks  = poolToks + tokensIn;
        uint256 newPoolQuote = (k + newPoolToks - 1) / newPoolToks;
        uint256 grossQuote   = poolQuote > newPoolQuote ? poolQuote - newPoolQuote : 0;
        if (grossQuote > raisedQuote) return (0, 0);
        feeQuote = (grossQuote * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
        quoteOut = grossQuote - feeQuote;
    }

    function predictTokenAddress(address creator_, bytes32 userSalt_, address impl_, address deployer)
        external view returns (address predicted)
    {
        bytes32 salt = keccak256(abi.encode(creator_, userSalt_));
        bytes32 initcodeHash;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,         0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl_))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            initcodeHash := keccak256(ptr, 0x37)
        }
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            initcodeHash
        )))));
    }

    function rescueETH(uint256 totalRaisedETH, uint256 totalAccruedFeeETH, address to)
        external returns (uint256 amount)
    {
        uint256 reserved = totalRaisedETH + totalAccruedFeeETH;
        if (address(this).balance <= reserved) revert ZeroAmount();
        amount = address(this).balance - reserved;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function rescueToken(
        TokenConfig storage tc, address token_, address to, uint256 reservedRaised, uint256 reservedAccrued
    ) external returns (uint256 rescuable) {
        if (tc.token != address(0) && !tc.migrated) revert ActivePool();
        uint256 bal      = IERC20TransferBuy(token_).balanceOf(address(this));
        uint256 reserved = reservedRaised + reservedAccrued;
        if (bal <= reserved) revert ZeroAmount();
        rescuable = bal - reserved;
        if (!IERC20TransferBuy(token_).transfer(to, rescuable)) revert TransferFailed();
    }

    function setFeeSplits(
        FeeSplit[] storage feeSplits, address caller, address tcCreator, FeeSplit[] calldata splits_,
        uint256 maxFeeSplits
    ) external {
        if (tcCreator != caller) revert NotCreator();
        if (splits_.length > maxFeeSplits) revert TooManyFeeSplits();

        uint256 totalBps;
        for (uint256 i; i < splits_.length; ++i) {
            if (splits_[i].wallet == address(0)) revert ZeroAddress();
            totalBps += splits_[i].bps;
        }
        if (splits_.length > 0 && totalBps != BPS_DENOM) revert InvalidFeeSplitBps();

        while (feeSplits.length > 0) feeSplits.pop();
        for (uint256 i; i < splits_.length; ++i) {
            feeSplits.push(splits_[i]);
        }
    }

    function payCreator(
        FeeSplit[] storage splits, address creator_, address quoteToken_, uint256 amount
    ) external {
        if (splits.length == 0) {
            _payQuote(quoteToken_, creator_, amount);
            return;
        }
        uint256 len = splits.length;
        uint256 remaining = amount;
        for (uint256 i; i < len; ++i) {
            uint256 cut = i == len - 1 ? remaining : (amount * splits[i].bps) / BPS_DENOM;
            remaining -= cut;
            _payQuote(quoteToken_, splits[i].wallet, cut);
        }
    }

    function _payQuote(address quoteToken_, address to, uint256 amount) private {
        if (amount == 0) return;
        if (quoteToken_ == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            if (!IERC20TransferBuy(quoteToken_).transfer(to, amount)) revert TransferFailed();
        }
    }
}
