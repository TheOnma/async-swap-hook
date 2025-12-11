// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {AsyncSwapHook} from "../src/AsyncSwapHook.sol";

contract AsyncSwapHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency token0;
    Currency token1;
    AsyncSwapHook hook;

    function setUp() public {
        // Deploy v4 core
        deployFreshManagerAndRouters();

        // Deploy tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy hook with correct flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address(flags);

        deployCodeTo("AsyncSwapHook.sol", abi.encode(manager), hookAddress);
        hook = AsyncSwapHook(payable(hookAddress));

        // Approve hook
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // Initialize pool
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        // Add full range liquidity (100 ether)
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // Helper function to get the actual swap ID
    function _getSwapIdFromEvent() internal view returns (bytes32) {
        uint256 swapAmount = 2 ether;
        uint256 currentCount = hook.pendingSwapCount() - 1;

        bytes32 swapId = keccak256(
            abi.encodePacked(
                address(swapRouter), // sender is the router here
                key.toId(),
                swapAmount,
                block.timestamp,
                currentCount
            )
        );

        return swapId;
    }

    // ============================================
    // TEST 1: Small swaps should pass through
    // ============================================
    function test_SmallSwap_PassesThrough() public {
        // Small swap (0.5 ether < 1% of 100 ether liquidity)
        uint256 swapAmount = 0.5 ether;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 balance0Before = token0.balanceOfSelf();
        uint256 balance1Before = token1.balanceOfSelf();

        // Execute swap
        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), ZERO_BYTES);

        uint256 balance0After = token0.balanceOfSelf();
        uint256 balance1After = token1.balanceOfSelf();

        // Verify swap executed immediately
        assertEq(balance0Before - balance0After, swapAmount, "Token0 not spent");
        assertGt(balance1After, balance1Before, "Token1 not received");

        // Hook should not be holding any tokens
        assertEq(token0.balanceOf(address(hook)), 0, "Hook holding token0");
        assertEq(token1.balanceOf(address(hook)), 0, "Hook holding token1");

        // No pending swaps
        assertEq(hook.pendingSwapCount(), 0, "Unexpected pending swap");
    }

    // ============================================
    // TEST 2: Large swaps should get paused
    // ============================================
    function test_LargeSwap_GetsPaused() public {
        // Large swap (2 ether > 1% of 100 ether liquidity)
        uint256 swapAmount = 2 ether;
        uint256 minAmountOut = 0;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        bytes memory hookData = abi.encode(minAmountOut);

        uint256 balance0Before = token0.balanceOfSelf();
        uint256 balance1Before = token1.balanceOfSelf();

        // Execute swap
        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), hookData);

        uint256 balance0After = token0.balanceOfSelf();
        uint256 balance1After = token1.balanceOfSelf();

        // Verify tokens were taken but no output yet
        assertEq(balance0Before - balance0After, swapAmount, "Token0 not taken");
        assertEq(balance1After, balance1Before, "Token1 received too early");

        // Hook should be holding the input tokens
        assertEq(token0.balanceOf(address(hook)), swapAmount, "Hook not holding tokens");

        // Should have created a pending swap
        assertEq(hook.pendingSwapCount(), 1, "No pending swap created");
    }

    // ============================================
    // TEST 3: Execute paused swap after delay
    // ============================================
    function test_ExecuteSwap_AfterDelay() public {
        address executor = address(0xBEEF);
        uint256 swapAmount = 2 ether;
        uint256 minAmountOut = 0;

        // Pause a large swap
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(minAmountOut));

        // Get the swap ID
        bytes32 swapId = _getSwapIdFromEvent();

        // Verify the swap exists
        AsyncSwapHook.PendingSwap memory swap = hook.getPendingSwap(swapId);
        assertEq(swap.user, address(swapRouter), "Wrong user");
        assertEq(swap.amountIn, swapAmount, "Wrong amount");

        // Fast forward past delay
        vm.warp(block.timestamp + 120 seconds);

        // Record balances - note that user is swapRouter in this case
        uint256 routerBalance1Before = token1.balanceOf(address(swapRouter));
        uint256 executorBalance1Before = token1.balanceOf(executor);

        // Execute swap as executor
        vm.prank(executor);
        hook.executeSwap(swapId);

        // Verify outputs
        uint256 routerBalance1After = token1.balanceOf(address(swapRouter));
        uint256 executorBalance1After = token1.balanceOf(executor);

        // Router (the "user" in the swap) should receive most of output
        assertGt(routerBalance1After - routerBalance1Before, 0, "Router got no tokens");

        // Executor should receive fee
        assertGt(executorBalance1After - executorBalance1Before, 0, "Executor got no fee");

        // Calculate and verify fee is ~0.3%
        uint256 totalOutput =
            (routerBalance1After - routerBalance1Before) + (executorBalance1After - executorBalance1Before);
        uint256 executorFee = executorBalance1After - executorBalance1Before;
        uint256 expectedFee = (totalOutput * 30) / 10000;

        assertApproxEqAbs(executorFee, expectedFee, 1, "Executor fee incorrect");

        // Hook should be empty
        assertEq(token0.balanceOf(address(hook)), 0, "Hook holding token0");
        assertEq(token1.balanceOf(address(hook)), 0, "Hook holding token1");
    }

    // ============================================
    // TEST 4: Cannot execute too early
    // =======================================
    function test_CannotExecute_TooEarly() public {
        uint256 swapAmount = 2 ether;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0)));

        bytes32 swapId = _getSwapIdFromEvent();

        // Try to execute immediately (should fail)
        vm.expectRevert(bytes("Too early"));
        hook.executeSwap(swapId);
    }

    // =======================================
    // TEST 5: Cannot execute after expiry
    // ============================================
    function test_CannotExecute_Expired() public {
        uint256 swapAmount = 2 ether;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0)));

        bytes32 swapId = _getSwapIdFromEvent();

        // Fast forward way past expiry (24s + 60s + 10min + extra)
        vm.warp(block.timestamp + 15 minutes);

        // Try to execute (should fail)
        vm.expectRevert(bytes("Expired"));
        hook.executeSwap(swapId);
    }

    // ============================================
    // TEST 6: Slippage protection works
    // ============================================
    function test_SlippageProtection() public {
        uint256 swapAmount = 2 ether;
        uint256 impossibleMinOut = 1000 ether; // Way more than possible

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(impossibleMinOut));

        bytes32 swapId = _getSwapIdFromEvent();

        vm.warp(block.timestamp + 120 seconds);

        // Should revert due to slippage
        vm.expectRevert(bytes("Slippage exceeded"));
        hook.executeSwap(swapId);
    }

    // ============================================
    // TEST 7: Cancel swap after expiry
    // ============================================
    function test_CancelSwap_AfterExpiry() public {
        uint256 swapAmount = 2 ether;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0)));

        bytes32 swapId = _getSwapIdFromEvent();

        // Cannot cancel before expiry
        vm.prank(address(swapRouter)); // User is the swapRouter
        vm.expectRevert(bytes("Cannot cancel yet"));
        hook.cancelSwap(swapId);

        // Fast forward past expiry
        vm.warp(block.timestamp + 15 minutes);

        uint256 balance0Before = token0.balanceOf(address(swapRouter));

        // Now can cancel as the correct user (swapRouter)
        vm.prank(address(swapRouter));
        hook.cancelSwap(swapId);

        uint256 balance0After = token0.balanceOf(address(swapRouter));

        // Should get refund
        assertEq(balance0After - balance0Before, swapAmount, "Refund incorrect");

        // Hook should be empty
        assertEq(token0.balanceOf(address(hook)), 0);
    }

    // ============================================
    // TEST 8: Only owner can cancel
    // ============================================
    function test_OnlyOwner_CanCancel() public {
        uint256 swapAmount = 2 ether;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0)));

        bytes32 swapId = _getSwapIdFromEvent();

        vm.warp(block.timestamp + 15 minutes);

        // Try to cancel as different user (not swapRouter)
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("Not owner"));
        hook.cancelSwap(swapId);
    }

    // ============================================
    // TEST 9: Exact output swaps revert
    // ============================================
    function test_ExactOutput_Reverts() public {
        // Positive amount = exact output (not supported)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 2 ether, // Positive = exact output
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // The error gets wrapped, so we just check that it reverts
        vm.expectRevert();
        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), ZERO_BYTES);
    }

    // ============================================
    // TEST 10: Multiple swaps in sequence
    // ============================================
    function test_MultipleSwaps() public {
        uint256 swapAmount = 2 ether;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Pause first swap
        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0)));

        // Pause second swap
        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0)));

        // Should have 2 pending swaps
        assertEq(hook.pendingSwapCount(), 2, "Should have 2 pending swaps");

        // Hook should hold 4 ether total
        assertEq(token0.balanceOf(address(hook)), swapAmount * 2);
    }
}
