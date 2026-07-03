// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal ERC-4626 vault for tests. `accrue()` inflates managed assets to simulate yield.
contract MockERC4626 {
    MockERC20 public immutable underlying;
    uint256 public totalShares;
    uint256 public totalManaged;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 _underlying) {
        underlying = _underlying;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = totalShares == 0 ? assets : (assets * totalShares) / totalManaged;
        underlying.transferFrom(msg.sender, address(this), assets);
        totalManaged += assets;
        totalShares += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        shares = (assets * totalShares + totalManaged - 1) / totalManaged; // ceil
        balanceOf[owner] -= shares;
        totalShares -= shares;
        totalManaged -= assets;
        underlying.transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        assets = (shares * totalManaged) / totalShares;
        balanceOf[owner] -= shares;
        totalShares -= shares;
        totalManaged -= assets;
        underlying.transfer(receiver, assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return totalShares == 0 ? 0 : (shares * totalManaged) / totalShares;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function totalAssets() external view returns (uint256) {
        return totalManaged;
    }

    /// @dev Test helper: mint extra underlying to the vault, raising share value (yield).
    function accrue(uint256 amount) external {
        underlying.mint(address(this), amount);
        totalManaged += amount;
    }
}
