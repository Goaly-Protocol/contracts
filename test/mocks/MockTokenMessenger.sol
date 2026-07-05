// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ITokenMessenger} from "../../src/interfaces/ICCTP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal CCTP TokenMessenger mock: `depositForBurn` pulls the USDC from the caller and holds
///         it, simulating a burn-on-source cross-chain transfer.
contract MockTokenMessenger is ITokenMessenger {
    using SafeERC20 for IERC20;

    uint256 public lastAmount;
    uint32 public lastDomain;

    function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32, address burnToken)
        external
        returns (uint64)
    {
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
        lastDomain = destinationDomain;
        return 1;
    }
}
