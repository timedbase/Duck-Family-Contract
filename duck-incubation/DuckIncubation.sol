// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckIncubation

import "./interfaces/IDuckIncubationToken.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {LaunchRouting, Route, RouteShape, PoolKey} from "common-contracts/LaunchRouting.sol";
import {V4Math} from "common-contracts/V4Math.sol";
import {V4Minting} from "common-contracts/V4Minting.sol";
import {DuckIncubationMigration} from "common-contracts/DuckIncubationMigration.sol";
import {DuckIncubationBuying} from "common-contracts/DuckIncubationBuying.sol";
import {TokenConfig, FeeSplit} from "common-contracts/DuckIncubationTypes.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ITokenInit {
    function initForLaunchpad(
        string memory name_, string memory symbol_, uint256 totalSupply_,
        address launchManager_, address tokenOwner_, string memory metaURI_
    ) external;
}

contract DuckIncubation is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, LaunchRouting {

    struct Alloc {
        uint256 supply;
        uint256 liqTokens;
        uint256 bcTokens;
    }

    struct BaseParams {
        string       name;
        string       symbol;
        uint256      totalSupply;            // 18-decimal; bounded by minSupply/maxSupply
        uint256      curveBps;
        uint256      liquidityBps;
        address      quoteToken;             // address(0) = native currency, else a whitelisted ERC20
        uint256      startVirtualQuote;       // raw quote-asset units, creator-chosen
        uint256      migrationTargetQuote;    // raw quote-asset units, must exceed startVirtualQuote
        uint256      earlyBuyAmount;          // ERC20 quote only: pulled via transferFrom for an immediate first buy
        uint256      hookFeeBps;              // post-migration sell fee: 0 (default 2%), 100, 200, 300, or 500
        bool         enableAntibot;
        uint256      antibotBlocks;
        string       metaURI;
        bytes32      salt;
    }

    // A creator may split their claimed curve fee across up to MAX_FEE_SPLITS
    // wallets; empty (the default) means 100% to the creator.
    uint256 private constant BPS_DENOM          = 10_000;
    uint256 private constant CURVE_FEE_BPS      =    100; // 1%, fixed -- see claimCurveFee
    uint256 public constant MAX_FEE_SPLITS      =      5;
    uint256 private constant ANTIBOT_MIN_BLOCKS =     10;
    uint256 private constant ANTIBOT_MAX_BLOCKS =    199;
    address private constant DEAD               = 0x000000000000000000000000000000000000dEaD;

    uint24 private constant V4_FEE_TIER  = 10_000;  // 1% tier, matches the other launcher families
    int24  private constant V4_TICK_SPACING = 200;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    // Only the upgrade authority is timelocked; every other admin action
    // (DEX config, fees, recipients, rescue) stays instant onlyOwner.
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    bytes32 public constant TL_UPGRADE = keccak256("UPGRADE");

    // ── Admin ─────────────────────────────────────────────────────────
    address public tokenImpl;
    address public locker;

    // ── DEX config (Uniswap V4) ───────────────────────────────────────
    address public weth;
    address public v4PositionManager;
    address public v4Singleton; // PoolManager
    address public v4Permit2;
    address public v4Hook;

    // ── Quote assets ──────────────────────────────────────────────────
    // Native currency (address(0)) is always allowed and not tracked here.
    mapping(address => bool) public quoteTokenAllowed;

    // ── Allocation guardrails ─────────────────────────────────────────
    uint256 public minCurveBps;
    uint256 public minLiquidityBps;

    // ── Supply guardrails ─────────────────────────────────────────────
    uint256 public minSupply;
    uint256 public maxSupply;

    // ── Fees ──────────────────────────────────────────────────────────
    address public platformWallet;
    uint256 public creationFee;   // always native, regardless of a token's quote asset

    // When set, a token quoted against platformToken pays no creationFee,
    // and the platform's half of the accrued curve fee buys back and burns
    // the token instead of paying out (see claimCurveFee/_buyAndBurn).
    address public platformToken;

    // ── Token registry ────────────────────────────────────────────────
    // getToken() replaces the auto-generated getter, which exceeds the
    // EVM's 16-slot stack limit for this struct without viaIR.
    mapping(address => TokenConfig) internal tokens;
    address[] public allTokens;
    mapping(address => address[]) private _tokensByCreator;
    mapping(address => FeeSplit[]) private _feeSplits;

    uint256 private _totalRaisedETH;                       // sum across active native-quoted pools
    mapping(address => uint256) private _totalRaisedERC;   // per ERC20 quote asset
    uint256 private _totalAccruedFeeETH;                    // unclaimed curve fees, native-quoted
    mapping(address => uint256) private _totalAccruedFeeERC;
    uint256 private _status;

    mapping(bytes32 => uint256) public timelockExpiry;

    address private _pendingUpgradeImpl;

    error Reentrancy();
    error NotSelf();
    error PendingValueMismatch();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientCreationFee(uint256 required, uint256 provided);
    error CloneFailed();
    error VanityAddressRequired();
    error NativeTransferFailed();
    error NativeNotAccepted();
    error DeadlineExpired();
    error TimelockNotQueued();
    error TimelockNotExpired();
    error UnknownToken();
    error AlreadyMigrated();
    error ExceedsSoldSupply();
    error LiquidityReserveViolation();
    error InsufficientPoolQuote();
    error SlippageTooLittleQuote();
    error SlippageTooFewTokens();
    error MigrationTargetNotReached();
    error ActivePool();
    error AntibotBlocksOutOfRange();
    error InvalidAllocation();
    error InvalidMarketCaps();
    error InvalidSupply();
    error MigrationPending();
    error InsufficientContractBalance();
    error QuoteTokenNotAllowed();
    error InvalidHookFeeBps();
    error NotMigrated();
    error NotCreator();
    error TooManyFeeSplits();
    error InvalidFeeSplitBps();
    error NativeQuoteNoSwapNeeded();
    error RouteUnavailable();

    event TokenCreated(
        address indexed token,
        address indexed creator,
        address         quoteToken,
        uint256         totalSupply,
        uint256         virtualQuote,
        uint256         migrationTarget,
        bool            antibotEnabled,
        uint256         tradingBlock
    );
    event TokenRegistered(
        address indexed token,
        address indexed creator,
        address         quoteToken,
        uint256         totalSupply,
        uint256         virtualQuote,
        uint256         migrationTarget
    );
    event TokenBought(
        address indexed token, address indexed buyer,
        uint256 quoteIn, uint256 tokensOut, uint256 tokensToDead, uint256 raisedQuote
    );
    event TokenSold(
        address indexed token, address indexed seller,
        uint256 tokensIn, uint256 quoteOut, uint256 raisedQuote
    );
    event TokenMigrated(
        address indexed token, bytes32 poolId, uint256 liquidityQuote, uint256 liquidityTokens
    );
    event EmergencyMigrated(
        address indexed token, address indexed to, uint256 quoteAmount, uint256 tokenAmount
    );
    event MigrationFailed(address indexed token);
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event DexConfigUpdated(address positionManager, address singleton, address permit2, address hook);
    event QuoteTokenUpdated(address indexed token, bool allowed);
    event AllocationBoundsUpdated(uint256 minCurveBps, uint256 minLiquidityBps);
    event SupplyBoundsUpdated(uint256 minSupply, uint256 maxSupply);
    event PlatformWalletUpdated(address recipient);
    event PlatformTokenUpdated(address token);
    event CurveFeeClaimed(address indexed token, address indexed creator, uint256 creatorAmount, uint256 platformAmount);
    event FeeSplitsUpdated(address indexed token, FeeSplit[] splits);
    event LockerUpdated(address indexed prev, address indexed next);
    event TimelockQueued(bytes32 indexed actionId, uint256 executeAfter);
    event TimelockExecuted(bytes32 indexed actionId);
    event TimelockCancelled(bytes32 indexed actionId);
    event ETHRescued(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ImplUpdated(string implType, address indexed prev, address indexed next);

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address weth_,
        address v4PositionManager_,
        address v4Singleton_,
        address v4Permit2_,
        address v4Hook_,
        address platformWallet_,
        address tokenImpl_,
        address locker_
    ) external initializer {
        if (weth_               == address(0)) revert ZeroAddress();
        if (v4PositionManager_  == address(0)) revert ZeroAddress();
        if (v4Singleton_        == address(0)) revert ZeroAddress();
        if (v4Permit2_          == address(0)) revert ZeroAddress();
        if (platformWallet_       == address(0)) revert ZeroAddress();
        if (tokenImpl_          == address(0)) revert ZeroAddress();
        if (locker_             == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __Ownable2Step_init();

        weth              = weth_;
        v4PositionManager = v4PositionManager_;
        v4Singleton       = v4Singleton_;
        v4Permit2         = v4Permit2_;
        v4Hook            = v4Hook_;
        platformWallet      = platformWallet_;
        tokenImpl         = tokenImpl_;
        locker            = locker_;
        creationFee       = 0.0005 ether;
        _status           = _NOT_ENTERED;

        minCurveBps     = 3000; // 30% minimum on the bonding curve
        minLiquidityBps = 1000; // 10% minimum DEX liquidity at migration
        minSupply       = 1e18;
        maxSupply       = 999_000_000_000_000e18;

        _seedDefaultQuoteTokens();
        _seedDefaultRoutes(v4Singleton_);
    }

    // Of the 15 default quote tokens, only USDC and USDT0 have real Ink
    // liquidity today, and it sits in the hookless V4 pool paired against
    // native ETH specifically (not WETH). Seeds buyWithNative's routes for
    // just those two; the rest stay whitelisted for direct trading only.
    function _seedDefaultRoutes(address v4Singleton_) private {
        (address usdc, address usdt0) = DuckIncubationMigration.seedDefaultRoutes(routes, v4Singleton_);
        emit RoutesSet(usdc, 1);
        emit RoutesSet(usdt0, 1);
    }

    function _seedDefaultQuoteTokens() private {
        address[15] memory defaults = DuckIncubationMigration.seedDefaultQuoteTokens(quoteTokenAllowed);
        for (uint256 i; i < defaults.length; ++i) {
            emit QuoteTokenUpdated(defaults[i], true);
        }
    }

    // Bound to the specific proposed implementation -- re-proposing a
    // different address resets the delay.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation != _pendingUpgradeImpl) revert PendingValueMismatch();
        _consumeAction(TL_UPGRADE);
    }

    function proposeUpgrade(address newImpl_) external onlyOwner {
        if (newImpl_ == address(0)) revert ZeroAddress();
        _pendingUpgradeImpl = newImpl_;
        _queueAction(TL_UPGRADE);
    }

    // ── Token creation ────────────────────────────────────────────────

    function createToken(BaseParams memory p) external payable nonReentrant returns (address token) {
        if (p.quoteToken != address(0) && !quoteTokenAllowed[p.quoteToken]) revert QuoteTokenNotAllowed();
        if (!_isValidHookFeeBps(p.hookFeeBps)) revert InvalidHookFeeBps();
        uint256 earlyBuy = _collectCreationFee(p.quoteToken, p.earlyBuyAmount);
        token = DuckIncubationBuying.cloneCreate2(tokenImpl, msg.sender, p.salt);

        Alloc memory a = _computeAlloc(p.totalSupply, p.curveBps, p.liquidityBps);
        (uint256 vQuote, uint256 migTarget) = _computeQuoteTargets(p.startVirtualQuote, p.migrationTargetQuote);

        ITokenInit(token).initForLaunchpad(
            p.name, p.symbol, a.supply, address(this), msg.sender, p.metaURI
        );
        uint256 tradingBlock_ = _registerToken(
            token, msg.sender, p.quoteToken, a, vQuote, migTarget, p.enableAntibot, p.antibotBlocks, p.hookFeeBps
        );
        emit TokenCreated(token, msg.sender, p.quoteToken, a.supply, vQuote, migTarget, p.enableAntibot, tradingBlock_);

        if (earlyBuy > 0) {
            if (p.quoteToken != address(0)) {
                IERC20Min(p.quoteToken).transferFrom(msg.sender, address(this), earlyBuy);
            }
            _executeBuy(token, msg.sender, earlyBuy, 0, true);
        }
    }

    // ── Trading ───────────────────────────────────────────────────────

    function buy(address token_, uint256 amountIn, uint256 minOut, uint256 deadline)
        external payable nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();

        uint256 quoteIn;
        if (tc.quoteToken == address(0)) {
            if (msg.value == 0) revert ZeroAmount();
            quoteIn = msg.value;
        } else {
            if (msg.value != 0) revert NativeNotAccepted();
            if (amountIn == 0) revert ZeroAmount();
            IERC20Min(tc.quoteToken).transferFrom(msg.sender, address(this), amountIn);
            quoteIn = amountIn;
        }
        _executeBuy(token_, msg.sender, quoteIn, minOut, false);
    }

    // Lets a buyer who only holds native currency buy an ERC20-quoted
    // token: the incoming value is routed into the quote asset first (see
    // LaunchRouting/setRoutes), then bought exactly as buy() would.
    function buyWithNative(address token_, uint256 minQuoteOut, uint256 minOut, uint256 deadline)
        external payable nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.quoteToken == address(0)) revert NativeQuoteNoSwapNeeded();
        if (msg.value == 0) revert ZeroAmount();

        (uint256 quoteIn, bool ok) = _acquireQuoteToken(tc.quoteToken, msg.value, minQuoteOut, address(this));
        if (!ok) revert RouteUnavailable();

        _executeBuy(token_, msg.sender, quoteIn, minOut, false);
    }

    function sell(address token_, uint256 amountIn, uint256 minQuoteOut, uint256 deadline)
        external nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();
        IDuckIncubationToken(token_).transferFrom(msg.sender, address(this), amountIn);
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0))   revert UnknownToken();
        if (tc.migrated)              revert AlreadyMigrated();
        if (tc.migrationPending)      revert MigrationPending();
        // liquidityTokens are never part of the curve pool -- only
        // previously-bought tokens can be sold back.
        if (amountIn > tc.bcTokensSold) revert ExceedsSoldSupply();

        uint256 netQuote;
        uint256 raisedAfter;
        (_totalRaisedETH, _totalAccruedFeeETH, netQuote, raisedAfter) = DuckIncubationBuying.executeSell(
            tc, msg.sender, amountIn, minQuoteOut, _totalRaisedETH, _totalRaisedERC, _totalAccruedFeeETH, _totalAccruedFeeERC
        );
        emit TokenSold(token_, msg.sender, amountIn, netQuote, raisedAfter);
    }

    function migrate(address token_) external nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (!tc.migrationPending)   revert MigrationTargetNotReached();
        _doMigrate(tc, token_);
    }

    // 1% curve-trading fee accrues throughout the curve phase but only
    // becomes claimable post-migration, split 50/50 creator/platform.
    // Permissionless -- there's no discretion in the split.
    function claimCurveFee(address token_) external nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (!tc.migrated) revert NotMigrated();

        uint256 amount = tc.accruedFee;
        if (amount == 0) revert ZeroAmount();
        tc.accruedFee = 0;

        uint256 creatorCut;
        uint256 platformCut;
        bool needsBuyAndBurn;
        (_totalAccruedFeeETH, creatorCut, platformCut, needsBuyAndBurn) = DuckIncubationBuying.settleCurveFee(
            tc, tc.creator, amount, _totalAccruedFeeETH, _totalAccruedFeeERC,
            _feeSplits[token_], platformToken, platformWallet
        );

        if (needsBuyAndBurn) _buyAndBurn(tc, token_, platformCut);

        emit CurveFeeClaimed(token_, tc.creator, creatorCut, platformCut);
    }

    // Swaps the platform's share of the accrued fee for the launched token
    // via its own migrated pool and burns the proceeds -- the mechanism
    // behind platformToken's "platform takes zero fee" deal.
    function _buyAndBurn(TokenConfig storage tc, address token_, uint256 amountIn) private {
        if (amountIn == 0) return;
        uint256 boughtBack = _executeV4Swap(
            tc.pair, v4Hook, V4_FEE_TIER, V4_TICK_SPACING, tc.quoteToken, token_, amountIn, 0, address(this)
        );
        if (boughtBack > 0) IDuckIncubationToken(token_).transfer(DEAD, boughtBack);
    }

    // Only a token's own creator may configure where their claimed curve
    // fee goes. Empty splits_ resets to 100% direct to the creator.
    function setFeeSplits(address token_, FeeSplit[] calldata splits_) external {
        DuckIncubationBuying.setFeeSplits(_feeSplits[token_], msg.sender, tokens[token_].creator, splits_, MAX_FEE_SPLITS);
        emit FeeSplitsUpdated(token_, splits_);
    }

    function getFeeSplits(address token_) external view returns (FeeSplit[] memory) {
        return _feeSplits[token_];
    }

    // Entry point for the try/catch in DuckIncubationBuying's same-tx
    // migration retry. Not nonReentrant so it can run while the outer
    // buy() still holds _status = _ENTERED; only callable by address(this).
    function _tryMigrateExternal(address token_) external {
        if (msg.sender != address(this)) revert NotSelf();
        TokenConfig storage tc = tokens[token_];
        _doMigrate(tc, token_);
    }

    // Fallback for when a V4 pool has already been initialized at the
    // predicted pool key (PoolAlreadyExists()) -- the owner receives the
    // raised quote and liquidity tokens to provision liquidity manually,
    // while the rest of the token's accounting closes out normally.
    function emergencyMigrate(address token_) external onlyOwner nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (!tc.migrationPending)   revert MigrationTargetNotReached();

        address to = owner();
        uint256 migrationAmount;
        uint256 liqTokens;
        (_totalRaisedETH, migrationAmount, liqTokens) = DuckIncubationMigration.emergencyMigrate(
            tc, token_, to, _totalRaisedETH, _totalRaisedERC
        );

        emit EmergencyMigrated(token_, to, migrationAmount, liqTokens);
    }

    // ── Governance ────────────────────────────────────────────────────

    function setCreationFee(uint256 fee_) external onlyOwner {
        emit CreationFeeUpdated(creationFee, fee_);
        creationFee = fee_;
    }

    function setRoutes(address quoteToken_, Route[] calldata routes_) external onlyOwner {
        _setRoutes(quoteToken_, routes_);
    }

    function setQuoteTokenAllowed(address token_, bool allowed_) external onlyOwner {
        if (token_ == address(0)) revert ZeroAddress();
        quoteTokenAllowed[token_] = allowed_;
        emit QuoteTokenUpdated(token_, allowed_);
    }

    function setAllocationBounds(uint256 minCurveBps_, uint256 minLiquidityBps_) external onlyOwner {
        if (minCurveBps_ + minLiquidityBps_ > BPS_DENOM) revert InvalidAllocation();
        minCurveBps     = minCurveBps_;
        minLiquidityBps = minLiquidityBps_;
        emit AllocationBoundsUpdated(minCurveBps_, minLiquidityBps_);
    }

    function setSupplyBounds(uint256 minSupply_, uint256 maxSupply_) external onlyOwner {
        if (minSupply_ == 0 || minSupply_ > maxSupply_) revert InvalidSupply();
        minSupply = minSupply_;
        maxSupply = maxSupply_;
        emit SupplyBoundsUpdated(minSupply_, maxSupply_);
    }

    function setTokenImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        emit ImplUpdated("token", tokenImpl, impl_);
        tokenImpl = impl_;
    }

    function setLocker(address locker_) external onlyOwner {
        if (locker_ == address(0)) revert ZeroAddress();
        emit LockerUpdated(locker, locker_);
        locker = locker_;
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        if (timelockExpiry[actionId] == 0) revert TimelockNotQueued();
        timelockExpiry[actionId] = 0;
        emit TimelockCancelled(actionId);
    }

    function setDexConfig(address positionManager_, address singleton_, address permit2_, address hook_) external onlyOwner {
        if (positionManager_ == address(0)) revert ZeroAddress();
        if (singleton_        == address(0)) revert ZeroAddress();
        if (permit2_          == address(0)) revert ZeroAddress();
        v4PositionManager = positionManager_;
        v4Singleton       = singleton_;
        v4Permit2         = permit2_;
        v4Hook            = hook_;
        emit DexConfigUpdated(positionManager_, singleton_, permit2_, hook_);
    }

    function setPlatformWallet(address wallet_) external onlyOwner {
        if (wallet_ == address(0)) revert ZeroAddress();
        platformWallet = wallet_;
        emit PlatformWalletUpdated(wallet_);
    }

    // address(0) disables the fee-waiver/buyback mechanism entirely.
    function setPlatformToken(address token_) external onlyOwner {
        platformToken = token_;
        emit PlatformTokenUpdated(token_);
    }

    function _weth() internal view override returns (address) {
        return weth;
    }

    // ── Rescue ────────────────────────────────────────────────────────

    function rescueETH(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = DuckIncubationBuying.rescueETH(_totalRaisedETH, _totalAccruedFeeETH, to);
        emit ETHRescued(to, amount);
    }

    function rescueToken(address token_, address to) external onlyOwner nonReentrant {
        if (token_ == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        TokenConfig storage tc = tokens[token_];
        uint256 rescuable = DuckIncubationBuying.rescueToken(
            tc, token_, to, _totalRaisedERC[token_], _totalAccruedFeeERC[token_]
        );
        emit TokenRescued(token_, to, rescuable);
    }

    // ── Internal: creation / allocation ──────────────────────────────

    function _registerToken(
        address token_,
        address creator_,
        address quoteToken_,
        Alloc memory a,
        uint256 virtualQuote_,
        uint256 migrationTarget_,
        bool enableAntibot_,
        uint256 antibotBlocks_,
        uint256 hookFeeBps_
    ) private returns (uint256 tradingBlock_) {
        TokenConfig storage tc = tokens[token_];
        tradingBlock_ = DuckIncubationMigration.registerToken(
            tc, allTokens, _tokensByCreator,
            token_, creator_, quoteToken_, a.supply, a.liqTokens, a.bcTokens,
            virtualQuote_, migrationTarget_, enableAntibot_, antibotBlocks_, hookFeeBps_
        );

        emit TokenRegistered(token_, creator_, quoteToken_, a.supply, virtualQuote_, migrationTarget_);
    }

    function _computeAlloc(
        uint256 supply, uint256 curveBps, uint256 liquidityBps
    ) private view returns (Alloc memory a) {
        if (supply < minSupply || supply > maxSupply) revert InvalidSupply();
        if (curveBps + liquidityBps != BPS_DENOM) revert InvalidAllocation();
        if (curveBps     < minCurveBps)     revert InvalidAllocation();
        if (liquidityBps < minLiquidityBps) revert InvalidAllocation();

        a.supply    = supply;
        a.liqTokens = (supply * liquidityBps) / BPS_DENOM;
        a.bcTokens  = supply - a.liqTokens;
    }

    function _computeQuoteTargets(uint256 startVirtualQuote_, uint256 migrationTargetQuote_)
        private pure returns (uint256 virtualQuote, uint256 migrationTarget)
    {
        if (startVirtualQuote_ == 0 || migrationTargetQuote_ <= startVirtualQuote_) revert InvalidMarketCaps();
        virtualQuote    = startVirtualQuote_;
        migrationTarget = migrationTargetQuote_;
    }

    // Native quote: msg.value must cover the flat fee, excess is an
    // immediate first buy. ERC20 quote: msg.value must exactly equal the
    // fee, and earlyBuyAmount_ (pulled separately via transferFrom) is the
    // first buy. Waived entirely for platformToken-quoted launches.
    function _collectCreationFee(address quoteToken_, uint256 earlyBuyAmount_)
        private returns (uint256 earlyBuy)
    {
        bool waived = platformToken != address(0) && quoteToken_ == platformToken;
        uint256 cf = waived ? 0 : creationFee;
        if (quoteToken_ == address(0)) {
            if (msg.value < cf) revert InsufficientCreationFee(cf, msg.value);
            earlyBuy = msg.value - cf;
        } else {
            if (msg.value != cf) revert InsufficientCreationFee(cf, msg.value);
            earlyBuy = earlyBuyAmount_;
        }
        if (cf > 0) _safeSendNative(platformWallet, cf);
    }

    function _isValidHookFeeBps(uint256 bps) private pure returns (bool) {
        return bps == 0 || bps == 100 || bps == 200 || bps == 300 || bps == 500;
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

    // ── Internal: buy/sell/migrate ────────────────────────────────────

    // Pricing, aggregate accounting, antibot burn, payout, and the same-tx
    // migration retry live in the external DuckIncubationBuying library
    // (moved out to fit under EIP-170's 24,576-byte contract size limit).
    function _executeBuy(
        address token_, address buyer, uint256 quoteIn, uint256 minOut, bool skipAntibot
    ) private {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0))  revert UnknownToken();
        if (tc.migrated)             revert AlreadyMigrated();
        if (tc.migrationPending)     revert MigrationPending();

        uint256 tokensOut;
        uint256 netQuoteIn;
        uint256 tokensToDead;
        bool migrationAttemptFailed;
        (_totalRaisedETH, _totalAccruedFeeETH, tokensOut, netQuoteIn, tokensToDead, migrationAttemptFailed) =
            DuckIncubationBuying.executeBuy(
                tc, token_, buyer, quoteIn, minOut, skipAntibot,
                _totalRaisedETH, _totalRaisedERC, _totalAccruedFeeETH, _totalAccruedFeeERC
            );

        emit TokenBought(token_, buyer, netQuoteIn, tokensOut, tokensToDead, tc.raisedQuote);
        if (migrationAttemptFailed) emit MigrationFailed(token_);
    }

    // Migrates into a fresh Uniswap V4 1% pool, full-range, hook-gated,
    // minted to and locked permanently in the shared DuckLocker (moved to
    // the external DuckIncubationMigration library for the same size
    // reason as _executeBuy above).
    function _doMigrate(TokenConfig storage tc, address token_) private {
        uint256 migrationAmount = tc.raisedQuote;
        uint256 liqTokens       = tc.liquidityTokens;

        bytes32 poolId;
        (_totalRaisedETH, poolId) = DuckIncubationMigration.migrate(
            tc, token_, _totalRaisedETH, _totalRaisedERC,
            DuckIncubationMigration.MigrationConfig({
                locker:          locker,
                hook:            v4Hook,
                weth:            weth,
                positionManager: v4PositionManager,
                permit2:         v4Permit2,
                singleton:       v4Singleton,
                fee:             V4_FEE_TIER,
                tickSpacing:     V4_TICK_SPACING
            })
        );

        emit TokenMigrated(token_, poolId, migrationAmount, liqTokens);
    }

    function _safeSendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    // ── Views ─────────────────────────────────────────────────────────

    function getAmountOut(address token_, uint256 quoteIn)
        external view
        returns (uint256 tokensOut, uint256 feeQuote)
    {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0) || tc.migrated) return (0, 0);

        uint256 poolQuote   = tc.virtualQuote + tc.raisedQuote;
        uint256 poolTokens  = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 grossNeeded = ((tc.migrationTarget - tc.raisedQuote) * BPS_DENOM + (BPS_DENOM - CURVE_FEE_BPS) - 1)
              / (BPS_DENOM - CURVE_FEE_BPS);

        if (quoteIn >= grossNeeded) {
            feeQuote  = (grossNeeded * CURVE_FEE_BPS) / BPS_DENOM;
            tokensOut = poolTokens;
        } else {
            feeQuote         = (quoteIn * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
            uint256 netQuote = quoteIn - feeQuote;
            tokensOut = poolTokens - ((tc.k + poolQuote + netQuote - 1) / (poolQuote + netQuote));
        }
    }

    function getAmountOutSell(address token_, uint256 tokensIn)
        external view
        returns (uint256 quoteOut, uint256 feeQuote)
    {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0) || tc.migrated || tc.bcTokensSold < tokensIn) return (0, 0);
        uint256 poolQuote    = tc.virtualQuote + tc.raisedQuote;
        uint256 poolToks     = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 newPoolToks  = poolToks + tokensIn;
        uint256 newPoolQuote = (tc.k + newPoolToks - 1) / newPoolToks;
        uint256 grossQuote   = poolQuote > newPoolQuote ? poolQuote - newPoolQuote : 0;
        if (grossQuote > tc.raisedQuote) return (0, 0);
        feeQuote = (grossQuote * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
        quoteOut = grossQuote - feeQuote;
    }

    function getSpotPrice(address token_) external view returns (uint256 price) {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        uint256 poolQuote  = tc.virtualQuote + tc.raisedQuote;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        if (poolTokens == 0) return type(uint256).max;
        price = (poolQuote * 1e18) / poolTokens;
    }

    function getToken(address token_) external view returns (TokenConfig memory) {
        return tokens[token_];
    }

    function totalTokensLaunched() external view returns (uint256) { return allTokens.length; }

    function getTokensByCreator(address creator_) external view returns (address[] memory) {
        return _tokensByCreator[creator_];
    }

    function tokenCountByCreator(address creator_) external view returns (uint256) {
        return _tokensByCreator[creator_].length;
    }

    function getAntibotBlocksRange() external pure returns (uint256 min, uint256 max) {
        return (ANTIBOT_MIN_BLOCKS, ANTIBOT_MAX_BLOCKS);
    }

    function predictTokenAddress(address creator_, bytes32 userSalt_, address impl_)
        external view
        returns (address predicted)
    {
        predicted = DuckIncubationBuying.predictTokenAddress(creator_, userSalt_, impl_, address(this));
    }

    receive() external payable {}
}
