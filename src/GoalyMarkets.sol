// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title GoalyMarkets
/// @notice The no-loss prediction layer. Players stake USDT0 on a match outcome; every stake is
///         deposited straight into the {GoalyVault} (same-asset, so it is always redeemable 1:1 — the
///         principal is never at risk). Winners additionally split a prize funded by the accrued yield
///         + an odds boost. The market never touches yield mechanics directly: the vault is the engine,
///         this contract is just a depositor with an on-chain solvency invariant.
///
///         Roles: ORACLE_ROLE (create/settle/harvest), GUARDIAN_ROLE (pause), DEFAULT_ADMIN
///         (governance: params, unpause, upgrades). UUPS + ERC-7201 storage.
contract GoalyMarkets is
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    enum Outcome {
        HOME,
        DRAW,
        AWAY
    }

    enum Status {
        NONE,
        OPEN,
        SETTLED
    }

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint16 internal constant BPS = 10_000;

    struct Market {
        uint64 closeTime;
        Status status;
        Outcome result;
        uint256 totalStake;
        uint256 winningStake;
        uint256 prize;
    }

    /// @custom:storage-location erc7201:goaly.storage.GoalyMarkets
    struct Layout {
        IERC20 asset; // USDT0
        IERC4626 vault; // GoalyVault
        uint256 totalStaked; // principal owed, redeemable 1:1
        uint256 reserve; // USDT0 (held in the vault) earmarked for prizes/boosts
        uint16 feeBps; // protocol fee, taken from the prize only (never principal)
        uint16 boostBps; // odds-boost intensity
        mapping(bytes32 => Market) markets;
        mapping(bytes32 => mapping(address => uint256)) stakeOf;
        mapping(bytes32 => mapping(address => Outcome)) pickOf;
        mapping(bytes32 => mapping(address => bool)) claimed;
        mapping(bytes32 => mapping(uint8 => uint256)) outcomeStake;
    }

    // keccak256(abi.encode(uint256(keccak256("goaly.storage.GoalyMarkets")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAYOUT_SLOT =
        0xd6ac6ce6d71cc83ef0ef58d7ab10f63db5c63995ba8327493173d335733a1900;

    function _layout() private pure returns (Layout storage $) {
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    event MarketCreated(bytes32 indexed marketId, uint64 closeTime);
    event Predicted(bytes32 indexed marketId, address indexed user, Outcome outcome, uint256 stake);
    event MarketSettled(
        bytes32 indexed marketId, Outcome result, uint256 winningStake, uint256 prize
    );
    event Claimed(
        bytes32 indexed marketId, address indexed user, uint256 stakeReturned, uint256 prize
    );
    event YieldHarvested(uint256 amount, uint256 reserve);
    event ReserveFunded(address indexed from, uint256 amount, uint256 reserve);

    error MarketClosed();
    error MarketExists();
    error NotOpen();
    error NotSettled();
    error AlreadyClaimed();
    error NothingStaked();
    error ZeroAmount();
    error PickLocked();
    error AssetMismatch();
    error InvalidFee();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 asset_,
        IERC4626 vault_,
        address governance,
        address oracle,
        uint16 feeBps_,
        uint16 boostBps_
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        if (vault_.asset() != address(asset_)) revert AssetMismatch();
        if (feeBps_ > BPS) revert InvalidFee();
        Layout storage $ = _layout();
        $.asset = asset_;
        $.vault = vault_;
        $.feeBps = feeBps_;
        $.boostBps = boostBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(ORACLE_ROLE, oracle);
    }

    // ── Player ───────────────────────────────────────────────────────────────────────────────────

    /// @notice Stake `amount` USDT0 on `outcome`. The stake is deposited into the vault to earn yield;
    ///         it stays fully redeemable — only the yield is ever put on the line.
    function predict(bytes32 marketId, Outcome outcome, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        Layout storage $ = _layout();
        Market storage m = $.markets[marketId];
        if (m.status != Status.OPEN || block.timestamp >= m.closeTime) revert MarketClosed();
        if (amount == 0) revert ZeroAmount();
        if ($.stakeOf[marketId][msg.sender] != 0 && $.pickOf[marketId][msg.sender] != outcome) {
            revert PickLocked();
        }

        $.asset.safeTransferFrom(msg.sender, address(this), amount);
        $.asset.forceApprove(address($.vault), amount);
        $.vault.deposit(amount, address(this));

        $.stakeOf[marketId][msg.sender] += amount;
        $.pickOf[marketId][msg.sender] = outcome;
        $.outcomeStake[marketId][uint8(outcome)] += amount;
        m.totalStake += amount;
        $.totalStaked += amount;
        emit Predicted(marketId, msg.sender, outcome, amount);
    }

    /// @notice Reclaim your stake (always — no-loss) plus your prize (if you won), in USDT0.
    function claim(bytes32 marketId)
        external
        nonReentrant
        returns (uint256 stakeReturned, uint256 prize)
    {
        Layout storage $ = _layout();
        Market storage m = $.markets[marketId];
        if (m.status != Status.SETTLED) revert NotSettled();
        if ($.claimed[marketId][msg.sender]) revert AlreadyClaimed();
        stakeReturned = $.stakeOf[marketId][msg.sender];
        if (stakeReturned == 0) revert NothingStaked();

        $.claimed[marketId][msg.sender] = true;
        prize = prizeOf(marketId, msg.sender);
        $.totalStaked -= stakeReturned;
        // Same-asset vault → withdrawing (stake + prize) is always 1:1, never a cross-asset shortfall.
        $.vault.withdraw(stakeReturned + prize, msg.sender, address(this));
        emit Claimed(marketId, msg.sender, stakeReturned, prize);
    }

    // ── Oracle ───────────────────────────────────────────────────────────────────────────────────

    function createMarket(bytes32 marketId, uint64 closeTime) external onlyRole(ORACLE_ROLE) {
        Layout storage $ = _layout();
        if ($.markets[marketId].status != Status.NONE) revert MarketExists();
        $.markets[marketId] = Market(closeTime, Status.OPEN, Outcome.HOME, 0, 0, 0);
        emit MarketCreated(marketId, closeTime);
    }

    /// @notice Settle with the result and the winning outcome's decimal odds (×10_000). An odds boost
    ///         (bigger for underdogs) is drawn from the reserve and folded into the winners' prize.
    function settleMarket(bytes32 marketId, Outcome result, uint256 winningOddsBps)
        external
        onlyRole(ORACLE_ROLE)
    {
        Layout storage $ = _layout();
        Market storage m = $.markets[marketId];
        if (m.status != Status.OPEN) revert NotOpen();
        m.status = Status.SETTLED;
        m.result = result;
        m.winningStake = $.outcomeStake[marketId][uint8(result)];
        uint256 boost = _boost(m.winningStake, winningOddsBps);
        m.prize = boost;
        $.reserve -= boost;
        emit MarketSettled(marketId, result, m.winningStake, boost);
    }

    /// @notice Move the vault's accrued surplus (above principal + reserve) into the prize reserve.
    function harvestYield() external onlyRole(ORACLE_ROLE) returns (uint256 harvested) {
        Layout storage $ = _layout();
        uint256 pos = $.vault.convertToAssets($.vault.balanceOf(address(this)));
        uint256 owed = $.totalStaked + $.reserve;
        if (pos > owed) {
            harvested = pos - owed;
            $.reserve += harvested;
        }
        emit YieldHarvested(harvested, $.reserve);
    }

    // ── Reserve ──────────────────────────────────────────────────────────────────────────────────

    /// @notice Top up the prize/boost reserve with USDT0 (deposited into the vault so it earns too).
    function fundReserve(uint256 amount) external {
        Layout storage $ = _layout();
        $.asset.safeTransferFrom(msg.sender, address(this), amount);
        $.asset.forceApprove(address($.vault), amount);
        $.vault.deposit(amount, address(this));
        $.reserve += amount;
        emit ReserveFunded(msg.sender, amount, $.reserve);
    }

    // ── Views ────────────────────────────────────────────────────────────────────────────────────

    /// @notice A winner's prize share in USDT0 (0 for losers / unsettled markets), net of the fee.
    function prizeOf(bytes32 marketId, address user) public view returns (uint256) {
        Layout storage $ = _layout();
        Market storage m = $.markets[marketId];
        if (m.status != Status.SETTLED || $.pickOf[marketId][user] != m.result) return 0;
        uint256 stake = $.stakeOf[marketId][user];
        if (stake == 0 || m.winningStake == 0 || m.prize == 0) return 0;
        uint256 gross = (m.prize * stake) / m.winningStake;
        return gross - (gross * $.feeBps) / BPS;
    }

    /// @notice The core no-loss invariant: the vault position always covers principal + reserve.
    function isSolvent() public view returns (bool) {
        Layout storage $ = _layout();
        return
            $.vault.convertToAssets($.vault.balanceOf(address(this))) >= $.totalStaked + $.reserve;
    }

    function stakeOf(bytes32 marketId, address user) external view returns (uint256) {
        return _layout().stakeOf[marketId][user];
    }

    function markets(bytes32 marketId) external view returns (Market memory) {
        return _layout().markets[marketId];
    }

    function totalStaked() external view returns (uint256) {
        return _layout().totalStaked;
    }

    function reserve() external view returns (uint256) {
        return _layout().reserve;
    }

    function vault() external view returns (IERC4626) {
        return _layout().vault;
    }

    // ── Governance ───────────────────────────────────────────────────────────────────────────────

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ── Internals ────────────────────────────────────────────────────────────────────────────────

    /// @dev Odds boost = winningStake × (odds − 1) × boostBps, capped by the available reserve.
    function _boost(uint256 winningStake, uint256 oddsBps) internal view returns (uint256) {
        Layout storage $ = _layout();
        if (winningStake == 0 || oddsBps <= BPS) return 0;
        uint256 uncapped = (winningStake * (oddsBps - BPS) * $.boostBps) / (uint256(BPS) * BPS);
        return uncapped > $.reserve ? $.reserve : uncapped;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
