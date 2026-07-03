// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PredictionPool
/// @notice No-loss prediction markets. Players stake **goUSDT** (the GoalyVault receipt) on an
///         outcome; the stake is locked during the market and **returned in full at claim** — no
///         principal is ever lost. Winners additionally split a **USDT0 prize** (funded from vault
///         yield) pro-rata by their stake, minus a protocol fee.
contract PredictionPool is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    uint256 internal constant BPS = 10_000;

    IERC20 public immutable stakeToken; // goUSDT
    IERC20 public immutable prizeToken; // USDT0
    uint16 public immutable feeBps;
    /// @notice Odds boost factor in bps (e.g. 5_000 = 0.5×). Bigger odds → bigger boost.
    uint16 public immutable boostBps;

    /// @notice USDT0 reserve (harvested protocol yield) that funds odds boosts.
    uint256 public reserve;

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
        uint256 totalStake;
        uint256 winningStake;
        uint256 prize;
    }

    mapping(bytes32 marketId => Market) public markets;
    mapping(bytes32 marketId => mapping(uint8 outcome => uint256 stake)) public outcomeStake;
    mapping(bytes32 marketId => mapping(address user => uint256 stake)) public stakeOf;
    mapping(bytes32 marketId => mapping(address user => Outcome pick)) public pickOf;
    mapping(bytes32 marketId => mapping(address user => bool)) public claimed;

    event MarketCreated(bytes32 indexed marketId, uint64 closeTime);
    event PredictionPlaced(
        bytes32 indexed marketId, address indexed user, Outcome outcome, uint256 amount
    );
    event MarketSettled(
        bytes32 indexed marketId, Outcome result, uint256 winningStake, uint256 totalStake
    );
    event PrizeFunded(bytes32 indexed marketId, uint256 amount);
    event ReserveFunded(address indexed from, uint256 amount, uint256 reserve);
    event OddsBoostApplied(bytes32 indexed marketId, uint256 winningOddsBps, uint256 boost);
    event Claimed(
        bytes32 indexed marketId, address indexed user, uint256 stakeReturned, uint256 prize
    );

    error MarketExists();
    error MarketNotOpen();
    error MarketClosed();
    error AlreadyPredicted();
    error ZeroAmount();
    error NotSettled();
    error AlreadyClaimed();
    error NothingStaked();

    constructor(IERC20 _stakeToken, IERC20 _prizeToken, uint16 _feeBps, uint16 _boostBps) {
        require(_feeBps <= BPS, "fee too high");
        stakeToken = _stakeToken;
        prizeToken = _prizeToken;
        feeBps = _feeBps;
        boostBps = _boostBps;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
    }

    // ── Oracle ──

    function createMarket(bytes32 marketId, uint64 closeTime) external onlyRole(ORACLE_ROLE) {
        if (markets[marketId].status != Status.NONE) revert MarketExists();
        markets[marketId] = Market({
            closeTime: closeTime,
            status: Status.OPEN,
            result: Outcome.HOME,
            totalStake: 0,
            winningStake: 0,
            prize: 0
        });
        emit MarketCreated(marketId, closeTime);
    }

    /// @notice Settle a market with its result and the winning outcome's decimal odds (×10_000,
    ///         e.g. 8.00 → 80_000). An odds boost (larger for underdogs) is drawn from the reserve
    ///         and folded into the prize, so the existing pro-rata claim distributes it to winners.
    function settleMarket(bytes32 marketId, Outcome result, uint256 winningOddsBps)
        external
        onlyRole(ORACLE_ROLE)
    {
        Market storage market = markets[marketId];
        if (market.status != Status.OPEN) revert MarketNotOpen();
        market.status = Status.SETTLED;
        market.result = result;
        uint256 winningStake = outcomeStake[marketId][uint8(result)];
        market.winningStake = winningStake;

        uint256 boost = _oddsBoost(winningStake, winningOddsBps);
        if (boost > 0) {
            reserve -= boost;
            market.prize += boost;
            emit OddsBoostApplied(marketId, winningOddsBps, boost);
        }
        emit MarketSettled(marketId, result, winningStake, market.totalStake);
    }

    /// @dev Odds boost = winningStake × (odds − 1) × boostBps, capped by the reserve so payouts can
    ///      never exceed the yield that exists. Mirrors the core oddsBoostedPrize helper.
    function _oddsBoost(uint256 winningStake, uint256 winningOddsBps)
        internal
        view
        returns (uint256)
    {
        if (winningStake == 0 || winningOddsBps <= BPS || boostBps == 0) return 0;
        uint256 uncapped = (winningStake * (winningOddsBps - BPS) * boostBps) / (BPS * BPS);
        return uncapped > reserve ? reserve : uncapped;
    }

    /// @notice Fund a market's base prize with USDT0 (e.g. harvested vault yield).
    function fundPrize(bytes32 marketId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        Market storage market = markets[marketId];
        if (market.status == Status.NONE) revert MarketNotOpen();
        prizeToken.safeTransferFrom(msg.sender, address(this), amount);
        market.prize += amount;
        emit PrizeFunded(marketId, amount);
    }

    /// @notice Top up the odds-boost reserve with USDT0 (harvested protocol yield).
    function fundReserve(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        prizeToken.safeTransferFrom(msg.sender, address(this), amount);
        reserve += amount;
        emit ReserveFunded(msg.sender, amount, reserve);
    }

    // ── Players ──

    /// @notice Stake `amount` goUSDT on `outcome`. The stake is locked and returned in full at claim.
    function placePrediction(bytes32 marketId, Outcome outcome, uint256 amount)
        external
        nonReentrant
    {
        Market storage market = markets[marketId];
        if (market.status != Status.OPEN) revert MarketNotOpen();
        if (block.timestamp >= market.closeTime) revert MarketClosed();
        if (amount == 0) revert ZeroAmount();
        if (stakeOf[marketId][msg.sender] != 0) revert AlreadyPredicted();

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        stakeOf[marketId][msg.sender] = amount;
        pickOf[marketId][msg.sender] = outcome;
        outcomeStake[marketId][uint8(outcome)] += amount;
        market.totalStake += amount;
        emit PredictionPlaced(marketId, msg.sender, outcome, amount);
    }

    /// @notice A winner's USDT0 prize share (0 for losers or unsettled markets).
    function prizeOf(bytes32 marketId, address user) public view returns (uint256) {
        Market storage market = markets[marketId];
        if (market.status != Status.SETTLED) return 0;
        if (pickOf[marketId][user] != market.result) return 0;
        uint256 stake = stakeOf[marketId][user];
        if (stake == 0 || market.winningStake == 0 || market.prize == 0) return 0;
        uint256 gross = (market.prize * stake) / market.winningStake;
        return gross - (gross * feeBps) / BPS;
    }

    /// @notice Reclaim your staked goUSDT (always, no-loss) plus your USDT0 prize (if you won).
    function claim(bytes32 marketId)
        external
        nonReentrant
        returns (uint256 stakeReturned, uint256 prize)
    {
        Market storage market = markets[marketId];
        if (market.status != Status.SETTLED) revert NotSettled();
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed();
        stakeReturned = stakeOf[marketId][msg.sender];
        if (stakeReturned == 0) revert NothingStaked();

        claimed[marketId][msg.sender] = true;
        prize = prizeOf(marketId, msg.sender);

        stakeToken.safeTransfer(msg.sender, stakeReturned);
        if (prize > 0) prizeToken.safeTransfer(msg.sender, prize);
        emit Claimed(marketId, msg.sender, stakeReturned, prize);
    }
}
