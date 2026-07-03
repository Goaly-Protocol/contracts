// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

/// @title ISwapRouter
/// @notice Minimal Uniswap V3 SwapRouter surface used by GoalyVault for stable-to-stable swaps
///         between USDT0 and a cross-asset yield token. Kept as an interface so the concrete router
///         is configurable (maintainability) and mockable (testability).
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swap `amountIn` of `tokenIn` for as much `tokenOut` as possible.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Buy exactly `amountOut` of `tokenOut`, spending at most `amountInMaximum` of `tokenIn`.
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn);
}
