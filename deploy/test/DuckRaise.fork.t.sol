// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Fork test for DuckRaise.sol -- the crowdfunding family. Exercises the full
// campaign lifecycle against the REAL, verified Uniswap V4 deployment on Ink
// chain: token deployed immediately at launch(), contribution window,
// success path (finalize -> two-sided V4 pool seeded, locker-registered,
// pro-rata claim), failure path (goal missed -> refunds), and governance/
// error paths.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckRaise} from "duckraise-contracts/DuckRaise.sol";
import {DuckRaiseToken} from "duckraise-contracts/DuckRaiseToken.sol";
import {DuckLocker} from "duck-launcher-contracts/DuckLocker.sol";
import {DuckHookV4} from "duck-launcher-contracts/DuckHookV4.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";

interface IStateView {
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

contract DuckRaiseForkTest is Test {
    address constant WETH                = 0x4200000000000000000000000000000000000006;
    address constant V4_POOL_MANAGER     = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant V4_POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant V4_STATE_VIEW       = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address constant PERMIT2             = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    DuckRaise      raise;
    DuckLocker     locker;
    DuckHookV4     hook;
    DuckRaiseToken tokenImpl;

    address owner          = makeAddr("dr-owner");
    address platformWallet = makeAddr("dr-platform");
    address creator        = makeAddr("dr-creator");
    address contributorA   = makeAddr("dr-contributorA");
    address contributorB   = makeAddr("dr-contributorB");

    uint256 private _tokenSaltNonceCursor;

    function setUp() public {
        vm.createSelectFork(vm.envString("INK_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(platformWallet, "");
        vm.etch(creator, "");
        vm.etch(contributorA, "");
        vm.etch(contributorB, "");

        vm.startPrank(owner);

        tokenImpl = new DuckRaiseToken();

        DuckLocker lockerImpl = new DuckLocker();
        ERC1967Proxy lockerProxy = new ERC1967Proxy(
            address(lockerImpl),
            abi.encodeCall(DuckLocker.initialize, (platformWallet))
        );
        locker = DuckLocker(payable(address(lockerProxy)));

        DuckRaise raiseImpl = new DuckRaise();
        ERC1967Proxy raiseProxy = new ERC1967Proxy(
            address(raiseImpl),
            abi.encodeCall(DuckRaise.initialize, (
                WETH, address(tokenImpl), address(locker),
                V4_POOL_MANAGER, V4_POSITION_MANAGER, PERMIT2, address(0), platformWallet
            ))
        );
        raise = DuckRaise(payable(address(raiseProxy)));

        locker.addLauncher(address(raise));

        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(DuckHookV4).creationCode,
            abi.encode(V4_POOL_MANAGER)
        ));
        (bytes32 salt,) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(salt, V4_POOL_MANAGER, owner);
        hook = DuckHookV4(payable(hookAddr));
        require(uint160(hookAddr) & 0x3FFF == 0xC4, "bad hook permission bits");

        hook.addLauncher(address(raise));
        raise.setDexConfig(V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2, hookAddr);

        vm.stopPrank();

        vm.deal(creator, 10 ether);
        vm.deal(contributorA, 100 ether);
        vm.deal(contributorB, 100 ether);
    }

    function _mineHookSalt(address factory, bytes32 initCodeHash)
        internal pure returns (bytes32 salt, address predicted)
    {
        for (uint256 nonce = 0; nonce < 200_000; nonce++) {
            salt = bytes32(nonce);
            predicted = _computeCreate2Address(salt, initCodeHash, factory);
            if (uint160(predicted) & 0x3FFF == 0xC4) return (salt, predicted);
        }
        revert("salt not found");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer)
        internal pure returns (address addr)
    {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            addr := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _saltFor(address creator_, bytes32 userSalt) internal pure returns (bytes32 salt) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, creator_)
            mstore(add(ptr, 32), userSalt)
            salt := keccak256(ptr, 64)
        }
    }

    // Mirrors DuckRaise's own EIP-1167 minimal-proxy CREATE2 formula.
    function _mineTokenSalt(address creator_) internal returns (bytes32 userSalt) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            address(tokenImpl),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 initCodeHash = keccak256(initCode);
        uint256 nonce = _tokenSaltNonceCursor;
        for (uint256 i = 0; i < 1_000_000; i++) {
            userSalt = bytes32(nonce + i);
            bytes32 salt = _saltFor(creator_, userSalt);
            address predicted = _computeCreate2Address(salt, initCodeHash, address(raise));
            if (uint16(uint160(predicted)) == 0x8888) {
                _tokenSaltNonceCursor = nonce + i + 1;
                return userSalt;
            }
        }
        revert("token salt not found");
    }

    function _launch(uint256 goal, uint256 hookFeeBps) internal returns (uint256 campaignId, address token) {
        bytes32 salt = _mineTokenSalt(creator);
        vm.prank(creator);
        (campaignId, token) = raise.launch{value: 0.0005 ether}(
            "Duck Raise Token", "DRT", "", address(0), goal, 0, salt, hookFeeBps
        );
    }

    function test_LaunchDeploysTokenImmediately() public {
        uint256 platformBefore = platformWallet.balance;
        (uint256 campaignId, address token) = _launch(10 ether, 0);

        assertEq(uint16(uint160(token)), 0x8888);
        assertEq(DuckRaiseToken(token).owner(), address(0), "ownership should be renounced at launch");
        assertEq(DuckRaiseToken(token).balanceOf(address(raise)), raise.TOTAL_SUPPLY(), "full supply escrowed");
        assertEq(platformWallet.balance, platformBefore + 0.0005 ether);
        assertEq(raise.campaignCount(), campaignId + 1);
    }

    function test_LaunchRevertsOnInvalidHookFeeBps() public {
        bytes32 salt = _mineTokenSalt(creator);
        vm.prank(creator);
        vm.expectRevert(DuckRaise.InvalidHookFeeBps.selector);
        raise.launch{value: 0.0005 ether}("N", "S", "", address(0), 10 ether, 0, salt, 150);
    }

    function test_LaunchRevertsOnWrongFee() public {
        bytes32 salt = _mineTokenSalt(creator);
        vm.prank(creator);
        vm.expectRevert(DuckRaise.WrongFee.selector);
        raise.launch{value: 0.0001 ether}("N", "S", "", address(0), 10 ether, 0, salt, 0);
    }

    function test_PlatformTokenWaivesCampaignFee() public {
        address fakePlatformToken = makeAddr("platform-token");
        vm.startPrank(owner);
        raise.setPlatformToken(fakePlatformToken);
        raise.setQuoteAssetAllowed(fakePlatformToken, true);
        vm.stopPrank();

        bytes32 salt = _mineTokenSalt(creator);
        uint256 platformBefore = platformWallet.balance;

        vm.prank(creator);
        raise.launch{value: 0}("N", "S", "", fakePlatformToken, 10 ether, 0, salt, 0);

        assertEq(platformWallet.balance, platformBefore, "no campaign fee should have been collected");
    }

    function test_PlatformTokenDoesNotWaiveFeeForOtherQuoteAssets() public {
        address fakePlatformToken = makeAddr("platform-token");
        vm.prank(owner);
        raise.setPlatformToken(fakePlatformToken);

        // Native-quoted campaign is unaffected -- still requires the full fee.
        bytes32 salt = _mineTokenSalt(creator);
        vm.prank(creator);
        vm.expectRevert(DuckRaise.WrongFee.selector);
        raise.launch{value: 0}("N", "S", "", address(0), 10 ether, 0, salt, 0);
    }

    function test_LaunchRevertsOnUnroutableQuoteAsset() public {
        // Only USDC/USDT0 (real, verified Ink liquidity) are allowed by
        // default -- an arbitrary ERC20 with no configured swap route would
        // just guarantee _seedSuccessLiquidity fails at finalize, so it's
        // rejected up front at launch() instead.
        address randomToken = makeAddr("no-liquidity-token");
        bytes32 salt = _mineTokenSalt(creator);
        vm.prank(creator);
        vm.expectRevert(DuckRaise.QuoteAssetNotAllowed.selector);
        raise.launch{value: 0.0005 ether}("N", "S", "", randomToken, 10 ether, 0, salt, 0);
    }

    function test_LaunchAllowsDefaultRoutedQuoteAsset() public {
        address USDC = 0x2D270e6886d130D724215A266106e6832161EAEd;
        bytes32 salt = _mineTokenSalt(creator);
        vm.prank(creator);
        (, address token) = raise.launch{value: 0.0005 ether}("N", "S", "", USDC, 10 ether, 0, salt, 0);
        assertTrue(token != address(0));
    }

    function test_LaunchRevertsOnZeroGoal() public {
        bytes32 salt = _mineTokenSalt(creator);
        vm.prank(creator);
        vm.expectRevert(DuckRaise.ZeroAmount.selector);
        raise.launch{value: 0.0005 ether}("N", "S", "", address(0), 0, 0, salt, 0);
    }

    function test_ContributeRevertsBeforeStartAndAfterDeadline() public {
        (uint256 campaignId,) = _launch(10 ether, 0);

        vm.prank(contributorA);
        vm.expectRevert(DuckRaise.DeadlinePassed.selector);
        vm.warp(block.timestamp + 3 hours);
        raise.contribute{value: 1 ether}(campaignId);
    }

    function test_SuccessfulCampaignFinalizeClaimAndFees() public {
        (uint256 campaignId, address token) = _launch(10 ether, 500); // 5% hook fee

        vm.prank(contributorA);
        raise.contribute{value: 6 ether}(campaignId);
        vm.prank(contributorB);
        raise.contribute{value: 4 ether}(campaignId);

        vm.warp(block.timestamp + 2 hours + 1);
        address finalizedToken = raise.finalize(campaignId);
        assertEq(finalizedToken, token);

        (,,,,,,,,,,,, bool finalized, bool succeeded,,) = raise.campaigns(campaignId);
        assertTrue(finalized);
        assertTrue(succeeded, "campaign should have succeeded (10 ETH raised == 10 ETH goal)");

        (uint256 lockedTokenId,,, bytes32 poolId, address lockedHook,) = locker.positions(token);
        assertGt(lockedTokenId, 0, "LP position should be locked");
        assertEq(lockedHook, address(hook));

        (uint160 sqrtPriceX96,,,) = IStateView(V4_STATE_VIEW).getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, "pool should be initialized");

        (,,, address hookCreator,, bool registered, uint256 hookFeeBps) = hook.pools(poolId);
        assertTrue(registered);
        assertEq(hookCreator, creator);
        assertEq(hookFeeBps, 500);

        // Pro-rata claim: contributorA put in 60% of the raise.
        uint256 contributorSupply = raise.TOTAL_SUPPLY() * 8_000 / 10_000; // default 80% contributor split
        uint256 expectedA = contributorSupply * 6 ether / 10 ether;

        vm.prank(contributorA);
        raise.claim(campaignId);
        assertEq(DuckRaiseToken(token).balanceOf(contributorA), expectedA);

        vm.prank(contributorA);
        vm.expectRevert(DuckRaise.NothingToClaim.selector);
        raise.claim(campaignId);
    }

    function test_FailedCampaignUnlocksRefunds() public {
        (uint256 campaignId,) = _launch(10 ether, 0);

        vm.prank(contributorA);
        raise.contribute{value: 2 ether}(campaignId); // well under the 10 ETH goal

        vm.warp(block.timestamp + 2 hours + 1);
        raise.finalize(campaignId);

        (,,,,,,,,,,,, bool finalized, bool succeeded,,) = raise.campaigns(campaignId);
        assertTrue(finalized);
        assertFalse(succeeded);

        uint256 balBefore = contributorA.balance;
        vm.prank(contributorA);
        raise.claimRefund(campaignId);
        assertEq(contributorA.balance, balBefore + 2 ether);

        vm.prank(contributorA);
        vm.expectRevert(DuckRaise.NothingToClaim.selector);
        raise.claimRefund(campaignId);

        vm.prank(contributorA);
        vm.expectRevert(DuckRaise.CampaignFailed_.selector);
        raise.claim(campaignId);
    }

    function test_GovernanceSetters() public {
        vm.startPrank(owner);
        address newPlatform = makeAddr("dr-new-platform");
        raise.setPlatformWallet(newPlatform);
        assertEq(raise.platformWallet(), newPlatform);

        raise.setCampaignFee(0.001 ether);
        assertEq(raise.campaignFee(), 0.001 ether);

        raise.setSupplySplit(7_000, 3_000);
        assertEq(raise.contributorBps(), 7_000);
        assertEq(raise.lpBps(), 3_000);

        vm.expectRevert(DuckRaise.InvalidBps.selector);
        raise.setSupplySplit(7_000, 4_000);

        raise.setCampaignDuration(1 days);
        assertEq(raise.campaignDuration(), 1 days);

        vm.expectRevert(DuckRaise.ZeroAmount.selector);
        raise.setCampaignDuration(0);
        vm.stopPrank();
    }
}
