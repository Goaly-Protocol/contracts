// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";
import {ITokenMessenger} from "../../src/interfaces/ICCTP.sol";

/// @notice Minimal CCTP TokenMessenger mock: `depositForBurn` pulls the USDC from the caller and holds
///         it, simulating a burn-on-source cross-chain transfer.
contract MockTokenMessenger is ITokenMessenger {
    uint256 public lastAmount;
    uint32 public lastDomain;

    function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32, address burnToken)
        external
        returns (uint64)
    {
        MockERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
        lastDomain = destinationDomain;
        return 1;
    }
}
