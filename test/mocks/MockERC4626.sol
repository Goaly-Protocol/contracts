// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal ERC-4626 vault for tests. `accrue()` inflates managed assets to simulate yield.
contract MockERC4626 {
    using SafeERC20 for IERC20;

    MockERC20 public immutable UNDERLYING;
    uint256 public totalShares;
    uint256 public totalManaged;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 _underlying) {
        UNDERLYING = _underlying;
    }

    function asset() external view returns (address) {
        return address(UNDERLYING);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = totalShares == 0 ? assets : (assets * totalShares) / totalManaged;
        IERC20(address(UNDERLYING)).safeTransferFrom(msg.sender, address(this), assets);
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
        IERC20(address(UNDERLYING)).safeTransfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        assets = (shares * totalManaged) / totalShares;
        balanceOf[owner] -= shares;
        totalShares -= shares;
        totalManaged -= assets;
        IERC20(address(UNDERLYING)).safeTransfer(receiver, assets);
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

    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf[owner]);
    }

    /// @dev Test helper: mint extra underlying to the vault, raising share value (yield).
    function accrue(uint256 amount) external {
        UNDERLYING.mint(address(this), amount);
        totalManaged += amount;
    }
}
