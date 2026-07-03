// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {PredictionPool} from "../src/PredictionPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract PredictionPoolTest is Test {
    MockERC20 internal usdt0;
    MockERC4626 internal morpho;
    GoalyVault internal vault; // goUSDT
    PredictionPool internal pool;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    bytes32 internal constant MARKET = keccak256("ARG-BRA");
    uint256 internal constant UNIT = 1e6;

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        morpho = new MockERC4626(usdt0);
        vault = new GoalyVault(
            IERC20(address(usdt0)), IERC4626(address(morpho)), ISwapRouter(address(0)), 100, 50
        );
        // 2.5% fee, 0.5× odds boost
        pool = new PredictionPool(IERC20(address(vault)), IERC20(address(usdt0)), 250, 5000);

        _fund(alice, 100 * UNIT);
        _fund(bob, 100 * UNIT);
        pool.createMarket(MARKET, uint64(block.timestamp + 1 days));
    }

    /// Give `user` goUSDT (deposit into the vault) and approve the pool to stake it.
    function _fund(address user, uint256 amount) internal {
        usdt0.mint(user, amount);
        vm.startPrank(user);
        usdt0.approve(address(vault), type(uint256).max);
        vault.deposit(amount, user);
        IERC20(address(vault)).approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _place(address user, PredictionPool.Outcome outcome, uint256 amount) internal {
        vm.prank(user);
        pool.placePrediction(MARKET, outcome, amount);
    }

    function _fundPrize(uint256 amount) internal {
        usdt0.mint(address(this), amount);
        usdt0.approve(address(pool), amount);
        pool.fundPrize(MARKET, amount);
    }

    function _fundReserve(uint256 amount) internal {
        usdt0.mint(address(this), amount);
        usdt0.approve(address(pool), amount);
        pool.fundReserve(amount);
    }

    function test_PlaceLocksGoUsdt() public {
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        assertEq(vault.balanceOf(alice), 90 * UNIT); // 10 goUSDT locked
        assertEq(vault.balanceOf(address(pool)), 10 * UNIT);
        assertEq(pool.stakeOf(MARKET, alice), 10 * UNIT);
    }

    function test_NoLoss_WinnerGetsPrizeLoserGetsStakeBack() public {
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        _place(bob, PredictionPool.Outcome.AWAY, 10 * UNIT);
        pool.settleMarket(MARKET, PredictionPool.Outcome.HOME, 20_000);
        _fundPrize(5 * UNIT);

        // Winner: stake returned + prize (minus 2.5% fee)
        vm.prank(alice);
        (uint256 aStake, uint256 aPrize) = pool.claim(MARKET);
        assertEq(aStake, 10 * UNIT);
        assertEq(aPrize, 5 * UNIT - (5 * UNIT * 250) / 10_000); // 4.875
        assertEq(vault.balanceOf(alice), 100 * UNIT); // goUSDT back to full
        assertEq(usdt0.balanceOf(alice), aPrize);

        // Loser: stake returned in full, no prize — never lost principal
        vm.prank(bob);
        (uint256 bStake, uint256 bPrize) = pool.claim(MARKET);
        assertEq(bStake, 10 * UNIT);
        assertEq(bPrize, 0);
        assertEq(vault.balanceOf(bob), 100 * UNIT);
        assertEq(usdt0.balanceOf(bob), 0);
    }

    function test_CannotPredictTwice() public {
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        vm.expectRevert(PredictionPool.AlreadyPredicted.selector);
        _place(alice, PredictionPool.Outcome.DRAW, 5 * UNIT);
    }

    function test_CannotPlaceAfterClose() public {
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(PredictionPool.MarketClosed.selector);
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
    }

    function test_SettleRequiresOracleRole() public {
        vm.expectRevert();
        vm.prank(alice);
        pool.settleMarket(MARKET, PredictionPool.Outcome.HOME, 20_000);
    }

    function test_DoubleClaimReverts() public {
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        pool.settleMarket(MARKET, PredictionPool.Outcome.HOME, 20_000);
        _fundPrize(5 * UNIT);
        vm.prank(alice);
        pool.claim(MARKET);
        vm.expectRevert(PredictionPool.AlreadyClaimed.selector);
        vm.prank(alice);
        pool.claim(MARKET);
    }

    // ── Odds boost ──

    function test_FundReserve() public {
        _fundReserve(50 * UNIT);
        assertEq(pool.reserve(), 50 * UNIT);
        assertEq(usdt0.balanceOf(address(pool)), 50 * UNIT);
    }

    function test_OddsBoostFoldedIntoPrizeFromReserve() public {
        // Only alice bets the winning outcome (10 goUSDT). Base prize 5, reserve 100.
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        _fundPrize(5 * UNIT);
        _fundReserve(100 * UNIT);

        // Settle at 3.00 odds → boost = 10 × (3−1) × 0.5 = 10; prize = 5 + 10 = 15, reserve = 90.
        pool.settleMarket(MARKET, PredictionPool.Outcome.HOME, 30_000);
        assertEq(pool.reserve(), 90 * UNIT);
        (,,,,, uint256 prize) = pool.markets(MARKET);
        assertEq(prize, 15 * UNIT);

        // Sole winner claims 15 minus the 2.5% fee.
        vm.prank(alice);
        (, uint256 aPrize) = pool.claim(MARKET);
        assertEq(aPrize, 15 * UNIT - (15 * UNIT * 250) / 10_000);
    }

    function test_BoostCappedByReserve() public {
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        _fundReserve(3 * UNIT); // uncapped boost would be 10

        pool.settleMarket(MARKET, PredictionPool.Outcome.HOME, 30_000);
        assertEq(pool.reserve(), 0);
        (,,,,, uint256 prize) = pool.markets(MARKET);
        assertEq(prize, 3 * UNIT); // capped boost only (no base prize funded)
    }

    function test_NoBoostForEvenOdds() public {
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        _fundReserve(100 * UNIT);
        pool.settleMarket(MARKET, PredictionPool.Outcome.HOME, 10_000); // 1.00 odds
        assertEq(pool.reserve(), 100 * UNIT); // untouched
    }
}
