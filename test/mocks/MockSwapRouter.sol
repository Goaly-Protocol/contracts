// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";
import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock Uniswap V3-style router for tests: a 1:1 stable swap minus a configurable fee.
///         Mints the output token so no pre-seeded liquidity is required.
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    uint256 public feeBps; // e.g. 5 = 0.05%
    uint256 private constant BPS = 10_000;

    constructor(uint256 _feeBps) {
        feeBps = _feeBps;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (p.amountIn * (BPS - feeBps)) / BPS;
        require(amountOut >= p.amountOutMinimum, "slippage");
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p)
        external
        payable
        returns (uint256 amountIn)
    {
        // Spend enough input to produce exactly amountOut after the fee (round up).
        amountIn = (p.amountOut * BPS + (BPS - feeBps) - 1) / (BPS - feeBps);
        require(amountIn <= p.amountInMaximum, "slippage");
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, p.amountOut);
    }
}
