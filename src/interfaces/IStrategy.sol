// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IStrategy
/// @notice A pluggable yield adapter the {GoalyVault} allocates principal into. Each strategy wraps
///         exactly one *same-asset* yield source (e.g. a Morpho USDT0 vault) so no cross-asset swap is
///         ever needed on a withdrawal — the class of shortfall that could strand principal is
///         eliminated by construction. The vault is the only depositor; strategies hold none of the
///         user-facing accounting, only the vault's funds.
interface IStrategy {
    /// @notice The asset this strategy accepts and returns. MUST equal the vault's asset (USDT0).
    function asset() external view returns (IERC20);

    /// @notice Total assets this strategy currently holds for the vault, in `asset()` units.
    function totalAssets() external view returns (uint256);

    /// @notice Assets withdrawable right now (bounded by the underlying source's live liquidity).
    function maxWithdraw() external view returns (uint256);

    /// @notice Pull `assets` from the caller (the vault, which must have approved) and deploy them.
    function deposit(uint256 assets) external;

    /// @notice Return `assets` to the vault. MUST revert if `assets > maxWithdraw()`.
    function withdraw(uint256 assets) external;

    /// @notice Return everything to the vault (used when the strategy is retired). Returns assets sent.
    function withdrawAll() external returns (uint256 assets);
}
