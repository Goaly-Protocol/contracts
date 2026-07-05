// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {GoalyMarkets} from "./GoalyMarkets.sol";

/// @title GoalySettlement
/// @notice An optimistic settlement oracle for {GoalyMarkets}, replacing a single trusted key. Anyone
///         may propose a match result by posting a bond once the match is over; it becomes final and
///         settles the market after a dispute window if nobody challenges it. A challenger posts an
///         equal bond to escalate to governance, which resolves and awards both bonds to whoever was
///         right. This makes settlement permissionless + economically secured — no one party decides
///         a winner. (A later phase can swap governance resolution for UMA's optimistic oracle.)
///
///         This contract holds ORACLE_ROLE on GoalyMarkets. Replacing the oracle = deploy a new one
///         and move the role — more trustless than an upgradeable key.
contract GoalySettlement is AccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

    GoalyMarkets public immutable markets;
    IERC20 public immutable bondToken;
    uint256 public immutable bondAmount;
    uint64 public immutable disputeWindow;

    enum Phase {
        NONE,
        PROPOSED,
        DISPUTED,
        FINALIZED
    }

    struct Proposal {
        Phase phase;
        GoalyMarkets.Outcome outcome;
        uint256 oddsBps;
        uint64 proposedAt;
        address proposer;
        address disputer;
    }

    mapping(bytes32 => Proposal) public proposals;

    event MarketOpened(bytes32 indexed marketId, uint64 closeTime);
    event Proposed(
        bytes32 indexed marketId, GoalyMarkets.Outcome outcome, uint256 oddsBps, address proposer
    );
    event Disputed(bytes32 indexed marketId, address disputer);
    event Finalized(bytes32 indexed marketId, GoalyMarkets.Outcome outcome);
    event Resolved(bytes32 indexed marketId, GoalyMarkets.Outcome outcome, address bondWinner);

    error MatchNotOver();
    error AlreadyProposed();
    error NotProposed();
    error WindowOpen();
    error WindowClosed();
    error NotDisputed();

    constructor(
        GoalyMarkets markets_,
        IERC20 bondToken_,
        uint256 bondAmount_,
        uint64 disputeWindow_,
        address governance
    ) {
        markets = markets_;
        bondToken = bondToken_;
        bondAmount = bondAmount_;
        disputeWindow = disputeWindow_;
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
    }

    /// @notice Open a market for a fixture (the backend, holding PROPOSER_ROLE, mirrors the schedule).
    function openMarket(bytes32 marketId, uint64 closeTime) external onlyRole(PROPOSER_ROLE) {
        markets.createMarket(marketId, closeTime);
        emit MarketOpened(marketId, closeTime);
    }

    /// @notice Propose the result once the match is over, backing it with a bond.
    function proposeResult(bytes32 marketId, GoalyMarkets.Outcome outcome, uint256 oddsBps)
        external
        nonReentrant
    {
        GoalyMarkets.Market memory m = markets.markets(marketId);
        if (block.timestamp < m.closeTime) revert MatchNotOver();
        Proposal storage p = proposals[marketId];
        if (p.phase != Phase.NONE) revert AlreadyProposed();

        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);
        p.phase = Phase.PROPOSED;
        p.outcome = outcome;
        p.oddsBps = oddsBps;
        p.proposedAt = uint64(block.timestamp);
        p.proposer = msg.sender;
        emit Proposed(marketId, outcome, oddsBps, msg.sender);
    }

    /// @notice Challenge a proposed result within the dispute window (posts an equal bond).
    function dispute(bytes32 marketId) external nonReentrant {
        Proposal storage p = proposals[marketId];
        if (p.phase != Phase.PROPOSED) revert NotProposed();
        if (block.timestamp >= p.proposedAt + disputeWindow) revert WindowClosed();

        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);
        p.phase = Phase.DISPUTED;
        p.disputer = msg.sender;
        emit Disputed(marketId, msg.sender);
    }

    /// @notice Settle the market with the proposed result after an unchallenged dispute window, and
    ///         refund the honest proposer.
    function finalize(bytes32 marketId) external nonReentrant {
        Proposal storage p = proposals[marketId];
        if (p.phase != Phase.PROPOSED) revert NotProposed();
        if (block.timestamp < p.proposedAt + disputeWindow) revert WindowOpen();

        p.phase = Phase.FINALIZED;
        markets.settleMarket(marketId, p.outcome, p.oddsBps);
        bondToken.safeTransfer(p.proposer, bondAmount);
        emit Finalized(marketId, p.outcome);
    }

    /// @notice Governance resolves a disputed market with the true result, awarding both bonds to the
    ///         party that was right.
    function resolveDispute(
        bytes32 marketId,
        GoalyMarkets.Outcome outcome,
        uint256 oddsBps,
        bool proposerWasRight
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        Proposal storage p = proposals[marketId];
        if (p.phase != Phase.DISPUTED) revert NotDisputed();

        p.phase = Phase.FINALIZED;
        markets.settleMarket(marketId, outcome, oddsBps);
        address winner = proposerWasRight ? p.proposer : p.disputer;
        bondToken.safeTransfer(winner, bondAmount * 2);
        emit Resolved(marketId, outcome, winner);
    }
}
