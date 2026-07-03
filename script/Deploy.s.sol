// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyPool} from "../src/GoalyPool.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";

/// @notice Deploys GoalyPool on Arbitrum One — no-loss prediction markets with a built-in Morpho
///         yield engine (multi-token stake, cross-asset backing, withdraw-to-token). No receipt token.
contract Deploy is Script {
    address internal constant MORPHO_VAULT = 0x139250CdB310D657eAC506c7C7FC6AcDE34Af1ec;
    // Uniswap V3 SwapRouter on Arbitrum One — normalises stakes/payouts + cross-asset backing.
    address internal constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function run() external returns (GoalyPool pool) {
        uint256 pk = vm.envOr("WALLET_PK", uint256(0));
        if (pk == 0) pk = vm.envUint("PRIVATE_KEY");

        uint16 feeBps = uint16(vm.envOr("PROTOCOL_FEE_BPS", uint256(250)));
        uint16 boostBps = uint16(vm.envOr("PROTOCOL_BOOST_BPS", uint256(5000)));
        address swapRouter = vm.envOr("SWAP_ROUTER", UNISWAP_ROUTER);
        uint24 swapFee = uint24(vm.envOr("SWAP_FEE", uint256(100)));
        uint256 maxSlippageBps = vm.envOr("SWAP_MAX_SLIPPAGE_BPS", uint256(50));

        IERC4626 morpho = IERC4626(MORPHO_VAULT);
        address usdt0 = morpho.asset();

        vm.startBroadcast(pk);
        pool = new GoalyPool(
            IERC20(usdt0),
            morpho,
            ISwapRouter(swapRouter),
            swapFee,
            maxSlippageBps,
            feeBps,
            boostBps
        );
        vm.stopBroadcast();

        console2.log("GoalyPool:", address(pool));
    }
}
