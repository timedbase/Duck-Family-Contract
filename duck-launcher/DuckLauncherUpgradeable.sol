// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckLauncher

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// Namespaced-storage-slot based -- safe to use directly here with no
// separate "Upgradeable" variant or initializer needed.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchRouting, Route, RouteShape, PoolKey} from "../common/LaunchRouting.sol";
import {V4Math} from "../common/V4Math.sol";

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

contract DuckLauncher is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard, LaunchRouting {

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
        address singleton; // V4 PoolManager
        address permit2;
        address hook;
        bool    enabled;
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
        launchFee       = 0.0005 ether; // default; adjustable later via setLaunchFee

        dexes[initialPositionMgr_] = DexConfig({
            singleton: initialSingleton_,
            permit2:   initialPermit2_,
            hook:      initialHook_,
            enabled:   true
        });
        emit DexAdded(initialPositionMgr_, initialSingleton_, initialPermit2_, initialHook_);

        quoteTokens[address(0)] = true;
        emit QuoteTokenAdded(address(0));

        _seedDefaultQuoteTokens();
        _seedDefaultRoutes(initialSingleton_);
    }

    // Of the 15 default quote tokens, only USDC and USDT0 have real Ink
    // liquidity today, and it sits in the hookless V4 pool paired against
    // native ETH specifically (not WETH). Seeds the early-buy native->quote
    // conversion for just those two; the rest stay whitelisted for direct
    // trading only.
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
    }

    // Same default quote-asset list as DuckIncubation -- addQuoteToken/
    // disableQuoteToken can change this set at any time.
    function _seedDefaultQuoteTokens() private {
        address[15] memory defaults = [
            0x2D270e6886d130D724215A266106e6832161EAEd, // USDC
            0x71052BAe71C25C78E37fD12E5ff1101A71d9018F, // LINK
            0x0200C29006150606B650577BBE7B6248F58470c1, // USD₮0
            0xe343167631d89B6Ffc58B88d6b7fB0228795491D, // USDG
            0x142cdc44890978B506e745bB3Bd11607B7f7faEf, // PYUSD
            0xc3eACf0612346366Db554C991D7858716db09f58, // RSETH
            0xF50258D3c1dd88946C567920B986A12e65b50dAc, // XAUT0
            0xc845b2894dBddd03858fd2D643B4eF725fE0849d, // NVDAX
            0xb63EFBc28860c8097e341DE1fCF59456161E9D98, // SNDKX
            0x53Ad50D3B6FCaCB8965d3A49cB722917C7DAE1F3, // ACRED
            0x6F75AC3b1b6Fbe8Bb5F948e25aF03620f26Ae838, // XLEX
            0xeFD30445A4ec1f4b3E0a6f4d9bDbd215F805047F, // MRNAX
            0xBca703C64f616A17b4f2763F34f93400Dbe20F17, // ETNX
            0x7636244Bab612264e1B2dFd4bA6E26d0311b1Eb7, // CEGX
            0x06A0138F8c3e5110fd98e34a4473Fb08F1304b87  // MOOX
        ];
        for (uint256 i; i < defaults.length; ++i) {
            quoteTokens[defaults[i]] = true;
            emit QuoteTokenAdded(defaults[i]);
        }
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
        dexes[positionManager_] = DexConfig({singleton: singleton_, permit2: permit2_, hook: hook_, enabled: true});
        emit DexAdded(positionManager_, singleton_, permit2_, hook_);
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
        if (dex.hook == address(0)) revert HookRequired();
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

        int24 tick;
        (tick, poolId) = _initPool(p.positionManager, dex.hook, token0, token1, token, p.quoteToken, creator, p.hookFeeBps, p.launchMarketCap);

        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _computeOneSidedLiquidity(tick, tokenIsCurrency1);

        IDuckLauncherToken(token).setExempt(dex.singleton, true);

        tokenId = _mintV4(p.positionManager, dex.hook, dex.permit2, token, token0, token1, tickLower, tickUpper, liquidity);
        locker.registerPosition(token, tokenId, token0, token1, poolId, dex.hook, p.positionManager);

        if (extraEth > 0) {
            try this.instantBuy{value: extraEth}(
                p.quoteToken, token, extraEth, p.minQuoteOut, p.minTokensOut,
                dex.singleton, dex.hook, msg.sender
            ) {} catch {
                if (p.revertOnInstantBuyFailure) revert InstantBuyFailed();
                (bool refundOk,) = msg.sender.call{value: extraEth}("");
                if (!refundOk) revert TransferFailed();
                emit InstantBuySkipped(token, extraEth);
            }
        }

        uint256 creatorTokens = IDuckLauncherToken(token).balanceOf(address(this));
        if (creatorTokens > 0) IDuckLauncherToken(token).transfer(msg.sender, creatorTokens);

        IDuckLauncherToken(token).renounceOwnership();

        emit TokenLaunched(token, creator, p.positionManager, p.quoteToken, dex.hook, poolId, tokenId);
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

    function instantBuy(
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

    // Must match DuckHookV4's own allowed set exactly.
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
