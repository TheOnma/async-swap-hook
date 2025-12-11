// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

contract AsyncSwapHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    // ============ Constants ============
    uint256 public constant LIQUIDITY_THRESHOLD_BPS = 100; // 1% of liquidity
    uint256 public constant MIN_DELAY = 24 seconds;
    uint256 public constant EXECUTION_WINDOW = 60 seconds;
    uint256 public constant MAX_PENDING_TIME = 10 minutes;
    uint256 public constant EXECUTOR_FEE_BPS = 30; // 0.3%
    uint256 public constant BASIS_POINTS = 10000;

    // ============ Structs ============
    struct PendingSwap {
        address user;
        PoolKey poolKey;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
        uint160 sqrtPriceLimitX96;
        uint40 validAfter;
        uint40 validUntil;
        bool executed;
    }

    // ============ Storage ============
    mapping(bytes32 => PendingSwap) public pendingSwaps;
    uint256 public pendingSwapCount;

    // ============ Events ============
    event SwapPaused(
        bytes32 indexed swapId, address indexed user, uint256 amountIn, uint256 validAfter, uint256 validUntil
    );
    event SwapExecuted(bytes32 indexed swapId, address indexed executor, uint256 amountOut, uint256 fee);
    event SwapCancelled(bytes32 indexed swapId);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Hook Implementation ============
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Bypass when hook is executing its own swaps
        if (sender == address(this)) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // Only handle exact input swaps (negative amountSpecified)
        if (params.amountSpecified > 0) {
            revert("AsyncSwapHook: Exact Input Only");
        }

        // Check if this is a large swap
        if (!_isLargeSwap(key, params)) {
            // Small swap - let it through immediately
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // Large swap - pause it
        uint256 amountIn = uint256(-params.amountSpecified);

        // Decode minAmountOut from hookData if provided
        uint256 minAmountOut = 0;
        if (hookData.length > 0) {
            (minAmountOut) = abi.decode(hookData, (uint256));
        }

        // Generate swap ID
        bytes32 swapId = keccak256(abi.encodePacked(sender, key.toId(), amountIn, block.timestamp, pendingSwapCount++));

        // Calculate random delay
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, swapId)));
        uint256 randomDelay = seed % EXECUTION_WINDOW;
        uint40 validAfter = uint40(block.timestamp + MIN_DELAY + randomDelay);
        uint40 validUntil = uint40(validAfter + EXECUTION_WINDOW + MAX_PENDING_TIME);

        // Store pending swap
        pendingSwaps[swapId] = PendingSwap({
            user: sender,
            poolKey: key,
            zeroForOne: params.zeroForOne,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            validAfter: validAfter,
            validUntil: validUntil,
            executed: false
        });

        emit SwapPaused(swapId, sender, amountIn, validAfter, validUntil);

        // Take custody of tokens from PoolManager
        // The router has already sent tokens to PoolManager, so we take them to hold
        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        currencyIn.take(poolManager, address(this), amountIn, false);

        // Return delta to consume the swap
        // This tells PoolManager we handled the input, and
        // there's no output
        BeforeSwapDelta delta = params.zeroForOne
            ? toBeforeSwapDelta(int128(int256(amountIn)), 0)
            : toBeforeSwapDelta(0, int128(int256(amountIn)));

        return (this.beforeSwap.selector, delta, 0);
    }

    // ============ Execution ============
    function executeSwap(bytes32 swapId) external {
        PendingSwap storage swap = pendingSwaps[swapId];
        require(!swap.executed, "Already executed");
        require(swap.user != address(0), "Swap does not exist");
        require(block.timestamp >= swap.validAfter, "Too early");
        require(block.timestamp <= swap.validUntil, "Expired");

        swap.executed = true;

        // Execute the swap using unlock pattern
        bytes memory result =
            poolManager.unlock(abi.encode(CallbackData({swapId: swapId, swap: swap, executor: msg.sender})));

        (, uint256 executorFee, uint256 userAmount) = abi.decode(result, (uint256, uint256, uint256));

        emit SwapExecuted(swapId, msg.sender, userAmount, executorFee);
    }

    // ============ Cancellation ============
    function cancelSwap(bytes32 swapId) external {
        PendingSwap storage swap = pendingSwaps[swapId];
        require(msg.sender == swap.user, "Not owner");
        require(!swap.executed, "Already executed");
        require(block.timestamp > swap.validUntil, "Cannot cancel yet");

        swap.executed = true;

        // Refund tokens
        Currency currencyIn = swap.zeroForOne ? swap.poolKey.currency0 : swap.poolKey.currency1;
        currencyIn.transfer(swap.user, swap.amountIn);

        emit SwapCancelled(swapId);
    }

    // ======= Unlock Callback ============
    struct CallbackData {
        bytes32 swapId;
        PendingSwap swap;
        address executor;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Not pool manager");

        CallbackData memory callback = abi.decode(data, (CallbackData));
        PendingSwap memory swap = callback.swap;

        // Reconstruct swap params
        SwapParams memory params = SwapParams({
            zeroForOne: swap.zeroForOne,
            amountSpecified: -int256(swap.amountIn),
            sqrtPriceLimitX96: swap.sqrtPriceLimitX96
        });

        // Execute swap
        BalanceDelta delta = poolManager.swap(swap.poolKey, params, "");

        // Settle input (we have the tokens so send to PM)
        Currency currencyIn = swap.zeroForOne ? swap.poolKey.currency0 : swap.poolKey.currency1;
        uint256 amountToSettle = swap.zeroForOne ? uint256(int256(-delta.amount0())) : uint256(int256(-delta.amount1()));
        currencyIn.settle(poolManager, address(this), amountToSettle, false);

        // Take output(PM sends to us)
        Currency currencyOut = swap.zeroForOne ? swap.poolKey.currency1 : swap.poolKey.currency0;
        uint256 amountOut = swap.zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        currencyOut.take(poolManager, address(this), amountOut, false);

        //Check slippage
        require(amountOut >= swap.minAmountOut, "Slippage exceeded");

        // Calculate fees
        uint256 executorFee = (amountOut * EXECUTOR_FEE_BPS) / BASIS_POINTS;
        uint256 userAmount = amountOut - executorFee;

        // Transfer tokens
        currencyOut.transfer(swap.user, userAmount);
        currencyOut.transfer(callback.executor, executorFee);

        return abi.encode(amountOut, executorFee, userAmount);
    }

    // ============ Internal Helpers ============
    function _isLargeSwap(PoolKey calldata key, SwapParams calldata params) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = poolManager.getLiquidity(key.toId());

        if (liquidity == 0) return false;

        uint256 amountIn = uint256(-params.amountSpecified);

        // Calculate threshold based on pool reserves
        uint256 threshold;
        if (params.zeroForOne) {
            // Reserve0 = (L * Q96) / sqrtP
            uint256 reserves0 = FullMath.mulDiv(uint256(liquidity), FixedPoint96.Q96, sqrtPriceX96);
            threshold = (reserves0 * LIQUIDITY_THRESHOLD_BPS) / BASIS_POINTS;
        } else {
            // Reserve1 = (L * sqrtP) / Q96
            uint256 reserves1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, FixedPoint96.Q96);
            threshold = (reserves1 * LIQUIDITY_THRESHOLD_BPS) / BASIS_POINTS;
        }

        return amountIn > threshold;
    }

    // ============ View Functions ============
    function getPendingSwap(bytes32 swapId) external view returns (PendingSwap memory) {
        return pendingSwaps[swapId];
    }

    function canExecute(bytes32 swapId) external view returns (bool) {
        PendingSwap memory swap = pendingSwaps[swapId];
        return !swap.executed && swap.user != address(0) && block.timestamp >= swap.validAfter
            && block.timestamp <= swap.validUntil;
    }

    receive() external payable {}
}
