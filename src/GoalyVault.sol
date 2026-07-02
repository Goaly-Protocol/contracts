// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IGoalyVault} from "./interfaces/IGoalyVault.sol";
import {YieldMath} from "./libraries/YieldMath.sol";

/// @title GoalyVault
/// @notice Self-custodial deposit vault for Goaly. Deposited USDT0 is supplied to a Morpho
///         ERC-4626 vault to earn yield. Players borrow prediction *credit* (tracked as debt);
///         that debt is only ever repaid by the yield their own principal earns — never by the
///         principal itself. Principal unlocks for withdrawal once yield has cleared the debt, so
///         a player can never lose their deposit, only their future yield.
/// @dev    Access is role-based (see {SETTLER_ROLE}); mutating flows are `nonReentrant` and
///         deposits are `Pausable` for emergencies.
contract GoalyVault is IGoalyVault, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to charge prediction credit as debt (granted to the prediction pool).
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    IERC20 public immutable asset; // USDT0
    IERC4626 public immutable yieldVault; // Morpho MetaMorpho vault

    uint256 public totalPrincipal;
    uint256 public totalShares;
    uint256 public protocolShares; // yield shares retained after withdrawals

    mapping(address account => Account data) private _accounts;

    constructor(IERC20 _asset, IERC4626 _yieldVault) {
        if (_yieldVault.asset() != address(_asset)) revert AssetMismatch();
        asset = _asset;
        yieldVault = _yieldVault;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ── Views ──

    function accountOf(address user) external view returns (Account memory) {
        return _accounts[user];
    }

    function principalOf(address user) external view returns (uint256) {
        return _accounts[user].principal;
    }

    function sharesOf(address user) external view returns (uint256) {
        return _accounts[user].shares;
    }

    function debtOf(address user) external view returns (uint256) {
        return _accounts[user].debt;
    }

    /// @inheritdoc IGoalyVault
    function yieldOf(address user) public view returns (uint256) {
        uint256 value = yieldVault.convertToAssets(_accounts[user].shares);
        return YieldMath.accruedYield(value, _accounts[user].principal);
    }

    /// @inheritdoc IGoalyVault
    function remainingDebt(address user) public view returns (uint256) {
        return YieldMath.outstanding(_accounts[user].debt, yieldOf(user));
    }

    /// @inheritdoc IGoalyVault
    function principalLocked(address user) public view returns (bool) {
        return remainingDebt(user) > 0;
    }

    // ── Admin ──

    /// @inheritdoc IGoalyVault
    function setSettler(address settler, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (settler == address(0)) revert ZeroAddress();
        if (enabled) {
            _grantRole(SETTLER_ROLE, settler);
        } else {
            _revokeRole(SETTLER_ROLE, settler);
        }
        emit SettlerSet(settler, enabled);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ── Deposits ──

    /// @inheritdoc IGoalyVault
    function deposit(uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        return _deposit(msg.sender, assets);
    }

    /// @inheritdoc IGoalyVault
    /// @dev The caller funds the deposit but the position is credited to `user`. Used by the
    ///      LayerZero composer to attribute cross-chain deposits to the origin-chain user.
    function depositFor(address user, uint256 assets)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (user == address(0)) revert ZeroAddress();
        return _deposit(user, assets);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(address(yieldVault), assets);
        shares = yieldVault.deposit(assets, address(this));

        Account storage account = _accounts[user];
        account.principal += assets;
        account.shares += shares;
        totalPrincipal += assets;
        totalShares += shares;
        emit Deposited(user, assets, shares);
    }

    // ── Credit (settler only) ──

    /// @inheritdoc IGoalyVault
    function chargeDebt(address user, uint256 amount) external onlyRole(SETTLER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        Account storage account = _accounts[user];
        account.debt += amount;
        emit DebtCharged(user, amount, account.debt);
    }

    // ── Withdraw ──

    /// @inheritdoc IGoalyVault
    function withdraw() external nonReentrant returns (uint256 assets) {
        Account storage account = _accounts[msg.sender];
        uint256 principal = account.principal;
        if (principal == 0) revert NothingToWithdraw();
        if (principalLocked(msg.sender)) revert PrincipalLocked();

        uint256 userShares = account.shares;
        uint256 sharesBurned = yieldVault.withdraw(principal, msg.sender, address(this));
        uint256 residual = userShares > sharesBurned ? userShares - sharesBurned : 0;

        account.principal = 0;
        account.shares = 0;
        account.debt = 0;
        protocolShares += residual;
        totalPrincipal -= principal;
        totalShares -= sharesBurned;

        assets = principal;
        emit Withdrawn(msg.sender, assets, sharesBurned);
    }

    /// @inheritdoc IGoalyVault
    function skim(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (uint256 assets) {
        if (to == address(0)) revert ZeroAddress();
        uint256 shares = protocolShares;
        if (shares == 0) revert ZeroAmount();
        protocolShares = 0;
        totalShares -= shares;
        assets = yieldVault.redeem(shares, to, address(this));
        emit Skimmed(to, assets, shares);
    }
}
