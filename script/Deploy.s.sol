// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalYieldVault} from "../src/GoalYieldVault.sol";

/// @notice Deploys GoalYieldVault wired to the Morpho "Gauntlet USDT0 Core" vault on Arbitrum One.
contract Deploy is Script {
    address internal constant MORPHO_VAULT = 0x139250CdB310D657eAC506c7C7FC6AcDE34Af1ec;

    function run() external returns (GoalYieldVault vault) {
        // Deployer key from the repo .env (WALLET_PK), falling back to PRIVATE_KEY.
        uint256 pk = vm.envOr("WALLET_PK", uint256(0));
        if (pk == 0) pk = vm.envUint("PRIVATE_KEY");
        IERC4626 morpho = IERC4626(MORPHO_VAULT);
        vm.startBroadcast(pk);
        vault = new GoalYieldVault(IERC20(morpho.asset()), morpho);
        vm.stopBroadcast();
        console2.log("GoalYieldVault deployed at:", address(vault));
    }
}
