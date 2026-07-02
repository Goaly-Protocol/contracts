// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IGoalyVault
/// @notice External surface of the Goaly deposit vault: the self-custodial principal store
///         whose yield self-repays prediction credit. Kept separate from the implementation so
///         integrators (the prediction pool, the indexer, the frontend) depend only on the ABI.
interface IGoalyVault {
    /// @param principal Deposited collateral (never at risk).
    /// @param shares    Morpho vault shares held on the user's behalf.
    /// @param debt      Prediction credit borrowed (repaid only by yield).
    struct Account {
        uint256 principal;
        uint256 shares;
        uint256 debt;
    }

    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 assets, uint256 sharesBurned);
    event DebtCharged(address indexed user, uint256 amount, uint256 totalDebt);
    event SettlerSet(address indexed settler, bool enabled);
    event YieldCollected(address indexed to, uint256 assets, uint256 shares);

    error ZeroAmount();
    error ZeroAddress();
    error PrincipalLocked();
    error NothingToWithdraw();
    error AssetMismatch();

    function asset() external view returns (IERC20);
    function yieldVault() external view returns (IERC4626);

    function deposit(uint256 assets) external returns (uint256 shares);
    function depositFor(address user, uint256 assets) external returns (uint256 shares);
    function withdraw() external returns (uint256 assets);
    function chargeDebt(address user, uint256 amount) external;
    function collectYield(address to) external returns (uint256 assets);
    function setSettler(address settler, bool enabled) external;

    function accountOf(address user) external view returns (Account memory);
    function yieldOf(address user) external view returns (uint256);
    function remainingDebt(address user) external view returns (uint256);
    function principalLocked(address user) external view returns (bool);
}
