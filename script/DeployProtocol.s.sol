// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {GoalyMarkets} from "../src/GoalyMarkets.sol";
import {MorphoStrategy} from "../src/strategies/MorphoStrategy.sol";
import {GoalySettlement} from "../src/GoalySettlement.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {IOFT} from "../src/interfaces/IOFT.sol";

/// @notice Deploys the layered Goaly protocol behind UUPS proxies, wires the least-privilege roles,
///         then hands DEFAULT_ADMIN to governance (Timelock + Safe) and renounces the deployer's.
///
///         env: USDT0, MORPHO_USDT0_VAULT, GOVERNANCE, ORACLE, AGENT, GUARDIAN
///              [BUFFER_BPS=1500] [FEE_BPS=250] [BOOST_BPS=5000]
contract DeployProtocol is Script {
    function run() external {
        address deployer = msg.sender;
        address usdt0 = vm.envAddress("USDT0");
        address morphoVault = vm.envAddress("MORPHO_USDT0_VAULT");
        address governance = vm.envAddress("GOVERNANCE");
        address oracle = vm.envAddress("ORACLE");
        address agent = vm.envAddress("AGENT");
        address guardian = vm.envAddress("GUARDIAN");
        uint16 bufferBps = uint16(vm.envOr("BUFFER_BPS", uint256(1500)));
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(250)));
        uint16 boostBps = uint16(vm.envOr("BOOST_BPS", uint256(5000)));

        vm.startBroadcast();

        // 1) Vault behind a UUPS proxy — deployer is the temporary admin so it can wire everything.
        GoalyVault vault = GoalyVault(
            address(
                new ERC1967Proxy(
                    address(new GoalyVault()),
                    abi.encodeCall(
                        GoalyVault.initialize,
                        (IERC20(usdt0), "Goaly Vault USDT", "gvUSDT", deployer, bufferBps)
                    )
                )
            )
        );

        // 2) A same-asset Morpho USDT0 strategy, whitelisted on the vault.
        MorphoStrategy strategy = new MorphoStrategy(IERC4626(morphoVault), address(vault));
        vault.addStrategy(strategy);
        vault.grantRole(vault.AGENT_ROLE(), agent);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);

        // 3) Markets behind a UUPS proxy.
        GoalyMarkets markets = GoalyMarkets(
            address(
                new ERC1967Proxy(
                    address(new GoalyMarkets()),
                    abi.encodeCall(
                        GoalyMarkets.initialize,
                        (IERC20(usdt0), IERC4626(address(vault)), deployer, oracle, feeBps, boostBps)
                    )
                )
            )
        );
        markets.grantRole(markets.GUARDIAN_ROLE(), guardian);

        // 4) Optimistic settlement oracle (holds ORACLE_ROLE; backend gets PROPOSER_ROLE).
        GoalySettlement settlement = new GoalySettlement(
            markets,
            IERC20(usdt0),
            vm.envOr("BOND_AMOUNT", uint256(10e6)),
            uint64(vm.envOr("DISPUTE_WINDOW", uint256(2 hours))),
            deployer // temporary admin so the deployer can wire the sub-roles
        );
        markets.grantRole(markets.ORACLE_ROLE(), address(settlement));
        settlement.grantRole(settlement.PROPOSER_ROLE(), oracle);
        settlement.grantRole(settlement.DEFAULT_ADMIN_ROLE(), governance);
        settlement.renounceRole(settlement.DEFAULT_ADMIN_ROLE(), deployer);

        // 5) Reserve manager (surplus-only cross-chain via the USDT0 OFT; agent is the keeper).
        ReserveManager reserve = new ReserveManager(IOFT(vm.envAddress("USDT0_OFT")), deployer);
        reserve.grantRole(reserve.KEEPER_ROLE(), agent);
        reserve.grantRole(reserve.DEFAULT_ADMIN_ROLE(), governance);
        reserve.renounceRole(reserve.DEFAULT_ADMIN_ROLE(), deployer);

        // 6) Hand DEFAULT_ADMIN to governance (Timelock + Safe) and drop the deployer's.
        if (governance != deployer) {
            vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), governance);
            markets.grantRole(markets.DEFAULT_ADMIN_ROLE(), governance);
            vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), deployer);
            markets.renounceRole(markets.DEFAULT_ADMIN_ROLE(), deployer);
        }

        vm.stopBroadcast();

        console2.log("GoalyVault     ", address(vault));
        console2.log("MorphoStrategy ", address(strategy));
        console2.log("GoalyMarkets   ", address(markets));
        console2.log("GoalySettlement", address(settlement));
        console2.log("ReserveManager ", address(reserve));
        console2.log("governance     ", governance);
    }
}
