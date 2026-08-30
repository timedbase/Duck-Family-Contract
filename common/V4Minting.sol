// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — V4Minting

import {PoolKey} from "./LaunchRouting.sol";
import {V4Math} from "./V4Math.sol";

interface IV4PositionManagerMint {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

interface IAllowanceTransferMint {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IDuckHookV4Mint {
    function registerPool(PoolKey calldata key, address token, address creator, uint256 hookFeeBps) external;
}

interface IERC20Mint {
    function approve(address spender, uint256 amount) external returns (bool);
}

library V4Minting {
    error PoolAlreadyExists();
    error ApprovalFailed();

    uint256 private constant ACTION_MINT_POSITION = 0x02;
    uint256 private constant ACTION_SETTLE_PAIR   = 0x0d;
    int24   private constant MIN_TICK = -887_200;
    int24   private constant MAX_TICK =  887_200;

    struct MintParams {
        address positionManager;
        address permit2;
        address hook;
        address token;      // the launched project token -- passed through to hook.registerPool
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        address recipient;  // gets the minted LP NFT (always the shared locker)
        address creator;
        uint256 hookFeeBps;
        uint24  fee;
        int24   tickSpacing;
    }

    // Full-range, two-sided mint: initializes the pool (permissionless --
    // reverts PoolAlreadyExists if someone already did), registers it with
    // the hook, and mints the position directly to `recipient` via Permit2.
    function initAndMintFullRange(MintParams memory p) external returns (bytes32 poolId, uint256 tokenId) {
        PoolKey memory key = PoolKey({
            currency0:   p.token0,
            currency1:   p.token1,
            fee:         p.fee,
            tickSpacing: p.tickSpacing,
            hooks:       p.hook
        });

        int24 tick = IV4PositionManagerMint(p.positionManager).initializePool(
            key, V4Math.sqrtPriceX96FromAmounts(p.amount0, p.amount1)
        );
        if (tick == type(int24).max) revert PoolAlreadyExists();
        poolId = keccak256(abi.encode(key));
        IDuckHookV4Mint(p.hook).registerPool(key, p.token, p.creator, p.hookFeeBps);

        uint128 liquidity = V4Math.getLiquidityForAmounts(
            V4Math.getSqrtPriceAtTick(tick), V4Math.getSqrtPriceAtTick(MIN_TICK), V4Math.getSqrtPriceAtTick(MAX_TICK),
            p.amount0, p.amount1
        );

        _safeApprove(p.token0, p.permit2, p.amount0);
        _safeApprove(p.token1, p.permit2, p.amount1);
        IAllowanceTransferMint(p.permit2).approve(p.token0, p.positionManager, uint160(p.amount0), uint48(block.timestamp + 300));
        IAllowanceTransferMint(p.permit2).approve(p.token1, p.positionManager, uint160(p.amount1), uint48(block.timestamp + 300));

        bytes memory actions = abi.encodePacked(uint8(ACTION_MINT_POSITION), uint8(ACTION_SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, MIN_TICK, MAX_TICK, uint256(liquidity), uint128(p.amount0), uint128(p.amount1), p.recipient, bytes(""));
        params[1] = abi.encode(p.token0, p.token1);

        tokenId = IV4PositionManagerMint(p.positionManager).nextTokenId();
        IV4PositionManagerMint(p.positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    // Same reset-then-approve safety pattern as LaunchRouting._safeApprove
    // (some ERC20s require dropping an existing allowance to zero before
    // setting a new nonzero one).
    function _safeApprove(address token_, address spender, uint256 amount) private {
        (bool reset,) = token_.call(abi.encodeWithSelector(IERC20Mint.approve.selector, spender, 0));
        reset;
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(IERC20Mint.approve.selector, spender, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert ApprovalFailed();
    }
}
