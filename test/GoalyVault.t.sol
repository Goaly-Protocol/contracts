// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {IGoalyVault} from "../src/interfaces/IGoalyVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract GoalyVaultTest is Test {
    MockERC20 internal usdt0;
    MockERC4626 internal morpho;
    GoalyVault internal vault;

    address internal alice = address(0xA11CE);
    address internal settler = address(0x5E77);

    uint256 internal constant UNIT = 1e6; // 6 decimals

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        morpho = new MockERC4626(usdt0);
        vault = new GoalyVault(IERC20(address(usdt0)), IERC4626(address(morpho)));
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

    function test_ChargeDebtRequiresSettlerRole() public {
        _depositAsAlice(100 * UNIT);
        // The admin (this test) lacks SETTLER_ROLE.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), vault.SETTLER_ROLE()
            )
        );
        vault.chargeDebt(alice, 5 * UNIT);

        vm.prank(settler);
        vault.chargeDebt(alice, 5 * UNIT);
        assertEq(vault.debtOf(alice), 5 * UNIT);
    }

    function test_PrincipalLockedUntilYieldRepaysDebt() public {
        _depositAsAlice(100 * UNIT);
        vm.prank(settler);
        vault.chargeDebt(alice, 5 * UNIT);

        assertEq(vault.remainingDebt(alice), 5 * UNIT);
        assertTrue(vault.principalLocked(alice));

        vm.expectRevert(IGoalyVault.PrincipalLocked.selector);
        vm.prank(alice);
        vault.withdraw();

        morpho.accrue(5 * UNIT); // simulate 5 USDT0 of yield
        assertEq(vault.yieldOf(alice), 5 * UNIT);
        assertEq(vault.remainingDebt(alice), 0);
        assertFalse(vault.principalLocked(alice));
    }

    function test_WithdrawReturnsPrincipalAndProtocolKeepsYield() public {
        _depositAsAlice(100 * UNIT);
        vm.prank(settler);
        vault.chargeDebt(alice, 5 * UNIT);
        morpho.accrue(5 * UNIT);

        vm.prank(alice);
        uint256 assets = vault.withdraw();

        // Alice gets exactly her principal back — she lost the bet but kept her money.
        assertEq(assets, 100 * UNIT);
        assertEq(usdt0.balanceOf(alice), 100 * UNIT);
        assertEq(vault.principalOf(alice), 0);
        assertEq(vault.debtOf(alice), 0);

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

    function test_DepositRevertsWhenPaused() public {
        vault.pause();
        vm.expectRevert(); // Pausable: EnforcedPause
        _depositAsAlice(100 * UNIT);
        vault.unpause();
        _depositAsAlice(100 * UNIT);
        assertEq(vault.principalOf(alice), 100 * UNIT);
    }

    function test_DepositZeroReverts() public {
        vm.expectRevert(IGoalyVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.deposit(0);
    }

    function test_ConstructorRejectsAssetMismatch() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 6);
        vm.expectRevert(IGoalyVault.AssetMismatch.selector);
        new GoalyVault(IERC20(address(other)), IERC4626(address(morpho)));
    }
}
