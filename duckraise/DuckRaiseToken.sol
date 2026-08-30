// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — DuckRaiseToken

contract DuckRaiseToken {

    error AlreadyInitialized();
    error ZeroAddress();
    error NotOwner();
    error InsufficientBalance();
    error ExceedsAllowance();
    error PermitExpired();
    error InvalidSignature();

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    bool    private _initialized;
    address private _owner;

    string private _name;
    string  private _symbol;
    string  private _metaURI;
    uint256 private _totalSupply;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;
    bytes32 private _DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MetaURISet(string uri);

    constructor() { _initialized = true; }

    function initDuckRaise(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        _name    = name_;
        _symbol  = symbol_;
        _metaURI = metaURI_;
        emit MetaURISet(metaURI_);

        uint256 supply = TOTAL_SUPPLY;
        _totalSupply   = supply;
        _balances[msg.sender] = supply;
        emit Transfer(address(0), msg.sender, supply);

        _cachedChainId    = block.chainid;
        _DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    function name()        external view returns (string memory) { return _name;        }
    function symbol()      external view returns (string memory) { return _symbol;      }
    function decimals()    external pure returns (uint8)         { return 18;           }
    function totalSupply() external view returns (uint256)       { return _totalSupply; }
    function metaURI()     external view returns (string memory) { return _metaURI;     }
    function owner()       external view returns (address)       { return _owner;       }

    function setMetaURI(string calldata uri_) external {
        if (msg.sender != _owner) revert NotOwner();
        _metaURI = uri_;
        emit MetaURISet(uri_);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != _owner) revert NotOwner();
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() external {
        if (msg.sender != _owner) revert NotOwner();
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert ExceedsAllowance();
            unchecked { _allowances[from][msg.sender] = allowed - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - amount;
            _balances[to]  += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _cachedChainId ? _DOMAIN_SEPARATOR : _buildDomainSeparator();
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
        uint8 v, bytes32 r, bytes32 s
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
}
