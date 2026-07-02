// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {IGoalyVault} from "../src/interfaces/IGoalyVault.sol";
import {PredictionPool} from "../src/PredictionPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract PredictionPoolTest is Test {
    MockERC20 internal usdt0;
    MockERC4626 internal morpho;
    GoalyVault internal vault;
    PredictionPool internal pool;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    bytes32 internal constant MARKET = keccak256("ARG-BRA");
    uint256 internal constant UNIT = 1e6;

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        morpho = new MockERC4626(usdt0);
        vault = new GoalyVault(IERC20(address(usdt0)), IERC4626(address(morpho)));
        pool = new PredictionPool(IERC20(address(usdt0)), IGoalyVault(address(vault)), 250); // 2.5% fee
        vault.setSettler(address(pool), true); // pool may charge credit

        usdt0.mint(address(this), 100 * UNIT);
        usdt0.approve(address(pool), type(uint256).max);
        pool.createMarket(MARKET, uint64(block.timestamp + 1 days));
    }

    function _place(address user, PredictionPool.Outcome outcome, uint256 amount) internal {
        vm.prank(user);
        pool.placePrediction(MARKET, outcome, amount);
    }

    function test_PlaceChargesCreditDebt() public {
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        assertEq(vault.debtOf(alice), 10 * UNIT);
        assertEq(pool.stakeOf(MARKET, alice), 10 * UNIT);
    }

    function test_WinnersSplitPrizeAndLosersLoseNothing() public {
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        _place(bob, PredictionPool.Outcome.AWAY, 10 * UNIT);

        pool.settleMarket(MARKET, PredictionPool.Outcome.HOME);
        pool.fundPrize(MARKET, 5 * UNIT); // 5 USDT0 of yield as the prize

        vm.prank(alice);
        uint256 payout = pool.claim(MARKET);
        uint256 expected = 5 * UNIT - (5 * UNIT * 250) / 10_000; // prize minus 2.5% fee
        assertEq(payout, expected);
        assertEq(usdt0.balanceOf(alice), expected);

        // Loser: nothing to claim, but nothing lost — only credit debt (repaid by their own yield).
        assertEq(pool.payoutOf(MARKET, bob), 0);
        vm.expectRevert(PredictionPool.NothingToClaim.selector);
        vm.prank(bob);
        pool.claim(MARKET);

        assertEq(vault.debtOf(alice), 10 * UNIT);
        assertEq(vault.debtOf(bob), 10 * UNIT);
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
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        vm.prank(alice);
        pool.settleMarket(MARKET, PredictionPool.Outcome.HOME);
    }

    function test_DoubleClaimReverts() public {
        _place(alice, PredictionPool.Outcome.HOME, 10 * UNIT);
        pool.settleMarket(MARKET, PredictionPool.Outcome.HOME);
        pool.fundPrize(MARKET, 5 * UNIT);
        vm.prank(alice);
        pool.claim(MARKET);
        vm.expectRevert(PredictionPool.AlreadyClaimed.selector);
        vm.prank(alice);
        pool.claim(MARKET);
    }
}
