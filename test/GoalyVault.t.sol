// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract GoalyVaultTest is Test {
    MockERC20 internal usdt0;
    MockERC4626 internal morpho;
    GoalyVault internal vault;

    address internal alice = address(0xA11CE);
    uint256 internal constant UNIT = 1e6;

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        morpho = new MockERC4626(usdt0);
        vault = new GoalyVault(IERC20(address(usdt0)), IERC4626(address(morpho)));

        usdt0.mint(alice, 100 * UNIT);
        vm.prank(alice);
        usdt0.approve(address(vault), type(uint256).max);
    }

    function _depositAsAlice(uint256 assets) internal {
        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    function test_DepositMintsGoUsdt1to1() public {
        _depositAsAlice(100 * UNIT);
        assertEq(vault.balanceOf(alice), 100 * UNIT); // goUSDT
        assertEq(vault.totalSupply(), 100 * UNIT);
        assertEq(usdt0.balanceOf(alice), 0);
        assertEq(vault.decimals(), 6);
    }

    function test_WithdrawRedeems1to1() public {
        _depositAsAlice(100 * UNIT);
        vm.prank(alice);
        vault.withdraw(100 * UNIT, alice);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(usdt0.balanceOf(alice), 100 * UNIT);
    }

    function test_YieldAccruesToProtocolNotHolders() public {
        _depositAsAlice(100 * UNIT);
        morpho.accrue(5 * UNIT); // 5 USDT0 of yield
        assertEq(vault.accruedYield(), 5 * UNIT);
        assertEq(vault.balanceOf(alice), 100 * UNIT); // holder principal unchanged (1:1)

        uint256 harvested = vault.harvestYield(address(this));
        assertEq(harvested, 5 * UNIT);
        assertEq(usdt0.balanceOf(address(this)), 5 * UNIT);
        assertEq(vault.accruedYield(), 0);

        // Alice still redeems her full principal.
        vm.prank(alice);
        vault.withdraw(100 * UNIT, alice);
        assertEq(usdt0.balanceOf(alice), 100 * UNIT);
    }

    function test_HarvestRevertsWithoutYield() public {
        _depositAsAlice(100 * UNIT);
        vm.expectRevert(GoalyVault.NoYield.selector);
        vault.harvestYield(address(this));
    }

    function test_MigrateYieldVaultPreservesGoUsdt() public {
        _depositAsAlice(100 * UNIT);
        morpho.accrue(10 * UNIT);
        assertApproxEqAbs(vault.totalAssets(), 110 * UNIT, 2);

        MockERC4626 morphoB = new MockERC4626(usdt0);
        vault.migrateYieldVault(IERC4626(address(morphoB)));

        assertEq(address(vault.yieldVault()), address(morphoB));
        assertApproxEqAbs(vault.totalAssets(), 110 * UNIT, 3);
        assertEq(vault.balanceOf(alice), 100 * UNIT); // holder unaffected
        // still redeemable 1:1
        vm.prank(alice);
        vault.withdraw(100 * UNIT, alice);
        assertEq(usdt0.balanceOf(alice), 100 * UNIT);
    }

    function test_DepositZeroReverts() public {
        vm.expectRevert(GoalyVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.deposit(0, alice);
    }

    function test_DepositRevertsWhenPaused() public {
        vault.pause();
        vm.expectRevert();
        _depositAsAlice(100 * UNIT);
    }

    function test_ConstructorRejectsAssetMismatch() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 6);
        vm.expectRevert(GoalyVault.AssetMismatch.selector);
        new GoalyVault(IERC20(address(other)), IERC4626(address(morpho)));
    }
}
