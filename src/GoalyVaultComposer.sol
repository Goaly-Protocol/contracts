// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

interface IGoalyVaultDeposit {
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

/// @title GoalyVaultComposer
/// @notice LayerZero V2 composer that turns a cross-chain USDT0 transfer into a Goaly deposit.
///         A user on any chain sends USDT0 via its OFT to Arbitrum, targeting this composer with a
///         compose message carrying their hub-chain address. The USDT0 OFT delivers the tokens here
///         and the LayerZero Endpoint calls {lzCompose}; we then deposit them into {GoalyVault},
///         minting goUSDT to the origin-chain user. This is how "deposit from any chain" works.
contract GoalyVaultComposer is ILayerZeroComposer {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdt0;
    IGoalyVaultDeposit public immutable vault;
    address public immutable endpoint;
    address public immutable oft;

    event CrossChainDeposit(address indexed recipient, uint256 amount, bytes32 guid);

    error NotEndpoint();
    error UnexpectedOft();

    constructor(IERC20 _usdt0, IGoalyVaultDeposit _vault, address _endpoint, address _oft) {
        usdt0 = _usdt0;
        vault = _vault;
        endpoint = _endpoint;
        oft = _oft;
        _usdt0.forceApprove(address(_vault), type(uint256).max);
    }

    /// @inheritdoc ILayerZeroComposer
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    ) external payable {
        if (msg.sender != endpoint) revert NotEndpoint();
        if (_from != oft) revert UnexpectedOft();

        uint256 amount = OFTComposeMsgCodec.amountLD(_message);
        address recipient = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (address));

        // Tokens were delivered to this contract by the OFT prior to this call.
        vault.deposit(amount, recipient);
        emit CrossChainDeposit(recipient, amount, _guid);
    }
}
