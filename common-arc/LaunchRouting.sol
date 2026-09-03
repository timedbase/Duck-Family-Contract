// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family — LaunchRouting

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IV3SwapRouterNoDeadline {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

// Some V2-style routers only expose the fee-on-transfer-supporting swap
// variant (plain swapExactETHForTokens doesn't exist) — takes an extra
// `referrer` param and returns nothing, so amountOut is read back via a
// balance diff on the recipient instead of a return array.
interface IUniswapV2Router {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin, address[] calldata path, address to, address referrer, uint256 deadline
    ) external payable;
}

interface IERC20BalanceRouting {
    function balanceOf(address account) external view returns (uint256);
}

// Uniswap's UniversalRouter (verified on Ink at 0x1129...1fa0, same contract
// this platform already uses for its own V4 swaps). Its V3_SWAP_EXACT_IN
// command computes the target pool address via CREATE2 from a factory
// address baked into the router's own bytecode at deployment -- it never
// calls factory.getPool() -- so this only ever reaches pools created by
// whichever V3 factory that router was deployed against.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24  fee;
    int24   tickSpacing;
    address hooks;
}

struct SwapParams {
    bool    zeroForOne;
    int256  amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IV4PoolManagerSwap {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

interface IWETH {
    function deposit() external payable;
}

enum RouteShape { V2_STYLE, V3_STYLE, V4_STYLE, UNIVERSAL_ROUTER_STYLE }

struct Route {
    RouteShape shape;
    bool       enabled;
    address    router;
    bool       routerNoDeadline;
    address[]  path;
    uint24[]   fees;
    address[]  routers;
    address    singleton;   // V4 PoolManager
    address    hook;
    uint24     fee;
    int24      tickSpacing;
}

abstract contract LaunchRouting {

    error Unauthorized();
    error InsufficientOutput();
    error ApprovalFailed();
    error TransferFailed();

    uint160 internal constant ROUTING_MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant ROUTING_MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    mapping(address => Route[]) public routes;

    event RouteSucceeded(address indexed quoteToken, uint256 indexed routeIndex, uint256 amountOut);
    event RoutesSet(address indexed quoteToken, uint256 count);

    address private _cbExpected;

    function _weth() internal view virtual returns (address);

    function _setRoutes(address quoteToken_, Route[] memory routes_) internal {
        delete routes[quoteToken_];
        for (uint256 i; i < routes_.length; ++i) {
            routes[quoteToken_].push(routes_[i]);
        }
        emit RoutesSet(quoteToken_, routes_.length);
    }

    function _acquireQuoteToken(address quoteToken_, uint256 nativeIn_, uint256 minOut_, address recipient_)
        internal returns (uint256 amountOut, bool ok)
    {
        Route[] storage list = routes[quoteToken_];
        for (uint256 i; i < list.length; ++i) {
            if (!list[i].enabled) continue;
            try this.executeRoute{value: nativeIn_}(list[i], quoteToken_, nativeIn_, minOut_, recipient_)
                returns (uint256 out)
            {
                emit RouteSucceeded(quoteToken_, i, out);
                return (out, true);
            } catch {}
        }
        return (0, false);
    }

    function executeRoute(Route calldata route_, address quoteToken_, uint256 amountIn_, uint256 minOut_, address recipient_)
        external payable returns (uint256 amountOut)
    {
        if (msg.sender != address(this)) revert Unauthorized();
        if (route_.shape == RouteShape.V2_STYLE) {
            amountOut = _swapV2Style(route_, amountIn_, minOut_, recipient_);
        } else if (route_.shape == RouteShape.V3_STYLE) {
            amountOut = _swapV3Style(route_, amountIn_, minOut_, recipient_);
        } else if (route_.shape == RouteShape.UNIVERSAL_ROUTER_STYLE) {
            amountOut = _swapUniversalRouterStyle(route_, amountIn_, minOut_, recipient_);
        } else {
            amountOut = _swapV4Style(route_, quoteToken_, amountIn_, minOut_, recipient_);
        }
    }

    function _swapV2Style(Route calldata route_, uint256 amountIn_, uint256 minOut_, address recipient_)
        private returns (uint256 amountOut)
    {
        address tokenOut = route_.path[route_.path.length - 1];
        uint256 balBefore = IERC20BalanceRouting(tokenOut).balanceOf(recipient_);
        IUniswapV2Router(route_.router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn_}(
            minOut_, route_.path, recipient_, address(0), block.timestamp
        );
        amountOut = IERC20BalanceRouting(tokenOut).balanceOf(recipient_) - balBefore;
    }

    function _swapV3Style(Route calldata route_, uint256 amountIn_, uint256 minOut_, address recipient_)
        private returns (uint256 amountOut)
    {
        if (route_.routers.length > 0) {
            return _swapV3ChainedStyle(route_, amountIn_, minOut_, recipient_);
        }

        address weth = _weth();
        IWETH(weth).deposit{value: amountIn_}();
        _safeApprove(weth, route_.router, amountIn_);

        if (route_.path.length == 2) {
            if (route_.routerNoDeadline) {
                amountOut = IV3SwapRouterNoDeadline(route_.router).exactInputSingle(IV3SwapRouterNoDeadline.ExactInputSingleParams({
                    tokenIn:           route_.path[0],
                    tokenOut:          route_.path[1],
                    fee:               route_.fees[0],
                    recipient:         recipient_,
                    amountIn:          amountIn_,
                    amountOutMinimum:  minOut_,
                    sqrtPriceLimitX96: 0
                }));
            } else {
                amountOut = ISwapRouter(route_.router).exactInputSingle(ISwapRouter.ExactInputSingleParams({
                    tokenIn:           route_.path[0],
                    tokenOut:          route_.path[1],
                    fee:               route_.fees[0],
                    recipient:         recipient_,
                    deadline:          block.timestamp,
                    amountIn:          amountIn_,
                    amountOutMinimum:  minOut_,
                    sqrtPriceLimitX96: 0
                }));
            }
        } else {
            bytes memory encodedPath = _encodeV3Path(route_.path, route_.fees);
            if (route_.routerNoDeadline) {
                amountOut = IV3SwapRouterNoDeadline(route_.router).exactInput(IV3SwapRouterNoDeadline.ExactInputParams({
                    path:             encodedPath,
                    recipient:        recipient_,
                    amountIn:         amountIn_,
                    amountOutMinimum: minOut_
                }));
            } else {
                amountOut = ISwapRouter(route_.router).exactInput(ISwapRouter.ExactInputParams({
                    path:             encodedPath,
                    recipient:        recipient_,
                    deadline:         block.timestamp,
                    amountIn:         amountIn_,
                    amountOutMinimum: minOut_
                }));
            }
        }
    }

    // route_.router = UniversalRouter; route_.path/fees = the V3 hop(s), same
    // packed encoding _encodeV3Path already produces for the plain V3 style.
    // WRAP_ETH deposits amountIn_ into WETH held by the router itself, then
    // V3_SWAP_EXACT_IN spends that balance directly (payerIsUser=false) --
    // no Permit2 approval needed since we fund the router's own balance
    // rather than have it pull from us.
    function _swapUniversalRouterStyle(Route calldata route_, uint256 amountIn_, uint256 minOut_, address recipient_)
        private returns (uint256 amountOut)
    {
        address tokenOut = route_.path[route_.path.length - 1];
        uint256 balBefore = IERC20BalanceRouting(tokenOut).balanceOf(recipient_);

        bytes memory commands = abi.encodePacked(bytes1(0x0b), bytes1(0x00)); // WRAP_ETH, V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(address(2), amountIn_); // ActionConstants.ADDRESS_THIS
        inputs[1] = abi.encode(recipient_, amountIn_, minOut_, _encodeV3Path(route_.path, route_.fees), false);

        IUniversalRouter(route_.router).execute{value: amountIn_}(commands, inputs, block.timestamp);

        amountOut = IERC20BalanceRouting(tokenOut).balanceOf(recipient_) - balBefore;
    }

    function _swapV3ChainedStyle(Route calldata route_, uint256 amountIn_, uint256 minOut_, address recipient_)
        private returns (uint256 amountOut)
    {
        address weth = _weth();
        IWETH(weth).deposit{value: amountIn_}();

        uint256 hopIn = amountIn_;
        uint256 hops  = route_.routers.length;
        for (uint256 i; i < hops; ++i) {
            address hopRouter    = route_.routers[i];
            address tokenIn      = route_.path[i];
            address tokenOut     = route_.path[i + 1];
            bool    isLast       = i == hops - 1;
            address hopRecipient = isLast ? recipient_ : address(this);
            uint256 hopMinOut    = isLast ? minOut_ : 0;

            _safeApprove(tokenIn, hopRouter, hopIn);
            if (route_.routerNoDeadline) {
                hopIn = IV3SwapRouterNoDeadline(hopRouter).exactInputSingle(IV3SwapRouterNoDeadline.ExactInputSingleParams({
                    tokenIn:           tokenIn,
                    tokenOut:          tokenOut,
                    fee:               route_.fees[i],
                    recipient:         hopRecipient,
                    amountIn:          hopIn,
                    amountOutMinimum:  hopMinOut,
                    sqrtPriceLimitX96: 0
                }));
            } else {
                hopIn = ISwapRouter(hopRouter).exactInputSingle(ISwapRouter.ExactInputSingleParams({
                    tokenIn:           tokenIn,
                    tokenOut:          tokenOut,
                    fee:               route_.fees[i],
                    recipient:         hopRecipient,
                    deadline:          block.timestamp,
                    amountIn:          hopIn,
                    amountOutMinimum:  hopMinOut,
                    sqrtPriceLimitX96: 0
                }));
            }
        }
        amountOut = hopIn;
    }

    function _swapV4Style(Route calldata route_, address quoteToken_, uint256 amountIn_, uint256 minOut_, address recipient_)
        private returns (uint256 amountOut)
    {
        amountOut = _executeV4Swap(route_.singleton, route_.hook, route_.fee, route_.tickSpacing, address(0), quoteToken_, amountIn_, minOut_, recipient_);
    }

    function _executeV4Swap(
        address singleton_,
        address hook_,
        uint24  fee_,
        int24   tickSpacing_,
        address currencyIn_,
        address currencyOut_,
        uint256 amountIn_,
        uint256 minOut_,
        address recipient_
    ) internal returns (uint256 amountOut) {
        _cbExpected = singleton_;
        bytes memory result = IV4PoolManagerSwap(singleton_).unlock(
            abi.encode(hook_, fee_, tickSpacing_, currencyIn_, currencyOut_, amountIn_, minOut_, recipient_)
        );
        _cbExpected = address(0);
        amountOut = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (_cbExpected == address(0) || msg.sender != _cbExpected) revert Unauthorized();
        (address hook_, uint24 fee_, int24 tickSpacing_, address currencyIn_, address currencyOut_, uint256 amountIn_, uint256 minOut_, address recipient_) =
            abi.decode(data, (address, uint24, int24, address, address, uint256, uint256, address));

        bool zeroForOne = currencyIn_ < currencyOut_;
        PoolKey memory key = PoolKey({
            currency0:   zeroForOne ? currencyIn_  : currencyOut_,
            currency1:   zeroForOne ? currencyOut_ : currencyIn_,
            fee:         fee_,
            tickSpacing: tickSpacing_,
            hooks:       hook_
        });
        int256 delta = IV4PoolManagerSwap(msg.sender).swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(amountIn_),
                sqrtPriceLimitX96: zeroForOne ? ROUTING_MIN_SQRT_PRICE + 1 : ROUTING_MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 amountOut = zeroForOne ? uint256(uint128(int128(delta))) : uint256(uint128(int128(delta >> 128)));
        if (amountOut < minOut_) revert InsufficientOutput();

        if (currencyIn_ == address(0)) {
            IV4PoolManagerSwap(msg.sender).settle{value: amountIn_}();
        } else {
            IV4PoolManagerSwap(msg.sender).sync(currencyIn_);
            _safeTransfer(currencyIn_, msg.sender, amountIn_);
            IV4PoolManagerSwap(msg.sender).settle();
        }
        IV4PoolManagerSwap(msg.sender).take(currencyOut_, recipient_, amountOut);
        return abi.encode(amountOut);
    }

    function _encodeV3Path(address[] calldata path, uint24[] calldata fees) private pure returns (bytes memory encoded) {
        encoded = abi.encodePacked(path[0]);
        for (uint256 i; i < fees.length; ++i) {
            encoded = abi.encodePacked(encoded, fees[i], path[i + 1]);
        }
    }

    function _safeApprove(address token_, address spender, uint256 amount) internal {
        (bool reset,) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, 0));
        reset;
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert ApprovalFailed();
    }

    function _safeTransfer(address token_, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
