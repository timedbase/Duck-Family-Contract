// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckLocker

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PoolKey, SwapParams, IV4PoolManagerSwap} from "common-contracts/LaunchRouting.sol";

interface IPositionManagerV4 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function poolManager() external view returns (address);
}

interface IDuckHookV4Minimal {
    function pools(bytes32 poolId) external view returns (
        address token,
        address quoteCurrency,
        bool    tokenIsCurrency0,
        address creator,
        uint256 launchTimestamp,
        bool    registered,
        uint256 hookFeeBps
    );
    function claimFees(bytes32 poolId) external;
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

interface IStateView {
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

// The real, verified Uniswap V3 NonfungiblePositionManager on Ink
// (0xC0836E5B058BBE22ae2266e1AC488A1A0fD8DCE8, confirmed via its factory()
// matching Ink's genuine UniswapV3Factory at 0x640887A9ba3A9C53Ed27D0F7e8246A4F933f3424,
// plus WETH9()/name()/symbol() all matching canonical Uniswap V3) -- wired
// in via setV3PositionManager, see _parkOrBurn.
interface IPositionManagerV3 {
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params)
        external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params)
        external payable
        returns (uint256 amount0, uint256 amount1);
}

contract DuckLocker is Initializable, UUPSUpgradeable, OwnableUpgradeable {

    error NotLauncher();
    error NotAuthorized();
    error ZeroAddress();
    error AlreadyRegistered();
    error UnknownToken();
    error TransferFailed();
    error TimelockNotQueued();
    error TimelockNotExpired();
    error PendingValueMismatch();
    error Unauthorized();
    error NotSelf();

    uint256 public constant DECREASE_LIQUIDITY = 0x01;
    uint256 public constant TAKE_PAIR          = 0x11;

    // Every pool this platform creates uses this same 1% tier / 200 tick
    // spacing convention (see DuckIncubation/DuckLauncher/DuckRaise), needed
    // here to reconstruct a PoolKey for the buyback swap.
    uint24 private constant FEE_TIER     = 10_000;
    int24  private constant TICK_SPACING = 200;
    uint160 private constant _MIN_SQRT_PRICE = 4295128739;
    uint160 private constant _MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // The token-side LP fee is parked as a single-sided V3 position starting
    // this many ticks above (or, mirrored, below -- see parkTokenSide) the
    // pool's current price, rather than being burned outright. 9200 ticks =
    // 1.0001^9200 ~= +150.9% (2.51x), safely clearing the intended "2.5x
    // spot" floor even after rounding to a usable (TICK_SPACING-aligned)
    // tick. Under ordinary price action this range never gets crossed -- the
    // parked tokens sit locked forever, same as a burn -- it only starts
    // trading (and earning V3 fees) if price rallies through it.
    int24 private constant PARK_TICK_OFFSET = 9200;
    // TickMath.MIN_TICK/MAX_TICK (-887272/887272) rounded to the nearest
    // usable multiple of TICK_SPACING (200), so the far side of the parked
    // range always spans to the edge of the curve.
    int24 private constant PARK_MIN_TICK = -887200;
    int24 private constant PARK_MAX_TICK = 887200;

    struct Position {
        uint256 tokenId;
        address token0;
        address token1;
        bytes32 poolId;
        address hook;
        address positionManager;
    }

    // One shared locker across all launcher families -- DuckLauncher,
    // DuckRaise and DuckIncubation are each authorized here rather than each
    // getting their own dedicated locker instance.
    mapping(address => bool) public isLauncher;
    address public platformWallet;

    // When set, the quote-asset side of every LP-fee collection buys back
    // and burns the project token instead of going to platformWallet -- see
    // the file header. address(0) disables it (default behavior).
    address public platformToken;

    mapping(address => Position) public positions;
    address[] public allTokens;

    // When both are set, the token-side LP fee is parked as permanently-
    // locked, single-sided V3 liquidity (see parkTokenSide) instead of being
    // burned. address(0) on either disables it -- default behavior is an
    // outright burn, same as before this was added.
    address public v3PositionManager;
    address public v4StateView;

    // Second, independent NFT position per token -- separate from the V4
    // position already tracked in `positions`, since this lives on a
    // completely different pool (the token's own V3 pool, not the V4 one it
    // launched on).
    mapping(address => uint256) public v3LockTokenId;

    address private _cbPoolManagerExpected;

    // Only the upgrade authority is timelocked; every other admin action
    // stays instant onlyOwner.
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    bytes32 public constant TL_UPGRADE = keccak256("UPGRADE");

    mapping(bytes32 => uint256) public timelockExpiry;

    address private _pendingUpgradeImpl;

    event TimelockQueued(bytes32 indexed actionId, uint256 executeAfter);
    event TimelockExecuted(bytes32 indexed actionId);
    event TimelockCancelled(bytes32 indexed actionId);

    event PositionRegistered(
        address indexed token,
        uint256 indexed tokenId,
        bytes32         poolId,
        address         hook,
        address         positionManager
    );
    // token/quote amounts collected from the pool's 1% LP fee this round --
    // burned (token) and sent to the platform wallet (quote) respectively.
    event FeesClaimed(
        address indexed token,
        uint256 burned,
        uint256 toPlatform
    );
    event LauncherAdded(address indexed launcher);
    event LauncherRemoved(address indexed launcher);
    event PlatformWalletSet(address indexed wallet);
    event PlatformTokenSet(address indexed token);
    event V3PositionManagerSet(address indexed manager);
    event V4StateViewSet(address indexed stateView);
    // Emitted instead of (or as part of) FeesClaimed's burn amount when the
    // token side was parked into the V3 position rather than sent to DEAD.
    event TokenSideParked(address indexed token, uint256 indexed tokenId, uint256 amount);

    modifier onlyLauncher() { if (!isLauncher[msg.sender]) revert NotLauncher(); _; }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address platformWallet_) external initializer {
        if (platformWallet_ == address(0)) revert ZeroAddress();
        __Ownable_init(msg.sender);
        platformWallet = platformWallet_;
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

    function addLauncher(address launcher_) external onlyOwner {
        if (launcher_ == address(0)) revert ZeroAddress();
        isLauncher[launcher_] = true;
        emit LauncherAdded(launcher_);
    }

    function removeLauncher(address launcher_) external onlyOwner {
        isLauncher[launcher_] = false;
        emit LauncherRemoved(launcher_);
    }

    function setPlatformWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        platformWallet = wallet;
        emit PlatformWalletSet(wallet);
    }

    // address(0) disables the buyback mechanism.
    function setPlatformToken(address token) external onlyOwner {
        platformToken = token;
        emit PlatformTokenSet(token);
    }

    // address(0) disables token-side parking -- falls back to a plain burn.
    function setV3PositionManager(address manager) external onlyOwner {
        v3PositionManager = manager;
        emit V3PositionManagerSet(manager);
    }

    // address(0) disables token-side parking -- falls back to a plain burn.
    function setV4StateView(address stateView) external onlyOwner {
        v4StateView = stateView;
        emit V4StateViewSet(stateView);
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

    function registerPosition(
        address token,
        uint256 tokenId,
        address token0,
        address token1,
        bytes32 poolId,
        address hook,
        address positionManager
    ) external onlyLauncher {
        if (positions[token].tokenId != 0) revert AlreadyRegistered();
        positions[token] = Position({
            tokenId:         tokenId,
            token0:          token0,
            token1:          token1,
            poolId:          poolId,
            hook:            hook,
            positionManager: positionManager
        });
        allTokens.push(token);
        emit PositionRegistered(token, tokenId, poolId, hook, positionManager);
    }

    function claimFees(address token) external {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();

        address creator = _poolCreator(pos);
        if (msg.sender != creator && msg.sender != owner() && msg.sender != address(this))
            revert NotAuthorized();

        _collectAndDistribute(token, pos);

        // Best-effort: the hook pays creator/platform directly out of its own
        // separately-accrued sell-fee balance -- if there's nothing accrued
        // it just no-ops, so this never blocks the LP-side claim above.
        try IDuckHookV4Minimal(pos.hook).claimFees(pos.poolId) {} catch {}

        // Best-effort, same reasoning: collects whatever real V3 trading
        // fees the parked position (see parkTokenSide) has earned -- only
        // nonzero once/if price actually rallies through the parked range --
        // straight to platformWallet. No-ops when there's no parked
        // position yet, or nothing accrued on it.
        try this.claimParkedV3Fees(token) {} catch {}
    }

    // Routes the parked V3 position's own trading-fee revenue to
    // platformWallet -- distinct from, and in addition to, the V4-side
    // token/quote split _collectAndDistribute already handles above. Never
    // touches the position's underlying liquidity (that stays permanently
    // locked; collect() only ever returns fees accrued since the last
    // collect/increaseLiquidity, never principal). External + self-only
    // (see NotSelf) purely so claimFees can wrap it in try/catch.
    function claimParkedV3Fees(address token) external {
        if (msg.sender != address(this)) revert NotSelf();
        uint256 tokenId = v3LockTokenId[token];
        if (tokenId == 0 || v3PositionManager == address(0)) return;
        IPositionManagerV3(v3PositionManager).collect(IPositionManagerV3.CollectParams({
            tokenId:     tokenId,
            recipient:   platformWallet,
            amount0Max:  type(uint128).max,
            amount1Max:  type(uint128).max
        }));
    }

    function claimAllFees() external onlyOwner {
        uint256 len = allTokens.length;
        for (uint256 i; i < len; ++i) {
            try this.claimFees(allTokens[i]) {} catch {}
        }
    }

    function claimFeesRange(uint256 from, uint256 to) external onlyOwner {
        uint256 len = allTokens.length;
        if (to > len) to = len;
        for (uint256 i = from; i < to; ++i) {
            try this.claimFees(allTokens[i]) {} catch {}
        }
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function creatorOf(address token) external view returns (address) {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();
        return _poolCreator(pos);
    }

    function _poolCreator(Position storage pos) private view returns (address creator) {
        (,,, creator,,,) = IDuckHookV4Minimal(pos.hook).pools(pos.poolId);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return 0x150b7a02;
    }

    function _collectAndDistribute(address token, Position storage pos) private {
        uint256 bal0Before = _balanceOf(pos.token0);
        uint256 bal1Before = _balanceOf(pos.token1);

        bytes memory actions = abi.encodePacked(uint8(DECREASE_LIQUIDITY), uint8(TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(pos.tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(pos.token0, pos.token1, address(this));
        IPositionManagerV4(pos.positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp);

        uint256 a0 = _balanceOf(pos.token0) - bal0Before;
        uint256 a1 = _balanceOf(pos.token1) - bal1Before;
        if (a0 == 0 && a1 == 0) return;

        bool tokenIsCurrency0 = pos.token0 == token;
        (uint256 burned, uint256 toPlatform) = tokenIsCurrency0 ? (a0, a1) : (a1, a0);
        (address tokenSide, address quoteSide) = tokenIsCurrency0
            ? (pos.token0, pos.token1)
            : (pos.token1, pos.token0);

        _parkOrBurn(token, tokenSide, burned);

        if (toPlatform > 0 && platformToken != address(0) && quoteSide == platformToken) {
            uint256 boughtBack = _swapForBurn(pos, quoteSide, tokenSide, toPlatform);
            if (boughtBack > 0) _safeTransfer(tokenSide, DEAD, boughtBack);
            emit FeesClaimed(token, burned + boughtBack, 0);
        } else {
            _safeTransfer(quoteSide, platformWallet, toPlatform);
            emit FeesClaimed(token, burned, toPlatform);
        }
    }

    // Parks the token-side LP fee as a single-sided V3 position instead of
    // burning it outright, when the owner has wired up v3PositionManager/
    // v4StateView. try/catch (self-call, see parkTokenSide) so a failure --
    // no V3 infra wired up yet, or a pathological pool/price state -- can
    // never block the underlying V4 fee claim; it just falls back to a
    // plain burn for that round.
    function _parkOrBurn(address token, address tokenSide, uint256 amount) private {
        if (amount == 0) return;
        if (v3PositionManager != address(0) && v4StateView != address(0)) {
            try this.parkTokenSide(token, tokenSide, amount) returns (uint256) {
                return;
            } catch {}
        }
        _safeTransfer(tokenSide, DEAD, amount);
    }

    // Mints (first claim) or extends (every claim after) a single-sided V3
    // position holding the token-side fee, placed starting ~2.5x above the
    // pool's current price -- see PARK_TICK_OFFSET. A position with a range
    // entirely on one side of the current price is 100% composed of
    // whichever currency that side represents (standard Uniswap V3
    // behavior), which is what makes single-sided funding possible with no
    // swap. Ticks price token1-per-token0, so which direction "above
    // current price" points depends on whether the project token is token0
    // or token1 -- token0 up / token1 down, worked out below.
    //
    // External + self-only (see NotSelf) purely so _parkOrBurn can wrap it
    // in try/catch.
    function parkTokenSide(address token, address tokenSide, uint256 amount)
        external returns (uint256 tokenId)
    {
        if (msg.sender != address(this)) revert NotSelf();

        Position storage pos = positions[token];
        (uint160 poolSqrtPriceX96, int24 poolTick,,) = IStateView(v4StateView).getSlot0(pos.poolId);
        bool tokenIsToken0 = tokenSide == pos.token0;

        tokenId = v3LockTokenId[token];
        if (tokenId == 0) {
            IPositionManagerV3(v3PositionManager).createAndInitializePoolIfNecessary(
                pos.token0, pos.token1, FEE_TIER, poolSqrtPriceX96
            );

            (int24 tickLower, int24 tickUpper) = tokenIsToken0
                ? (_roundUpToSpacing(poolTick + PARK_TICK_OFFSET, TICK_SPACING), PARK_MAX_TICK)
                : (PARK_MIN_TICK, _roundDownToSpacing(poolTick - PARK_TICK_OFFSET, TICK_SPACING));

            _approve(tokenSide, v3PositionManager, amount);
            (tokenId,,,) = IPositionManagerV3(v3PositionManager).mint(IPositionManagerV3.MintParams({
                token0:          pos.token0,
                token1:          pos.token1,
                fee:             FEE_TIER,
                tickLower:       tickLower,
                tickUpper:       tickUpper,
                amount0Desired:  tokenIsToken0 ? amount : 0,
                amount1Desired:  tokenIsToken0 ? 0 : amount,
                amount0Min:      0,
                amount1Min:      0,
                recipient:       address(this),
                deadline:        block.timestamp
            }));
            v3LockTokenId[token] = tokenId;
        } else {
            _approve(tokenSide, v3PositionManager, amount);
            IPositionManagerV3(v3PositionManager).increaseLiquidity(IPositionManagerV3.IncreaseLiquidityParams({
                tokenId:         tokenId,
                amount0Desired:  tokenIsToken0 ? amount : 0,
                amount1Desired:  tokenIsToken0 ? 0 : amount,
                amount0Min:      0,
                amount1Min:      0,
                deadline:        block.timestamp
            }));
        }

        emit TokenSideParked(token, tokenId, amount);
    }

    function _roundUpToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 r = tick % spacing;
        if (r == 0) return tick;
        if (r > 0) return tick - r + spacing;
        return tick - r;
    }

    function _roundDownToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 r = tick % spacing;
        if (r == 0) return tick;
        if (r > 0) return tick - r;
        return tick - r - spacing;
    }

    // Swaps the platform's quote-side cut for the project token itself (via
    // its own locked pool) so it can be burned instead of paid out -- the
    // mechanism behind platformToken's "platform takes zero fee" deal.
    function _swapForBurn(Position storage pos, address currencyIn, address currencyOut, uint256 amountIn)
        private returns (uint256 amountOut)
    {
        address singleton = IPositionManagerV4(pos.positionManager).poolManager();
        _cbPoolManagerExpected = singleton;
        bytes memory result = IV4PoolManagerSwap(singleton).unlock(
            abi.encode(pos.hook, currencyIn, currencyOut, amountIn)
        );
        _cbPoolManagerExpected = address(0);
        amountOut = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (_cbPoolManagerExpected == address(0) || msg.sender != _cbPoolManagerExpected) revert Unauthorized();
        (address hook_, address currencyIn_, address currencyOut_, uint256 amountIn_) =
            abi.decode(data, (address, address, address, uint256));

        bool zeroForOne = currencyIn_ < currencyOut_;
        PoolKey memory key = PoolKey({
            currency0:   zeroForOne ? currencyIn_ : currencyOut_,
            currency1:   zeroForOne ? currencyOut_ : currencyIn_,
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       hook_
        });
        int256 delta = IV4PoolManagerSwap(msg.sender).swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(amountIn_),
                sqrtPriceLimitX96: zeroForOne ? _MIN_SQRT_PRICE + 1 : _MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 amountOut = zeroForOne ? uint256(uint128(int128(delta))) : uint256(uint128(int128(delta >> 128)));

        // currencyIn_ is always an ERC20 here (platformToken), never native.
        IV4PoolManagerSwap(msg.sender).sync(currencyIn_);
        _safeTransfer(currencyIn_, msg.sender, amountIn_);
        IV4PoolManagerSwap(msg.sender).settle();
        IV4PoolManagerSwap(msg.sender).take(currencyOut_, address(this), amountOut);
        return abi.encode(amountOut);
    }

    function _balanceOf(address currency) private view returns (uint256) {
        if (currency == address(0)) return address(this).balance;
        return IERC20Balance(currency).balanceOf(address(this));
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
            return;
        }
        (bool ok2, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        if (!ok2 || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(0x095ea7b3, spender, amount)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    receive() external payable {}
}
