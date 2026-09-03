// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckLauncherArc

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// Namespaced-storage-slot based -- safe to use directly here with no
// separate "Upgradeable" variant or initializer needed.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchRouting, Route, RouteShape, PoolKey, IV3SwapRouterNoDeadline} from "../common-arc/LaunchRouting.sol";
import {V4Math} from "../common-arc/V4Math.sol";

interface IDuckLauncherToken {
    function initDuckLauncher(string calldata name_, string calldata symbol_, string calldata metaURI_, address launcher_) external;
    function renounceOwnership() external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function setExempt(address account, bool exempt_) external;
}

interface IDuckLocker {
    function registerPosition(
        address token,
        uint256 tokenId,
        address token0,
        address token1,
        bytes32 poolId,
        address hook,
        address positionManager
    ) external;

    function registerPositionV3(
        address token,
        uint256 tokenId,
        address token0,
        address token1,
        address positionManager,
        address creator
    ) external;
}

interface IDuckHookV4 {
    function registerPool(PoolKey calldata key, address token, address creator, uint256 hookFeeBps) external;
}

interface IV4PositionManager {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IWETHLocal {
    function deposit() external payable;
}

// Uniswap V3 -- no hooks, no PoolKey/singleton, each pool its own contract
// instance rather than a shared singleton's slot. Only DuckLauncherArc ever
// uses these; DuckIncubationArc and DuckRaiseArc stay V4-only.
interface IV3PositionManager {
    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external payable returns (address pool);

    struct MintParams {
        address token0;
        address token1;
        uint24  fee;
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params)
        external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IV3PoolSlot0 {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool
    );
}


contract DuckLauncherArc is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard, LaunchRouting {

    error UnsupportedQuoteToken();
    error UnsupportedDex();
    error WrongFee();
    error ZeroAddress();
    error ZeroAmount();
    error CloneFailed();
    error PoolAlreadyExists();
    error InvalidTickRange();
    error VanityMismatch();
    error InstantBuyFailed();
    error HookRequired();
    error TimelockNotQueued();
    error TimelockNotExpired();
    error PendingValueMismatch();
    error InvalidHookFeeBps();
    error NativeNotSupportedOnV3();
    error HookFeeNotSupportedOnV3();

    uint16 public constant VANITY_SUFFIX = 0x8888;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    // 1% pool-level swap fee (LP-side), independent of the hook's own
    // separate sell-only skim.
    uint24 private constant FEE_TIER     = 10_000;
    int24  private constant MIN_TICK     = -887_200;
    int24  private constant MAX_TICK     =  887_200;
    int24  private constant TICK_SPACING =  200;

    uint256 private constant ACTION_MINT_POSITION = 0x02;
    uint256 private constant ACTION_SETTLE_PAIR   = 0x0d;

    struct DexConfig {
        address singleton; // V4 PoolManager -- unused (zero) for a V3 entry
        address permit2;   // V4 only (Permit2 approval); unused for V3
        address hook;      // V4 only; unused (zero) for V3 -- no hooks on V3
        address router;    // V3 SwapRouter for instantBuy; unused for V4
        bool    enabled;
        bool    isV3;
    }

    struct LaunchParams {
        string  name;
        string  symbol;
        string  metaURI;
        address feeWallet;                   // address(0) = msg.sender is the creator
        address positionManager;             // keys into `dexes`
        address quoteToken;
        bytes32 vanitySalt;
        uint256 launchMarketCap;             // creator-chosen virtual FDV, in the quote token's own raw units
        uint256 minQuoteOut;                // leg 1 slippage floor; 0 = no check
        uint256 minTokensOut;                // leg 2 slippage floor; 0 = no check
        uint256 hookFeeBps;                  // sell-fee rate: 0 (default 2%), 100, 200, 300, or 500
        bool    revertOnInstantBuyFailure;   // false = skip + refund instead of reverting
    }

    mapping(address => DexConfig) public dexes;
    mapping(address => bool)      public quoteTokens;

    address      public weth;
    address      public tokenImpl;
    IDuckLocker public locker;
    address      public platformWallet;
    uint256      public launchFee;

    // When set, a launch quoted against platformToken pays no launchFee.
    // address(0) disables it.
    address      public platformToken;

    // Only the upgrade authority is timelocked; every other admin action
    // stays instant onlyOwner.
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    bytes32 public constant TL_UPGRADE = keccak256("UPGRADE");

    mapping(bytes32 => uint256) public timelockExpiry;

    address private _pendingUpgradeImpl;

    event TimelockQueued(bytes32 indexed actionId, uint256 executeAfter);
    event TimelockExecuted(bytes32 indexed actionId);
    event TimelockCancelled(bytes32 indexed actionId);

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address indexed positionManager,
        address         quoteToken,
        address         hook,
        bytes32         poolId,
        uint256         tokenId
    );
    event DexAdded(address indexed positionManager, address singleton, address permit2, address hook);
    event DexDisabled(address indexed positionManager);
    event QuoteTokenAdded(address indexed token);
    event QuoteTokenDisabled(address indexed token);
    event PlatformWalletSet(address indexed wallet);
    event PlatformTokenSet(address indexed token);
    event LaunchFeeSet(uint256 fee);
    event TokenImplSet(address indexed tokenImpl);
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event InstantBuySkipped(address indexed token, uint256 refundedWei);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address weth_,
        address tokenImpl_,
        address locker_,
        address platformWallet_,
        address initialPositionMgr_,
        address initialSingleton_,
        address initialPermit2_,
        address initialHook_
    ) external initializer {
        if (weth_               == address(0)) revert ZeroAddress();
        if (tokenImpl_          == address(0)) revert ZeroAddress();
        if (locker_             == address(0)) revert ZeroAddress();
        if (initialPositionMgr_ == address(0)) revert ZeroAddress();
        if (initialSingleton_   == address(0)) revert ZeroAddress();
        if (initialPermit2_     == address(0)) revert ZeroAddress();
        if (platformWallet_     == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);

        weth            = weth_;
        tokenImpl       = tokenImpl_;
        locker          = IDuckLocker(locker_);
        platformWallet  = platformWallet_;
        launchFee       = 1e18; // 1 USDC -- Arc's native gas token, 18 decimals; adjustable later via setLaunchFee

        dexes[initialPositionMgr_] = DexConfig({
            singleton: initialSingleton_,
            permit2:   initialPermit2_,
            hook:      initialHook_,
            router:    address(0),
            enabled:   true,
            isV3:      false
        });
        emit DexAdded(initialPositionMgr_, initialSingleton_, initialPermit2_, initialHook_);

        quoteTokens[address(0)] = true;
        emit QuoteTokenAdded(address(0));

        // Deliberately NOT seeding any further default quote tokens/routes
        // here, unlike the Ink deployment this was copied from -- that list
        // was 15 real, verified Ink-chain token addresses. None of that
        // carries over to Arc; the owner adds real Arc-chain assets via
        // addQuoteToken/setRoutes once they're identified and verified.
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation != _pendingUpgradeImpl) revert PendingValueMismatch();
        _consumeAction(TL_UPGRADE);
    }

    function proposeUpgrade(address newImpl_) external onlyOwner {
        if (newImpl_ == address(0)) revert ZeroAddress();
        _pendingUpgradeImpl = newImpl_;
        _queueAction(TL_UPGRADE);
    }

    function _weth() internal view override returns (address) {
        return weth;
    }

    function setRoutes(address quoteToken_, Route[] calldata routes_) external onlyOwner {
        _setRoutes(quoteToken_, routes_);
    }

    function setPlatformWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        platformWallet = wallet;
        emit PlatformWalletSet(wallet);
    }

    // address(0) disables the launchFee waiver.
    function setPlatformToken(address token) external onlyOwner {
        platformToken = token;
        emit PlatformTokenSet(token);
    }

    function setTokenImpl(address tokenImpl_) external onlyOwner {
        if (tokenImpl_ == address(0)) revert ZeroAddress();
        tokenImpl = tokenImpl_;
        emit TokenImplSet(tokenImpl_);
    }

    function setLaunchFee(uint256 fee_) external onlyOwner {
        if (fee_ == 0) revert ZeroAmount();
        launchFee = fee_;
        emit LaunchFeeSet(fee_);
    }

    function addDex(address positionManager_, address singleton_, address permit2_, address hook_) external onlyOwner {
        if (positionManager_ == address(0)) revert ZeroAddress();
        if (singleton_        == address(0)) revert ZeroAddress();
        if (permit2_          == address(0)) revert ZeroAddress();
        dexes[positionManager_] = DexConfig({
            singleton: singleton_, permit2: permit2_, hook: hook_, router: address(0), enabled: true, isV3: false
        });
        emit DexAdded(positionManager_, singleton_, permit2_, hook_);
    }

    // V3 dex venue -- only DuckLauncherArc offers this; DuckIncubationArc and
    // DuckRaiseArc stay V4-only. `positionManager_` is V3's
    // NonfungiblePositionManager (doubles as the pool-creation entry point
    // via createAndInitializePoolIfNecessary); `router_` is the separate
    // SwapRouter used for the post-launch instant-buy swap.
    function addDexV3(address positionManager_, address router_) external onlyOwner {
        if (positionManager_ == address(0)) revert ZeroAddress();
        if (router_           == address(0)) revert ZeroAddress();
        dexes[positionManager_] = DexConfig({
            singleton: address(0), permit2: address(0), hook: address(0), router: router_, enabled: true, isV3: true
        });
        emit DexAdded(positionManager_, address(0), address(0), address(0));
    }

    function disableDex(address positionManager_) external onlyOwner {
        if (!dexes[positionManager_].enabled) revert UnsupportedDex();
        dexes[positionManager_].enabled = false;
        emit DexDisabled(positionManager_);
    }

    function addQuoteToken(address token_) external onlyOwner {
        quoteTokens[token_] = true;
        emit QuoteTokenAdded(token_);
    }

    function disableQuoteToken(address token_) external onlyOwner {
        if (!quoteTokens[token_]) revert UnsupportedQuoteToken();
        quoteTokens[token_] = false;
        emit QuoteTokenDisabled(token_);
    }

    function rescueETH(address to_, uint256 amount_) external onlyOwner {
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();
        (bool ok,) = to_.call{value: amount_}("");
        if (!ok) revert TransferFailed();
        emit ETHRescued(to_, amount_);
    }

    function rescueERC20(address token_, address to_, uint256 amount_) external onlyOwner {
        if (token_  == address(0)) revert ZeroAddress();
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();
        _safeTransfer(token_, to_, amount_);
        emit ERC20Rescued(token_, to_, amount_);
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        if (timelockExpiry[actionId] == 0) revert TimelockNotQueued();
        timelockExpiry[actionId] = 0;
        emit TimelockCancelled(actionId);
    }

    function _queueAction(bytes32 actionId) private {
        uint256 unlock = block.timestamp + TIMELOCK_DELAY;
        timelockExpiry[actionId] = unlock;
        emit TimelockQueued(actionId, unlock);
    }

    function _consumeAction(bytes32 actionId) private {
        uint256 expiry = timelockExpiry[actionId];
        if (expiry == 0) revert TimelockNotQueued();
        if (block.timestamp < expiry) revert TimelockNotExpired();
        timelockExpiry[actionId] = 0;
        emit TimelockExecuted(actionId);
    }

    function launch(LaunchParams calldata p) external payable nonReentrant
        returns (address token, bytes32 poolId, uint256 tokenId)
    {
        token = _deployAndInit(p.name, p.symbol, p.metaURI, p.vanitySalt);
        (poolId, tokenId) = _setupAndRegister(token, p);
    }

    function _setupAndRegister(
        address token,
        LaunchParams calldata p
    ) private returns (bytes32 poolId, uint256 tokenId) {
        DexConfig storage dex = dexes[p.positionManager];
        if (!dex.enabled) revert UnsupportedDex();
        if (!dex.isV3 && dex.hook == address(0)) revert HookRequired();
        // V3 has no hook, so hookFeeBps has nowhere to go -- require it be
        // explicitly left at 0 rather than silently ignoring a value the
        // creator set expecting it to apply.
        if (dex.isV3 && p.hookFeeBps != 0) revert HookFeeNotSupportedOnV3();
        // V3 pools are always ERC20/ERC20 -- there's no native-currency pool
        // concept like V4's address(0) currency, and Arc has no WETH to wrap
        // into for this venue (see LaunchRouting -- that wrap path is only
        // ever used for the *acquire-quote-token* step below, never for the
        // pool's own quote currency).
        if (dex.isV3 && p.quoteToken == address(0)) revert NativeNotSupportedOnV3();
        if (!quoteTokens[p.quoteToken]) revert UnsupportedQuoteToken();
        if (p.launchMarketCap == 0) revert ZeroAmount();
        bool feeWaived = platformToken != address(0) && p.quoteToken == platformToken;
        uint256 fee = feeWaived ? 0 : launchFee;
        if (msg.value < fee) revert WrongFee();
        if (!_isValidHookFeeBps(p.hookFeeBps)) revert InvalidHookFeeBps();

        if (fee > 0) {
            (bool feeOk,) = platformWallet.call{value: fee}("");
            if (!feeOk) revert TransferFailed();
        }
        uint256 extraEth = msg.value - fee;

        address creator = p.feeWallet == address(0) ? msg.sender : p.feeWallet;

        (address token0, address token1) = token < p.quoteToken ? (token, p.quoteToken) : (p.quoteToken, token);
        bool tokenIsCurrency1 = token > p.quoteToken;

        if (dex.isV3) {
            (poolId, tokenId) = _setupAndRegisterV3(token, token0, token1, tokenIsCurrency1, creator, p, dex, extraEth);
        } else {
            (poolId, tokenId) = _setupAndRegisterV4(token, token0, token1, tokenIsCurrency1, creator, p, dex, extraEth);
        }

        uint256 creatorTokens = IDuckLauncherToken(token).balanceOf(address(this));
        if (creatorTokens > 0) IDuckLauncherToken(token).transfer(msg.sender, creatorTokens);

        IDuckLauncherToken(token).renounceOwnership();

        emit TokenLaunched(token, creator, p.positionManager, p.quoteToken, dex.hook, poolId, tokenId);
    }

    function _setupAndRegisterV4(
        address token, address token0, address token1, bool tokenIsCurrency1,
        address creator, LaunchParams calldata p, DexConfig storage dex, uint256 extraEth
    ) private returns (bytes32 poolId, uint256 tokenId) {
        int24 tick;
        (tick, poolId) = _initPool(p.positionManager, dex.hook, token0, token1, token, p.quoteToken, creator, p.hookFeeBps, p.launchMarketCap);

        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _computeOneSidedLiquidity(tick, tokenIsCurrency1);

        IDuckLauncherToken(token).setExempt(dex.singleton, true);

        tokenId = _mintV4(p.positionManager, dex.hook, dex.permit2, token, token0, token1, tickLower, tickUpper, liquidity);
        locker.registerPosition(token, tokenId, token0, token1, poolId, dex.hook, p.positionManager);

        if (extraEth > 0) {
            try this.instantBuyV4{value: extraEth}(
                p.quoteToken, token, extraEth, p.minQuoteOut, p.minTokensOut,
                dex.singleton, dex.hook, msg.sender
            ) {} catch {
                if (p.revertOnInstantBuyFailure) revert InstantBuyFailed();
                (bool refundOk,) = msg.sender.call{value: extraEth}("");
                if (!refundOk) revert TransferFailed();
                emit InstantBuySkipped(token, extraEth);
            }
        }
    }

    function _setupAndRegisterV3(
        address token, address token0, address token1, bool tokenIsCurrency1,
        address creator, LaunchParams calldata p, DexConfig storage dex, uint256 extraEth
    ) private returns (bytes32 poolId, uint256 tokenId) {
        int24 tick;
        address pool;
        (tick, pool) = _initPoolV3(p.positionManager, token0, token1, token, p.quoteToken, p.launchMarketCap);
        poolId = bytes32(uint256(uint160(pool)));

        (int24 tickLower, int24 tickUpper) = _computeOneSidedTickRangeV3(tick, tokenIsCurrency1);

        // V3 holds pool reserves directly on the pool contract itself,
        // unlike V4's shared-singleton ledger -- so the pool address (not
        // the position manager or router) is what needs the antibot
        // max-wallet exemption to receive the full one-sided supply.
        IDuckLauncherToken(token).setExempt(pool, true);

        tokenId = _mintV3(p.positionManager, token, token0, token1, tickLower, tickUpper, tokenIsCurrency1);
        locker.registerPositionV3(token, tokenId, token0, token1, p.positionManager, creator);

        if (extraEth > 0) {
            try this.instantBuyV3{value: extraEth}(
                p.quoteToken, token, extraEth, p.minQuoteOut, p.minTokensOut, dex.router, msg.sender
            ) {} catch {
                if (p.revertOnInstantBuyFailure) revert InstantBuyFailed();
                (bool refundOk,) = msg.sender.call{value: extraEth}("");
                if (!refundOk) revert TransferFailed();
                emit InstantBuySkipped(token, extraEth);
            }
        }
    }

    receive() external payable {}

    function _initPool(
        address positionManager_,
        address hook_,
        address token0,
        address token1,
        address token,
        address quoteToken_,
        address creator,
        uint256 hookFeeBps_,
        uint256 launchMarketCap_
    ) private returns (int24 tick, bytes32 poolId) {
        PoolKey memory key = PoolKey({
            currency0:   token0,
            currency1:   token1,
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       hook_
        });
        tick = IV4PositionManager(positionManager_).initializePool(key, _computeSqrtPriceX96(token, quoteToken_, launchMarketCap_));
        if (tick == type(int24).max) revert PoolAlreadyExists();
        poolId = keccak256(abi.encode(key));
        IDuckHookV4(hook_).registerPool(key, token, creator, hookFeeBps_);
    }

    function _computeOneSidedLiquidity(int24 currentTick, bool tokenIsCurrency1)
        private pure returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        if (tokenIsCurrency1) {
            tickLower = MIN_TICK;
            tickUpper = _floorToTickSpacing(currentTick);
            if (tickLower >= tickUpper) revert InvalidTickRange();
            liquidity = V4Math.getLiquidityForAmount1(ROUTING_MIN_SQRT_PRICE, V4Math.getSqrtPriceAtTick(tickUpper), TOTAL_SUPPLY);
        } else {
            tickLower = _floorToTickSpacing(currentTick) + TICK_SPACING;
            tickUpper = MAX_TICK;
            if (tickLower >= tickUpper) revert InvalidTickRange();
            liquidity = V4Math.getLiquidityForAmount0(V4Math.getSqrtPriceAtTick(tickLower), ROUTING_MAX_SQRT_PRICE, TOTAL_SUPPLY);
        }
    }

    // Same one-sided tick bounds as V4 -- V3's mint() takes desired token
    // amounts directly rather than a pre-computed liquidity value (the
    // position manager derives liquidity internally), so there's no
    // liquidity return here.
    function _computeOneSidedTickRangeV3(int24 currentTick, bool tokenIsCurrency1)
        private pure returns (int24 tickLower, int24 tickUpper)
    {
        if (tokenIsCurrency1) {
            tickLower = MIN_TICK;
            tickUpper = _floorToTickSpacing(currentTick);
        } else {
            tickLower = _floorToTickSpacing(currentTick) + TICK_SPACING;
            tickUpper = MAX_TICK;
        }
        if (tickLower >= tickUpper) revert InvalidTickRange();
    }

    // createAndInitializePoolIfNecessary doesn't return the tick directly
    // (unlike V4's initializePool) -- read it back from the pool's own
    // slot0() once initialized. Reverts key mismatches too, so PoolKey's
    // stronger deterministic-poolId guarantee doesn't carry over to V3
    // (each pool is its own contract instance; poolId here is just the
    // pool address itself, reported to the locker/subgraph for identity).
    function _initPoolV3(
        address positionManager_, address token0, address token1,
        address token, address quoteToken_, uint256 launchMarketCap_
    ) private returns (int24 tick, address pool) {
        uint160 sqrtPriceX96 = _computeSqrtPriceX96(token, quoteToken_, launchMarketCap_);
        pool = IV3PositionManager(positionManager_).createAndInitializePoolIfNecessary(token0, token1, FEE_TIER, sqrtPriceX96);
        (, tick,,,,,) = IV3PoolSlot0(pool).slot0();
    }

    function instantBuyV4(
        address quoteToken_,
        address token_,
        uint256 extraEth_,
        uint256 minQuoteOut_,
        uint256 minTokensOut_,
        address singleton_,
        address hook_,
        address recipient_
    ) external payable {
        if (msg.sender != address(this)) revert Unauthorized();

        uint256 quoteAmount = extraEth_;
        if (quoteToken_ != address(0)) {
            bool ok;
            (quoteAmount, ok) = _acquireQuoteToken(quoteToken_, extraEth_, minQuoteOut_, address(this));
            if (!ok) revert InstantBuyFailed();
        }

        uint256 tokensOut = _executeV4Swap(singleton_, hook_, FEE_TIER, TICK_SPACING, quoteToken_, token_, quoteAmount, minTokensOut_, recipient_);
        if (tokensOut < minTokensOut_) revert InstantBuyFailed();
    }

    // V3 quote assets are always a real ERC20 (see NativeNotSupportedOnV3),
    // so extraEth_ (native) always needs converting via the same
    // native->quote routing table V4 launches use -- venue only changes how
    // the resulting quote amount actually buys the new token.
    function instantBuyV3(
        address quoteToken_,
        address token_,
        uint256 extraEth_,
        uint256 minQuoteOut_,
        uint256 minTokensOut_,
        address router_,
        address recipient_
    ) external payable {
        if (msg.sender != address(this)) revert Unauthorized();

        (uint256 quoteAmount, bool ok) = _acquireQuoteToken(quoteToken_, extraEth_, minQuoteOut_, address(this));
        if (!ok) revert InstantBuyFailed();

        uint256 tokensOut = _executeV3Swap(router_, quoteToken_, token_, quoteAmount, minTokensOut_, recipient_);
        if (tokensOut < minTokensOut_) revert InstantBuyFailed();
    }

    function _executeV3Swap(
        address router_, address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minOut_, address recipient_
    ) private returns (uint256 amountOut) {
        _safeApprove(tokenIn_, router_, amountIn_);
        // Arc's swapRouter02Address is SwapRouter02 -- no `deadline` field,
        // unlike the classic ISwapRouter this platform's routing table
        // otherwise supports (see LaunchRouting's routerNoDeadline flag).
        amountOut = IV3SwapRouterNoDeadline(router_).exactInputSingle(IV3SwapRouterNoDeadline.ExactInputSingleParams({
            tokenIn:           tokenIn_,
            tokenOut:          tokenOut_,
            fee:               FEE_TIER,
            recipient:         recipient_,
            amountIn:          amountIn_,
            amountOutMinimum:  minOut_,
            sqrtPriceLimitX96: 0
        }));
    }

    function _mintV4(
        address positionManager_,
        address hook_,
        address permit2_,
        address token,
        address token0,
        address token1,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity
    ) private returns (uint256 tokenId) {
        _safeApprove(token, permit2_, TOTAL_SUPPLY);
        IAllowanceTransfer(permit2_).approve(token, positionManager_, uint160(TOTAL_SUPPLY), uint48(block.timestamp + 300));

        PoolKey memory key = PoolKey({
            currency0:   token0,
            currency1:   token1,
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       hook_
        });

        bytes memory actions = abi.encodePacked(uint8(ACTION_MINT_POSITION), uint8(ACTION_SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tickLower, tickUpper, uint256(liquidity), uint128(TOTAL_SUPPLY), uint128(TOTAL_SUPPLY), address(locker), bytes(""));
        params[1] = abi.encode(token0, token1);

        tokenId = IV4PositionManager(positionManager_).nextTokenId();
        IV4PositionManager(positionManager_).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    // One-sided: only the project-token side ever has a nonzero desired
    // amount, so only that side needs an approval -- the position manager
    // never touches the quote-side token since its desired amount is 0.
    // Minted straight to the locker, same as V4.
    function _mintV3(
        address positionManager_, address token, address token0, address token1,
        int24 tickLower, int24 tickUpper, bool tokenIsCurrency1
    ) private returns (uint256 tokenId) {
        _safeApprove(token, positionManager_, TOTAL_SUPPLY);

        (uint256 amount0Desired, uint256 amount1Desired) = tokenIsCurrency1
            ? (uint256(0), TOTAL_SUPPLY)
            : (TOTAL_SUPPLY, uint256(0));

        (tokenId,,,) = IV3PositionManager(positionManager_).mint(IV3PositionManager.MintParams({
            token0:          token0,
            token1:          token1,
            fee:             FEE_TIER,
            tickLower:       tickLower,
            tickUpper:       tickUpper,
            amount0Desired:  amount0Desired,
            amount1Desired:  amount1Desired,
            amount0Min:      0,
            amount1Min:      0,
            recipient:       address(locker),
            deadline:        block.timestamp
        }));
    }

    function _deployAndInit(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_,
        bytes32         vanitySalt_
    ) private returns (address token) {
        bytes32 salt = keccak256(abi.encode(msg.sender, vanitySalt_));
        token = _clone(tokenImpl, salt);
        if (uint16(uint160(token)) != VANITY_SUFFIX) revert VanityMismatch();
        IDuckLauncherToken(token).initDuckLauncher(name_, symbol_, metaURI_, address(this));
    }

    function _computeSqrtPriceX96(address tokenAddr, address quoteToken_, uint256 launchMarketCap_)
        private pure returns (uint160)
    {
        if (tokenAddr < quoteToken_) {
            return V4Math.sqrtPriceX96FromAmounts(TOTAL_SUPPLY, launchMarketCap_);
        } else {
            return V4Math.sqrtPriceX96FromAmounts(launchMarketCap_, TOTAL_SUPPLY);
        }
    }

    function _floorToTickSpacing(int24 tick) private pure returns (int24) {
        int24 compressed = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) compressed--;
        return compressed * TICK_SPACING;
    }

    // Must match DuckHookV4Arc's own allowed set exactly.
    function _isValidHookFeeBps(uint256 bps) private pure returns (bool) {
        return bps == 0 || bps == 100 || bps == 200 || bps == 300 || bps == 500;
    }

    function _clone(address impl, bytes32 salt) private returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0)) revert CloneFailed();
    }

}
