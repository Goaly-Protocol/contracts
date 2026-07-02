// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {SafeTransfer} from "./libraries/SafeTransfer.sol";

/// @title GoalYieldVault
/// @notice Self-custodial deposit vault for GoalYield. Deposited USDT0 is supplied to a Morpho
///         ERC-4626 vault to earn yield. Players borrow prediction *credit* (tracked as debt);
///         that debt is only ever repaid by the yield their own principal earns — never by the
///         principal itself. Principal unlocks for withdrawal once yield has cleared the debt,
///         so a player can never lose their deposit, only their future yield.
contract GoalYieldVault {
    using SafeTransfer for address;

    IERC20 public immutable asset; // USDT0
    IERC4626 public immutable yieldVault; // Morpho MetaMorpho vault

    address public owner;
    mapping(address => bool) public settlers;

    uint256 public totalPrincipal;
    uint256 public totalShares;
    uint256 public protocolShares; // yield shares retained after withdrawals

    mapping(address => uint256) public principalOf;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public debtOf;

    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 assets, uint256 sharesBurned);
    event DebtCharged(address indexed user, uint256 amount, uint256 totalDebt);
    event SettlerSet(address indexed settler, bool enabled);
    event Skimmed(address indexed to, uint256 assets, uint256 shares);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotSettler();
    error ZeroAmount();
    error ZeroAddress();
    error PrincipalLocked();
    error NothingToWithdraw();
    error AssetMismatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlySettler() {
        if (!settlers[msg.sender]) revert NotSettler();
        _;
    }

    constructor(IERC20 _asset, IERC4626 _yieldVault) {
        if (_yieldVault.asset() != address(_asset)) revert AssetMismatch();
        asset = _asset;
        yieldVault = _yieldVault;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ── Admin ──

    function setSettler(address settler, bool enabled) external onlyOwner {
        if (settler == address(0)) revert ZeroAddress();
        settlers[settler] = enabled;
        emit SettlerSet(settler, enabled);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ── Deposits ──

    /// @notice Deposit `assets` USDT0 as principal; it is supplied to the Morpho vault to earn yield.
    function deposit(uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        address(asset).safeTransferFrom(msg.sender, address(this), assets);
        address(asset).safeApprove(address(yieldVault), assets);
        shares = yieldVault.deposit(assets, address(this));

        principalOf[msg.sender] += assets;
        sharesOf[msg.sender] += shares;
        totalPrincipal += assets;
        totalShares += shares;
        emit Deposited(msg.sender, assets, shares);
    }

    // ── Views ──

    /// @notice Yield accrued for `user`: current value of their shares minus their principal.
    function yieldOf(address user) public view returns (uint256) {
        uint256 value = yieldVault.convertToAssets(sharesOf[user]);
        uint256 principal = principalOf[user];
        return value > principal ? value - principal : 0;
    }

    /// @notice Credit debt still outstanding after applying accrued yield.
    function remainingDebt(address user) public view returns (uint256) {
        uint256 debt = debtOf[user];
        uint256 accrued = yieldOf(user);
        return debt > accrued ? debt - accrued : 0;
    }

    /// @notice Principal is locked while any debt remains unrepaid by yield.
    function principalLocked(address user) public view returns (bool) {
        return remainingDebt(user) > 0;
    }

    // ── Credit (called by the settler, e.g. the prediction pool) ──

    function chargeDebt(address user, uint256 amount) external onlySettler {
        if (amount == 0) revert ZeroAmount();
        debtOf[user] += amount;
        emit DebtCharged(user, amount, debtOf[user]);
    }

    // ── Withdraw ──

    /// @notice Withdraw principal — only once yield has fully repaid the credit debt. The accrued
    ///         yield stays with the protocol (it is what funded the game), never the principal.
    function withdraw() external returns (uint256 assets) {
        uint256 principal = principalOf[msg.sender];
        if (principal == 0) revert NothingToWithdraw();
        if (principalLocked(msg.sender)) revert PrincipalLocked();

        uint256 userShares = sharesOf[msg.sender];
        uint256 sharesBurned = yieldVault.withdraw(principal, msg.sender, address(this));
        uint256 residual = userShares > sharesBurned ? userShares - sharesBurned : 0;

        sharesOf[msg.sender] = 0;
        principalOf[msg.sender] = 0;
        debtOf[msg.sender] = 0;
        protocolShares += residual;
        totalPrincipal -= principal;
        totalShares -= sharesBurned;

        assets = principal;
        emit Withdrawn(msg.sender, assets, sharesBurned);
    }

    /// @notice Redeem accrued protocol yield (retained from settled positions) to `to`.
    function skim(address to) external onlyOwner returns (uint256 assets) {
        if (to == address(0)) revert ZeroAddress();
        uint256 shares = protocolShares;
        if (shares == 0) revert ZeroAmount();
        protocolShares = 0;
        totalShares -= shares;
        assets = yieldVault.redeem(shares, to, address(this));
        emit Skimmed(to, assets, shares);
    }
}
