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
/// @notice Self-custodial deposit vault for Goaly. Deposited USDT0 is supplied to a Morpho ERC-4626
///         vault to earn yield. Players borrow prediction *credit* (tracked as debt); that debt is
///         only ever repaid by the yield their own principal earns — never the principal itself.
/// @dev    Accounting uses **internal shares** decoupled from the underlying Morpho shares, so the
///         yield vault can be migrated ({migrateYieldVault}) if a Morpho vault is deprecated —
///         users' claims are unaffected. Role-based access; mutating flows are `nonReentrant`.
contract GoalyVault is IGoalyVault, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to charge prediction credit as debt (the prediction pool).
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    /// @notice Role allowed to migrate the underlying Morpho yield vault.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IERC20 public immutable asset; // USDT0
    IERC4626 public yieldVault; // Morpho MetaMorpho vault (migratable)

    uint256 public totalPrincipal;
    uint256 public totalShares; // internal shares
    uint256 public protocolShares; // internal shares retained as protocol yield

    mapping(address account => Account data) private _accounts;

    event YieldVaultMigrated(address indexed from, address indexed to, uint256 assets);

    constructor(IERC20 _asset, IERC4626 _yieldVault) {
        if (_yieldVault.asset() != address(_asset)) revert AssetMismatch();
        asset = _asset;
        yieldVault = _yieldVault;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    // ── Views ──

    /// @inheritdoc IGoalyVault
    /// @notice Total assets currently redeemable for the Morpho shares the vault holds.
    function totalAssets() public view returns (uint256) {
        return yieldVault.convertToAssets(yieldVault.balanceOf(address(this)));
    }

    /// @notice Current asset value of a user's internal shares.
    function valueOf(address user) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (totalAssets() * _accounts[user].shares) / totalShares;
    }

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
        return YieldMath.accruedYield(valueOf(user), _accounts[user].principal);
    }

    /// @inheritdoc IGoalyVault
    function remainingDebt(address user) public view returns (uint256) {
        return YieldMath.outstandingDebt(_accounts[user].debt, yieldOf(user));
    }

    /// @inheritdoc IGoalyVault
    function principalLocked(address user) public view returns (bool) {
        return remainingDebt(user) > 0;
    }

    // ── Admin ──

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

    /// @inheritdoc IGoalyVault
    /// @notice Move the entire position to a new Morpho vault (e.g. if the current one is deprecated).
    ///         Internal share accounting is unchanged, so user claims are preserved.
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

    // ── Deposits ──

    function deposit(uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        return _deposit(msg.sender, assets);
    }

    /// @inheritdoc IGoalyVault
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
        uint256 poolBefore = totalAssets();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(address(yieldVault), assets);
        yieldVault.deposit(assets, address(this));

        shares = (totalShares == 0 || poolBefore == 0) ? assets : (assets * totalShares) / poolBefore;
        Account storage account = _accounts[user];
        account.principal += assets;
        account.shares += shares;
        totalPrincipal += assets;
        totalShares += shares;
        emit Deposited(user, assets, shares);
    }

    // ── Credit (settler only) ──

    function chargeDebt(address user, uint256 amount) external onlyRole(SETTLER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        Account storage account = _accounts[user];
        account.debt += amount;
        emit DebtCharged(user, amount, account.debt);
    }

    // ── Withdraw ──

    /// @notice Withdraw principal — only once yield has cleared the debt. Accrued yield stays with
    ///         the protocol (it funds the game); principal is never touched.
    function withdraw() external nonReentrant returns (uint256 assets) {
        Account storage account = _accounts[msg.sender];
        uint256 principal = account.principal;
        if (principal == 0) revert NothingToWithdraw();
        if (principalLocked(msg.sender)) revert PrincipalLocked();

        uint256 userShares = account.shares;
        uint256 pool = totalAssets();
        uint256 principalShares = pool == 0 ? userShares : (principal * totalShares) / pool;
        if (principalShares > userShares) principalShares = userShares;
        uint256 yieldShares = userShares - principalShares;

        account.principal = 0;
        account.shares = 0;
        account.debt = 0;
        totalPrincipal -= principal;
        totalShares -= principalShares;
        protocolShares += yieldShares;

        yieldVault.withdraw(principal, msg.sender, address(this));
        assets = principal;
        emit Withdrawn(msg.sender, assets, principalShares);
    }

    /// @inheritdoc IGoalyVault
    function collectYield(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (uint256 assets) {
        if (to == address(0)) revert ZeroAddress();
        uint256 shares = protocolShares;
        if (shares == 0) revert ZeroAmount();
        assets = (totalAssets() * shares) / totalShares;
        protocolShares = 0;
        totalShares -= shares;
        yieldVault.withdraw(assets, to, address(this));
        emit YieldCollected(to, assets, shares);
    }
}
