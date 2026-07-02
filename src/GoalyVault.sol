// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title GoalyVault (goUSDT)
/// @notice ERC-20 receipt vault for Goaly. Deposit USDT0 → receive **goUSDT 1:1**; the USDT0 is
///         supplied to a Morpho ERC-4626 vault to earn yield. goUSDT is the representative token
///         used to place predictions and **always redeems 1:1 for USDT0** (no-loss). Yield earned
///         above the total goUSDT supply is protocol yield, harvested to fund prizes. The Morpho
///         vault is migratable, so goUSDT is unaffected if a Morpho vault is deprecated.
contract GoalyVault is ERC20, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IERC20 public immutable asset; // USDT0
    IERC4626 public yieldVault; // Morpho MetaMorpho vault (migratable)

    event Deposited(address indexed receiver, uint256 assets);
    event Withdrawn(address indexed owner, address indexed receiver, uint256 assets);
    event YieldHarvested(address indexed to, uint256 amount);
    event YieldVaultMigrated(address indexed from, address indexed to, uint256 assets);

    error ZeroAmount();
    error ZeroAddress();
    error AssetMismatch();
    error NoYield();

    constructor(IERC20 _asset, IERC4626 _yieldVault) ERC20("Goaly USDT0", "goUSDT") {
        if (_yieldVault.asset() != address(_asset)) revert AssetMismatch();
        asset = _asset;
        yieldVault = _yieldVault;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    /// @dev goUSDT mirrors USDT0's 6 decimals.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

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
        asset.forceApprove(address(yieldVault), assets);
        yieldVault.deposit(assets, address(this));
        _mint(receiver, assets);
        emit Deposited(receiver, assets);
        return assets;
    }

    /// @notice Burn `assets` goUSDT from the caller and redeem `assets` USDT0 to `receiver` (1:1).
    function withdraw(uint256 assets, address receiver) external nonReentrant returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _burn(msg.sender, assets);
        yieldVault.withdraw(assets, receiver, address(this));
        emit Withdrawn(msg.sender, receiver, assets);
        return assets;
    }

    /// @notice Total USDT0 currently backing the vault (principal + accrued yield).
    function totalAssets() public view returns (uint256) {
        return yieldVault.convertToAssets(yieldVault.balanceOf(address(this)));
    }

    /// @notice Yield accrued above total goUSDT principal.
    function accruedYield() public view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 principal = totalSupply();
        return assets > principal ? assets - principal : 0;
    }

    /// @notice Harvest protocol yield to `to` (e.g. to fund market prizes).
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

    /// @notice Move the whole position to a new Morpho vault (goUSDT holders unaffected).
    function migrateYieldVault(IERC4626 newYieldVault) external onlyRole(MANAGER_ROLE) nonReentrant {
        if (newYieldVault.asset() != address(asset)) revert AssetMismatch();
        IERC4626 old = yieldVault;
        uint256 held = old.balanceOf(address(this));
        uint256 assets = held > 0 ? old.redeem(held, address(this), address(this)) : 0;
        if (assets > 0) {
            asset.forceApprove(address(newYieldVault), assets);
            newYieldVault.deposit(assets, address(this));
        }
        yieldVault = newYieldVault;
        emit YieldVaultMigrated(address(old), address(newYieldVault), assets);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
