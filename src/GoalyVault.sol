// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {AllocationLib} from "./libraries/AllocationLib.sol";

/// @title GoalyVault
/// @notice An ERC-4626 tokenized vault that pools USDT0 principal and allocates it across whitelisted,
///         *same-asset* strategies while always keeping a liquidity buffer idle so claims are
///         serviceable on demand. The strategy-allocation logic lives in {AllocationLib} (an external
///         delegatecall library) so this contract compiles under the 24 KB limit without the optimizer.
///
///         Trust model: AGENT_ROLE may only `allocate`/`deallocate`/`rebalance` between the buffer and
///         whitelisted strategies (never transfer to an EOA); GUARDIAN_ROLE may `pause`; DEFAULT_ADMIN
///         (governance: Timelock + Safe) owns the whitelist, params, unpause and UUPS upgrades.
contract GoalyVault is
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    using AllocationLib for AllocationLib.Layout;

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_STRATEGIES = 16;

    // keccak256(abi.encode(uint256(keccak256("goaly.storage.GoalyVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAYOUT_SLOT =
        0xe5e9df8726d9c6f5b5338f3b8f93307a761bbb34be570f2c272f16acefa34a00;

    function _layout() private pure returns (AllocationLib.Layout storage $) {
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event BufferSet(uint16 bufferBps);

    error AssetMismatch();
    error TooManyStrategies();
    error StrategyNotEmpty();
    error InvalidBuffer();
    error NotStrategy();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _layout().totalStrategyAssets();
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

    /// @notice Assets that must stay idle as the instant-withdrawal buffer.
    function requiredBuffer() public view returns (uint256) {
        return (totalAssets() * _layout().bufferBps) / BPS;
    }

    // ── Agent: bounded allocation (delegated to AllocationLib) ────────────────────────────────────

    function allocate(IStrategy strategy, uint256 assets)
        external
        onlyRole(AGENT_ROLE)
        whenNotPaused
        nonReentrant
    {
        _layout().allocate(IERC20(asset()), strategy, assets, requiredBuffer());
    }

    function deallocate(IStrategy strategy, uint256 assets)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
    {
        _layout().deallocate(strategy, assets);
    }

    /// @notice Agent's optimised multi-strategy weights, applied in one tx (buffer-safe).
    function rebalance(IStrategy[] calldata strategies_, uint256[] calldata targets)
        external
        onlyRole(AGENT_ROLE)
        whenNotPaused
        nonReentrant
    {
        _layout().rebalance(IERC20(asset()), strategies_, targets, requiredBuffer());
    }

    // ── Governance ───────────────────────────────────────────────────────────────────────────────

    function addStrategy(IStrategy strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        AllocationLib.Layout storage $ = _layout();
        if (address(strategy.asset()) != asset()) revert AssetMismatch();
        if ($.strategies.length >= MAX_STRATEGIES) revert TooManyStrategies();
        if (!$.isStrategy[address(strategy)]) {
            $.isStrategy[address(strategy)] = true;
            $.strategies.push(strategy);
            emit StrategyAdded(address(strategy));
        }
    }

    function removeStrategy(IStrategy strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        AllocationLib.Layout storage $ = _layout();
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

    // ── ERC-4626 hook: draw a withdrawal from the buffer, topping up from strategies as needed ─────

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) _layout().pullFromStrategies(assets - idle);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
