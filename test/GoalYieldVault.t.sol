// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {GoalYieldVault} from "../src/GoalYieldVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IERC4626} from "../src/interfaces/IERC4626.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract GoalYieldVaultTest is Test {
    MockERC20 internal usdt0;
    MockERC4626 internal morpho;
    GoalYieldVault internal vault;

    address internal alice = address(0xA11CE);
    address internal settler = address(0x5E77);

    uint256 internal constant UNIT = 1e6; // 6 decimals

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        morpho = new MockERC4626(usdt0);
        vault = new GoalYieldVault(IERC20(address(usdt0)), IERC4626(address(morpho)));
        vault.setSettler(settler, true);

        usdt0.mint(alice, 100 * UNIT);
        vm.prank(alice);
        usdt0.approve(address(vault), type(uint256).max);
    }

    function _depositAsAlice(uint256 assets) internal {
        vm.prank(alice);
        vault.deposit(assets);
    }

    function test_DepositTracksPrincipalAndShares() public {
        _depositAsAlice(100 * UNIT);
        assertEq(vault.principalOf(alice), 100 * UNIT);
        assertGt(vault.sharesOf(alice), 0);
        assertEq(vault.totalPrincipal(), 100 * UNIT);
        assertEq(usdt0.balanceOf(alice), 0);
    }

    function test_ChargeDebtOnlySettler() public {
        _depositAsAlice(100 * UNIT);
        vm.expectRevert(GoalYieldVault.NotSettler.selector);
        vault.chargeDebt(alice, 5 * UNIT);

        vm.prank(settler);
        vault.chargeDebt(alice, 5 * UNIT);
        assertEq(vault.debtOf(alice), 5 * UNIT);
    }

    function test_PrincipalLockedUntilYieldRepaysDebt() public {
        _depositAsAlice(100 * UNIT);
        vm.prank(settler);
        vault.chargeDebt(alice, 5 * UNIT);

        // Debt outstanding, no yield yet -> locked.
        assertEq(vault.remainingDebt(alice), 5 * UNIT);
        assertTrue(vault.principalLocked(alice));

        vm.expectRevert(GoalYieldVault.PrincipalLocked.selector);
        vm.prank(alice);
        vault.withdraw();

        // Simulate 5 USDT0 of yield -> debt self-repays -> unlocked.
        morpho.accrue(5 * UNIT);
        assertEq(vault.yieldOf(alice), 5 * UNIT);
        assertEq(vault.remainingDebt(alice), 0);
        assertFalse(vault.principalLocked(alice));
    }

    function test_WithdrawReturnsPrincipalAndProtocolKeepsYield() public {
        _depositAsAlice(100 * UNIT);
        vm.prank(settler);
        vault.chargeDebt(alice, 5 * UNIT);
        morpho.accrue(5 * UNIT); // yield clears the debt

        vm.prank(alice);
        uint256 assets = vault.withdraw();

        // Alice gets exactly her principal back — never less. She lost the bet but kept her money.
        assertEq(assets, 100 * UNIT);
        assertEq(usdt0.balanceOf(alice), 100 * UNIT);
        assertEq(vault.principalOf(alice), 0);
        assertEq(vault.debtOf(alice), 0);

        // The yield stays with the protocol.
        assertGt(vault.protocolShares(), 0);
        uint256 skimmed = vault.skim(address(this));
        assertApproxEqAbs(skimmed, 5 * UNIT, 2);
    }

    function test_WithdrawWithoutDebtReturnsPrincipal() public {
        _depositAsAlice(100 * UNIT);
        vm.prank(alice);
        uint256 assets = vault.withdraw();
        assertEq(assets, 100 * UNIT);
        assertEq(usdt0.balanceOf(alice), 100 * UNIT);
    }

    function test_DepositZeroReverts() public {
        vm.expectRevert(GoalYieldVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.deposit(0);
    }

    function test_ConstructorRejectsAssetMismatch() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 6);
        vm.expectRevert(GoalYieldVault.AssetMismatch.selector);
        new GoalYieldVault(IERC20(address(other)), IERC4626(address(morpho)));
    }
}
