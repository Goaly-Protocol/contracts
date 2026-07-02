// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

/// @title YieldMath
/// @notice Pure helpers for the self-repaying-debt accounting. Mirrors the TypeScript domain logic
///         in the goaly core package so on-chain and off-chain math stay in lockstep.
library YieldMath {
    /// @notice Yield accrued = value of shares minus principal, floored at zero.
    function accruedYield(uint256 shareValue, uint256 principal) internal pure returns (uint256) {
        return shareValue > principal ? shareValue - principal : 0;
    }

    /// @notice Debt still outstanding after accrued yield is applied, floored at zero.
    function outstandingDebt(uint256 debt, uint256 accrued) internal pure returns (uint256) {
        return debt > accrued ? debt - accrued : 0;
    }
}
