// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IOFT, SendParam, MessagingFee} from "./interfaces/IOFT.sol";

/// @title ReserveManager
/// @notice Holds *surplus only* — harvested yield that funds prizes, never staked principal — and can
///         deploy it to a higher-yield venue on another chain. Because USDT0 is a native LayerZero OFT,
///         the surplus bridges directly (no swap). Principal never leaves the pool's chain, so no-loss
///         claims are unaffected; only prize funding takes on cross-chain latency. This is the safe way
///         to capture cross-chain yield.
///
///         KEEPER_ROLE (agent) may bridge; DEFAULT_ADMIN (governance) may recall. A keeper key that is
///         compromised can only move surplus between the protocol's own reserve managers.
contract ReserveManager is AccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IERC20 public immutable asset; // USDT0
    IOFT public immutable oft; // USDT0 as its own OFT

    event Bridged(uint32 indexed dstEid, bytes32 indexed to, uint256 amount);
    event Recalled(address indexed to, uint256 amount);

    error OftAssetMismatch();

    constructor(IOFT oft_, address governance) {
        oft = oft_;
        asset = IERC20(oft_.token());
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
    }

    /// @notice Bridge `amount` of surplus USDT0 to `to` on chain `dstEid`, paying the LayerZero fee in
    ///         native gas supplied with the call.
    function bridgeSurplus(
        uint32 dstEid,
        bytes32 to,
        uint256 amount,
        uint256 minAmount,
        bytes calldata options
    ) external payable onlyRole(KEEPER_ROLE) nonReentrant {
        SendParam memory sp = SendParam(dstEid, to, amount, minAmount, options, "", "");
        MessagingFee memory fee = oft.quoteSend(sp, false);
        asset.forceApprove(address(oft), amount);
        oft.send{value: fee.nativeFee}(sp, fee, msg.sender);
        emit Bridged(dstEid, to, amount);
    }

    /// @notice Governance pulls surplus back out (e.g. to fund prizes locally).
    function recall(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        asset.safeTransfer(to, amount);
        emit Recalled(to, amount);
    }

    /// @notice Surplus currently parked here.
    function balance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    receive() external payable {}
}
