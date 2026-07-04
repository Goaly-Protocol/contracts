// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev Minimal Circle CCTP `TokenMessenger` surface used to bridge USDC across chains (the mechanism
///      behind Wormhole's "Automatic CCTP" — Wormhole relays the burn/mint + pays destination gas).
interface ITokenMessenger {
    /// @notice Burn `amount` of `burnToken` (USDC) here and signal a mint of the same on `destinationDomain`.
    /// @param destinationDomain Circle domain id (Ethereum = 0, Arbitrum = 3).
    /// @param mintRecipient Recipient on the destination chain, as bytes32.
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);
}
