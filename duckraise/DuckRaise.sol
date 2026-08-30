// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckRaise

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// Namespaced-storage-slot based -- safe to use directly here with no
// separate "Upgradeable" variant or initializer needed.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchRouting, Route, RouteShape, PoolKey} from "../common/LaunchRouting.sol";
import {V4Math} from "../common/V4Math.sol";

interface IDuckRaiseTokenLocal {
    function initDuckRaise(string calldata name_, string calldata symbol_, string calldata metaURI_) external;
    function renounceOwnership() external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDuckLocker {
    function registerPosition(
        address token, uint256 tokenId, address token0, address token1,
        bytes32 poolId, address hook, address positionManager
    ) external;
}

interface IV4PositionManagerLL {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

interface IAllowanceTransferLL {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IDuckHookV4LL {
    function registerPool(PoolKey calldata key, address token, address creator, uint256 hookFeeBps) external;
}

interface IWETHLocal {
    function deposit() external payable;
}

contract DuckRaise is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard, LaunchRouting {

    error ZeroAddress();
    error ZeroAmount();
    error CloneFailed();
    error VanityMismatch();
    error NotLiveYet();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error WrongFee();
    error CampaignNotFound();
    error AlreadyFinalized();
    error NotFinalized();
    error CampaignFailed_();
    error CampaignSucceeded_();
    error NothingToClaim();
    error PoolAlreadyExists();
    error InvalidBps();
    error HookNotSet();
    error SwapFailed();
    error TimelockNotQueued();
    error TimelockNotExpired();
    error PendingValueMismatch();
    error InvalidHookFeeBps();
    error QuoteAssetNotAllowed();

    uint16  public constant VANITY_SUFFIX = 0x8888;
    uint256 public constant TOTAL_SUPPLY  = 1_000_000_000e18;
    uint24  private constant FEE_TIER     = 10_000;
    int24   private constant TICK_SPACING =  200;
    int24   private constant MIN_TICK     = -887_200;
    int24   private constant MAX_TICK     =  887_200;
    uint256 private constant ACTION_MINT_POSITION = 0x02;
    uint256 private constant ACTION_SETTLE_PAIR   = 0x0d;

    struct Campaign {
        address creator;
        string  name;
        string  symbol;
        string  metaURI;
        address dexQuoteAsset;      // address(0) = native, no swap needed at finalize
        uint256 goal;                // native wei, creator-specified at creation
        uint256 startTime;
        uint256 deadline;
        uint256 totalRaised;
        bytes32 vanitySalt;
        uint256 contributorBps;
        uint256 lpBps;
        bool    finalized;
        bool    succeeded;
        address token;
        uint256 hookFeeBps;          // post-finalize sell fee: 0 (default 2%), 100, 200, 300, or 500
    }

    Campaign[] public campaigns;
    mapping(uint256 => mapping(address => uint256)) public contributed;

    address      public tokenImpl;
    IDuckLocker public locker;
    address      public weth;
    address      public v4Singleton; // PoolManager
    address      public v4PositionManager;
    address      public v4Permit2;
    address      public v4Hook;      // shared DuckHookV4 instance, same one the other families use
    uint256      public contributorBps;
    uint256      public lpBps;
    uint256      public campaignFee;
    address      public platformWallet;

    // When set, a campaign quoted against platformToken pays no
    // campaignFee. address(0) disables it.
    address      public platformToken;

    // Narrower than DuckIncubation/DuckLauncher's quote-token lists: a
    // raise's dexQuoteAsset must actually be swappable at finalize (100% of
    // raised ETH converts into it), so only assets with a real configured
    // route belong here. address(0) is always implicitly allowed.
    mapping(address => bool) public quoteAssetAllowed;

    uint256 public campaignDuration;

    // Only the upgrade authority is timelocked; every other admin action
    // stays instant onlyOwner.
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    bytes32 public constant TL_UPGRADE = keccak256("UPGRADE");

    mapping(bytes32 => uint256) public timelockExpiry;

    address private _pendingUpgradeImpl;

    event TimelockQueued(bytes32 indexed actionId, uint256 executeAfter);
    event TimelockExecuted(bytes32 indexed actionId);
    event TimelockCancelled(bytes32 indexed actionId);

    event CampaignCreated(uint256 indexed campaignId, address indexed creator, address indexed token, string name, string symbol, address dexQuoteAsset, uint256 goal, uint256 startTime, uint256 deadline);
    event Contributed(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event CampaignSucceeded(uint256 indexed campaignId, address indexed token, uint256 totalRaised);
    event CampaignFailed(uint256 indexed campaignId, uint256 totalRaised, uint256 goal);
    event Claimed(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event Refunded(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event TokenImplSet(address indexed tokenImpl);
    event LockerSet(address indexed locker);
    event WethSet(address indexed weth);
    event DexConfigSet(address positionManager, address singleton, address permit2, address hook);
    event PlatformWalletSet(address indexed wallet);
    event PlatformTokenSet(address indexed token);
    event QuoteAssetUpdated(address indexed token, bool allowed);
    event CampaignFeeSet(uint256 fee);
    event SupplySplitSet(uint256 contributorBps, uint256 lpBps);
    event CampaignDurationSet(uint256 duration);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address weth_,
        address tokenImpl_,
        address locker_,
        address v4Singleton_,
        address v4PositionManager_,
        address v4Permit2_,
        address v4Hook_,
        address platformWallet_
    ) external initializer {
        if (weth_               == address(0)) revert ZeroAddress();
        if (tokenImpl_          == address(0)) revert ZeroAddress();
        if (locker_             == address(0)) revert ZeroAddress();
        if (v4Singleton_        == address(0)) revert ZeroAddress();
        if (v4PositionManager_  == address(0)) revert ZeroAddress();
        if (v4Permit2_          == address(0)) revert ZeroAddress();
        if (platformWallet_     == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);

        weth              = weth_;
        tokenImpl         = tokenImpl_;
        locker            = IDuckLocker(locker_);
        v4Singleton       = v4Singleton_;
        v4PositionManager = v4PositionManager_;
        v4Permit2         = v4Permit2_;
        v4Hook            = v4Hook_;
        platformWallet         = platformWallet_;
        campaignFee       = 0.0005 ether;

        contributorBps   = 8_000;
        lpBps            = 2_000;
        campaignDuration = 2 hours;

        _seedDefaultRoutes(v4Singleton_);
    }

    function setQuoteAssetAllowed(address token_, bool allowed_) external onlyOwner {
        if (token_ == address(0)) revert ZeroAddress();
        quoteAssetAllowed[token_] = allowed_;
        emit QuoteAssetUpdated(token_, allowed_);
    }

    // Of any ERC20 a creator could pick as dexQuoteAsset, only USDC and
    // USDT0 have real Ink liquidity today, and it sits in the hookless V4
    // pool paired against native ETH specifically (not WETH). Any other
    // dexQuoteAsset with no route configured just fails
    // _seedSuccessLiquidity safely (finalize() catches it and marks the
    // campaign failed for refunds).
    function _seedDefaultRoutes(address v4Singleton_) private {
        address usdc  = 0x2D270e6886d130D724215A266106e6832161EAEd;
        address usdt0 = 0x0200C29006150606B650577BBE7B6248F58470c1;

        Route[] memory r = new Route[](1);
        r[0] = Route({
            shape:            RouteShape.V4_STYLE,
            enabled:          true,
            router:           address(0),
            routerNoDeadline: false,
            path:             new address[](0),
            fees:             new uint24[](0),
            routers:          new address[](0),
            singleton:        v4Singleton_,
            hook:             address(0),
            fee:              3000,
            tickSpacing:      60
        });
        _setRoutes(usdc, r);
        _setRoutes(usdt0, r);

        quoteAssetAllowed[usdc]  = true;
        quoteAssetAllowed[usdt0] = true;
        emit QuoteAssetUpdated(usdc, true);
        emit QuoteAssetUpdated(usdt0, true);
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

    function setTokenImpl(address tokenImpl_) external onlyOwner {
        if (tokenImpl_ == address(0)) revert ZeroAddress();
        tokenImpl = tokenImpl_;
        emit TokenImplSet(tokenImpl_);
    }

    function setLocker(address locker_) external onlyOwner {
        if (locker_ == address(0)) revert ZeroAddress();
        locker = IDuckLocker(locker_);
        emit LockerSet(locker_);
    }

    function setWeth(address weth_) external onlyOwner {
        if (weth_ == address(0)) revert ZeroAddress();
        weth = weth_;
        emit WethSet(weth_);
    }

    function setDexConfig(address positionManager_, address singleton_, address permit2_, address hook_) external onlyOwner {
        if (positionManager_ == address(0)) revert ZeroAddress();
        if (singleton_        == address(0)) revert ZeroAddress();
        if (permit2_          == address(0)) revert ZeroAddress();
        v4PositionManager = positionManager_;
        v4Singleton       = singleton_;
        v4Permit2         = permit2_;
        v4Hook            = hook_;
        emit DexConfigSet(positionManager_, singleton_, permit2_, hook_);
    }

    function setRoutes(address quoteToken_, Route[] calldata routes_) external onlyOwner {
        _setRoutes(quoteToken_, routes_);
    }

    function setPlatformWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        platformWallet = wallet;
        emit PlatformWalletSet(wallet);
    }

    function setPlatformToken(address token) external onlyOwner {
        platformToken = token;
        emit PlatformTokenSet(token);
    }

    function setCampaignFee(uint256 fee_) external onlyOwner {
        campaignFee = fee_;
        emit CampaignFeeSet(fee_);
    }

    function setSupplySplit(uint256 contributorBps_, uint256 lpBps_) external onlyOwner {
        if (contributorBps_ + lpBps_ != 10_000) revert InvalidBps();
        contributorBps = contributorBps_;
        lpBps          = lpBps_;
        emit SupplySplitSet(contributorBps_, lpBps_);
    }

    function setCampaignDuration(uint256 duration_) external onlyOwner {
        if (duration_ == 0) revert ZeroAmount();
        campaignDuration = duration_;
        emit CampaignDurationSet(duration_);
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

    function campaignCount() external view returns (uint256) {
        return campaigns.length;
    }

    function previewClaimable(uint256 campaignId_, address account) external view returns (uint256) {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (!c.finalized || !c.succeeded) return 0;
        uint256 amount = contributed[campaignId_][account];
        if (amount == 0) return 0;
        uint256 contributorSupply = TOTAL_SUPPLY * c.contributorBps / 10_000;
        return contributorSupply * amount / c.totalRaised;
    }

    // Deploys the campaign's token immediately, up front -- not at
    // finalize(). Full TOTAL_SUPPLY sits escrowed in this contract until
    // finalize() splits it into the contributor share (claimable pro-rata)
    // and the LP share; a failed campaign leaves that balance undistributed
    // alongside the native refunds.
    function launch(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_,
        address dexQuoteAsset_,
        uint256 goalNativeWei_,
        uint256 startTime_,
        bytes32 vanitySalt_,
        uint256 hookFeeBps_
    ) external payable nonReentrant returns (uint256 campaignId, address token) {
        bool feeWaived = platformToken != address(0) && dexQuoteAsset_ == platformToken;
        uint256 fee = feeWaived ? 0 : campaignFee;
        if (msg.value != fee) revert WrongFee();
        if (goalNativeWei_ == 0) revert ZeroAmount();
        if (!_isValidHookFeeBps(hookFeeBps_)) revert InvalidHookFeeBps();
        if (dexQuoteAsset_ != address(0) && !quoteAssetAllowed[dexQuoteAsset_]) revert QuoteAssetNotAllowed();

        if (fee > 0) {
            (bool ok,) = platformWallet.call{value: fee}("");
            if (!ok) revert TransferFailed();
        }

        bytes32 salt = keccak256(abi.encode(msg.sender, vanitySalt_));
        token = _clone(tokenImpl, salt);
        if (uint16(uint160(token)) != VANITY_SUFFIX) revert VanityMismatch();
        IDuckRaiseTokenLocal(token).initDuckRaise(name_, symbol_, metaURI_);
        IDuckRaiseTokenLocal(token).renounceOwnership();

        uint256 startTime = startTime_ <= block.timestamp ? block.timestamp : startTime_;
        uint256 deadline = startTime + campaignDuration;

        campaignId = campaigns.length;
        campaigns.push(Campaign({
            creator:        msg.sender,
            name:           name_,
            symbol:         symbol_,
            metaURI:        metaURI_,
            dexQuoteAsset:  dexQuoteAsset_,
            goal:           goalNativeWei_,
            startTime:      startTime,
            deadline:       deadline,
            totalRaised:    0,
            vanitySalt:     vanitySalt_,
            contributorBps: contributorBps,
            lpBps:          lpBps,
            finalized:      false,
            succeeded:      false,
            token:          token,
            hookFeeBps:     hookFeeBps_
        }));
        emit CampaignCreated(campaignId, msg.sender, token, name_, symbol_, dexQuoteAsset_, goalNativeWei_, startTime, deadline);
    }

    function contribute(uint256 campaignId_) external payable nonReentrant {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (block.timestamp < c.startTime) revert NotLiveYet();
        if (block.timestamp >= c.deadline) revert DeadlinePassed();
        if (msg.value == 0) revert ZeroAmount();

        contributed[campaignId_][msg.sender] += msg.value;
        c.totalRaised += msg.value;
        emit Contributed(campaignId_, msg.sender, msg.value);
    }

    function finalize(uint256 campaignId_) external nonReentrant returns (address token) {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (block.timestamp < c.deadline) revert DeadlineNotPassed();
        if (c.finalized) revert AlreadyFinalized();

        c.finalized = true;
        token = c.token;

        if (c.totalRaised >= c.goal) {
            try this._seedSuccessLiquidity(campaignId_) {
                c.succeeded = true;
                emit CampaignSucceeded(campaignId_, token, c.totalRaised);
            } catch {
                emit CampaignFailed(campaignId_, c.totalRaised, c.goal);
            }
        } else {
            emit CampaignFailed(campaignId_, c.totalRaised, c.goal);
        }
    }

    // Token already exists (deployed at launch()) -- this only splits its
    // held supply into the contributor share (left here, claimable
    // pro-rata) and the LP share (swapped/seeded into the V4 pool).
    function _seedSuccessLiquidity(uint256 campaignId_) external {
        if (msg.sender != address(this)) revert Unauthorized();
        Campaign storage c = campaigns[campaignId_];
        address token = c.token;

        uint256 contributorSupply = TOTAL_SUPPLY * c.contributorBps / 10_000;
        uint256 lpSupply = TOTAL_SUPPLY - contributorSupply;

        address quoteAsset = c.dexQuoteAsset;
        uint256 quoteAmount = c.totalRaised;
        if (quoteAsset != address(0)) {
            (uint256 out, bool ok) = _acquireQuoteToken(quoteAsset, c.totalRaised, 0, address(this));
            if (!ok) revert SwapFailed();
            quoteAmount = out;
        }

        _seedV4(token, quoteAsset, lpSupply, quoteAmount, c.creator, c.hookFeeBps);
    }

    function _seedV4(
        address token,
        address quoteCurrency,
        uint256 lpSupply,
        uint256 quoteAmount,
        address creator,
        uint256 hookFeeBps
    ) private {
        address hookAddr = v4Hook;
        if (hookAddr == address(0)) revert HookNotSet();

        address quoteToken = quoteCurrency;
        if (quoteCurrency == address(0)) {
            IWETHLocal(weth).deposit{value: quoteAmount}();
            quoteToken = weth;
        }

        (address token0, address token1) = token < quoteToken ? (token, quoteToken) : (quoteToken, token);
        (uint256 amount0, uint256 amount1) = token == token0
            ? (lpSupply, quoteAmount)
            : (quoteAmount, lpSupply);

        PoolKey memory key = PoolKey({
            currency0:   token0,
            currency1:   token1,
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       hookAddr
        });

        int24 tick = IV4PositionManagerLL(v4PositionManager).initializePool(key, _computeSqrtPriceX96(token, quoteToken, lpSupply, quoteAmount));
        if (tick == type(int24).max) revert PoolAlreadyExists();
        bytes32 poolId = keccak256(abi.encode(key));
        IDuckHookV4LL(hookAddr).registerPool(key, token, creator, hookFeeBps);

        uint128 liquidity = V4Math.getLiquidityForAmounts(
            V4Math.getSqrtPriceAtTick(tick), V4Math.getSqrtPriceAtTick(MIN_TICK), V4Math.getSqrtPriceAtTick(MAX_TICK),
            amount0, amount1
        );

        _safeApprove(token0, v4Permit2, amount0);
        _safeApprove(token1, v4Permit2, amount1);
        IAllowanceTransferLL(v4Permit2).approve(token0, v4PositionManager, uint160(amount0), uint48(block.timestamp + 300));
        IAllowanceTransferLL(v4Permit2).approve(token1, v4PositionManager, uint160(amount1), uint48(block.timestamp + 300));

        bytes memory actions = abi.encodePacked(uint8(ACTION_MINT_POSITION), uint8(ACTION_SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, MIN_TICK, MAX_TICK, uint256(liquidity), uint128(amount0), uint128(amount1), address(locker), bytes(""));
        params[1] = abi.encode(token0, token1);

        uint256 tokenId = IV4PositionManagerLL(v4PositionManager).nextTokenId();
        IV4PositionManagerLL(v4PositionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp);

        locker.registerPosition(token, tokenId, token0, token1, poolId, hookAddr, v4PositionManager);
    }

    function claim(uint256 campaignId_) external nonReentrant {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (!c.finalized) revert NotFinalized();
        if (!c.succeeded) revert CampaignFailed_();
        uint256 amount = contributed[campaignId_][msg.sender];
        if (amount == 0) revert NothingToClaim();

        contributed[campaignId_][msg.sender] = 0;

        uint256 contributorSupply = TOTAL_SUPPLY * c.contributorBps / 10_000;
        uint256 share = contributorSupply * amount / c.totalRaised;

        IDuckRaiseTokenLocal(c.token).transfer(msg.sender, share);
        emit Claimed(campaignId_, msg.sender, share);
    }

    function claimRefund(uint256 campaignId_) external nonReentrant {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (!c.finalized) revert NotFinalized();
        if (c.succeeded) revert CampaignSucceeded_();
        uint256 amount = contributed[campaignId_][msg.sender];
        if (amount == 0) revert NothingToClaim();

        contributed[campaignId_][msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Refunded(campaignId_, msg.sender, amount);
    }

    receive() external payable {}

    // ── Shared helpers ────────────────────────────────────────────────

    function _clone(address impl, bytes32 salt) private returns (address instance) {
        assembly ("memory-safe") {
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

    function _computeSqrtPriceX96(address tokenAddr, address quoteToken_, uint256 tokenAmount, uint256 quoteAmount)
        private pure returns (uint160)
    {
        if (tokenAddr < quoteToken_) {
            return V4Math.sqrtPriceX96FromAmounts(tokenAmount, quoteAmount);
        } else {
            return V4Math.sqrtPriceX96FromAmounts(quoteAmount, tokenAmount);
        }
    }

    // Must match DuckHookV4's own allowed set exactly.
    function _isValidHookFeeBps(uint256 bps) private pure returns (bool) {
        return bps == 0 || bps == 100 || bps == 200 || bps == 300 || bps == 500;
    }

}
