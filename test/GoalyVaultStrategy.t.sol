// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {AllocationLib} from "../src/libraries/AllocationLib.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MorphoStrategy} from "../src/strategies/MorphoStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @notice Exercises the vault's strategy allocation: the buffer is always respected, `rebalance`
///         hits the agent's targets, and withdrawals transparently pull back from strategies.
contract GoalyVaultStrategyTest is Test {
    MockERC20 usdt;
    MockERC4626 morpho;
    GoalyVault vault;
    MorphoStrategy strat;

    address agent = makeAddr("agent");
    address user = makeAddr("user");

    function setUp() public {
        usdt = new MockERC20("Tether USDT0", "USDT0", 6);
        morpho = new MockERC4626(usdt);

        vault = GoalyVault(
            address(
                new ERC1967Proxy(
                    address(new GoalyVault()),
                    abi.encodeCall(
                        GoalyVault.initialize,
                        (IERC20(address(usdt)), "Goaly Vault USDT", "gvUSDT", address(this), 1000)
                    )
                )
            )
        );
        strat = new MorphoStrategy(IERC4626(address(morpho)), address(vault));
        vault.addStrategy(strat);
        vault.grantRole(vault.AGENT_ROLE(), agent);

        usdt.mint(user, 1000e6);
        vm.startPrank(user);
        usdt.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();
    }

    function test_allocate_respectsBuffer() public {
        // 1000 total, 10% buffer = 100 must stay idle → at most 900 allocatable.
        vm.prank(agent);
        vault.allocate(strat, 900e6);
        assertEq(strat.totalAssets(), 900e6);
        assertEq(usdt.balanceOf(address(vault)), 100e6);

        vm.prank(agent);
        vm.expectRevert(AllocationLib.BufferBreached.selector);
        vault.allocate(strat, 1);
    }

    function test_rebalanceToTarget_thenWithdrawPullsFromStrategy() public {
        vm.prank(agent);
        vault.allocate(strat, 500e6);

        IStrategy[] memory s = new IStrategy[](1);
        s[0] = strat;
        uint256[] memory t = new uint256[](1);
        t[0] = 800e6;
        vm.prank(agent);
        vault.rebalance(s, t);
        assertEq(strat.totalAssets(), 800e6, "target hit");
        assertEq(usdt.balanceOf(address(vault)), 200e6, "buffer + slack idle");

        // 200 idle < 950 requested → 750 is pulled back from the strategy automatically.
        vm.prank(user);
        vault.withdraw(950e6, user, user);
        assertEq(usdt.balanceOf(user), 950e6, "withdrawal serviced across buffer + strategy");
        assertGe(vault.totalAssets(), vault.convertToAssets(vault.balanceOf(user)), "solvent");
    }

    function test_onlyAgentCanAllocate() public {
        vm.expectRevert();
        vault.allocate(strat, 100e6); // address(this) has no AGENT_ROLE
    }
}
