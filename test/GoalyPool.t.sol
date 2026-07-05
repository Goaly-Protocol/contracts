// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyPool} from "../src/GoalyPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

contract GoalyPoolTest is Test {
    MockERC20 internal usdt0;
    MockERC20 internal usdc;
    MockERC4626 internal morpho; // USDT0 vault
    MockERC4626 internal morphoUsdc; // cross-asset USDC vault
    MockSwapRouter internal router;
    GoalyPool internal pool;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint256 internal constant UNIT = 1e6;
    bytes32 internal constant M = keccak256("match-1");

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        morpho = new MockERC4626(usdt0);
        morphoUsdc = new MockERC4626(usdc);
        router = new MockSwapRouter(5); // 0.05% fee
        pool = new GoalyPool(
            IERC20(address(usdt0)), IERC4626(address(morpho)), router, 100, 50, 250, 5000
        );

        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            usdt0.mint(u, 1000 * UNIT);
            usdc.mint(u, 1000 * UNIT);
            vm.startPrank(u);
            usdt0.approve(address(pool), type(uint256).max);
            usdc.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
        pool.createMarket(M, uint64(block.timestamp + 1 days));
    }

    function _fundReserve(uint256 amount) internal {
        usdt0.mint(address(this), amount);
        usdt0.approve(address(pool), amount);
        pool.fundReserve(amount);
    }

    function _predict(address u, IERC20 token, GoalyPool.Outcome o, uint256 amount) internal {
        vm.prank(u);
        pool.placePrediction(M, o, token, amount, 0);
    }

    function test_PredictWithUsdt0ThenClaimNoLoss() public {
        _predict(alice, IERC20(address(usdt0)), GoalyPool.Outcome.HOME, 100 * UNIT);
        assertEq(pool.stakeOf(M, alice), 100 * UNIT);
        assertEq(pool.totalStaked(), 100 * UNIT);

        pool.settleMarket(M, GoalyPool.Outcome.HOME, 10_000); // no boost (even odds)
        vm.prank(alice);
        (uint256 stakeBack, uint256 prize) = pool.claim(M, IERC20(address(usdt0)), 0);
        assertEq(stakeBack, 100 * UNIT);
        assertEq(prize, 0);
        assertEq(usdt0.balanceOf(alice), 1000 * UNIT); // whole principal back — no loss
    }

    function test_PredictWithUsdcIsSwappedToUsdt0Stake() public {
        _predict(alice, IERC20(address(usdc)), GoalyPool.Outcome.HOME, 100 * UNIT);
        // 100 USDC → ~99.95 USDT0 after the 0.05% swap.
        assertApproxEqAbs(pool.stakeOf(M, alice), 100 * UNIT, 1 * UNIT / 10);
        assertEq(usdc.balanceOf(alice), 900 * UNIT); // 100 USDC spent
    }

    function test_WinnerGetsPrizeLoserGetsStakeBack() public {
        _predict(alice, IERC20(address(usdt0)), GoalyPool.Outcome.HOME, 100 * UNIT);
        _predict(bob, IERC20(address(usdt0)), GoalyPool.Outcome.AWAY, 100 * UNIT);
        _fundReserve(100 * UNIT);

        pool.settleMarket(M, GoalyPool.Outcome.HOME, 30_000); // odds 3.0 → underdog boost
        uint256 alicePrize = pool.prizeOf(M, alice);
        assertGt(alicePrize, 0);

        vm.prank(alice);
        (uint256 aStake, uint256 aPrize) = pool.claim(M, IERC20(address(usdt0)), 0);
        assertEq(aStake, 100 * UNIT);
        assertEq(aPrize, alicePrize);
        assertEq(usdt0.balanceOf(alice), 1000 * UNIT + aPrize); // principal + prize

        vm.prank(bob);
        (uint256 bStake, uint256 bPrize) = pool.claim(M, IERC20(address(usdt0)), 0);
        assertEq(bStake, 100 * UNIT);
        assertEq(bPrize, 0);
        assertEq(usdt0.balanceOf(bob), 1000 * UNIT); // stake back, no loss
    }

    function test_ClaimPaysOutInChosenToken() public {
        _predict(alice, IERC20(address(usdt0)), GoalyPool.Outcome.HOME, 100 * UNIT);
        pool.settleMarket(M, GoalyPool.Outcome.HOME, 10_000);

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.claim(M, IERC20(address(usdc)), 99 * UNIT); // withdraw as USDC
        assertGt(usdc.balanceOf(alice) - usdcBefore, 99 * UNIT); // ~100 USDC out
    }

    function test_CrossAssetMigrateKeepsNoLoss() public {
        _predict(alice, IERC20(address(usdt0)), GoalyPool.Outcome.HOME, 100 * UNIT);
        morpho.accrue(10 * UNIT); // yield buffer covers the round-trip swap
        pool.migrateYieldVault(IERC4626(address(morphoUsdc)));
        assertEq(address(pool.yieldAsset()), address(usdc));

        pool.settleMarket(M, GoalyPool.Outcome.HOME, 10_000);
        vm.prank(alice);
        (uint256 stakeBack,) = pool.claim(M, IERC20(address(usdt0)), 0);
        assertEq(stakeBack, 100 * UNIT);
        assertEq(usdt0.balanceOf(alice), 1000 * UNIT); // full USDT0 back despite USDC backing
    }

    function test_HarvestYieldToReserve() public {
        _predict(alice, IERC20(address(usdt0)), GoalyPool.Outcome.HOME, 100 * UNIT);
        morpho.accrue(8 * UNIT);
        assertEq(pool.accruedYield(), 8 * UNIT);
        uint256 harvested = pool.harvestYield();
        assertEq(harvested, 8 * UNIT);
        assertEq(pool.reserve(), 8 * UNIT);
    }

    function test_OnePredictionPerMarket() public {
        _predict(alice, IERC20(address(usdt0)), GoalyPool.Outcome.HOME, 100 * UNIT);
        vm.expectRevert(GoalyPool.AlreadyPredicted.selector);
        _predict(alice, IERC20(address(usdt0)), GoalyPool.Outcome.AWAY, 50 * UNIT);
    }
}
