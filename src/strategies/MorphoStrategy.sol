// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title MorphoStrategy
/// @notice A *same-asset* yield adapter: it supplies the vault's USDT0 straight into a Morpho ERC-4626
///         vault whose underlying asset is USDT0. Because there is no cross-asset swap on the way out,
///         no swap-slippage shortfall can ever strand principal (the failure mode of the old
///         cross-asset design). Only the owning {GoalyVault} may move funds.
contract MorphoStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC20 private immutable _ASSET; // USDT0
    IERC4626 public immutable MORPHO; // underlying Morpho USDT0 vault
    address public immutable VAULT; // the GoalyVault (sole caller)

    error OnlyVault();

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    function _onlyVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }

    constructor(IERC4626 morpho_, address vault_) {
        MORPHO = morpho_;
        VAULT = vault_;
        _ASSET = IERC20(morpho_.asset());
    }

    function asset() external view returns (IERC20) {
        return _ASSET;
    }

    function totalAssets() public view returns (uint256) {
        return MORPHO.convertToAssets(MORPHO.balanceOf(address(this)));
    }

    function maxWithdraw() external view returns (uint256) {
        return MORPHO.maxWithdraw(address(this));
    }

    function deposit(uint256 assets) external onlyVault {
        _ASSET.safeTransferFrom(VAULT, address(this), assets);
        _ASSET.forceApprove(address(MORPHO), assets);
        MORPHO.deposit(assets, address(this));
    }

    /// @dev Sends `assets` USDT0 straight back to the vault. Reverts (via Morpho) if it exceeds
    ///      the live withdrawable liquidity — never a partial/silent fill.
    function withdraw(uint256 assets) external onlyVault {
        MORPHO.withdraw(assets, VAULT, address(this));
    }

    function withdrawAll() external onlyVault returns (uint256 assets) {
        uint256 shares = MORPHO.balanceOf(address(this));
        if (shares != 0) assets = MORPHO.redeem(shares, VAULT, address(this));
    }
}
