// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

/// @notice Minimal ERC-4626 surface used by GoalYield (Morpho MetaMorpho vaults implement this).
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function totalAssets() external view returns (uint256);
}
