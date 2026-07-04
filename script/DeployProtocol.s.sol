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

/// @notice Deploys the layered Goaly protocol behind UUPS proxies, wires least-privilege roles, then
///         hands DEFAULT_ADMIN to governance (Timelock + Safe) and renounces the deployer's. Split
///         into helpers so it compiles without via-IR / the optimizer.
///
///         env: USDT0, MORPHO_USDT0_VAULT, GOVERNANCE, ORACLE, AGENT, GUARDIAN
///              [USDT0_OFT] [BUFFER_BPS=1500] [FEE_BPS=250] [BOOST_BPS=5000]
///              [BOND_AMOUNT=10e6] [DISPUTE_WINDOW=7200]
contract DeployProtocol is Script {
    function run() external {
        vm.startBroadcast();
        GoalyVault vault = _vault();
        GoalyMarkets markets = _markets(vault);
        _settlement(markets);
        _reserve();
        vm.stopBroadcast();
    }

    function _vault() internal returns (GoalyVault vault) {
        address deployer = msg.sender;
        vault = GoalyVault(
            address(
                new ERC1967Proxy(
                    address(new GoalyVault()),
                    abi.encodeCall(
                        GoalyVault.initialize,
                        (
                            IERC20(vm.envAddress("USDT0")),
                            "Goaly Vault USDT",
                            "gvUSDT",
                            deployer,
                            uint16(vm.envOr("BUFFER_BPS", uint256(1500)))
                        )
                    )
                )
            )
        );
        MorphoStrategy strategy =
            new MorphoStrategy(IERC4626(vm.envAddress("MORPHO_USDT0_VAULT")), address(vault));
        vault.addStrategy(strategy);
        vault.grantRole(vault.AGENT_ROLE(), vm.envAddress("AGENT"));
        vault.grantRole(vault.GUARDIAN_ROLE(), vm.envAddress("GUARDIAN"));
        _handoff(address(vault), deployer);
        console2.log("GoalyVault    ", address(vault));
        console2.log("MorphoStrategy", address(strategy));
    }

    function _markets(GoalyVault vault) internal returns (GoalyMarkets markets) {
        address deployer = msg.sender;
        markets = GoalyMarkets(
            address(
                new ERC1967Proxy(
                    address(new GoalyMarkets()),
                    abi.encodeCall(
                        GoalyMarkets.initialize,
                        (
                            IERC20(vm.envAddress("USDT0")),
                            IERC4626(address(vault)),
                            deployer, // temp admin so ORACLE_ROLE can be wired to settlement
                            deployer, // temp oracle
                            uint16(vm.envOr("FEE_BPS", uint256(250))),
                            uint16(vm.envOr("BOOST_BPS", uint256(5000)))
                        )
                    )
                )
            )
        );
        markets.grantRole(markets.GUARDIAN_ROLE(), vm.envAddress("GUARDIAN"));
        console2.log("GoalyMarkets  ", address(markets));
    }

    function _settlement(GoalyMarkets markets) internal {
        address deployer = msg.sender;
        GoalySettlement settlement = new GoalySettlement(
            markets,
            IERC20(vm.envAddress("USDT0")),
            vm.envOr("BOND_AMOUNT", uint256(10e6)),
            uint64(vm.envOr("DISPUTE_WINDOW", uint256(2 hours))),
            deployer
        );
        markets.grantRole(markets.ORACLE_ROLE(), address(settlement));
        settlement.grantRole(settlement.PROPOSER_ROLE(), vm.envAddress("ORACLE"));
        _handoff(address(settlement), deployer);
        _handoff(address(markets), deployer); // now safe — settlement already holds ORACLE_ROLE
        console2.log("GoalySettlement", address(settlement));
    }

    function _reserve() internal {
        address oft = vm.envOr("USDT0_OFT", address(0));
        if (oft == address(0)) return;
        address deployer = msg.sender;
        ReserveManager reserve = new ReserveManager(IOFT(oft), deployer);
        reserve.grantRole(reserve.KEEPER_ROLE(), vm.envAddress("AGENT"));
        _handoff(address(reserve), deployer);
        console2.log("ReserveManager", address(reserve));
    }

    /// @dev Grant DEFAULT_ADMIN (bytes32(0)) to governance and renounce the deployer's, if distinct.
    ///      Low-level so it works for both AccessControl and AccessControlUpgradeable targets.
    function _handoff(address target, address deployer) internal {
        address gov = vm.envAddress("GOVERNANCE");
        if (gov == deployer) return;
        (bool ok,) =
            target.call(abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), gov));
        require(ok, "grant admin");
        (ok,) = target.call(
            abi.encodeWithSignature("renounceRole(bytes32,address)", bytes32(0), deployer)
        );
        require(ok, "renounce admin");
    }
}
