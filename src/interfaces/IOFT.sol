// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev Minimal LayerZero OFT surface used to bridge USDT0 (a native OFT) across chains.
struct SendParam {
    uint32 dstEid; // destination endpoint id
    bytes32 to; // recipient (address as bytes32)
    uint256 amountLD; // amount in local decimals
    uint256 minAmountLD; // min received (slippage floor)
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

interface IOFT {
    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory);

    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external
        view
        returns (MessagingFee memory);

    function token() external view returns (address);
}
