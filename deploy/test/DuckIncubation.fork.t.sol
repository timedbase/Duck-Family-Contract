// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Fork test for the rewritten DuckIncubation.sol -- exercises both quote-asset
// paths (native currency and an owner-whitelisted ERC20) end to end against
// the REAL, verified Uniswap V4 deployment on Ink chain: create -> partial
// buy -> partial sell -> migration-cap buy (auto-migrates in the same tx) ->
// verify the V4 pool actually exists via StateView and the position landed
// in DuckLocker. Also covers the quote-token allowlist gate and the
// rescue-function fund-safety guards added alongside the raisedETH/raisedERC
// split.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckIncubation} from "duck-incubation-contracts/DuckIncubation.sol";
import {DuckIncubationToken} from "duck-incubation-contracts/DuckIncubationToken.sol";
import {DuckLocker} from "duck-launcher-contracts/DuckLocker.sol";
import {DuckHookV4} from "duck-launcher-contracts/DuckHookV4.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";
import {Route, RouteShape} from "common-contracts/LaunchRouting.sol";
import {TokenConfig, FeeSplit} from "common-contracts/DuckIncubationTypes.sol";

interface IERC20Real {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IStateView {
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
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

// Stand-in for a real V2-style router (deterministic 1 ETH -> 2 quote-token
// rate) so buyWithNative's swap-then-buy path can be exercised without
// needing a real liquid Ink pool for a mock quote asset.
contract MockV2Router {
    uint256 public constant RATE = 2;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin, address[] calldata path, address to, address, uint256
    ) external payable {
        address tokenOut = path[path.length - 1];
        uint256 amountOut = msg.value * RATE;
        require(amountOut >= amountOutMin, "slippage");
        MockERC20(tokenOut).mint(to, amountOut);
    }
}

contract DuckIncubationForkTest is Test {
    // ── Verified Ink chain (57073) infrastructure ───────────────────────────
    address constant WETH               = 0x4200000000000000000000000000000000000006;
    address constant V4_POOL_MANAGER    = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant V4_POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant V4_STATE_VIEW      = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address constant PERMIT2            = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    DuckIncubation       curve;
    DuckLocker      locker;
    DuckHookV4      hook;
    DuckIncubationToken  tokenImpl;
    MockERC20           quoteErc20;

    address owner        = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address platform     = makeAddr("platform");
    address buyer        = makeAddr("buyer");
    address creator      = makeAddr("creator");

    uint256 private _tokenSaltNonceCursor;

    function setUp() public {
        vm.createSelectFork(vm.envString("INK_RPC_URL"));

        // These labeled test addresses are plain EOA stand-ins, but on a live
        // mainnet fork any deterministic address can coincidentally already
        // hold real contract code (as one of these did here, silently
        // forwarding received ETH elsewhere via its own fallback) -- clear
        // them so native transfers in this test land as plain balance credits.
        vm.etch(owner, "");
        vm.etch(feeRecipient, "");
        vm.etch(platform, "");
        vm.etch(buyer, "");
        vm.etch(creator, "");

        vm.startPrank(owner);

        tokenImpl = new DuckIncubationToken();

        DuckLocker lockerImpl = new DuckLocker();
        ERC1967Proxy lockerProxy = new ERC1967Proxy(
            address(lockerImpl),
            abi.encodeCall(DuckLocker.initialize, (platform))
        );
        locker = DuckLocker(payable(address(lockerProxy)));

        DuckIncubation curveImpl = new DuckIncubation();
        ERC1967Proxy curveProxy = new ERC1967Proxy(
            address(curveImpl),
            abi.encodeCall(DuckIncubation.initialize, (
                WETH, V4_POSITION_MANAGER, V4_POOL_MANAGER, PERMIT2,
                address(0), // hook wired in after deployment, below (circular dep: hook needs curve's address)
                feeRecipient, address(tokenImpl), address(locker)
            ))
        );
        curve = DuckIncubation(payable(address(curveProxy)));

        locker.addLauncher(address(curve));

        // Deploy the hook via the CREATE2 factory with a mined salt so the
        // resulting address satisfies V4's permission-bit requirement
        // (uint160(addr) & 0x3FFF == 0xC4). The hook is shared across launcher
        // families, so it's authorized per-family via addLauncher() after
        // deployment -- same two-step pattern as DuckLocker.addLauncher.
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

        quoteErc20 = new MockERC20();
        curve.setQuoteTokenAllowed(address(quoteErc20), true);

        vm.stopPrank();

        vm.deal(buyer, 1_000 ether);
        vm.deal(creator, 10 ether);
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

    // Deliberately avoids abi.encodePacked: mining loops here call this up to a
    // million times, and abi.encodePacked allocates fresh heap memory on every
    // call that the EVM never reclaims mid-call -- over enough iterations that
    // alone blows the per-call memory limit (observed in practice). Writing
    // into the same scratch region every time (never bumping the free-memory
    // pointer at 0x40) keeps memory usage flat across the whole search.
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

    // Same fixed-scratch-space rationale as _computeCreate2Address -- avoids
    // abi.encode's per-call heap allocation inside the mining loop.
    function _saltFor(address creator_, bytes32 userSalt) internal pure returns (bytes32 salt) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, creator_)
            mstore(add(ptr, 32), userSalt)
            salt := keccak256(ptr, 64)
        }
    }

    // Mirrors DuckIncubation's own EIP-1167 minimal-proxy CREATE2 formula so a
    // vanity (0x8888-suffixed) salt can be found off-chain before calling
    // createToken, exactly like the real frontend's vanity miner would.
    // Resumes from _tokenSaltNonceCursor so repeated calls (e.g. multiple
    // tokens created by the same creator_ within one test) never re-find the
    // same salt -- CREATE2 would otherwise collide with the address already
    // deployed at the first find.
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

    function _baseParams(address quoteToken_, uint256 startVirtual, uint256 migrationTarget, bytes32 salt)
        internal pure returns (DuckIncubation.BaseParams memory p)
    {
        p.name                 = "Test Token";
        p.symbol               = "TEST";
        p.totalSupply          = 1_000_000_000e18;
        p.curveBps             = 8_000;
        p.liquidityBps         = 2_000;
        p.quoteToken           = quoteToken_;
        p.startVirtualQuote    = startVirtual;
        p.migrationTargetQuote = migrationTarget;
        p.earlyBuyAmount       = 0;
        p.enableAntibot        = false;
        p.antibotBlocks        = 0;
        p.metaURI              = "";
        p.salt                 = salt;
    }

    // ── Native-quoted lifecycle ─────────────────────────────────────────────

    function test_NativeQuoteFullLifecycle() public {
        DuckIncubation.BaseParams memory p =
            _baseParams(address(0), 1 ether, 10 ether, _mineTokenSalt(creator));

        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        TokenConfig memory tc = curve.getToken(token);
        assertEq(tc.quoteToken, address(0));
        assertEq(tc.raisedQuote, 0);

        // Partial buy, well under the migration cap.
        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);

        tc = curve.getToken(token);
        assertGt(tc.raisedQuote, 0);
        assertFalse(tc.migrated);

        uint256 boughtTokens = tc.bcTokensSold;
        assertGt(boughtTokens, 0);

        // Partial sell of half what was bought.
        uint256 sellAmount = boughtTokens / 2;
        vm.startPrank(buyer);
        DuckIncubationToken(payable(token)).approve(address(curve), sellAmount);
        uint256 balBefore = buyer.balance;
        curve.sell(token, sellAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();
        assertGt(buyer.balance, balBefore);

        // Buy past the migration cap -- should sell out remaining BC supply,
        // refund the excess, and auto-migrate in the same transaction.
        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        tc = curve.getToken(token);
        assertTrue(tc.migrated, "expected auto-migration to succeed");
        assertFalse(tc.migrationPending);
        assertEq(tc.raisedQuote, 0, "raisedQuote should be zeroed post-migration");

        _assertPoolLive(tc.poolId, token);
    }

    // ── Curve fee accrual/claim ──────────────────────────────────────────────

    function test_CurveFeeAccrualAndClaim() public {
        DuckIncubation.BaseParams memory p =
            _baseParams(address(0), 1 ether, 10 ether, _mineTokenSalt(creator));

        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);

        TokenConfig memory tc = curve.getToken(token);
        assertEq(tc.accruedFee, (1 ether * 100) / 10_000, "1% of the buy should have accrued as fee");
        assertFalse(tc.migrated);

        // Not claimable until the token has migrated.
        vm.expectRevert(DuckIncubation.NotMigrated.selector);
        curve.claimCurveFee(token);

        // Migration-cap buy: sells out the curve and auto-migrates.
        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        tc = curve.getToken(token);
        assertTrue(tc.migrated);
        uint256 accrued = tc.accruedFee;
        assertGt(accrued, 0);

        uint256 creatorBefore  = creator.balance;
        uint256 platformBefore = feeRecipient.balance;

        curve.claimCurveFee(token); // permissionless

        uint256 expectedCreator = accrued / 2;
        assertEq(creator.balance,      creatorBefore  + expectedCreator);
        assertEq(feeRecipient.balance, platformBefore + (accrued - expectedCreator));

        tc = curve.getToken(token);
        assertEq(tc.accruedFee, 0);

        vm.expectRevert(DuckIncubation.ZeroAmount.selector);
        curve.claimCurveFee(token);
    }

    function test_PlatformTokenWaivesCreationFeeAndBuysAndBurns() public {
        vm.prank(owner);
        curve.setPlatformToken(address(quoteErc20));

        DuckIncubation.BaseParams memory p =
            _baseParams(address(quoteErc20), 1_000e18, 10_000e18, _mineTokenSalt(creator));

        // No creationFee required when quoted against platformToken.
        vm.prank(creator);
        address token = curve.createToken{value: 0}(p);

        vm.startPrank(buyer);
        quoteErc20.approve(address(curve), type(uint256).max);
        curve.buy(token, 1_000e18, 0, block.timestamp + 1 hours);
        curve.buy(token, 50_000e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        TokenConfig memory tc = curve.getToken(token);
        assertTrue(tc.migrated);
        uint256 accrued = tc.accruedFee;
        assertGt(accrued, 0);

        address DEAD = 0x000000000000000000000000000000000000dEaD;
        uint256 creatorBefore  = quoteErc20.balanceOf(creator);
        uint256 platformBefore = quoteErc20.balanceOf(feeRecipient);
        uint256 deadBefore     = DuckIncubationToken(payable(token)).balanceOf(DEAD);

        curve.claimCurveFee(token);

        uint256 expectedCreatorCut = accrued / 2;
        assertEq(quoteErc20.balanceOf(creator), creatorBefore + expectedCreatorCut, "creator keeps their normal half");
        assertEq(quoteErc20.balanceOf(feeRecipient), platformBefore, "platform takes zero fee from this token");
        assertGt(
            DuckIncubationToken(payable(token)).balanceOf(DEAD), deadBefore,
            "platform's half should have bought back and burned the launched token"
        );
    }

    function test_PlatformTokenDoesNotAffectOtherQuoteTokens() public {
        vm.prank(owner);
        curve.setPlatformToken(address(quoteErc20));

        // A native-quoted token is unaffected -- still pays creationFee, still
        // pays platformWallet its normal half.
        DuckIncubation.BaseParams memory p =
            _baseParams(address(0), 1 ether, 10 ether, _mineTokenSalt(creator));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(DuckIncubation.InsufficientCreationFee.selector, 0.0005 ether, 0));
        curve.createToken{value: 0}(p);

        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        TokenConfig memory tc = curve.getToken(token);
        assertTrue(tc.migrated);

        uint256 platformBefore = feeRecipient.balance;
        curve.claimCurveFee(token);
        assertGt(feeRecipient.balance, platformBefore, "platform should still be paid for non-platform-quoted tokens");
    }

    function test_CreatorFeeSplitRoutesCorrectly() public {
        DuckIncubation.BaseParams memory p =
            _baseParams(address(0), 1 ether, 10 ether, _mineTokenSalt(creator));

        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        address walletA = makeAddr("splitWalletA");
        address walletB = makeAddr("splitWalletB");
        vm.etch(walletA, "");
        vm.etch(walletB, "");

        FeeSplit[] memory splits = new FeeSplit[](2);
        splits[0] = FeeSplit({wallet: walletA, bps: 3_000}); // 30%
        splits[1] = FeeSplit({wallet: walletB, bps: 7_000}); // 70%

        // Only the token's own creator may configure its split.
        vm.expectRevert(DuckIncubation.NotCreator.selector);
        curve.setFeeSplits(token, splits);

        vm.prank(creator);
        curve.setFeeSplits(token, splits);

        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        TokenConfig memory tc = curve.getToken(token);
        assertTrue(tc.migrated);
        uint256 accrued = tc.accruedFee;
        uint256 creatorCut = accrued / 2;

        curve.claimCurveFee(token);

        assertEq(walletA.balance, (creatorCut * 3_000) / 10_000);
        assertEq(walletB.balance, creatorCut - (creatorCut * 3_000) / 10_000);
        assertEq(creator.balance, 10 ether - 0.0005 ether); // untouched by the split
    }

    // ── ERC20-quoted lifecycle ───────────────────────────────────────────────

    function test_ERC20QuoteFullLifecycle() public {
        DuckIncubation.BaseParams memory p =
            _baseParams(address(quoteErc20), 1_000e18, 10_000e18, _mineTokenSalt(creator));

        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        TokenConfig memory tc = curve.getToken(token);
        assertEq(tc.quoteToken, address(quoteErc20));

        vm.startPrank(buyer);
        quoteErc20.approve(address(curve), type(uint256).max);
        curve.buy(token, 1_000e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        tc = curve.getToken(token);
        assertGt(tc.raisedQuote, 0);
        assertFalse(tc.migrated);

        uint256 boughtTokens = tc.bcTokensSold;
        uint256 sellAmount = boughtTokens / 2;
        vm.startPrank(buyer);
        DuckIncubationToken(payable(token)).approve(address(curve), sellAmount);
        uint256 balBefore = quoteErc20.balanceOf(buyer);
        curve.sell(token, sellAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();
        assertGt(quoteErc20.balanceOf(buyer), balBefore);

        vm.prank(buyer);
        curve.buy(token, 50_000e18, 0, block.timestamp + 1 hours);

        tc = curve.getToken(token);
        assertTrue(tc.migrated, "expected auto-migration to succeed");
        assertEq(tc.raisedQuote, 0);

        _assertPoolLive(tc.poolId, token);
    }

    // Every other ERC20-quote lifecycle test above uses MockERC20 -- clean,
    // fully-compliant, but not proof the real deployed contract behaves the
    // same way (non-standard return values, unusual decimals, transfer
    // hooks, etc. are all real risks with a live token). This runs the full
    // create -> buy -> sell -> migration-cap buy -> pool-verification cycle
    // against the genuine deployed USDC contract on Ink, funded via deal().
    function test_RealUSDCFullLifecycle() public {
        address USDC = 0x2D270e6886d130D724215A266106e6832161EAEd;
        deal(USDC, buyer, 1_000_000e6);

        // USDC has 6 decimals on Ink (verified on-chain), unlike the 18-decimal
        // MockERC20 used elsewhere -- targets are scaled accordingly.
        DuckIncubation.BaseParams memory p =
            _baseParams(USDC, 1_000e6, 10_000e6, _mineTokenSalt(creator));

        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        TokenConfig memory tc = curve.getToken(token);
        assertEq(tc.quoteToken, USDC);

        vm.startPrank(buyer);
        IERC20Real(USDC).approve(address(curve), type(uint256).max);
        curve.buy(token, 1_000e6, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        tc = curve.getToken(token);
        assertGt(tc.raisedQuote, 0, "real USDC should have been pulled via transferFrom");
        assertFalse(tc.migrated);

        uint256 boughtTokens = tc.bcTokensSold;
        uint256 sellAmount = boughtTokens / 2;
        vm.startPrank(buyer);
        DuckIncubationToken(payable(token)).approve(address(curve), sellAmount);
        uint256 balBefore = IERC20Real(USDC).balanceOf(buyer);
        curve.sell(token, sellAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();
        assertGt(IERC20Real(USDC).balanceOf(buyer), balBefore, "real USDC should have been paid out on sell");

        vm.prank(buyer);
        curve.buy(token, 50_000e6, 0, block.timestamp + 1 hours);

        tc = curve.getToken(token);
        assertTrue(tc.migrated, "expected auto-migration to succeed against a real USDC pool");
        assertEq(tc.raisedQuote, 0);

        _assertPoolLive(tc.poolId, token);

        // Curve fee (accrued in real USDC) should be claimable post-migration.
        uint256 creatorUsdcBefore = IERC20Real(USDC).balanceOf(creator);
        curve.claimCurveFee(token);
        assertGt(IERC20Real(USDC).balanceOf(creator), creatorUsdcBefore, "creator should receive real USDC curve-fee cut");
    }

    function test_BuyWithNativeRoutesIntoErc20Quote() public {
        MockV2Router router = new MockV2Router();
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(quoteErc20);

        Route[] memory rs = new Route[](1);
        rs[0] = Route({
            shape:            RouteShape.V2_STYLE,
            enabled:          true,
            router:           address(router),
            routerNoDeadline: false,
            path:             path,
            fees:             new uint24[](0),
            routers:          new address[](0),
            singleton:        address(0),
            hook:             address(0),
            fee:              0,
            tickSpacing:      0
        });

        vm.prank(owner);
        curve.setRoutes(address(quoteErc20), rs);

        DuckIncubation.BaseParams memory p =
            _baseParams(address(quoteErc20), 1_000e18, 10_000e18, _mineTokenSalt(creator));
        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        uint256 tokenBalBefore = DuckIncubationToken(payable(token)).balanceOf(buyer);

        vm.prank(buyer);
        curve.buyWithNative{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);

        TokenConfig memory tc = curve.getToken(token);
        // 2 ether routed in at the mock's fixed 1:2 rate, net of the curve's own 1% trading fee.
        assertEq(tc.raisedQuote, 2 ether - (2 ether * 100 / 10_000), "native routed into the quote asset and bought, net of the 1% curve fee");
        assertGt(
            DuckIncubationToken(payable(token)).balanceOf(buyer), tokenBalBefore,
            "buyer should have received the launched token bought with the routed quote asset"
        );
    }

    function test_BuyWithNativeRevertsWithoutRoute() public {
        DuckIncubation.BaseParams memory p =
            _baseParams(address(quoteErc20), 1_000e18, 10_000e18, _mineTokenSalt(creator));
        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        vm.prank(buyer);
        vm.expectRevert(DuckIncubation.RouteUnavailable.selector);
        curve.buyWithNative{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
    }

    // USDC is one of the two default quote tokens (see
    // DuckIncubation._seedDefaultRoutes) with real, verified liquidity on
    // Ink chain -- this proves buyWithNative against the genuine live V4
    // pool on the fork, not a mock router.
    function test_BuyWithNativeUsesRealSeededLiquidity() public {
        address USDC = 0x2D270e6886d130D724215A266106e6832161EAEd;

        DuckIncubation.BaseParams memory p =
            _baseParams(USDC, 1_000e6, 1_000_000e6, _mineTokenSalt(creator));
        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        uint256 tokenBalBefore = DuckIncubationToken(payable(token)).balanceOf(buyer);

        vm.prank(buyer);
        curve.buyWithNative{value: 0.05 ether}(token, 0, 0, block.timestamp + 1 hours);

        TokenConfig memory tc = curve.getToken(token);
        assertGt(tc.raisedQuote, 0, "native ETH should have routed into real USDC liquidity");
        assertGt(
            DuckIncubationToken(payable(token)).balanceOf(buyer), tokenBalBefore,
            "buyer should have received the launched token bought with the routed USDC"
        );
    }

    function test_BuyWithNativeRevertsForNativeQuotedToken() public {
        DuckIncubation.BaseParams memory p =
            _baseParams(address(0), 1 ether, 10 ether, _mineTokenSalt(creator));
        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        vm.prank(buyer);
        vm.expectRevert(DuckIncubation.NativeQuoteNoSwapNeeded.selector);
        curve.buyWithNative{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
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
            assertTrue(curve.quoteTokenAllowed(defaults[i]), "default quote token should be enabled at deploy");
        }
    }

    function test_QuoteTokenNotAllowedReverts() public {
        MockERC20 rogue = new MockERC20();
        DuckIncubation.BaseParams memory p =
            _baseParams(address(rogue), 1_000e18, 10_000e18, keccak256("rogue-token"));

        vm.prank(creator);
        vm.expectRevert(DuckIncubation.QuoteTokenNotAllowed.selector);
        curve.createToken(p);
    }

    function test_CreatorChosenHookFeeBpsAppliesAtMigration() public {
        DuckIncubation.BaseParams memory p =
            _baseParams(address(0), 1 ether, 10 ether, _mineTokenSalt(creator));
        p.hookFeeBps = 150; // not one of {0,100,200,300,500}

        vm.prank(creator);
        vm.expectRevert(DuckIncubation.InvalidHookFeeBps.selector);
        curve.createToken{value: 0.0005 ether}(p);

        p.hookFeeBps = 500; // 5%, a valid tier
        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        TokenConfig memory tc = curve.getToken(token);
        assertEq(tc.hookFeeBps, 500);

        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        tc = curve.getToken(token);
        assertTrue(tc.migrated);

        (,,,,,, uint256 registeredFeeBps) = hook.pools(tc.poolId);
        assertEq(registeredFeeBps, 500, "creator-chosen 5% should carry through to the hook");
    }

    // ── Rescue guards ────────────────────────────────────────────────────────

    function test_RescueGuardsRespectReservedQuote() public {
        DuckIncubation.BaseParams memory p1 =
            _baseParams(address(0), 1 ether, 100 ether, _mineTokenSalt(creator));
        vm.prank(creator);
        address nativeToken = curve.createToken{value: 0.0005 ether}(p1);
        vm.prank(buyer);
        curve.buy{value: 5 ether}(nativeToken, 0, 0, block.timestamp + 1 hours);

        // Nothing beyond what's actively raised should be rescuable yet.
        vm.prank(owner);
        vm.expectRevert(DuckIncubation.ZeroAmount.selector);
        curve.rescueETH(owner);

        // Send stray native currency directly to the curve -- only the surplus
        // above the live raisedQuote total should be rescuable.
        vm.deal(address(curve), address(curve).balance + 2 ether);
        vm.prank(owner);
        curve.rescueETH(owner);
        assertEq(owner.balance, 2 ether);

        DuckIncubation.BaseParams memory p2 =
            _baseParams(address(quoteErc20), 1_000e18, 100_000e18, _mineTokenSalt(creator));
        vm.prank(creator);
        address ercToken = curve.createToken{value: 0.0005 ether}(p2);
        vm.startPrank(buyer);
        quoteErc20.approve(address(curve), type(uint256).max);
        curve.buy(ercToken, 5_000e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        // The whole ERC20 balance the curve holds is actively raised -- rescue must revert.
        vm.prank(owner);
        vm.expectRevert(DuckIncubation.ZeroAmount.selector);
        curve.rescueToken(address(quoteErc20), owner);

        // A stray extra transfer on top should be rescuable, leaving the raised amount intact.
        quoteErc20.mint(address(curve), 500e18);
        vm.prank(owner);
        curve.rescueToken(address(quoteErc20), owner);
        assertEq(quoteErc20.balanceOf(owner), 500e18);
    }

    function _assertPoolLive(bytes32 poolId, address token) internal view {
        (uint160 sqrtPriceX96,,,) = IStateView(V4_STATE_VIEW).getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, "pool should be initialized with a nonzero price");

        (uint256 tokenId,,,,,) = locker.positions(token);
        assertGt(tokenId, 0, "position should be registered in the locker");

        (,,, address hookCreator,, bool registered,) = hook.pools(poolId);
        assertTrue(registered);
        assertEq(hookCreator, creator);
    }
}
