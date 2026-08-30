// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Fork test for DuckLauncher.sol -- the instant-launch family. Exercises the
// full launch lifecycle against the REAL, verified Uniswap V4 deployment on
// Ink chain: token deployment (vanity address), one-sided V4 pool seeding,
// locker registration, the optional same-tx instant buy (real V4
// unlock/swap/settle/take via LaunchRouting), creator-chosen hook fee tier,
// and governance/error paths.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckLauncher} from "duck-launcher-contracts/DuckLauncherUpgradeable.sol";
import {DuckLauncherToken} from "duck-launcher-contracts/DuckLauncherToken.sol";
import {DuckLocker} from "duck-launcher-contracts/DuckLocker.sol";
import {DuckHookV4} from "duck-launcher-contracts/DuckHookV4.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";

interface IStateView {
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

contract DuckLauncherForkTest is Test {
    address constant WETH                = 0x4200000000000000000000000000000000000006;
    address constant V4_POOL_MANAGER     = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant V4_POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant V4_STATE_VIEW       = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address constant PERMIT2             = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    DuckLauncher       launcher;
    DuckLocker         locker;
    DuckHookV4         hook;
    DuckLauncherToken  tokenImpl;

    address owner        = makeAddr("dl-owner");
    address platformWallet = makeAddr("dl-platform");
    address creator      = makeAddr("dl-creator");

    uint256 private _tokenSaltNonceCursor;

    function setUp() public {
        vm.createSelectFork(vm.envString("INK_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(platformWallet, "");
        vm.etch(creator, "");

        vm.startPrank(owner);

        tokenImpl = new DuckLauncherToken();

        DuckLocker lockerImpl = new DuckLocker();
        ERC1967Proxy lockerProxy = new ERC1967Proxy(
            address(lockerImpl),
            abi.encodeCall(DuckLocker.initialize, (platformWallet))
        );
        locker = DuckLocker(payable(address(lockerProxy)));

        DuckLauncher launcherImpl = new DuckLauncher();
        ERC1967Proxy launcherProxy = new ERC1967Proxy(
            address(launcherImpl),
            abi.encodeCall(DuckLauncher.initialize, (
                WETH, address(tokenImpl), address(locker), platformWallet,
                V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2, address(0)
            ))
        );
        launcher = DuckLauncher(payable(address(launcherProxy)));

        locker.addLauncher(address(launcher));

        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(DuckHookV4).creationCode,
            abi.encode(V4_POOL_MANAGER)
        ));
        (bytes32 salt,) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(salt, V4_POOL_MANAGER, owner);
        hook = DuckHookV4(payable(hookAddr));
        require(uint160(hookAddr) & 0x3FFF == 0xC4, "bad hook permission bits");

        hook.addLauncher(address(launcher));
        launcher.addDex(V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2, hookAddr);

        vm.stopPrank();

        vm.deal(creator, 1_000 ether);
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

    // Mirrors DuckLauncher's own EIP-1167 minimal-proxy CREATE2 formula.
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
            address predicted = _computeCreate2Address(salt, initCodeHash, address(launcher));
            if (uint16(uint160(predicted)) == 0x8888) {
                _tokenSaltNonceCursor = nonce + i + 1;
                return userSalt;
            }
        }
        revert("token salt not found");
    }

    function _baseLaunchParams(bytes32 salt) internal pure returns (DuckLauncher.LaunchParams memory p) {
        p.name             = "Duck Token";
        p.symbol           = "DUCK";
        p.metaURI          = "";
        p.feeWallet        = address(0); // msg.sender is the creator
        p.positionManager  = V4_POSITION_MANAGER;
        p.quoteToken       = address(0); // native
        p.vanitySalt       = salt;
        p.launchMarketCap  = 5 ether; // creator-chosen virtual FDV, in native wei
        p.minQuoteOut      = 0;
        p.minTokensOut     = 0;
        p.hookFeeBps       = 0; // default 2%
        p.revertOnInstantBuyFailure = false;
    }

    function test_LaunchNoInstantBuy() public {
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);

        uint256 platformBefore = platformWallet.balance;

        vm.prank(creator);
        (address token, bytes32 poolId, uint256 tokenId) = launcher.launch{value: 0.0005 ether}(p);

        assertEq(uint16(uint160(token)), 0x8888);
        assertEq(platformWallet.balance, platformBefore + 0.0005 ether);

        (uint160 sqrtPriceX96,,,) = IStateView(V4_STATE_VIEW).getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, "pool should be initialized");

        (uint256 lockedTokenId,,,,,) = locker.positions(token);
        assertEq(lockedTokenId, tokenId);

        assertEq(DuckLauncherToken(token).owner(), address(0), "ownership should be renounced");

        (,,, address hookCreator,, bool registered, uint256 hookFeeBps) = hook.pools(poolId);
        assertTrue(registered);
        assertEq(hookCreator, creator);
        assertEq(hookFeeBps, 200); // default
    }

    function test_LaunchWithInstantBuy() public {
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);

        vm.prank(creator);
        (address token,,) = launcher.launch{value: 0.0005 ether + 1 ether}(p);

        assertGt(DuckLauncherToken(token).balanceOf(creator), 0, "instant buy should have landed tokens on the creator");
    }

    // Proves the ERC20-quoted instant-buy path (extraEth -> _acquireQuoteToken
    // -> quote asset -> _executeV4Swap into the freshly launched pool)
    // against genuine live liquidity on Ink, now that DuckLauncher seeds
    // real routes for USDC/USDT0 (see _seedDefaultRoutes) the same way
    // DuckIncubation/DuckRaise do.
    function test_LaunchWithInstantBuyUsesRealSeededLiquidity() public {
        address USDC = 0x2D270e6886d130D724215A266106e6832161EAEd;
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);
        p.quoteToken      = USDC;
        p.launchMarketCap = 10_000e6; // creator-chosen virtual FDV, in USDC's own 6-decimal units

        vm.prank(creator);
        (address token,,) = launcher.launch{value: 0.0005 ether + 0.05 ether}(p);

        assertGt(
            DuckLauncherToken(token).balanceOf(creator), 0,
            "instant buy should have routed ETH -> real USDC -> launched token and landed on the creator"
        );
    }

    function test_LaunchRevertsForUnroutedQuoteTokenInstantBuy() public {
        // LINK is whitelisted for direct trading (see _seedDefaultQuoteTokens)
        // but has no real liquidity anywhere on Ink, so no route is seeded
        // for it -- an instant-buy attempt should skip (not revert the whole
        // launch) when revertOnInstantBuyFailure is false.
        address LINK = 0x71052BAe71C25C78E37fD12E5ff1101A71d9018F;
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);
        p.quoteToken      = LINK;
        p.launchMarketCap = 1_000e18;

        uint256 creatorBalBefore = creator.balance;

        vm.prank(creator);
        (address token,,) = launcher.launch{value: 0.0005 ether + 0.05 ether}(p);

        // Any nonzero balance here is just LP-minting dust swept to the creator
        // regardless of instant-buy outcome, not a real ~0.05 ETH buy's worth.
        assertLt(DuckLauncherToken(token).balanceOf(creator), 1e12, "instant buy should have been skipped, not force-succeeded");
        assertEq(creator.balance, creatorBalBefore - 0.0005 ether, "the unroutable extraEth should have been refunded");
    }

    function test_LaunchCreatorChosenHookFeeBps() public {
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);
        p.hookFeeBps = 300; // 3%

        vm.prank(creator);
        (, bytes32 poolId,) = launcher.launch{value: 0.0005 ether}(p);

        (,,,,,, uint256 hookFeeBps) = hook.pools(poolId);
        assertEq(hookFeeBps, 300);
    }

    function test_LaunchRevertsOnInvalidHookFeeBps() public {
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);
        p.hookFeeBps = 150;

        vm.prank(creator);
        vm.expectRevert(DuckLauncher.InvalidHookFeeBps.selector);
        launcher.launch{value: 0.0005 ether}(p);
    }

    function test_LaunchRevertsOnWrongFee() public {
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);

        vm.prank(creator);
        vm.expectRevert(DuckLauncher.WrongFee.selector);
        launcher.launch{value: 0.0001 ether}(p);
    }

    function test_LaunchRevertsOnUnsupportedDex() public {
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);
        p.positionManager = address(0xdead);

        vm.prank(creator);
        vm.expectRevert(DuckLauncher.UnsupportedDex.selector);
        launcher.launch{value: 0.0005 ether}(p);
    }

    function test_LaunchRevertsOnUnsupportedQuoteToken() public {
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);
        p.quoteToken = makeAddr("not-a-registered-quote-token");

        vm.prank(creator);
        vm.expectRevert(DuckLauncher.UnsupportedQuoteToken.selector);
        launcher.launch{value: 0.0005 ether}(p);
    }

    function test_PlatformTokenWaivesLaunchFee() public {
        address fakePlatformToken = makeAddr("platform-token");
        vm.startPrank(owner);
        launcher.addQuoteToken(fakePlatformToken);
        launcher.setPlatformToken(fakePlatformToken);
        vm.stopPrank();

        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);
        p.quoteToken = fakePlatformToken;

        uint256 platformBefore = platformWallet.balance;

        vm.prank(creator);
        launcher.launch{value: 0}(p); // no launchFee required

        assertEq(platformWallet.balance, platformBefore, "no launch fee should have been collected");
    }

    function test_PlatformTokenDoesNotWaiveFeeForOtherQuoteTokens() public {
        address fakePlatformToken = makeAddr("platform-token");
        vm.prank(owner);
        launcher.setPlatformToken(fakePlatformToken);

        // Native-quoted launch is unaffected -- still requires the full fee.
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);

        vm.prank(creator);
        vm.expectRevert(DuckLauncher.WrongFee.selector);
        launcher.launch{value: 0}(p);
    }

    function test_LaunchRevertsOnZeroLaunchMarketCap() public {
        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);
        p.launchMarketCap = 0;

        vm.prank(creator);
        vm.expectRevert(DuckLauncher.ZeroAmount.selector);
        launcher.launch{value: 0.0005 ether}(p);
    }

    function test_CreatorChosenLaunchMarketCapAffectsInitialPrice() public {
        bytes32 saltLow = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory pLow = _baseLaunchParams(saltLow);
        pLow.launchMarketCap = 1 ether;
        vm.prank(creator);
        (, bytes32 poolIdLow,) = launcher.launch{value: 0.0005 ether}(pLow);

        bytes32 saltHigh = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory pHigh = _baseLaunchParams(saltHigh);
        pHigh.launchMarketCap = 50 ether;
        vm.prank(creator);
        (, bytes32 poolIdHigh,) = launcher.launch{value: 0.0005 ether}(pHigh);

        (uint160 sqrtPriceLow,,,) = IStateView(V4_STATE_VIEW).getSlot0(poolIdLow);
        (uint160 sqrtPriceHigh,,,) = IStateView(V4_STATE_VIEW).getSlot0(poolIdHigh);
        assertTrue(sqrtPriceLow != sqrtPriceHigh, "different launch market caps should seed different initial prices");
    }

    function test_DefaultQuoteTokensEnabledAtDeploy() public view {
        address[15] memory defaults = [
            0x2D270e6886d130D724215A266106e6832161EAEd,
            0x71052BAe71C25C78E37fD12E5ff1101A71d9018F,
            0x0200C29006150606B650577BBE7B6248F58470c1,
            0xe343167631d89B6Ffc58B88d6b7fB0228795491D,
            0x142cdc44890978B506e745bB3Bd11607B7f7faEf,
            0xc3eACf0612346366Db554C991D7858716db09f58,
            0xF50258D3c1dd88946C567920B986A12e65b50dAc,
            0xc845b2894dBddd03858fd2D643B4eF725fE0849d,
            0xb63EFBc28860c8097e341DE1fCF59456161E9D98,
            0x53Ad50D3B6FCaCB8965d3A49cB722917C7DAE1F3,
            0x6F75AC3b1b6Fbe8Bb5F948e25aF03620f26Ae838,
            0xeFD30445A4ec1f4b3E0a6f4d9bDbd215F805047F,
            0xBca703C64f616A17b4f2763F34f93400Dbe20F17,
            0x7636244Bab612264e1B2dFd4bA6E26d0311b1Eb7,
            0x06A0138F8c3e5110fd98e34a4473Fb08F1304b87
        ];
        for (uint256 i; i < defaults.length; ++i) {
            assertTrue(launcher.quoteTokens(defaults[i]), "default quote token should be enabled at deploy");
        }
    }

    function test_AddQuoteTokenSimplifiedSignature() public {
        address newQuote = makeAddr("new-quote-token");
        assertFalse(launcher.quoteTokens(newQuote));

        vm.prank(owner);
        launcher.addQuoteToken(newQuote);
        assertTrue(launcher.quoteTokens(newQuote));

        vm.prank(owner);
        launcher.disableQuoteToken(newQuote);
        assertFalse(launcher.quoteTokens(newQuote));
    }

    function test_GovernanceSetters() public {
        vm.startPrank(owner);
        address newPlatform = makeAddr("dl-new-platform");
        launcher.setPlatformWallet(newPlatform);
        assertEq(launcher.platformWallet(), newPlatform);

        launcher.setLaunchFee(0.001 ether);
        assertEq(launcher.launchFee(), 0.001 ether);

        vm.expectRevert(DuckLauncher.ZeroAmount.selector);
        launcher.setLaunchFee(0);

        launcher.disableDex(V4_POSITION_MANAGER);
        vm.stopPrank();

        bytes32 salt = _mineTokenSalt(creator);
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(salt);
        vm.prank(creator);
        vm.expectRevert(DuckLauncher.UnsupportedDex.selector);
        launcher.launch{value: 0.001 ether}(p);
    }

    function test_RescueETH() public {
        vm.deal(address(launcher), 1 ether);
        uint256 before = owner.balance;
        vm.prank(owner);
        launcher.rescueETH(owner, 1 ether);
        assertEq(owner.balance, before + 1 ether);
    }
}
