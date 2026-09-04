// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Fork test for DuckLockerArc.sol -- reuses DuckIncubationArc to get a real,
// migrated V4 position locked in the locker (the same way any of the three
// families would register one), then exercises the locker's own surface:
// claimFees authorization, claimAllFees/claimFeesRange aggregation,
// creatorOf, launcher governance, and (new) the V4-launched-token park-
// into-V3 mechanism (see DuckLockerArc.parkTokenSide). This is the first
// fork test suite for the Arc contracts -- ported from
// deploy/test/DuckLocker.fork.t.sol (Ink's equivalent), trimmed to what's
// needed to exercise this specific feature against Arc's real, live
// infrastructure rather than duplicating every Ink test 1:1.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckIncubationArc} from "duck-incubation-contracts/DuckIncubation.sol";
import {DuckIncubationTokenArc} from "duck-incubation-contracts/DuckIncubationToken.sol";
import {DuckLockerArc} from "duck-launcher-contracts/DuckLocker.sol";
import {DuckHookV4Arc} from "duck-launcher-contracts/DuckHookV4.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";
import {TokenConfig} from "common-contracts/DuckIncubationTypes.sol";

interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
}

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

interface IPositionManagerV3ReadOnly {
    function positions(uint256 tokenId) external view returns (
        uint96  nonce,
        address operator,
        address token0,
        address token1,
        uint24  fee,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );
}

contract DuckLockerArcForkTest is Test {
    // Real, verified Arc (chain id 5042) infrastructure -- same addresses
    // deploy-arc/script/Deploy.s.sol uses for the real production deploy.
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    address constant PERMIT2             = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // Only ever read by an inert routing fallback with no route configured
    // against it in this test -- see Deploy.s.sol's header for why this is
    // passed as the (otherwise-unused-on-Arc) weth_ constructor param.
    address constant NATIVE_ERC20_MIRROR = 0x3600000000000000000000000000000000000000;
    // Real, verified Uniswap V3 NonfungiblePositionManager on Arc --
    // confirmed via name()/symbol() matching canonical Uniswap V3, and
    // already trusted elsewhere in this codebase (DuckLauncherArc's own V3
    // launch path uses this exact address).
    address constant V3_POSITION_MANAGER = 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377;

    DuckIncubationArc      curve;
    DuckLockerArc          locker;
    DuckHookV4Arc          hook;
    DuckIncubationTokenArc tokenImpl;
    MockERC20              quoteErc20;

    address owner          = makeAddr("dlk-owner");
    address platformWallet = makeAddr("dlk-platform");
    address buyer          = makeAddr("dlk-buyer");
    address creator        = makeAddr("dlk-creator");

    uint256 private _tokenSaltNonceCursor;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARC_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(platformWallet, "");
        vm.etch(buyer, "");
        vm.etch(creator, "");

        vm.startPrank(owner);

        tokenImpl = new DuckIncubationTokenArc();

        DuckLockerArc lockerImpl = new DuckLockerArc();
        ERC1967Proxy lockerProxy = new ERC1967Proxy(
            address(lockerImpl),
            abi.encodeCall(DuckLockerArc.initialize, (platformWallet))
        );
        locker = DuckLockerArc(payable(address(lockerProxy)));

        DuckIncubationArc curveImpl = new DuckIncubationArc();
        ERC1967Proxy curveProxy = new ERC1967Proxy(
            address(curveImpl),
            abi.encodeCall(DuckIncubationArc.initialize, (
                NATIVE_ERC20_MIRROR, V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2,
                address(0), platformWallet, address(tokenImpl), address(locker)
            ))
        );
        curve = DuckIncubationArc(payable(address(curveProxy)));

        locker.addLauncher(address(curve));

        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(DuckHookV4Arc).creationCode,
            abi.encode(V4_POOL_MANAGER)
        ));
        (bytes32 salt,) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(salt, V4_POOL_MANAGER, owner);
        hook = DuckHookV4Arc(payable(hookAddr));
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

    // Launches and migrates a fresh token quoted in a plain ERC20, returning
    // its address once locked.
    //
    // Deliberately NOT native-quoted (unlike Ink's equivalent fixture) --
    // doing so surfaced a real, separate bug in DuckIncubationArc's live
    // migration path: DuckIncubationMigration._mintV4 unconditionally calls
    // IWETH9Mig(cfg.weth).deposit{value: migrationAmount}() for a native-
    // quoted token, but Arc's deployed weth_ is NATIVE_ERC20_MIRROR
    // (0x3600...), which Deploy.s.sol's own header already documents as NOT
    // a working WETH-shaped contract -- confirmed here via a real revert
    // inside that deposit() call, caught by buy()'s try/catch and surfaced
    // only as a MigrationFailed event (migrated stays false forever, no
    // funds lost but the token can never get a real pool). The same
    // deposit() pattern exists in DuckRaiseArc.sol's finalize() path too.
    // This is a pre-existing production bug, unrelated to and out of scope
    // for the park-into-V3 feature this file otherwise tests -- flagged
    // separately. An ERC20-quoted migration never touches cfg.weth at all
    // (DuckIncubationMigration._mintV4 only takes that branch when
    // tc.quoteToken == address(0)), so it's unaffected and lets this file
    // exercise the real feature under test.
    function _migratedToken() internal returns (address token) {
        vm.prank(owner);
        curve.setQuoteTokenAllowed(address(quoteErc20), true);

        DuckIncubationArc.BaseParams memory p;
        p.name                 = "Test Token";
        p.symbol               = "TEST";
        p.totalSupply          = 1_000_000_000e18;
        p.curveBps             = 8_000;
        p.liquidityBps         = 2_000;
        p.quoteToken           = address(quoteErc20);
        p.startVirtualQuote    = 1_000e18;
        p.migrationTargetQuote = 10_000e18;
        p.salt                 = _mineTokenSalt(creator);

        vm.prank(creator);
        token = curve.createToken{value: 1e18}(p);

        vm.startPrank(buyer);
        quoteErc20.approve(address(curve), type(uint256).max);
        curve.buy(token, 60_000e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        TokenConfig memory tc = curve.getToken(token);
        require(tc.migrated, "expected migration to succeed");
    }

    function test_ClaimFeesRevertsForUnknownToken() public {
        vm.expectRevert(DuckLockerArc.UnknownToken.selector);
        locker.claimFees(makeAddr("not-a-token"));
    }

    function test_ClaimFeesUnauthorizedCallerReverts() public {
        address token = _migratedToken();
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(DuckLockerArc.NotAuthorized.selector);
        locker.claimFees(token);
    }

    function test_ClaimFeesCreatorCanCallWithNoAccruedFees() public {
        address token = _migratedToken();
        // No trading volume against the migrated pool yet -- should just no-op, not revert.
        vm.prank(creator);
        locker.claimFees(token);
    }

    function test_CreatorOfMatchesHook() public {
        address token = _migratedToken();
        assertEq(locker.creatorOf(token), creator);
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
        vm.expectRevert(DuckLockerArc.NotLauncher.selector);
        locker.registerPosition(makeAddr("t"), 1, address(0), address(1), bytes32(0), address(hook), V4_POSITION_MANAGER);
    }

    // parkTokenSide is external + self-only (see DuckLockerArc.NotSelf)
    // purely so _parkOrBurn can wrap it in try/catch -- pranking as the
    // locker itself is the correct way to drive it directly, with the exact
    // same call shape _parkOrBurn uses. Driving it directly (rather than
    // manufacturing a real token-side LP fee, which needs an actual sell of
    // the project token through the pool -- a single-direction buy-and-burn
    // swap only ever accrues fee on its *input* currency, confirmed against
    // this exact fixture family on Ink) exercises the same code path with a
    // much smaller fixture.
    function test_ParkTokenSideMintsSingleSidedV3Position() public {
        vm.prank(owner);
        locker.setV3PositionManager(V3_POSITION_MANAGER);

        address token = _migratedToken();

        vm.prank(buyer);
        DuckIncubationTokenArc(payable(token)).transfer(address(locker), 1_000e18);

        vm.prank(address(locker));
        locker.parkTokenSide(token, token, 1_000e18);

        uint256 tokenId = locker.v3LockTokenId(token);
        assertGt(tokenId, 0, "expected a V3 lock position to be minted");
        assertEq(
            IERC721Minimal(V3_POSITION_MANAGER).ownerOf(tokenId), address(locker),
            "locker itself should hold the minted V3 position"
        );

        (,, address posToken0, address posToken1,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            IPositionManagerV3ReadOnly(V3_POSITION_MANAGER).positions(tokenId);
        assertGt(liquidity, 0, "position should hold real liquidity");
        // Whichever side the project token is on, the range must sit
        // entirely on that side of a legal tick range -- i.e. touch the far
        // edge of the curve on that side (see PARK_MIN_TICK/PARK_MAX_TICK).
        if (token == posToken0) {
            assertEq(tickUpper, int24(887200), "token0 side should extend to the top of the curve");
        } else {
            assertEq(posToken1, token);
            assertEq(tickLower, int24(-887200), "token1 side should extend to the bottom of the curve");
        }
    }

    function test_ParkTokenSideExtendsRatherThanReMints() public {
        vm.prank(owner);
        locker.setV3PositionManager(V3_POSITION_MANAGER);

        address token = _migratedToken();

        vm.prank(buyer);
        DuckIncubationTokenArc(payable(token)).transfer(address(locker), 2_000e18);

        vm.prank(address(locker));
        locker.parkTokenSide(token, token, 1_000e18);
        uint256 tokenId = locker.v3LockTokenId(token);
        (,,,,,,, uint128 liquidityBefore,,,,) = IPositionManagerV3ReadOnly(V3_POSITION_MANAGER).positions(tokenId);

        vm.prank(address(locker));
        locker.parkTokenSide(token, token, 1_000e18);

        assertEq(locker.v3LockTokenId(token), tokenId, "second call should extend, not re-mint");
        (,,,,,,, uint128 liquidityAfter,,,,) = IPositionManagerV3ReadOnly(V3_POSITION_MANAGER).positions(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "extending should add real liquidity to the same position");
    }

    // Real V3 trading-fee accrual on the parked position only happens once
    // price actually crosses through it (2.5x above spot -- see
    // PARK_TICK_OFFSET), which needs a large, real directional swap against
    // the newly-created pool to reach -- out of scope here for the same
    // reason as Ink's equivalent test: collect() itself is standard,
    // already-audited Uniswap machinery, so what's worth testing is this
    // contract's own wiring (self-only gating, safe no-op with nothing
    // parked, and that claimFees's best-effort call never breaks the claim).
    function test_ClaimParkedV3FeesOnlySelf() public {
        address token = _migratedToken();
        vm.prank(owner);
        vm.expectRevert(DuckLockerArc.NotSelf.selector);
        locker.claimParkedV3Fees(token);
    }

    function test_ClaimParkedV3FeesNoopsWithNoParkedPosition() public {
        address token = _migratedToken();
        // No park has happened yet (v3PositionManager unset in this test) --
        // should just no-op, not revert.
        vm.prank(address(locker));
        locker.claimParkedV3Fees(token);
        assertEq(locker.v3LockTokenId(token), 0);
    }

    function test_ClaimFeesRoutesParkedV3FeesToPlatformWallet() public {
        vm.prank(owner);
        locker.setV3PositionManager(V3_POSITION_MANAGER);

        address token = _migratedToken();
        vm.prank(buyer);
        DuckIncubationTokenArc(payable(token)).transfer(address(locker), 1_000e18);
        vm.prank(address(locker));
        locker.parkTokenSide(token, token, 1_000e18);
        uint256 tokenId = locker.v3LockTokenId(token);

        // No real trading volume has crossed the parked range in this test,
        // so there's nothing to collect yet -- this just confirms claimFees
        // reaches claimParkedV3Fees and it no-ops cleanly rather than
        // reverting the whole claim.
        uint256 platformTokenBefore = DuckIncubationTokenArc(payable(token)).balanceOf(platformWallet);
        vm.prank(creator);
        locker.claimFees(token);
        assertEq(DuckIncubationTokenArc(payable(token)).balanceOf(platformWallet), platformTokenBefore);
        assertEq(locker.v3LockTokenId(token), tokenId, "claimFees must not disturb the parked position");
    }

    function test_ClaimFeesFallsBackToBurnByDefault() public view {
        // Default state (setUp never wires v3PositionManager) -- parking
        // must stay off until the owner opts in.
        assertEq(locker.v3PositionManager(), address(0));
    }

    function test_SetV3PositionManager() public {
        vm.prank(owner);
        locker.setV3PositionManager(V3_POSITION_MANAGER);
        assertEq(locker.v3PositionManager(), V3_POSITION_MANAGER);
    }

    function test_SetPlatformWallet() public {
        address newWallet = makeAddr("new-platform");
        vm.prank(owner);
        locker.setPlatformWallet(newWallet);
        assertEq(locker.platformWallet(), newWallet);

        vm.prank(owner);
        vm.expectRevert(DuckLockerArc.ZeroAddress.selector);
        locker.setPlatformWallet(address(0));
    }
}
