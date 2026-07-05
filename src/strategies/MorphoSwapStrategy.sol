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

    IERC20 private immutable _ASSET; // USDT0 (the vault's asset)
    IERC20 public immutable YIELD_ASSET; // e.g. USDC
    IERC4626 public immutable MORPHO; // the USDC Morpho vault
    ISwapRouter public immutable ROUTER;
    address public immutable VAULT;
    uint24 public immutable POOL_FEE; // Uniswap V3 fee tier for the stable pair
    uint16 public immutable MAX_SLIPPAGE_BPS;

    error OnlyVault();

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    function _onlyVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }

    constructor(
        IERC20 asset_,
        IERC4626 morpho_,
        ISwapRouter router_,
        address vault_,
        uint24 poolFee_,
        uint16 maxSlippageBps_
    ) {
        _ASSET = asset_;
        MORPHO = morpho_;
        YIELD_ASSET = IERC20(morpho_.asset());
        ROUTER = router_;
        VAULT = vault_;
        POOL_FEE = poolFee_;
        MAX_SLIPPAGE_BPS = maxSlippageBps_;
    }

    function asset() external view returns (IERC20) {
        return _ASSET;
    }

    /// @dev The USDC position valued 1:1 in USDT0 (a stable pair). The tiny swap spread is covered by
    ///      the vault's buffer; the position's higher yield outgrows it over time.
    function totalAssets() public view returns (uint256) {
        return MORPHO.convertToAssets(MORPHO.balanceOf(address(this)));
    }

    /// @dev Conservatively haircut by the max slippage so a subsequent exact-out withdraw always has
    ///      enough USDC to cover it — the vault never over-relies on this strategy for liquidity.
    function maxWithdraw() external view returns (uint256) {
        return (MORPHO.maxWithdraw(address(this)) * (BPS - MAX_SLIPPAGE_BPS)) / BPS;
    }

    function deposit(uint256 assets) external onlyVault {
        _ASSET.safeTransferFrom(VAULT, address(this), assets);
        uint256 usdcOut = _swapExactIn(_ASSET, YIELD_ASSET, assets);
        YIELD_ASSET.forceApprove(address(MORPHO), usdcOut);
        MORPHO.deposit(usdcOut, address(this));
    }

    function withdraw(uint256 assets) external onlyVault {
        uint256 maxIn = (assets * (BPS + MAX_SLIPPAGE_BPS)) / BPS;
        MORPHO.withdraw(maxIn, address(this), address(this));
        uint256 spent = _swapExactOut(YIELD_ASSET, _ASSET, assets, maxIn);
        uint256 leftover = maxIn - spent;
        if (leftover > 0) {
            YIELD_ASSET.forceApprove(address(MORPHO), leftover);
            MORPHO.deposit(leftover, address(this));
        }
        _ASSET.safeTransfer(VAULT, assets);
    }

    function withdrawAll() external onlyVault returns (uint256 assets) {
        uint256 shares = MORPHO.balanceOf(address(this));
        if (shares == 0) return 0;
        uint256 usdc = MORPHO.redeem(shares, address(this), address(this));
        assets = _swapExactIn(YIELD_ASSET, _ASSET, usdc);
        _ASSET.safeTransfer(VAULT, assets);
    }

    function _swapExactIn(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn)
        internal
        returns (uint256)
    {
        tokenIn.forceApprove(address(ROUTER), amountIn);
        return ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: (amountIn * (BPS - MAX_SLIPPAGE_BPS)) / BPS,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _swapExactOut(IERC20 tokenIn, IERC20 tokenOut, uint256 amountOut, uint256 amountInMax)
        internal
        returns (uint256)
    {
        tokenIn.forceApprove(address(ROUTER), amountInMax);
        return ROUTER.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
