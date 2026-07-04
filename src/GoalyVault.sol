// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from
    "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title GoalyVault
/// @notice An ERC-4626 tokenized vault that pools USDT0 principal and allocates it across a set of
///         whitelisted, *same-asset* yield strategies while always keeping a liquidity buffer idle so
///         claims are serviceable on demand. This is the yield engine; the prediction/no-loss logic
///         lives in {GoalyMarkets}, which is just a depositor here.
///
///         Trust model (least privilege):
///           • AGENT_ROLE     — may only move funds between the idle buffer and whitelisted strategies
///                              (`allocate`/`deallocate`). It can NEVER transfer assets to an EOA, add a
///                              strategy, or change params. A compromised agent key cannot steal funds.
///           • GUARDIAN_ROLE  — may `pause` (circuit breaker).
///           • DEFAULT_ADMIN  — governance (Timelock + Safe): whitelist, params, unpause, upgrades.
///
///         Upgradeable via UUPS with ERC-7201 namespaced storage (collision-safe across upgrades).
contract GoalyVault is
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_STRATEGIES = 16;

    /// @custom:storage-location erc7201:goaly.storage.GoalyVault
    struct Layout {
        IStrategy[] strategies;
        mapping(address => bool) isStrategy;
        uint16 bufferBps; // share of total assets kept idle for instant withdrawals
    }

    // keccak256(abi.encode(uint256(keccak256("goaly.storage.GoalyVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAYOUT_SLOT =
        0xe5e9df8726d9c6f5b5338f3b8f93307a761bbb34be570f2c272f16acefa34a00;

    function _layout() private pure returns (Layout storage $) {
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event Allocated(address indexed strategy, uint256 assets);
    event Deallocated(address indexed strategy, uint256 assets);
    event BufferSet(uint16 bufferBps);

    error NotStrategy();
    error AssetMismatch();
    error TooManyStrategies();
    error BufferBreached();
    error StrategyNotEmpty();
    error InvalidBuffer();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param asset_ USDT0 (the pool's accounting token).
    /// @param governance Timelock + Safe address that receives DEFAULT_ADMIN_ROLE.
    /// @param bufferBps_ Share of assets kept idle as the instant-withdrawal buffer.
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address governance,
        uint16 bufferBps_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __AccessControl_init();
        __Pausable_init();
        if (bufferBps_ > BPS) revert InvalidBuffer();
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _layout().bufferBps = bufferBps_;
        emit BufferSet(bufferBps_);
    }

    // ── Views ──────────────────────────────────────────────────────────────────────────────────────

    /// @notice Idle USDT0 in the vault plus the assets held across every strategy.
    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));
        IStrategy[] storage strats = _layout().strategies;
        for (uint256 i; i < strats.length; ++i) {
            total += strats[i].totalAssets();
        }
    }

    function strategies() external view returns (IStrategy[] memory) {
        return _layout().strategies;
    }

    function isStrategy(address strategy) external view returns (bool) {
        return _layout().isStrategy[strategy];
    }

    function bufferBps() external view returns (uint16) {
        return _layout().bufferBps;
    }

    /// @notice Assets that must stay idle in the vault as the instant-withdrawal buffer.
    function requiredBuffer() public view returns (uint256) {
        return (totalAssets() * _layout().bufferBps) / BPS;
    }

    // ── Agent: bounded allocation ────────────────────────────────────────────────────────────────

    /// @notice Move `assets` from the idle buffer into a whitelisted strategy. Reverts if it would
    ///         push idle below the required liquidity buffer — the agent can never starve claims.
    function allocate(IStrategy strategy, uint256 assets)
        external
        onlyRole(AGENT_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (!_layout().isStrategy[address(strategy)]) revert NotStrategy();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets || idle - assets < requiredBuffer()) revert BufferBreached();
        IERC20(asset()).forceApprove(address(strategy), assets);
        strategy.deposit(assets);
        emit Allocated(address(strategy), assets);
    }

    /// @notice Pull `assets` back from a strategy into the idle buffer.
    function deallocate(IStrategy strategy, uint256 assets)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
    {
        if (!_layout().isStrategy[address(strategy)]) revert NotStrategy();
        strategy.withdraw(assets);
        emit Deallocated(address(strategy), assets);
    }

    // ── Governance ───────────────────────────────────────────────────────────────────────────────

    function addStrategy(IStrategy strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Layout storage $ = _layout();
        if (address(strategy.asset()) != asset()) revert AssetMismatch();
        if ($.strategies.length >= MAX_STRATEGIES) revert TooManyStrategies();
        if (!$.isStrategy[address(strategy)]) {
            $.isStrategy[address(strategy)] = true;
            $.strategies.push(strategy);
            emit StrategyAdded(address(strategy));
        }
    }

    function removeStrategy(IStrategy strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Layout storage $ = _layout();
        if (!$.isStrategy[address(strategy)]) revert NotStrategy();
        if (strategy.totalAssets() != 0) revert StrategyNotEmpty();
        $.isStrategy[address(strategy)] = false;
        uint256 n = $.strategies.length;
        for (uint256 i; i < n; ++i) {
            if ($.strategies[i] == strategy) {
                $.strategies[i] = $.strategies[n - 1];
                $.strategies.pop();
                break;
            }
        }
        emit StrategyRemoved(address(strategy));
    }

    function setBufferBps(uint16 bufferBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bufferBps_ > BPS) revert InvalidBuffer();
        _layout().bufferBps = bufferBps_;
        emit BufferSet(bufferBps_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ── ERC-4626 hooks: withdrawals draw from the idle buffer, then top up from strategies ─────────

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) _pullFromStrategies(assets - idle);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Pull `needed` assets back from strategies, most-liquid-first. If the strategies can't
    ///      cover it the subsequent transfer in `super._withdraw` reverts — never a silent shortfall.
    function _pullFromStrategies(uint256 needed) private {
        IStrategy[] storage strats = _layout().strategies;
        for (uint256 i; i < strats.length && needed > 0; ++i) {
            uint256 avail = strats[i].maxWithdraw();
            if (avail == 0) continue;
            uint256 take = avail < needed ? avail : needed;
            strats[i].withdraw(take);
            needed -= take;
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
