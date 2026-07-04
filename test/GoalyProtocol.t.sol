// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {GoalyMarkets} from "../src/GoalyMarkets.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Exercises the layered architecture end-to-end and asserts the no-loss invariant holds
///         through staking, yield accrual, settlement and claims — for both winners and losers.
contract GoalyProtocolTest is Test {
    MockERC20 usdt;
    GoalyVault vault;
    GoalyMarkets markets;

    address gov = makeAddr("gov");
    address oracle = makeAddr("oracle");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bytes32 constant MKT = keccak256("MATCH-1");

    function setUp() public {
        usdt = new MockERC20("Tether USDT0", "USDT0", 6);

        GoalyVault vaultImpl = new GoalyVault();
        vault = GoalyVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        GoalyVault.initialize,
                        (IERC20(address(usdt)), "Goaly Vault USDT", "gvUSDT", gov, 1000)
                    )
                )
            )
        );

        GoalyMarkets marketsImpl = new GoalyMarkets();
        markets = GoalyMarkets(
            address(
                new ERC1967Proxy(
                    address(marketsImpl),
                    abi.encodeCall(
                        GoalyMarkets.initialize,
                        (IERC20(address(usdt)), IERC4626(address(vault)), gov, oracle, 250, 5000)
                    )
                )
            )
        );

        usdt.mint(alice, 1000e6);
        usdt.mint(bob, 1000e6);
    }

    function _stake(address who, GoalyMarkets.Outcome outcome, uint256 amt) internal {
        vm.startPrank(who);
        usdt.approve(address(markets), amt);
        markets.predict(MKT, outcome, amt);
        vm.stopPrank();
    }

    function test_noLoss_winnerAndLoserBothRedeemPrincipal() public {
        vm.prank(oracle);
        markets.createMarket(MKT, uint64(block.timestamp + 1 days));

        _stake(alice, GoalyMarkets.Outcome.HOME, 100e6);
        _stake(bob, GoalyMarkets.Outcome.AWAY, 300e6);

        assertEq(markets.totalStaked(), 400e6);
        assertTrue(markets.isSolvent());

        // Yield accrues in the vault (10%).
        usdt.mint(address(vault), 40e6);
        assertTrue(markets.isSolvent());

        // ERC-4626 virtual shares round in the vault's favour → allow a couple of wei.
        vm.prank(oracle);
        assertApproxEqAbs(markets.harvestYield(), 40e6, 2);

        // HOME wins at 2.0x odds.
        vm.prank(oracle);
        markets.settleMarket(MKT, GoalyMarkets.Outcome.HOME, 20000);

        // Winner: full stake back 1:1 + a prize.
        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        (uint256 aliceStake, uint256 alicePrize) = markets.claim(MKT);
        assertEq(aliceStake, 100e6, "winner stake 1:1");
        assertGt(alicePrize, 0, "winner prize");
        assertEq(usdt.balanceOf(alice) - aliceBefore, aliceStake + alicePrize);
        assertTrue(markets.isSolvent(), "solvent after winner claim");

        // Loser: full stake back 1:1, no prize — principal is never lost.
        uint256 bobBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        (uint256 bobStake, uint256 bobPrize) = markets.claim(MKT);
        assertEq(bobStake, 300e6, "loser stake 1:1");
        assertEq(bobPrize, 0, "loser no prize");
        assertEq(usdt.balanceOf(bob) - bobBefore, 300e6);
        assertTrue(markets.isSolvent(), "solvent after loser claim");
    }

    /// @dev No matter the stakes or yield, every staker's principal is always fully redeemable.
    function testFuzz_principalAlwaysRedeemable(uint96 aStake, uint96 bStake, uint96 yield) public {
        aStake = uint96(bound(aStake, 1e6, 500e6));
        bStake = uint96(bound(bStake, 1e6, 500e6));
        yield = uint96(bound(yield, 0, 100e6));

        vm.prank(oracle);
        markets.createMarket(MKT, uint64(block.timestamp + 1 days));
        _stake(alice, GoalyMarkets.Outcome.HOME, aStake);
        _stake(bob, GoalyMarkets.Outcome.AWAY, bStake);

        if (yield > 0) usdt.mint(address(vault), yield);
        assertTrue(markets.isSolvent());

        vm.prank(oracle);
        markets.harvestYield();
        vm.prank(oracle);
        markets.settleMarket(MKT, GoalyMarkets.Outcome.DRAW, 30000); // nobody won → pure no-loss

        uint256 aBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        markets.claim(MKT);
        assertEq(usdt.balanceOf(alice) - aBefore, aStake, "alice principal 1:1");

        uint256 bBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        markets.claim(MKT);
        assertEq(usdt.balanceOf(bob) - bBefore, bStake, "bob principal 1:1");

        assertTrue(markets.isSolvent(), "solvent after all claims");
    }
}
