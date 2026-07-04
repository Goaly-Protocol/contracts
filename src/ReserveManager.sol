// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ITokenMessenger} from "./interfaces/ICCTP.sol";

/// @title ReserveManager
/// @notice Holds *surplus only* — harvested yield that funds prizes, never staked principal — and can
///         deploy it to a higher-yield venue on another chain. It bridges USDC via Circle **CCTP**
///         (the mechanism behind Wormhole's Automatic CCTP: burn here, Wormhole relays the mint on the
///         destination), matching the agent's cross-chain route. Principal never leaves the pool's
///         chain, so no-loss claims are unaffected; only prize funding takes on cross-chain latency.
///
///         KEEPER_ROLE (agent) may bridge; DEFAULT_ADMIN (governance) may recall. A compromised keeper
///         can only move surplus between the protocol's own reserve managers.
contract ReserveManager is AccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IERC20 public immutable usdc;
    ITokenMessenger public immutable cctp; // Circle TokenMessenger (Wormhole-relayed CCTP)

    event Bridged(uint32 indexed destinationDomain, bytes32 indexed to, uint256 amount, uint64 nonce);
    event Recalled(address indexed to, uint256 amount);

    constructor(ITokenMessenger cctp_, IERC20 usdc_, address governance) {
        cctp = cctp_;
        usdc = usdc_;
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
    }

    /// @notice Bridge `amount` of surplus USDC to `to` on `destinationDomain` (Circle domain id:
    ///         Ethereum = 0, Arbitrum = 3) via CCTP — burn here, Wormhole relays the mint.
    function bridgeSurplus(uint32 destinationDomain, bytes32 to, uint256 amount)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (uint64 nonce)
    {
        usdc.forceApprove(address(cctp), amount);
        nonce = cctp.depositForBurn(amount, destinationDomain, to, address(usdc));
        emit Bridged(destinationDomain, to, amount, nonce);
    }

    /// @notice Governance pulls surplus back out (e.g. to fund prizes locally).
    function recall(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        usdc.safeTransfer(to, amount);
        emit Recalled(to, amount);
    }

    /// @notice Surplus USDC currently parked here.
    function balance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
