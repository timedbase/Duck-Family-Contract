// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Unit test for DuckHookV4.sol -- the hook's own logic (registration,
// sell-fee accrual, fee-split routing, and the CTO flow) is entirely
// self-contained and doesn't need a real V4 PoolManager: every call that
// would normally originate from the PoolManager is simulated via vm.prank
// against a plain address standing in for it. No fork needed.

import {Test} from "forge-std/Test.sol";
import {DuckHookV4} from "duck-launcher-contracts/DuckHookV4.sol";
import {PoolKey, SwapParams} from "common-contracts/LaunchRouting.sol";

// afterSwap calls IPoolManagerMinimal(msg.sender).take(...) -- Solidity's
// external-call codegen reverts on a call to an address with no code (not a
// silent no-op the way a raw low-level .call would be), so poolManager must
// be a real (if trivial) contract, not just a bare address.
contract MockPoolManager {
    function take(address, address, uint256) external {}
}

contract DuckHookV4Test is Test {
    DuckHookV4 hook;

    address poolManager    = address(new MockPoolManager());
    address owner          = makeAddr("owner");
    address launcher       = makeAddr("launcher");
    address creator        = makeAddr("creator");
    address platformWallet = makeAddr("platformWallet");

    PoolKey key;
    bytes32 poolId;

    function setUp() public {
        vm.prank(owner);
        hook = new DuckHookV4(poolManager);

        vm.prank(owner);
        hook.addLauncher(launcher);

        key = PoolKey({
            currency0:   address(0xAAA1), // stand-in project token
            currency1:   address(0),      // native quote
            fee:         10_000,
            tickSpacing: 200,
            hooks:       address(hook)
        });
        poolId = keccak256(abi.encode(key));

        vm.prank(launcher);
        hook.registerPool(key, key.currency0, creator, 0);

        vm.prank(owner);
        hook.setPlatformWallet(platformWallet);
    }

    // ── Registration ─────────────────────────────────────────────────────────

    function test_RegisterPoolAppliesDefaultFee() public view {
        (,,,,, bool registered, uint256 hookFeeBps) = hook.pools(poolId);
        assertTrue(registered);
        assertEq(hookFeeBps, 200);
    }

    function test_RegisterPoolOnlyLauncher() public {
        vm.expectRevert(DuckHookV4.NotLauncher.selector);
        hook.registerPool(key, key.currency0, creator, 0);
    }

    function test_RegisterPoolRevertsIfAlreadyRegistered() public {
        vm.prank(launcher);
        vm.expectRevert(DuckHookV4.AlreadyRegistered.selector);
        hook.registerPool(key, key.currency0, creator, 0);
    }

    function test_RegisterPoolRevertsOnInvalidHookFeeBps() public {
        PoolKey memory otherKey = key;
        otherKey.currency0 = address(0xAAA2);
        vm.prank(launcher);
        vm.expectRevert(DuckHookV4.InvalidHookFeeBps.selector);
        hook.registerPool(otherKey, otherKey.currency0, creator, 999);
    }

    // ── Anti-MEV (permanent, no expiry) ──────────────────────────────────────

    function test_BeforeSwapBlocksSameBlockRepeat() public {
        address bot = makeAddr("bot");
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(poolManager);
        hook.beforeSwap(bot, key, params, "");

        vm.prank(poolManager);
        vm.expectRevert(DuckHookV4.SameBlockSwap.selector);
        hook.beforeSwap(bot, key, params, "");
    }

    function test_BeforeSwapAllowsDifferentBlocks() public {
        address trader = makeAddr("trader");
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(poolManager);
        hook.beforeSwap(trader, key, params, "");

        vm.roll(block.number + 1);
        vm.prank(poolManager);
        hook.beforeSwap(trader, key, params, ""); // should not revert
    }

    function test_BeforeSwapStillBlocksLongAfterLaunch() public {
        // No expiry: the guard is just as active a year after registration.
        address trader = makeAddr("trader");
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.warp(block.timestamp + 365 days);

        vm.prank(poolManager);
        hook.beforeSwap(trader, key, params, "");

        vm.prank(poolManager);
        vm.expectRevert(DuckHookV4.SameBlockSwap.selector);
        hook.beforeSwap(trader, key, params, "");
    }

    // ── Sell-fee accrual + claim ─────────────────────────────────────────────

    // BalanceDelta packs (amount0 << 128 | amount1), each a raw int128 bit
    // pattern -- afterSwap recovers them via int128(delta >> 128) and
    // int128(delta), truncating casts that just take 128 bits and reinterpret
    // them as signed, so zero-extending each half into its own 128-bit slot
    // here reproduces exactly what a real BalanceDelta looks like.
    function _packDelta(int128 amount0, int128 amount1) internal pure returns (int256 delta) {
        uint256 hi = uint256(uint128(amount0)) << 128;
        uint256 lo = uint256(uint128(amount1));
        delta = int256(hi | lo);
    }

    function test_AfterSwapAccruesFeeOnExactInputSell() public {
        // token (currency0) leaves the trader (-100e18), quote (currency1) comes in (+10e18).
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0});
        int256 delta = _packDelta(-100e18, 10e18);

        vm.prank(poolManager);
        hook.afterSwap(address(this), key, params, delta, "");

        uint256 expectedFee = uint256(10e18) * 200 / 10_000; // 2% default
        assertEq(hook.accruedFees(poolId), expectedFee);
    }

    // A sell specified as exact-output (trader asks for an exact quote
    // amount out, letting the token input float) must still be fee'd --
    // only the resulting balance deltas identify a sell, not which side the
    // swapper specified as exact. Same deltas as the exact-input case
    // above, just a positive amountSpecified.
    function test_AfterSwapAccruesFeeOnExactOutputSell() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 10e18, sqrtPriceLimitX96: 0});
        int256 delta = _packDelta(-100e18, 10e18);

        vm.prank(poolManager);
        hook.afterSwap(address(this), key, params, delta, "");

        uint256 expectedFee = uint256(10e18) * 200 / 10_000; // 2% default
        assertEq(hook.accruedFees(poolId), expectedFee);
    }

    function test_AfterSwapSkipsBuys() public {
        // Buy: token comes in (+), quote leaves (-) -- not an exact-input sell.
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -10e18, sqrtPriceLimitX96: 0});
        int256 delta = _packDelta(100e18, -10e18);

        vm.prank(poolManager);
        hook.afterSwap(address(this), key, params, delta, "");

        assertEq(hook.accruedFees(poolId), 0);
    }

    function test_ClaimFeesPaysCreatorInFull() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0});
        int256 delta = _packDelta(-100e18, 10e18);
        vm.prank(poolManager);
        hook.afterSwap(address(this), key, params, delta, "");

        uint256 accrued = hook.accruedFees(poolId);
        assertGt(accrued, 0);
        // In a real pool, PoolManager.take() would have delivered this to the hook.
        vm.deal(address(hook), accrued);

        uint256 before = creator.balance;
        hook.claimFees(poolId);
        assertEq(creator.balance, before + accrued);
        assertEq(hook.accruedFees(poolId), 0);
    }

    // ── Creator fee splits ───────────────────────────────────────────────────

    function test_SetFeeSplitsOnlyCreator() public {
        DuckHookV4.FeeSplit[] memory splits = new DuckHookV4.FeeSplit[](1);
        splits[0] = DuckHookV4.FeeSplit({wallet: makeAddr("w1"), bps: 10_000});

        vm.expectRevert(DuckHookV4.NotCreator.selector);
        hook.setFeeSplits(poolId, splits);
    }

    function test_SetFeeSplitsRevertsOnBadBpsSum() public {
        DuckHookV4.FeeSplit[] memory splits = new DuckHookV4.FeeSplit[](2);
        splits[0] = DuckHookV4.FeeSplit({wallet: makeAddr("w1"), bps: 5_000});
        splits[1] = DuckHookV4.FeeSplit({wallet: makeAddr("w2"), bps: 4_000});

        vm.prank(creator);
        vm.expectRevert(DuckHookV4.InvalidFeeSplitBps.selector);
        hook.setFeeSplits(poolId, splits);
    }

    function test_SetFeeSplitsRevertsOnTooMany() public {
        DuckHookV4.FeeSplit[] memory splits = new DuckHookV4.FeeSplit[](6);
        uint16 evenShare = uint16(uint256(10_000) / 6);
        for (uint256 i; i < 6; ++i) {
            splits[i] = DuckHookV4.FeeSplit({wallet: makeAddr(string(abi.encodePacked("w", i))), bps: evenShare});
        }

        vm.prank(creator);
        vm.expectRevert(DuckHookV4.TooManyFeeSplits.selector);
        hook.setFeeSplits(poolId, splits);
    }

    function test_ClaimFeesRoutesThroughSplit() public {
        address walletA = makeAddr("splitA");
        address walletB = makeAddr("splitB");
        DuckHookV4.FeeSplit[] memory splits = new DuckHookV4.FeeSplit[](2);
        splits[0] = DuckHookV4.FeeSplit({wallet: walletA, bps: 4_000});
        splits[1] = DuckHookV4.FeeSplit({wallet: walletB, bps: 6_000});

        vm.prank(creator);
        hook.setFeeSplits(poolId, splits);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0});
        int256 delta = _packDelta(-100e18, 10e18);
        vm.prank(poolManager);
        hook.afterSwap(address(this), key, params, delta, "");

        uint256 accrued = hook.accruedFees(poolId);
        vm.deal(address(hook), accrued);

        hook.claimFees(poolId);
        assertEq(walletA.balance, accrued * 4_000 / 10_000);
        assertEq(walletB.balance, accrued - (accrued * 4_000 / 10_000));
    }

    // ── CTO ───────────────────────────────────────────────────────────────────

    function test_CTOApplyApproveFlow() public {
        address applicant = makeAddr("applicant");
        address newCreator = makeAddr("newCreator");
        vm.deal(applicant, 1 ether);

        uint256 fee = hook.ctoFee();
        vm.prank(applicant);
        hook.applyForCTO{value: fee}(poolId, newCreator);
        assertEq(platformWallet.balance, fee);

        vm.prank(owner);
        hook.approveCTO(poolId);

        (,,, address currentCreator,,,) = hook.pools(poolId);
        assertEq(currentCreator, newCreator);
    }

    function test_CTORejectFlow() public {
        address applicant = makeAddr("applicant");
        address newCreator = makeAddr("newCreator");
        vm.deal(applicant, 1 ether);
        uint256 fee = hook.ctoFee();

        vm.prank(applicant);
        hook.applyForCTO{value: fee}(poolId, newCreator);

        vm.prank(owner);
        hook.rejectCTO(poolId);

        (,,, address currentCreator,,,) = hook.pools(poolId);
        assertEq(currentCreator, creator, "creator should be unchanged after rejection");
    }

    function test_CTOInsufficientFeeReverts() public {
        address applicant = makeAddr("applicant");
        vm.deal(applicant, 1 ether);
        uint256 fee = hook.ctoFee();
        vm.prank(applicant);
        vm.expectRevert(DuckHookV4.InsufficientCTOFee.selector);
        hook.applyForCTO{value: fee - 1}(poolId, makeAddr("newCreator"));
    }

    function test_CTOSecondApplicationBlockedWhilePending() public {
        address applicant1 = makeAddr("applicant1");
        address applicant2 = makeAddr("applicant2");
        vm.deal(applicant1, 1 ether);
        vm.deal(applicant2, 1 ether);
        uint256 fee = hook.ctoFee();

        vm.prank(applicant1);
        hook.applyForCTO{value: fee}(poolId, makeAddr("newCreator1"));

        vm.prank(applicant2);
        vm.expectRevert(DuckHookV4.CTOApplicationPending.selector);
        hook.applyForCTO{value: fee}(poolId, makeAddr("newCreator2"));
    }

    function test_ApplyForCTORequiresPlatformWalletSet() public {
        DuckHookV4 freshHook;
        vm.prank(owner);
        freshHook = new DuckHookV4(poolManager);
        vm.prank(owner);
        freshHook.addLauncher(launcher);
        vm.prank(launcher);
        freshHook.registerPool(key, key.currency0, creator, 0);

        address applicant = makeAddr("applicant");
        vm.deal(applicant, 1 ether);
        uint256 fee = freshHook.ctoFee();
        vm.prank(applicant);
        vm.expectRevert(DuckHookV4.ZeroAddress.selector);
        freshHook.applyForCTO{value: fee}(poolId, makeAddr("newCreator"));
    }
}
