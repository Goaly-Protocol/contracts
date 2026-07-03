// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    IMessageTransmitter
} from "@wormhole-foundation/wormhole-solidity-sdk/interfaces/cctp/IMessageTransmitter.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {PredictionPool} from "../src/PredictionPool.sol";
import {GoalyWormholeReceiver, IGoalyVaultDeposit} from "../src/GoalyWormholeReceiver.sol";

/// @notice Deploys and wires the Goaly system on Arbitrum One:
///         GoalyVault (goUSDT over Morpho, cross-asset) + PredictionPool (stakes goUSDT, prizes in
///         USDT0) + GoalyWormholeReceiver (Wormhole/CCTP cross-chain deposits).
contract Deploy is Script {
    address internal constant MORPHO_VAULT = 0x139250CdB310D657eAC506c7C7FC6AcDE34Af1ec;
    // Uniswap V3 SwapRouter on Arbitrum One — used for cross-asset yield backing + the receiver swap.
    address internal constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    // Circle CCTP MessageTransmitter + USDC on Arbitrum One (Wormhole routes USDC over CCTP).
    address internal constant CCTP_MESSAGE_TRANSMITTER = 0xC30362313FBBA5cf9163F0bb16a0e01f01A896ca;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function run()
        external
        returns (GoalyVault vault, PredictionPool pool, GoalyWormholeReceiver receiver)
    {
        uint256 pk = vm.envOr("WALLET_PK", uint256(0));
        if (pk == 0) pk = vm.envUint("PRIVATE_KEY");

        uint16 feeBps = uint16(vm.envOr("PROTOCOL_FEE_BPS", uint256(250)));
        uint16 boostBps = uint16(vm.envOr("PROTOCOL_BOOST_BPS", uint256(5000)));

        IERC4626 morpho = IERC4626(MORPHO_VAULT);
        address usdt0 = morpho.asset();
        address swapRouter = vm.envOr("SWAP_ROUTER", UNISWAP_ROUTER);
        uint24 swapFee = uint24(vm.envOr("SWAP_FEE", uint256(100)));
        uint256 maxSlippageBps = vm.envOr("SWAP_MAX_SLIPPAGE_BPS", uint256(50));

        vm.startBroadcast(pk);
        vault =
            new GoalyVault(IERC20(usdt0), morpho, ISwapRouter(swapRouter), swapFee, maxSlippageBps);
        // goUSDT (the vault itself) is the stake token; USDT0 is the prize token.
        pool = new PredictionPool(IERC20(address(vault)), IERC20(usdt0), feeBps, boostBps);
        // Deposit-from-any-chain over Wormhole/CCTP: receive USDC, swap to USDT0, deposit into vault.
        receiver = new GoalyWormholeReceiver(
            IMessageTransmitter(CCTP_MESSAGE_TRANSMITTER),
            IERC20(USDC),
            IERC20(usdt0),
            IGoalyVaultDeposit(address(vault)),
            ISwapRouter(swapRouter),
            swapFee
        );
        vm.stopBroadcast();

        console2.log("GoalyVault (goUSDT):    ", address(vault));
        console2.log("PredictionPool:         ", address(pool));
        console2.log("GoalyWormholeReceiver:  ", address(receiver));
    }
}
