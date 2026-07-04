// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";

/// @title MorphoSwapStrategy
/// @notice A *cross-asset* yield adapter. To the vault it looks like a USDT0 strategy (deposits and
///         returns USDT0), but internally it swaps USDT0 ↔ a different stablecoin (e.g. USDC) so the
///         vault can tap higher-yield USDC Morpho vaults while players still stake and withdraw pure
///         USDT0. Withdrawals buy back *exactly* the USDT0 requested; the swap cost is borne by the
///         yield the position earned, and the vault's liquidity buffer front-runs claims — so the
///         cross-asset stranding of the old monolith cannot recur. Only the {GoalyVault} may move funds.
contract MorphoSwapStrategy is IStrategy {
    using SafeERC20 for IERC20;

    uint16 internal constant BPS = 10_000;

    IERC20 private immutable _asset; // USDT0 (the vault's asset)
    IERC20 public immutable yieldAsset; // e.g. USDC
    IERC4626 public immutable morpho; // the USDC Morpho vault
    ISwapRouter public immutable router;
    address public immutable vault;
    uint24 public immutable poolFee; // Uniswap V3 fee tier for the stable pair
    uint16 public immutable maxSlippageBps;

    error OnlyVault();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(
        IERC20 asset_,
        IERC4626 morpho_,
        ISwapRouter router_,
        address vault_,
        uint24 poolFee_,
        uint16 maxSlippageBps_
    ) {
        _asset = asset_;
        morpho = morpho_;
        yieldAsset = IERC20(morpho_.asset());
        router = router_;
        vault = vault_;
        poolFee = poolFee_;
        maxSlippageBps = maxSlippageBps_;
    }

    function asset() external view returns (IERC20) {
        return _asset;
    }

    /// @dev The USDC position valued 1:1 in USDT0 (a stable pair). The tiny swap spread is covered by
    ///      the vault's buffer; the position's higher yield outgrows it over time.
    function totalAssets() public view returns (uint256) {
        return morpho.convertToAssets(morpho.balanceOf(address(this)));
    }

    /// @dev Conservatively haircut by the max slippage so a subsequent exact-out withdraw always has
    ///      enough USDC to cover it — the vault never over-relies on this strategy for liquidity.
    function maxWithdraw() external view returns (uint256) {
        return (morpho.maxWithdraw(address(this)) * (BPS - maxSlippageBps)) / BPS;
    }

    function deposit(uint256 assets) external onlyVault {
        _asset.safeTransferFrom(vault, address(this), assets);
        uint256 usdcOut = _swapExactIn(_asset, yieldAsset, assets);
        yieldAsset.forceApprove(address(morpho), usdcOut);
        morpho.deposit(usdcOut, address(this));
    }

    function withdraw(uint256 assets) external onlyVault {
        uint256 maxIn = (assets * (BPS + maxSlippageBps)) / BPS;
        morpho.withdraw(maxIn, address(this), address(this));
        uint256 spent = _swapExactOut(yieldAsset, _asset, assets, maxIn);
        uint256 leftover = maxIn - spent;
        if (leftover > 0) {
            yieldAsset.forceApprove(address(morpho), leftover);
            morpho.deposit(leftover, address(this));
        }
        _asset.safeTransfer(vault, assets);
    }

    function withdrawAll() external onlyVault returns (uint256 assets) {
        uint256 shares = morpho.balanceOf(address(this));
        if (shares == 0) return 0;
        uint256 usdc = morpho.redeem(shares, address(this), address(this));
        assets = _swapExactIn(yieldAsset, _asset, usdc);
        _asset.safeTransfer(vault, assets);
    }

    function _swapExactIn(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn)
        internal
        returns (uint256)
    {
        tokenIn.forceApprove(address(router), amountIn);
        return router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: (amountIn * (BPS - maxSlippageBps)) / BPS,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _swapExactOut(IERC20 tokenIn, IERC20 tokenOut, uint256 amountOut, uint256 amountInMax)
        internal
        returns (uint256)
    {
        tokenIn.forceApprove(address(router), amountInMax);
        return router.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
