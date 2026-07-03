// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Mock Circle CCTP MessageTransmitter: `receiveMessage` mints USDC to the caller (the
///         receiver), simulating a completed cross-chain burn-and-mint.
contract MockMessageTransmitter {
    MockERC20 public immutable usdc;
    uint256 public mintAmount;

    constructor(MockERC20 _usdc, uint256 _mintAmount) {
        usdc = _usdc;
        mintAmount = _mintAmount;
    }

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        usdc.mint(msg.sender, mintAmount);
        return true;
    }
}
