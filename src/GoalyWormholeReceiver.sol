// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IMessageTransmitter
} from "@wormhole-foundation/wormhole-solidity-sdk/interfaces/cctp/IMessageTransmitter.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

interface IGoalyVaultDeposit {
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

/// @title GoalyWormholeReceiver
/// @notice Completes a Wormhole (Circle CCTP) USDC transfer on Arbitrum and turns it into a Goaly
///         deposit. A user on any CCTP chain bridges USDC to this receiver via Wormhole; anyone can
///         then relay the Circle attestation here. We mint the USDC ({receiveMessage}), swap it to
///         USDT0, and deposit into {GoalyVault} — minting goUSDT to `recipient`. This is Goaly's
///         "deposit from any chain", over Wormhole/CCTP (replacing the previous LayerZero composer).
/// @dev The USDC is bound to the CCTP message (burned on the source with this contract as the mint
///      recipient); production should also bind `recipient` via a CCTP hook / Wormhole payload.
contract GoalyWormholeReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IMessageTransmitter public immutable messageTransmitter; // Circle CCTP on Arbitrum
    IERC20 public immutable usdc;
    IERC20 public immutable usdt0;
    IGoalyVaultDeposit public immutable vault;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable swapFee;

    event CrossChainDeposit(address indexed recipient, uint256 usdcIn, uint256 goUsdtOut);

    error MintFailed();
    error ZeroReceived();
    error ZeroAddress();

    constructor(
        IMessageTransmitter _messageTransmitter,
        IERC20 _usdc,
        IERC20 _usdt0,
        IGoalyVaultDeposit _vault,
        ISwapRouter _swapRouter,
        uint24 _swapFee
    ) {
        messageTransmitter = _messageTransmitter;
        usdc = _usdc;
        usdt0 = _usdt0;
        vault = _vault;
        swapRouter = _swapRouter;
        swapFee = _swapFee;
        _usdt0.forceApprove(address(_vault), type(uint256).max);
    }

    /// @notice Redeem a Wormhole/CCTP USDC transfer (`message` + Circle `attestation`), swap it to
    ///         USDT0 (min `minUsdt0`), and deposit into the vault — minting goUSDT to `recipient`.
    function receiveAndDeposit(
        bytes calldata message,
        bytes calldata attestation,
        address recipient,
        uint256 minUsdt0
    ) external nonReentrant returns (uint256 goUsdt) {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 balBefore = usdc.balanceOf(address(this));
        if (!messageTransmitter.receiveMessage(message, attestation)) revert MintFailed();
        uint256 usdcIn = usdc.balanceOf(address(this)) - balBefore;
        if (usdcIn == 0) revert ZeroReceived();

        usdc.forceApprove(address(swapRouter), usdcIn);
        uint256 usdt0Out = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(usdt0),
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdcIn,
                amountOutMinimum: minUsdt0,
                sqrtPriceLimitX96: 0
            })
        );

        goUsdt = vault.deposit(usdt0Out, recipient);
        emit CrossChainDeposit(recipient, usdcIn, goUsdt);
    }
}
