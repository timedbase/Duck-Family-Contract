// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckHookV4

// PoolKey/SwapParams are imported (not redeclared) from LaunchRouting so
// every contract that passes a PoolKey around shares one identical type --
// Solidity treats separately-declared structs as incompatible even with
// matching fields.
import {PoolKey, SwapParams} from "common-contracts/LaunchRouting.sol";

interface IPoolManagerMinimal {
    function take(address currency, address to, uint256 amount) external;
}

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract DuckHookV4 {

    error ZeroAddress();
    error NotOwner();
    error NotLauncher();
    error NotPoolManager();
    error AlreadyRegistered();
    error NotRegistered();
    error SameBlockSwap();
    error TransferFailed();
    error InsufficientCTOFee();
    error NoCTOApplication();
    error CTOApplicationPending();
    error NotCreator();
    error TooManyFeeSplits();
    error InvalidFeeSplitBps();
    error InvalidHookFeeBps();

    // beforeSwap | afterSwap | afterSwapReturnDelta, matching Uniswap V4's
    // Hooks.ALL_HOOK_MASK (0x3FFF, the low 14 bits of an address).
    uint160 public constant REQUIRED_PERMISSIONS = 0xC4;
    uint160 public constant PERMISSION_MASK      = 0x3FFF;

    uint256 public constant HOOK_FEE_DEFAULT_BPS = 200; // 2%, sells only
    uint256 private constant BPS                = 10_000;
    uint256 public constant MAX_FEE_SPLITS      = 5;

    address public immutable poolManager;
    address public owner;
    address public platformWallet; // receives CTO application fees
    mapping(address => bool) public isLauncher;

    // A creator may split their own pool's claimed fees across up to
    // MAX_FEE_SPLITS wallets instead of receiving them at their own address
    // directly. Empty (the default) means 100% to the creator.
    struct FeeSplit {
        address wallet;
        uint16  bps;
    }
    mapping(bytes32 => FeeSplit[]) private _feeSplits;

    struct PoolInfo {
        address token;
        address quoteCurrency;   // address(0) = native
        bool    tokenIsCurrency0;
        address creator;
        uint256 launchTimestamp;
        bool    registered;
        uint256 hookFeeBps;      // sell-fee rate for this pool; creator-chosen at registration
    }

    mapping(bytes32 => PoolInfo)                   public pools;
    mapping(bytes32 => mapping(address => uint256)) private _lastSwapBlock;
    mapping(bytes32 => uint256)                     public accruedFees;

    struct CTOApplication {
        address applicant;
        address newCreator;
        uint256 paid;
    }

    uint256 public ctoFee = 0.1 ether;
    mapping(bytes32 => CTOApplication) public ctoApplications;

    event PoolRegistered(bytes32 indexed poolId, address indexed token, address indexed creator, uint256 hookFeeBps);
    event FeesClaimed(bytes32 indexed poolId, uint256 amount);
    event CTOFeeSet(uint256 fee);
    event PlatformWalletSet(address indexed wallet);
    event FeeSplitsUpdated(bytes32 indexed poolId, FeeSplit[] splits);
    event CTOApplied(bytes32 indexed poolId, address indexed applicant, address newCreator, uint256 paid);
    event CTOApproved(bytes32 indexed poolId, address newCreator);
    event CTORejected(bytes32 indexed poolId, address indexed applicant);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event LauncherAdded(address indexed launcher);
    event LauncherRemoved(address indexed launcher);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(address poolManager_) {
        if (poolManager_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        owner       = msg.sender;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
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

    function setCTOFee(uint256 fee_) external onlyOwner {
        ctoFee = fee_;
        emit CTOFeeSet(fee_);
    }

    function setPlatformWallet(address wallet_) external onlyOwner {
        if (wallet_ == address(0)) revert ZeroAddress();
        platformWallet = wallet_;
        emit PlatformWalletSet(wallet_);
    }

    // A pending application must be resolved before a new one can be filed for
    // the same pool -- otherwise a second applicant would overwrite the
    // first's record after the first's non-refundable fee was already paid.
    function applyForCTO(bytes32 poolId, address newCreator) external payable {
        if (!pools[poolId].registered) revert NotRegistered();
        if (newCreator == address(0)) revert ZeroAddress();
        if (platformWallet == address(0)) revert ZeroAddress();
        if (msg.value < ctoFee) revert InsufficientCTOFee();
        if (ctoApplications[poolId].newCreator != address(0)) revert CTOApplicationPending();
        ctoApplications[poolId] = CTOApplication({applicant: msg.sender, newCreator: newCreator, paid: msg.value});
        (bool ok,) = platformWallet.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
        emit CTOApplied(poolId, msg.sender, newCreator, msg.value);
    }

    // Only the pool's own creator may configure where their claimed fees go.
    // Empty splits_ resets to the default (100% directly to the creator).
    function setFeeSplits(bytes32 poolId, FeeSplit[] calldata splits_) external {
        if (pools[poolId].creator != msg.sender) revert NotCreator();
        if (splits_.length > MAX_FEE_SPLITS) revert TooManyFeeSplits();

        uint256 totalBps;
        for (uint256 i; i < splits_.length; ++i) {
            if (splits_[i].wallet == address(0)) revert ZeroAddress();
            totalBps += splits_[i].bps;
        }
        if (splits_.length > 0 && totalBps != BPS) revert InvalidFeeSplitBps();

        delete _feeSplits[poolId];
        for (uint256 i; i < splits_.length; ++i) {
            _feeSplits[poolId].push(splits_[i]);
        }
        emit FeeSplitsUpdated(poolId, splits_);
    }

    function getFeeSplits(bytes32 poolId) external view returns (FeeSplit[] memory) {
        return _feeSplits[poolId];
    }

    function approveCTO(bytes32 poolId) external onlyOwner {
        CTOApplication memory app = ctoApplications[poolId];
        if (app.newCreator == address(0)) revert NoCTOApplication();
        pools[poolId].creator = app.newCreator;
        delete ctoApplications[poolId];
        emit CTOApproved(poolId, app.newCreator);
    }

    function rejectCTO(bytes32 poolId) external onlyOwner {
        CTOApplication memory app = ctoApplications[poolId];
        if (app.newCreator == address(0)) revert NoCTOApplication();
        delete ctoApplications[poolId];
        emit CTORejected(poolId, app.applicant);
    }

    // hookFeeBps_ == 0 means "use the default" (HOOK_FEE_DEFAULT_BPS, 2%);
    // any nonzero value must be exactly one of the creator-selectable tiers.
    function registerPool(PoolKey calldata key, address token, address creator, uint256 hookFeeBps_) external {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        if (!_isValidHookFeeBps(hookFeeBps_)) revert InvalidHookFeeBps();
        uint256 feeBps = hookFeeBps_ == 0 ? HOOK_FEE_DEFAULT_BPS : hookFeeBps_;
        bytes32 poolId = keccak256(abi.encode(key));
        if (pools[poolId].registered) revert AlreadyRegistered();
        bool tokenIsCurrency0 = key.currency0 == token;
        pools[poolId] = PoolInfo({
            token:            token,
            quoteCurrency:    tokenIsCurrency0 ? key.currency1 : key.currency0,
            tokenIsCurrency0: tokenIsCurrency0,
            creator:          creator,
            launchTimestamp:  block.timestamp,
            registered:       true,
            hookFeeBps:       feeBps
        });
        emit PoolRegistered(poolId, token, creator, feeBps);
    }

    function _isValidHookFeeBps(uint256 bps) private pure returns (bool) {
        return bps == 0 || bps == 100 || bps == 200 || bps == 300 || bps == 500;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, bytes calldata, bytes calldata) external pure returns (bytes4) {
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, bytes calldata, bytes calldata) external pure returns (bytes4) {
        return this.beforeRemoveLiquidity.selector;
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.afterDonate.selector;
    }

    // Permanent anti-MEV guard: a given address can't touch a registered
    // pool twice in the same block, full stop -- no expiry window, unlike
    // the old launch-only antibot this hook used to also apply.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external returns (bytes4, int256, uint24)
    {
        if (msg.sender != poolManager) revert NotPoolManager();
        bytes32 poolId = keccak256(abi.encode(key));
        if (!pools[poolId].registered) return (this.beforeSwap.selector, int256(0), 0);

        if (_lastSwapBlock[poolId][sender] == block.number) revert SameBlockSwap();
        _lastSwapBlock[poolId][sender] = block.number;

        return (this.beforeSwap.selector, int256(0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, int256 delta, bytes calldata)
        external returns (bytes4, int128)
    {
        if (msg.sender != poolManager) revert NotPoolManager();
        bytes32 poolId = keccak256(abi.encode(key));
        PoolInfo storage info = pools[poolId];
        if (!info.registered) return (this.afterSwap.selector, int128(0));

        // BalanceDelta packs (amount0 << 128 | amount1), each a signed int128.
        int128 amount0Delta = int128(delta >> 128);
        int128 amount1Delta = int128(delta);
        (int128 tokenDelta, int128 quoteDelta) = info.tokenIsCurrency0
            ? (amount0Delta, amount1Delta)
            : (amount1Delta, amount0Delta);

        bool isExactInputSell = tokenDelta < 0 && params.amountSpecified < 0;
        if (!isExactInputSell || quoteDelta <= 0) return (this.afterSwap.selector, int128(0));

        uint256 feeCut = uint256(uint128(quoteDelta)) * info.hookFeeBps / BPS;
        if (feeCut == 0) return (this.afterSwap.selector, int128(0));

        accruedFees[poolId] += feeCut;
        IPoolManagerMinimal(msg.sender).take(info.quoteCurrency, address(this), feeCut);
        return (this.afterSwap.selector, int128(int256(feeCut)));
    }

    // Paid to the creator, or split across their configured wallets (see
    // setFeeSplits) -- the platform's cut of pool revenue comes from the
    // separate 1% pool-tier LP fee instead (see DuckLocker).
    function claimFees(bytes32 poolId) external {
        PoolInfo storage info = pools[poolId];
        if (!info.registered) revert NotRegistered();

        uint256 amount = accruedFees[poolId];
        if (amount > 0) {
            accruedFees[poolId] = 0;
            _payCreator(poolId, info.creator, info.quoteCurrency, amount);
        }
        emit FeesClaimed(poolId, amount);
    }

    receive() external payable {}

    function _payCreator(bytes32 poolId, address creator, address currency, uint256 amount) private {
        FeeSplit[] storage splits = _feeSplits[poolId];
        if (splits.length == 0) {
            _pay(currency, creator, amount);
            return;
        }
        uint256 len = splits.length;
        uint256 remaining = amount;
        for (uint256 i; i < len; ++i) {
            uint256 cut = i == len - 1 ? remaining : (amount * splits[i].bps) / BPS;
            remaining -= cut;
            _pay(currency, splits[i].wallet, cut);
        }
    }

    function _pay(address currency, address to, uint256 amount) private {
        if (amount == 0) return;
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            if (!IERC20Minimal(currency).transfer(to, amount)) revert TransferFailed();
        }
    }
}
