// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckIncubationToken

import "./interfaces/IDuckIncubationToken.sol";

contract DuckIncubationToken is IDuckIncubationToken {

    error NotOwner();
    error NotLaunchManager();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error ExceedsAllowance();
    error BNBTransferFailed();
    error TokenRescueFailed();
    error CannotRescueOwnToken();
    error PermitExpired();
    error InvalidSignature();
    error LaunchPhaseAlreadyEnded();
    error LaunchPhaseTransferRestricted();

    bool    private _initialized;
    bool    private _inLaunchPhase;
    address private _owner;
    address public  launchManager;

    string  private _name;
    string  private _symbol;
    uint256 private _totalSupply;

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;
    bytes32 private _DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;

    string private _metaURI;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event MetaURIUpdated(string uri);

    modifier onlyLaunchManager() { if (msg.sender != launchManager) revert NotLaunchManager(); _; }
    modifier onlyOwner()         { if (msg.sender != _owner)        revert NotOwner();   _; }

    constructor() { _initialized = true; }

    function initForLaunchpad(
        string  calldata name_,
        string  calldata symbol_,
        uint256          totalSupply_,
        address          launchManager_,
        address          tokenOwner_,
        string  calldata metaURI_
    ) external {
        if (_initialized)                  revert AlreadyInitialized();
        if (launchManager_ == address(0))  revert ZeroAddress();
        if (tokenOwner_     == address(0)) revert ZeroAddress();
        _initialized = true;
        _inLaunchPhase = true;

        launchManager = launchManager_;
        _owner       = tokenOwner_;
        _name        = name_;
        _symbol      = symbol_;
        _totalSupply = totalSupply_;

        _metaURI     = metaURI_;
        _balances[launchManager_] = totalSupply_;
        emit Transfer(address(0), launchManager_, totalSupply_);
        emit OwnershipTransferred(address(0), tokenOwner_);

        _cachedChainId    = block.chainid;
        _DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    function metaURI() external view override returns (string memory) { return _metaURI; }

    function setMetaURI(string calldata uri_) external override onlyOwner {
        _metaURI = uri_;
        emit MetaURIUpdated(uri_);
    }

    function postMigrateSetup() external override onlyLaunchManager {
        if (!_inLaunchPhase) revert LaunchPhaseAlreadyEnded();
        _inLaunchPhase = false;
    }

    function inLaunchPhase() public view returns (bool) { return _inLaunchPhase; }

    function owner() external view returns (address) { return _owner; }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function name()        external view returns (string memory) { return _name;   }
    function symbol()      external view returns (string memory) { return _symbol; }
    function decimals()    external pure returns (uint8)         { return 18;      }
    function totalSupply() external view override returns (uint256) { return _totalSupply; }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed < amount) revert ExceedsAllowance();
        unchecked { _allowances[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (_inLaunchPhase) {
            if (from != launchManager && to != launchManager) revert LaunchPhaseTransferRestricted();
        }
        if (_balances[from] < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] -= amount;
            _balances[to]   += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        if (owner_ == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    // Recomputed on chain forks.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _cachedChainId) return _DOMAIN_SEPARATOR;
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(_name)),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    function permit(
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH, owner_, spender, value, nonces[owner_]++, deadline
        ));
        address signer = ecrecover(
            keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash)),
            v, r, s
        );
        if (signer == address(0) || signer != owner_) revert InvalidSignature();
        _approve(owner_, spender, value);
    }

    function rescueBNB(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = to.call{value: bal}('');
        if (!ok) revert BNBTransferFailed();
    }

    receive() external payable {}

    // Cannot rescue the contract's own token (would allow draining vesting balances).
    function rescueTokens(address tokenAddr, address to) external onlyOwner {
        if (tokenAddr == address(0) || to == address(0)) revert ZeroAddress();
        if (tokenAddr == address(this)) revert CannotRescueOwnToken();
        uint256 bal = IERC20RescueUC(tokenAddr).balanceOf(address(this));
        if (bal == 0) return;
        bool ok = IERC20RescueUC(tokenAddr).transfer(to, bal);
        if (!ok) revert TokenRescueFailed();
    }
}

interface IERC20RescueUC {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}
