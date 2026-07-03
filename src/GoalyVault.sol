// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @title GoalyVault (goUSDT)
/// @notice ERC-20 receipt vault for Goaly. Deposit USDT0 → receive **goUSDT 1:1**; the deposit is
///         supplied to a Morpho ERC-4626 vault to earn yield. goUSDT is the token used to place
///         predictions and **always redeems 1:1 for USDT0** (no-loss).
///
///         The backing yield vault is migratable AND may hold a *different* stablecoin than USDT0
///         (e.g. a higher-APY USDC vault). When it does, the vault swaps USDT0 ↔ the yield asset at
///         the edges (deposit/withdraw/migrate) through a configurable Uniswap V3-style router.
///         Withdrawals use an exact-output swap so holders always receive the full USDT0 amount; the
///         swap cost is absorbed by accrued yield, keeping goUSDT strictly 1:1. Same-asset vaults
///         skip swapping entirely, so the common path is unchanged.
contract GoalyVault is ERC20, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    uint256 private constant BPS = 10_000;

    /// @notice The peg + deposit/withdraw token (USDT0). goUSDT is 1:1 with this.
    IERC20 public immutable asset;
    /// @notice Current Morpho ERC-4626 vault backing goUSDT (migratable).
    IERC4626 public yieldVault;
    /// @notice Underlying asset of `yieldVault` — equals `asset`, or another stablecoin when cross-asset.
    IERC20 public yieldAsset;

    /// @notice DEX router used to swap between `asset` and `yieldAsset` (Uniswap V3-style).
    ISwapRouter public swapRouter;
    /// @notice Pool fee tier for the swap (e.g. 100 = 0.01%, for stable pairs).
    uint24 public swapFee;
    /// @notice Max tolerated slippage on a swap, in bps (e.g. 50 = 0.5%). Guards every swap.
    uint256 public maxSlippageBps;

    event Deposited(address indexed receiver, uint256 assets);
    event Withdrawn(address indexed owner, address indexed receiver, uint256 assets);
    event YieldHarvested(address indexed to, uint256 amount);
    event YieldVaultMigrated(
        address indexed from, address indexed to, address indexed newAsset, uint256 assets
    );
    event SwapConfigUpdated(address router, uint24 fee, uint256 maxSlippageBps);

    error ZeroAmount();
    error ZeroAddress();
    error AssetMismatch();
    error NoYield();

    constructor(
        IERC20 _asset,
        IERC4626 _yieldVault,
        ISwapRouter _swapRouter,
        uint24 _swapFee,
        uint256 _maxSlippageBps
    ) ERC20("Goaly USDT0", "goUSDT") {
        // Start same-asset (USDT0) so the initial state needs no swap path configured to be safe.
        if (_yieldVault.asset() != address(_asset)) revert AssetMismatch();
        if (_maxSlippageBps > BPS) revert AssetMismatch();
        asset = _asset;
        yieldVault = _yieldVault;
        yieldAsset = _asset;
        swapRouter = _swapRouter;
        swapFee = _swapFee;
        maxSlippageBps = _maxSlippageBps;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    /// @dev goUSDT mirrors USDT0's 6 decimals.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice True when the backing vault holds a different token than USDT0 (swaps are active).
    function isCrossAsset() public view returns (bool) {
        return address(yieldAsset) != address(asset);
    }

    // --------------------------------------------------------------------------------------------
    // User flows
    // --------------------------------------------------------------------------------------------

    /// @notice Deposit `assets` USDT0 and mint `assets` goUSDT to `receiver` (1:1).
    function deposit(uint256 assets, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 deployable = address(yieldAsset) == address(asset)
            ? assets
            : _swapExactIn(asset, yieldAsset, assets);
        _depositToYield(deployable);
        _mint(receiver, assets);
        emit Deposited(receiver, assets);
        return assets;
    }

    /// @notice Burn `assets` goUSDT from the caller and redeem exactly `assets` USDT0 to `receiver`.
    function withdraw(uint256 assets, address receiver) external nonReentrant returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _burn(msg.sender, assets);
        if (address(yieldAsset) == address(asset)) {
            yieldVault.withdraw(assets, receiver, address(this));
        } else {
            // Over-redeem the yield asset, then buy *exactly* `assets` USDT0 so the holder is whole.
            uint256 maxIn = (assets * (BPS + maxSlippageBps)) / BPS;
            yieldVault.withdraw(maxIn, address(this), address(this));
            uint256 spent = _swapExactOut(yieldAsset, asset, assets, maxIn);
            uint256 leftover = maxIn - spent;
            if (leftover > 0) _depositToYield(leftover); // dust back to work
            asset.safeTransfer(receiver, assets);
        }
        emit Withdrawn(msg.sender, receiver, assets);
        return assets;
    }

    // --------------------------------------------------------------------------------------------
    // Accounting
    // --------------------------------------------------------------------------------------------

    /// @notice Total value backing the vault, in yield-asset units (~USD; stablecoins are ~1:1).
    function totalAssets() public view returns (uint256) {
        return yieldVault.convertToAssets(yieldVault.balanceOf(address(this)));
    }

    /// @notice Value accrued above total goUSDT principal (funds prizes / covers swap costs).
    function accruedYield() public view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 principal = totalSupply();
        return assets > principal ? assets - principal : 0;
    }

    /// @notice Harvest protocol yield to `to` (e.g. to fund market prizes), in the yield asset.
    function harvestYield(address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        returns (uint256 amount)
    {
        if (to == address(0)) revert ZeroAddress();
        amount = accruedYield();
        if (amount == 0) revert NoYield();
        yieldVault.withdraw(amount, to, address(this));
        emit YieldHarvested(to, amount);
    }

    // --------------------------------------------------------------------------------------------
    // Management
    // --------------------------------------------------------------------------------------------

    /// @notice Migrate the backing to `newYieldVault`, swapping the asset if it differs (cross-asset).
    ///         goUSDT holders are unaffected — only where the idle capital earns changes.
    function migrateYieldVault(IERC4626 newYieldVault)
        external
        onlyRole(MANAGER_ROLE)
        nonReentrant
    {
        IERC4626 old = yieldVault;
        IERC20 oldAsset = yieldAsset;
        IERC20 newAsset = IERC20(newYieldVault.asset());

        uint256 held = old.balanceOf(address(this));
        uint256 redeemed = held > 0 ? old.redeem(held, address(this), address(this)) : 0;
        uint256 deployable = redeemed;
        if (address(newAsset) != address(oldAsset) && redeemed > 0) {
            deployable = _swapExactIn(oldAsset, newAsset, redeemed);
        }

        yieldVault = newYieldVault;
        yieldAsset = newAsset;
        if (deployable > 0) _depositToYield(deployable);
        emit YieldVaultMigrated(address(old), address(newYieldVault), address(newAsset), deployable);
    }

    /// @notice Update the swap router / fee tier / slippage guard used for cross-asset backing.
    function setSwapConfig(ISwapRouter router, uint24 fee, uint256 maxSlippageBps_)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (address(router) == address(0)) revert ZeroAddress();
        if (maxSlippageBps_ > BPS) revert AssetMismatch();
        swapRouter = router;
        swapFee = fee;
        maxSlippageBps = maxSlippageBps_;
        emit SwapConfigUpdated(address(router), fee, maxSlippageBps_);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // --------------------------------------------------------------------------------------------
    // Internals
    // --------------------------------------------------------------------------------------------

    function _depositToYield(uint256 amount) internal {
        yieldAsset.forceApprove(address(yieldVault), amount);
        yieldVault.deposit(amount, address(this));
    }

    /// @dev Swap all of `amountIn` `tokenIn` for `tokenOut`, bounded by the slippage guard (1:1 ref).
    function _swapExactIn(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        tokenIn.forceApprove(address(swapRouter), amountIn);
        uint256 minOut = (amountIn * (BPS - maxSlippageBps)) / BPS;
        amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Buy exactly `amountOut` `tokenOut`, spending at most `maxIn` `tokenIn`.
    function _swapExactOut(IERC20 tokenIn, IERC20 tokenOut, uint256 amountOut, uint256 maxIn)
        internal
        returns (uint256 amountIn)
    {
        tokenIn.forceApprove(address(swapRouter), maxIn);
        amountIn = swapRouter.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: maxIn,
                sqrtPriceLimitX96: 0
            })
        );
        tokenIn.forceApprove(address(swapRouter), 0); // clear residual approval
    }
}
