// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGoalyVault} from "./interfaces/IGoalyVault.sol";

/// @title PredictionPool
/// @notice No-loss football prediction markets. Placing a prediction borrows *credit* against the
///         player's GoalyVault position (recorded as debt that their own yield repays) — no
///         principal is ever staked. Each market's prize is funded from protocol yield; winners
///         split that prize pro-rata by their credit stake. Losers simply win nothing; they never
///         lose their deposit. This contract holds the ORACLE role for market results and must be
///         granted GoalyVault's SETTLER_ROLE to charge credit.
contract PredictionPool is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    uint256 internal constant BPS = 10_000;

    IERC20 public immutable asset; // USDT0
    IGoalyVault public immutable vault;
    uint16 public immutable feeBps; // protocol fee on winnings

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

    struct Market {
        uint64 closeTime;
        Status status;
        Outcome result;
        uint256 pot; // total credit staked
        uint256 winningStake; // credit staked on the winning outcome (set at settle)
        uint256 prize; // USDT0 funded from yield, split among winners
    }

    mapping(bytes32 marketId => Market) public markets;
    mapping(bytes32 marketId => mapping(uint8 outcome => uint256 stake)) public outcomeStake;
    mapping(bytes32 marketId => mapping(address user => uint256 stake)) public stakeOf;
    mapping(bytes32 marketId => mapping(address user => Outcome pick)) public pickOf;
    mapping(bytes32 marketId => mapping(address user => bool)) public claimed;

    event MarketCreated(bytes32 indexed marketId, uint64 closeTime);
    event PredictionPlaced(bytes32 indexed marketId, address indexed user, Outcome outcome, uint256 amount);
    event MarketSettled(bytes32 indexed marketId, Outcome result, uint256 winningStake, uint256 pot);
    event PrizeFunded(bytes32 indexed marketId, uint256 amount);
    event PayoutClaimed(bytes32 indexed marketId, address indexed user, uint256 amount);
    event Swept(address indexed to, uint256 amount);

    error MarketExists();
    error MarketNotOpen();
    error MarketClosed();
    error AlreadyPredicted();
    error ZeroAmount();
    error NotSettled();
    error AlreadyClaimed();
    error NothingToClaim();
    error ZeroAddress();

    constructor(IERC20 _asset, IGoalyVault _vault, uint16 _feeBps) {
        if (address(_asset) == address(0) || address(_vault) == address(0)) revert ZeroAddress();
        require(_feeBps <= BPS, "fee too high");
        asset = _asset;
        vault = _vault;
        feeBps = _feeBps;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
    }

    // ── Oracle: market lifecycle ──

    function createMarket(bytes32 marketId, uint64 closeTime) external onlyRole(ORACLE_ROLE) {
        if (markets[marketId].status != Status.NONE) revert MarketExists();
        markets[marketId] =
            Market({closeTime: closeTime, status: Status.OPEN, result: Outcome.HOME, pot: 0, winningStake: 0, prize: 0});
        emit MarketCreated(marketId, closeTime);
    }

    function settleMarket(bytes32 marketId, Outcome result) external onlyRole(ORACLE_ROLE) {
        Market storage market = markets[marketId];
        if (market.status != Status.OPEN) revert MarketNotOpen();
        market.status = Status.SETTLED;
        market.result = result;
        market.winningStake = outcomeStake[marketId][uint8(result)];
        emit MarketSettled(marketId, result, market.winningStake, market.pot);
    }

    /// @notice Fund a market's prize from protocol yield (e.g. skimmed from the vault).
    function fundPrize(bytes32 marketId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        Market storage market = markets[marketId];
        if (market.status == Status.NONE) revert MarketNotOpen();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        market.prize += amount;
        emit PrizeFunded(marketId, amount);
    }

    // ── Players ──

    /// @notice Predict `outcome` for `marketId`, borrowing `amount` of credit (debt repaid by yield).
    function placePrediction(bytes32 marketId, Outcome outcome, uint256 amount) external nonReentrant {
        Market storage market = markets[marketId];
        if (market.status != Status.OPEN) revert MarketNotOpen();
        if (block.timestamp >= market.closeTime) revert MarketClosed();
        if (amount == 0) revert ZeroAmount();
        if (stakeOf[marketId][msg.sender] != 0) revert AlreadyPredicted();

        vault.chargeDebt(msg.sender, amount);

        stakeOf[marketId][msg.sender] = amount;
        pickOf[marketId][msg.sender] = outcome;
        outcomeStake[marketId][uint8(outcome)] += amount;
        market.pot += amount;
        emit PredictionPlaced(marketId, msg.sender, outcome, amount);
    }

    /// @notice A winner's claimable payout (prize share by stake, minus fee); 0 for losers.
    function payoutOf(bytes32 marketId, address user) public view returns (uint256) {
        Market storage market = markets[marketId];
        if (market.status != Status.SETTLED) return 0;
        if (pickOf[marketId][user] != market.result) return 0;
        uint256 stake = stakeOf[marketId][user];
        if (stake == 0 || market.winningStake == 0 || market.prize == 0) return 0;
        uint256 gross = (market.prize * stake) / market.winningStake;
        uint256 fee = (gross * feeBps) / BPS;
        return gross - fee;
    }

    function claim(bytes32 marketId) external nonReentrant returns (uint256 amount) {
        Market storage market = markets[marketId];
        if (market.status != Status.SETTLED) revert NotSettled();
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed();
        amount = payoutOf(marketId, msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[marketId][msg.sender] = true;
        asset.safeTransfer(msg.sender, amount);
        emit PayoutClaimed(marketId, msg.sender, amount);
    }

    // ── Admin ──

    /// @notice Withdraw leftover balance (accrued fees / unclaimed dust) to `to`.
    function sweep(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = asset.balanceOf(address(this));
        asset.safeTransfer(to, balance);
        emit Swept(to, balance);
    }
}
