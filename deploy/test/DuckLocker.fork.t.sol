// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Fork test for DuckLocker.sol -- reuses DuckIncubation to get a real,
// migrated V4 position locked in the locker (the same way any of the three
// families would register one), then exercises the locker's own surface:
// claimFees authorization, claimAllFees/claimFeesRange aggregation,
// creatorOf, and launcher governance.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckIncubation} from "duck-incubation-contracts/DuckIncubation.sol";
import {DuckIncubationToken} from "duck-incubation-contracts/DuckIncubationToken.sol";
import {DuckLocker} from "duck-launcher-contracts/DuckLocker.sol";
import {DuckHookV4} from "duck-launcher-contracts/DuckHookV4.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";
import {TokenConfig} from "common-contracts/DuckIncubationTypes.sol";

contract MockERC20 {
    string public name = "Mock USD";
    string public symbol = "mUSD";
    uint8  public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
    }
}

contract DuckLockerForkTest is Test {
    address constant WETH                = 0x4200000000000000000000000000000000000006;
    address constant V4_POOL_MANAGER     = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant V4_POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant PERMIT2             = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    DuckIncubation      curve;
    DuckLocker          locker;
    DuckHookV4          hook;
    DuckIncubationToken tokenImpl;
    MockERC20           quoteErc20;

    address owner          = makeAddr("dlk-owner");
    address platformWallet = makeAddr("dlk-platform");
    address buyer          = makeAddr("dlk-buyer");
    address creator        = makeAddr("dlk-creator");

    uint256 private _tokenSaltNonceCursor;

    function setUp() public {
        vm.createSelectFork(vm.envString("INK_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(platformWallet, "");
        vm.etch(buyer, "");
        vm.etch(creator, "");

        vm.startPrank(owner);

        tokenImpl = new DuckIncubationToken();

        DuckLocker lockerImpl = new DuckLocker();
        ERC1967Proxy lockerProxy = new ERC1967Proxy(
            address(lockerImpl),
            abi.encodeCall(DuckLocker.initialize, (platformWallet))
        );
        locker = DuckLocker(payable(address(lockerProxy)));

        DuckIncubation curveImpl = new DuckIncubation();
        ERC1967Proxy curveProxy = new ERC1967Proxy(
            address(curveImpl),
            abi.encodeCall(DuckIncubation.initialize, (
                WETH, V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2,
                address(0), platformWallet, address(tokenImpl), address(locker)
            ))
        );
        curve = DuckIncubation(payable(address(curveProxy)));

        locker.addLauncher(address(curve));

        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(DuckHookV4).creationCode,
            abi.encode(V4_POOL_MANAGER)
        ));
        (bytes32 salt,) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(salt, V4_POOL_MANAGER, owner);
        hook = DuckHookV4(payable(hookAddr));
        require(uint160(hookAddr) & 0x3FFF == 0xC4, "bad hook permission bits");

        hook.addLauncher(address(curve));
        curve.setDexConfig(V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2, hookAddr);

        vm.stopPrank();

        vm.deal(buyer, 1_000 ether);
        vm.deal(creator, 10 ether);

        quoteErc20 = new MockERC20();
        quoteErc20.mint(buyer, 1_000_000e18);
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
            address predicted = _computeCreate2Address(salt, initCodeHash, address(curve));
            if (uint16(uint160(predicted)) == 0x8888) {
                _tokenSaltNonceCursor = nonce + i + 1;
                return userSalt;
            }
        }
        revert("token salt not found");
    }

    // Launches and migrates a fresh token, returning its address once locked.
    function _migratedToken() internal returns (address token) {
        DuckIncubation.BaseParams memory p;
        p.name                 = "Test Token";
        p.symbol               = "TEST";
        p.totalSupply          = 1_000_000_000e18;
        p.curveBps             = 8_000;
        p.liquidityBps         = 2_000;
        p.quoteToken           = address(0);
        p.startVirtualQuote    = 1 ether;
        p.migrationTargetQuote = 10 ether;
        p.salt                 = _mineTokenSalt(creator);

        vm.prank(creator);
        token = curve.createToken{value: 0.0005 ether}(p);

        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        TokenConfig memory tc = curve.getToken(token);
        require(tc.migrated, "expected migration to succeed");
    }

    // Same as _migratedToken but quoted in an ERC20 (used for the platformToken
    // buy-and-burn test, since native ETH can never be the platformToken).
    function _migratedTokenQuotedIn(address quoteToken_, uint256 buyAmount_) internal returns (address token) {
        DuckIncubation.BaseParams memory p;
        p.name                 = "Test Token";
        p.symbol               = "TEST";
        p.totalSupply          = 1_000_000_000e18;
        p.curveBps             = 8_000;
        p.liquidityBps         = 2_000;
        p.quoteToken           = quoteToken_;
        p.startVirtualQuote    = 1_000e18;
        p.migrationTargetQuote = 10_000e18;
        p.salt                 = _mineTokenSalt(creator);

        vm.prank(creator);
        token = curve.createToken{value: 0}(p);

        vm.startPrank(buyer);
        MockERC20(quoteToken_).approve(address(curve), type(uint256).max);
        curve.buy(token, buyAmount_, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        TokenConfig memory tc = curve.getToken(token);
        require(tc.migrated, "expected migration to succeed");
    }

    function test_ClaimFeesRevertsForUnknownToken() public {
        vm.expectRevert(DuckLocker.UnknownToken.selector);
        locker.claimFees(makeAddr("not-a-token"));
    }

    function test_ClaimFeesUnauthorizedCallerReverts() public {
        address token = _migratedToken();
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(DuckLocker.NotAuthorized.selector);
        locker.claimFees(token);
    }

    function test_ClaimFeesCreatorCanCallWithNoAccruedFees() public {
        address token = _migratedToken();
        // No trading volume against the migrated pool yet -- should just no-op, not revert.
        vm.prank(creator);
        locker.claimFees(token);
    }

    function test_ClaimFeesOwnerCanAlwaysCall() public {
        address token = _migratedToken();
        vm.prank(owner);
        locker.claimFees(token);
    }

    function test_CreatorOfMatchesHook() public {
        address token = _migratedToken();
        assertEq(locker.creatorOf(token), creator);
    }

    function test_ClaimAllFeesIteratesEveryPosition() public {
        address tokenA = _migratedToken();
        address tokenB = _migratedToken();

        assertEq(locker.tokenCount(), 2);

        // Permissionless per-token calls would each need creator/owner auth,
        // but claimAllFees is owner-only and internally calls itself for each.
        vm.prank(owner);
        locker.claimAllFees();

        // Both positions should still be registered and untouched by errors.
        (uint256 idA,,,,,) = locker.positions(tokenA);
        (uint256 idB,,,,,) = locker.positions(tokenB);
        assertGt(idA, 0);
        assertGt(idB, 0);
    }

    function test_ClaimFeesRangeRespectsBounds() public {
        _migratedToken();
        _migratedToken();
        _migratedToken();

        vm.prank(owner);
        locker.claimFeesRange(0, 2); // only first two, out-of-range clamps internally

        vm.prank(owner);
        locker.claimFeesRange(2, 100); // upper bound beyond length should clamp, not revert
    }

    function test_AddRemoveLauncher() public {
        address newLauncher = makeAddr("new-launcher");
        assertFalse(locker.isLauncher(newLauncher));

        vm.prank(owner);
        locker.addLauncher(newLauncher);
        assertTrue(locker.isLauncher(newLauncher));

        vm.prank(owner);
        locker.removeLauncher(newLauncher);
        assertFalse(locker.isLauncher(newLauncher));
    }

    function test_RegisterPositionOnlyLauncher() public {
        vm.expectRevert(DuckLocker.NotLauncher.selector);
        locker.registerPosition(makeAddr("t"), 1, address(0), address(1), bytes32(0), address(hook), V4_POSITION_MANAGER);
    }

    function test_PlatformTokenBuysAndBurnsLPFee() public {
        vm.startPrank(owner);
        curve.setQuoteTokenAllowed(address(quoteErc20), true);
        curve.setPlatformToken(address(quoteErc20));
        locker.setPlatformToken(address(quoteErc20));
        vm.stopPrank();

        address token = _migratedTokenQuotedIn(address(quoteErc20), 60_000e18);

        // Real swap through the migrated V4 pool (quoteErc20 -> token) --
        // this is the platform's half of the curve fee buying back and
        // burning, which incidentally accrues real LP fee-growth on the
        // locked position (any swap through a V4 pool pays its 1% pool fee
        // to that pool's liquidity, and the locker holds the only LP here).
        curve.claimCurveFee(token);

        address DEAD = 0x000000000000000000000000000000000000dEaD;
        uint256 deadBefore     = DuckIncubationToken(payable(token)).balanceOf(DEAD);
        uint256 platformBefore = quoteErc20.balanceOf(platformWallet);

        vm.prank(creator);
        locker.claimFees(token);

        assertEq(
            quoteErc20.balanceOf(platformWallet), platformBefore,
            "platform should take zero LP-tier fee from a platformToken-quoted pool"
        );
        assertGt(
            DuckIncubationToken(payable(token)).balanceOf(DEAD), deadBefore,
            "locker's LP-tier buyback should have burned more of the launched token"
        );
    }

    function test_SetPlatformWallet() public {
        address newWallet = makeAddr("new-platform");
        vm.prank(owner);
        locker.setPlatformWallet(newWallet);
        assertEq(locker.platformWallet(), newWallet);

        vm.prank(owner);
        vm.expectRevert(DuckLocker.ZeroAddress.selector);
        locker.setPlatformWallet(address(0));
    }
}
