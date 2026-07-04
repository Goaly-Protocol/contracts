// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "../../src/interfaces/IOFT.sol";

/// @notice Minimal OFT mock: `send` pulls the amount from the caller and holds it, simulating a
///         burn-on-source cross-chain transfer. Charges a flat native fee.
contract MockOFT is IOFT {
    MockERC20 public immutable underlying;
    uint256 public constant FEE = 0.001 ether;
    uint256 public lastAmount;

    constructor(MockERC20 underlying_) {
        underlying = underlying_;
    }

    function token() external view returns (address) {
        return address(underlying);
    }

    function quoteSend(SendParam calldata, bool) external pure returns (MessagingFee memory) {
        return MessagingFee(FEE, 0);
    }

    function send(SendParam calldata sp, MessagingFee calldata, address)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        require(msg.value >= FEE, "fee");
        underlying.transferFrom(msg.sender, address(this), sp.amountLD);
        lastAmount = sp.amountLD;
        return (MessagingReceipt(bytes32(0), 0, MessagingFee(0, 0)), OFTReceipt(sp.amountLD, sp.amountLD));
    }
}
