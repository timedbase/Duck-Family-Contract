// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckLockerArc

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

// Uniswap V3's NonfungiblePositionManager -- no hook concept, so fee
// collection is one uniform stream per swap direction, unlike V4's separate
// hook-side creator skim. `collect` with max amounts pulls everything
// accrued without touching principal liquidity, mirroring what the V4
// branch below achieves via a zero-liquidity decrease + take-pair.
interface IPositionManagerV3 {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1);
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

contract DuckLockerArc is Initializable, UUPSUpgradeable, OwnableUpgradeable {

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
    error InvalidBps();
    error InsufficientCTOFee();
    error NoCTOApplication();
    error CTOApplicationPending();

    uint256 public constant DECREASE_LIQUIDITY = 0x01;
    uint256 public constant TAKE_PAIR          = 0x11;

    // Every pool this platform creates uses this same 1% tier / 200 tick
    // spacing convention (see DuckIncubationArc/DuckLauncherArc/DuckRaiseArc), needed
    // here to reconstruct a PoolKey for the buyback swap.
    uint24 private constant FEE_TIER     = 10_000;
    int24  private constant TICK_SPACING = 200;
    uint160 private constant _MIN_SQRT_PRICE = 4295128739;
    uint160 private constant _MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Position {
        uint256 tokenId;
        address token0;
        address token1;
        bytes32 poolId;         // V4 only; zero for a V3 position
        address hook;           // V4 only; zero for a V3 position
        address positionManager;
        bool    isV3;
        address creator;        // V3 only -- V4 asks its hook instead (see _poolCreator)
    }

    // V3 has one uniform fee stream per position (no hook to carve a
    // separate creator cut out of), so DuckLockerArc does that split itself
    // here. Both in bps out of 10_000, each independently owner-updateable:
    // v3TokenBurnBps of the collected TOKEN side is burned, the rest goes to
    // the creator; v3QuoteCreatorBps of the collected QUOTE side goes to the
    // creator, the rest to the platform wallet. Defaults (matching the
    // originally-specified 50/50 split on each side) are set in initialize()
    // below, NOT here -- an inline initializer on a UUPS-upgradeable
    // contract only ever applies to the implementation's own storage, never
    // a proxy's, so one here would silently leave every real deployment at 0.
    uint16 public v3TokenBurnBps;
    uint16 public v3QuoteCreatorBps;

    event V3TokenBurnBpsSet(uint16 bps);
    event V3QuoteCreatorBpsSet(uint16 bps);
    // token/quote amounts collected from a V3 position's own fee stream --
    // no separate hook-side creator fee exists on V3, so all three
    // recipients are reported together here (unlike FeesClaimed above,
    // which only ever carries the LP-side burn/platform cut).
    event FeesClaimedV3(
        address indexed token,
        uint256 burned,
        uint256 toCreator,
        uint256 toPlatform
    );

    // V3 has no hook to host a CTO mechanism, so DuckLockerArc runs it
    // directly for V3 positions -- same pending-application/owner-approval
    // shape as DuckHookV4Arc's applyForCTO/approveCTO/rejectCTO, keyed by
    // token instead of poolId since that's how `positions` is already
    // indexed. The fee is paid in native currency straight to platformWallet,
    // same as the hook does.
    struct V3CTOApplication {
        address applicant;
        address newCreator;
        uint256 paid;
    }

    // Default (50 USDC -- Arc's native gas token, 18 decimals) set in
    // initialize() below, not here -- see v3TokenBurnBps's comment above for
    // why an inline initializer here would silently do nothing on a proxy.
    uint256 public v3CtoFee;
    mapping(address => V3CTOApplication) public v3CtoApplications;

    event V3CTOFeeSet(uint256 fee);
    event V3CTOApplied(address indexed token, address indexed applicant, address newCreator, uint256 paid);
    event V3CTOApproved(address indexed token, address newCreator);
    event V3CTORejected(address indexed token, address indexed applicant);

    // One shared locker across all launcher families -- DuckLauncherArc,
    // DuckRaiseArc and DuckIncubationArc are each authorized here rather than each
    // getting their own dedicated locker instance.
    mapping(address => bool) public isLauncher;
    address public platformWallet;

    // When set, the quote-asset side of every LP-fee collection buys back
    // and burns the project token instead of going to platformWallet -- see
    // the file header. address(0) disables it (default behavior).
    address public platformToken;

    mapping(address => Position) public positions;
    address[] public allTokens;

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

    modifier onlyLauncher() { if (!isLauncher[msg.sender]) revert NotLauncher(); _; }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address platformWallet_) external initializer {
        if (platformWallet_ == address(0)) revert ZeroAddress();
        __Ownable_init(msg.sender);
        platformWallet = platformWallet_;
        // Inline field initializers below (now removed) only ever ran
        // against the implementation contract's own throwaway storage, never
        // the proxy's real storage -- a UUPS proxy's constructor never runs
        // via delegatecall, so v3TokenBurnBps/v3QuoteCreatorBps/v3CtoFee were
        // silently 0 on every real deployment until fixed here. Confirmed
        // live on Arc (cast calls returned 0/0/0) and corrected via
        // setV3TokenBurnBps/setV3QuoteCreatorBps/setV3CtoFee on that already-
        // live proxy -- this fix only matters for a FUTURE fresh deploy.
        v3TokenBurnBps = 5_000;
        v3QuoteCreatorBps = 5_000;
        v3CtoFee = 50e18;
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

    function setV3TokenBurnBps(uint16 bps) external onlyOwner {
        if (bps > 10_000) revert InvalidBps();
        v3TokenBurnBps = bps;
        emit V3TokenBurnBpsSet(bps);
    }

    function setV3QuoteCreatorBps(uint16 bps) external onlyOwner {
        if (bps > 10_000) revert InvalidBps();
        v3QuoteCreatorBps = bps;
        emit V3QuoteCreatorBpsSet(bps);
    }

    function setV3CtoFee(uint256 fee_) external onlyOwner {
        v3CtoFee = fee_;
        emit V3CTOFeeSet(fee_);
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
            positionManager: positionManager,
            isV3:            false,
            creator:         address(0)
        });
        allTokens.push(token);
        emit PositionRegistered(token, tokenId, poolId, hook, positionManager);
    }

    // V3 has no hook, so there's no poolId/hook to record and the creator
    // has to be stored here directly instead of looked up from one.
    function registerPositionV3(
        address token,
        uint256 tokenId,
        address token0,
        address token1,
        address positionManager,
        address creator
    ) external onlyLauncher {
        if (positions[token].tokenId != 0) revert AlreadyRegistered();
        if (creator == address(0)) revert ZeroAddress();
        positions[token] = Position({
            tokenId:         tokenId,
            token0:          token0,
            token1:          token1,
            poolId:          bytes32(0),
            hook:            address(0),
            positionManager: positionManager,
            isV3:            true,
            creator:         creator
        });
        allTokens.push(token);
        emit PositionRegistered(token, tokenId, bytes32(0), address(0), positionManager);
    }

    // A pending application must be resolved before a new one can be filed
    // for the same token -- otherwise a second applicant would overwrite the
    // first's record after the first's non-refundable fee was already paid.
    // Mirrors DuckHookV4Arc.applyForCTO exactly, just keyed by token and
    // settled here since a V3 position has no hook to host this on.
    function applyForCTOV3(address token, address newCreator) external payable {
        Position storage pos = positions[token];
        if (pos.tokenId == 0 || !pos.isV3) revert UnknownToken();
        if (newCreator == address(0)) revert ZeroAddress();
        if (platformWallet == address(0)) revert ZeroAddress();
        if (msg.value < v3CtoFee) revert InsufficientCTOFee();
        if (v3CtoApplications[token].newCreator != address(0)) revert CTOApplicationPending();
        v3CtoApplications[token] = V3CTOApplication({applicant: msg.sender, newCreator: newCreator, paid: msg.value});
        (bool ok,) = platformWallet.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
        emit V3CTOApplied(token, msg.sender, newCreator, msg.value);
    }

    function approveCTOV3(address token) external onlyOwner {
        V3CTOApplication memory app = v3CtoApplications[token];
        if (app.newCreator == address(0)) revert NoCTOApplication();
        positions[token].creator = app.newCreator;
        delete v3CtoApplications[token];
        emit V3CTOApproved(token, app.newCreator);
    }

    function rejectCTOV3(address token) external onlyOwner {
        V3CTOApplication memory app = v3CtoApplications[token];
        if (app.newCreator == address(0)) revert NoCTOApplication();
        delete v3CtoApplications[token];
        emit V3CTORejected(token, app.applicant);
    }

    function claimFees(address token) external {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();

        address creator = _poolCreator(pos);
        if (msg.sender != creator && msg.sender != owner() && msg.sender != address(this))
            revert NotAuthorized();

        _collectAndDistribute(token, pos);

        // V3 has no hook -- the creator's cut is already paid out directly
        // inside _collectAndDistribute's V3 branch above, there's nothing
        // separate to claim here.
        if (pos.isV3) return;

        // Best-effort: the hook pays creator/platform directly out of its own
        // separately-accrued sell-fee balance -- if there's nothing accrued
        // it just no-ops, so this never blocks the LP-side claim above.
        try IDuckHookV4Minimal(pos.hook).claimFees(pos.poolId) {} catch {}
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
        if (pos.isV3) return pos.creator;
        (,,, creator,,,) = IDuckHookV4Minimal(pos.hook).pools(pos.poolId);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return 0x150b7a02;
    }

    function _collectAndDistribute(address token, Position storage pos) private {
        if (pos.isV3) {
            _collectAndDistributeV3(token, pos);
            return;
        }

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

        _safeTransfer(tokenSide, DEAD, burned);

        if (toPlatform > 0 && platformToken != address(0) && quoteSide == platformToken) {
            uint256 boughtBack = _swapForBurn(pos, quoteSide, tokenSide, toPlatform);
            if (boughtBack > 0) _safeTransfer(tokenSide, DEAD, boughtBack);
            emit FeesClaimed(token, burned + boughtBack, 0);
        } else {
            _safeTransfer(quoteSide, platformWallet, toPlatform);
            emit FeesClaimed(token, burned, toPlatform);
        }
    }

    // No hook on V3 -- collect() pulls everything accrued (both directions,
    // one uniform fee tier) directly to this contract in one call, no
    // before/after balance diffing needed since collect() returns the exact
    // amounts. v3TokenBurnBps/v3QuoteCreatorBps (each owner-updateable) then
    // decide the three-way split described where they're declared above.
    function _collectAndDistributeV3(address token, Position storage pos) private {
        (uint256 a0, uint256 a1) = IPositionManagerV3(pos.positionManager).collect(
            IPositionManagerV3.CollectParams({
                tokenId:     pos.tokenId,
                recipient:   address(this),
                amount0Max:  type(uint128).max,
                amount1Max:  type(uint128).max
            })
        );
        if (a0 == 0 && a1 == 0) return;

        bool tokenIsCurrency0 = pos.token0 == token;
        (uint256 tokenAmt, uint256 quoteAmt) = tokenIsCurrency0 ? (a0, a1) : (a1, a0);
        (address tokenSide, address quoteSide) = tokenIsCurrency0
            ? (pos.token0, pos.token1)
            : (pos.token1, pos.token0);

        uint256 burned = (tokenAmt * v3TokenBurnBps) / 10_000;
        uint256 creatorTokenCut = tokenAmt - burned;
        uint256 creatorQuoteCut = (quoteAmt * v3QuoteCreatorBps) / 10_000;
        uint256 platformCut = quoteAmt - creatorQuoteCut;

        _safeTransfer(tokenSide, DEAD, burned);
        _safeTransfer(tokenSide, pos.creator, creatorTokenCut);
        _safeTransfer(quoteSide, pos.creator, creatorQuoteCut);
        _safeTransfer(quoteSide, platformWallet, platformCut);

        emit FeesClaimedV3(token, burned, creatorTokenCut + creatorQuoteCut, platformCut);
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

    receive() external payable {}
}
