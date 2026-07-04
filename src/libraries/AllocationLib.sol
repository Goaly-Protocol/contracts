// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title AllocationLib
/// @notice The {GoalyVault}'s strategy-allocation logic, deployed as an *external* (delegatecall)
///         library so the vault's own runtime bytecode stays comfortably under the 24 KB limit
///         **without the optimizer**. All functions take the vault's storage `Layout` by reference and
///         run in the vault's context (`address(this)` is the vault, storage is the vault's).
library AllocationLib {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:goaly.storage.GoalyVault
    struct Layout {
        IStrategy[] strategies;
        mapping(address => bool) isStrategy;
        uint16 bufferBps;
    }

    event Allocated(address indexed strategy, uint256 assets);
    event Deallocated(address indexed strategy, uint256 assets);
    event Rebalanced();

    error NotStrategy();
    error BufferBreached();
    error LengthMismatch();

    /// @notice Assets held across every strategy, in `asset` units.
    function totalStrategyAssets(Layout storage $) external view returns (uint256 total) {
        IStrategy[] storage strats = $.strategies;
        for (uint256 i; i < strats.length; ++i) {
            total += strats[i].totalAssets();
        }
    }

    /// @notice Move `assets` from idle into a whitelisted strategy, never below the liquidity buffer.
    function allocate(
        Layout storage $,
        IERC20 asset,
        IStrategy strategy,
        uint256 assets,
        uint256 buffer
    ) external {
        if (!$.isStrategy[address(strategy)]) revert NotStrategy();
        uint256 idle = asset.balanceOf(address(this));
        if (idle < assets || idle - assets < buffer) revert BufferBreached();
        asset.forceApprove(address(strategy), assets);
        strategy.deposit(assets);
        emit Allocated(address(strategy), assets);
    }

    /// @notice Pull `assets` back from a strategy into the idle buffer.
    function deallocate(Layout storage $, IStrategy strategy, uint256 assets) external {
        if (!$.isStrategy[address(strategy)]) revert NotStrategy();
        strategy.withdraw(assets);
        emit Deallocated(address(strategy), assets);
    }

    /// @notice Set target allocations across strategies: drain the over-funded first, then top up the
    ///         under-funded from whatever idle remains above the buffer.
    function rebalance(
        Layout storage $,
        IERC20 asset,
        IStrategy[] calldata strategies_,
        uint256[] calldata targets,
        uint256 buffer
    ) external {
        uint256 n = strategies_.length;
        if (n != targets.length) revert LengthMismatch();

        for (uint256 i; i < n; ++i) {
            if (!$.isStrategy[address(strategies_[i])]) revert NotStrategy();
            uint256 cur = strategies_[i].totalAssets();
            if (cur > targets[i]) strategies_[i].withdraw(cur - targets[i]);
        }
        for (uint256 i; i < n; ++i) {
            uint256 cur = strategies_[i].totalAssets();
            if (cur >= targets[i]) continue;
            uint256 idle = asset.balanceOf(address(this));
            uint256 free = idle > buffer ? idle - buffer : 0;
            if (free == 0) break;
            uint256 want = targets[i] - cur;
            uint256 amount = want < free ? want : free;
            asset.forceApprove(address(strategies_[i]), amount);
            strategies_[i].deposit(amount);
        }
        emit Rebalanced();
    }

    /// @notice Pull `needed` assets back from strategies, most-liquid-first, to service a withdrawal.
    function pullFromStrategies(Layout storage $, uint256 needed) external {
        IStrategy[] storage strats = $.strategies;
        for (uint256 i; i < strats.length && needed > 0; ++i) {
            uint256 avail = strats[i].maxWithdraw();
            if (avail == 0) continue;
            uint256 take = avail < needed ? avail : needed;
            strats[i].withdraw(take);
            needed -= take;
        }
    }
}
