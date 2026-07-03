// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

contract GoalyVaultTest is Test {
    MockERC20 internal usdt0;
    MockERC20 internal usdc;
    MockERC4626 internal morpho; // USDT0 vault
    MockERC4626 internal morphoUsdc; // cross-asset USDC vault
    MockSwapRouter internal router;
    GoalyVault internal vault;

    address internal alice = address(0xA11CE);
    uint256 internal constant UNIT = 1e6;
    uint24 internal constant FEE = 100;
    uint256 internal constant SLIPPAGE_BPS = 50;

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        morpho = new MockERC4626(usdt0);
        morphoUsdc = new MockERC4626(usdc);
        router = new MockSwapRouter(5); // 0.05% swap fee
        vault = new GoalyVault(
            IERC20(address(usdt0)), IERC4626(address(morpho)), router, FEE, SLIPPAGE_BPS
        );

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
        assertFalse(vault.isCrossAsset());
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

    // --- Cross-asset (USDT0 → USDC) ---------------------------------------------------------------

    function test_MigrateCrossAssetSwapsBacking() public {
        _depositAsAlice(100 * UNIT);
        morpho.accrue(10 * UNIT); // buffer to absorb swap cost

        vault.migrateYieldVault(IERC4626(address(morphoUsdc)));

        assertTrue(vault.isCrossAsset());
        assertEq(address(vault.yieldAsset()), address(usdc));
        // ~110 USDT0 swapped to USDC minus the 0.05% swap fee → backing now in USDC.
        assertApproxEqAbs(vault.totalAssets(), 110 * UNIT, 1 * UNIT / 10);
        assertGt(vault.accruedYield(), 0); // still over-collateralised
    }

    function test_CrossAssetWithdrawReturnsFullUsdt0() public {
        _depositAsAlice(100 * UNIT);
        morpho.accrue(10 * UNIT);
        vault.migrateYieldVault(IERC4626(address(morphoUsdc)));

        // Even though the backing is USDC, the holder gets exactly 100 USDT0 back (no-loss).
        vm.prank(alice);
        vault.withdraw(100 * UNIT, alice);
        assertEq(usdt0.balanceOf(alice), 100 * UNIT);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_CrossAssetDepositMintsGoUsdt1to1() public {
        _depositAsAlice(100 * UNIT);
        morpho.accrue(10 * UNIT);
        vault.migrateYieldVault(IERC4626(address(morphoUsdc)));

        // A fresh USDT0 deposit while cross-asset still mints goUSDT 1:1.
        usdt0.mint(alice, 20 * UNIT);
        vm.prank(alice);
        vault.deposit(20 * UNIT, alice);
        assertEq(vault.balanceOf(alice), 120 * UNIT);
        assertEq(vault.totalSupply(), 120 * UNIT);
    }

    function test_SetSwapConfigOnlyManager() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setSwapConfig(router, 500, 100);

        vault.setSwapConfig(router, 500, 100);
        assertEq(vault.swapFee(), 500);
        assertEq(vault.maxSlippageBps(), 100);
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
        new GoalyVault(IERC20(address(other)), IERC4626(address(morpho)), router, FEE, SLIPPAGE_BPS);
    }
}
