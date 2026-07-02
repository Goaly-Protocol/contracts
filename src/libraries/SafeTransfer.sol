// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

/// @notice Minimal safe ERC-20 helpers that tolerate tokens which do not return a bool.
library SafeTransfer {
    error TransferFailed();
    error TransferFromFailed();
    error ApproveFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0xa9059cbb, to, amount)); // transfer(address,uint256)
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount)); // transferFrom(address,address,uint256)
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFromFailed();
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount)); // approve(address,uint256)
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert ApproveFailed();
    }
}
