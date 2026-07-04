// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {GoalyMarkets} from "../src/GoalyMarkets.sol";
import {GoalySettlement} from "../src/GoalySettlement.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract GoalySettlementTest is Test {
    MockERC20 usdt;
    GoalyVault vault;
    GoalyMarkets markets;
    GoalySettlement settle;

    address gov = makeAddr("gov");
    address backend = makeAddr("backend");
    address proposer = makeAddr("proposer");
    address disputer = makeAddr("disputer");
    address alice = makeAddr("alice");

    uint256 constant BOND = 10e6;
    uint64 constant WINDOW = 2 hours;
    bytes32 constant MKT = keccak256("MATCH-1");

    function setUp() public {
        usdt = new MockERC20("Tether USDT0", "USDT0", 6);
        vault = GoalyVault(
            address(
                new ERC1967Proxy(
                    address(new GoalyVault()),
                    abi.encodeCall(
                        GoalyVault.initialize,
                        (IERC20(address(usdt)), "gv", "gv", gov, 1000)
                    )
                )
            )
        );
        markets = GoalyMarkets(
            address(
                new ERC1967Proxy(
                    address(new GoalyMarkets()),
                    abi.encodeCall(
                        GoalyMarkets.initialize,
                        (IERC20(address(usdt)), IERC4626(address(vault)), gov, gov, 250, 5000)
                    )
                )
            )
        );
        settle = new GoalySettlement(markets, IERC20(address(usdt)), BOND, WINDOW, gov);

        // wire: the settlement contract IS the oracle; backend may open markets.
        vm.startPrank(gov);
        markets.grantRole(markets.ORACLE_ROLE(), address(settle));
        settle.grantRole(settle.PROPOSER_ROLE(), backend);
        vm.stopPrank();

        usdt.mint(alice, 1000e6);
        usdt.mint(proposer, BOND);
        usdt.mint(disputer, BOND);
    }

    function _open() internal {
        vm.prank(backend);
        settle.openMarket(MKT, uint64(block.timestamp + 1 hours));
        vm.startPrank(alice);
        usdt.approve(address(markets), 100e6);
        markets.predict(MKT, GoalyMarkets.Outcome.HOME, 100e6);
        vm.stopPrank();
    }

    function test_optimistic_finalizeWhenUnchallenged() public {
        _open();
        vm.warp(block.timestamp + 2 hours); // match over

        vm.startPrank(proposer);
        usdt.approve(address(settle), BOND);
        settle.proposeResult(MKT, GoalyMarkets.Outcome.HOME, 20000);
        vm.stopPrank();

        vm.warp(block.timestamp + WINDOW); // dispute window elapses

        uint256 before = usdt.balanceOf(proposer);
        settle.finalize(MKT);
        assertEq(usdt.balanceOf(proposer), before + BOND, "proposer bond refunded");

        GoalyMarkets.Market memory m = markets.markets(MKT);
        assertEq(uint8(m.status), uint8(GoalyMarkets.Status.SETTLED), "settled");
        assertEq(uint8(m.result), uint8(GoalyMarkets.Outcome.HOME));
    }

    function test_dispute_thenGovernanceResolves() public {
        _open();
        vm.warp(block.timestamp + 2 hours);

        vm.startPrank(proposer);
        usdt.approve(address(settle), BOND);
        settle.proposeResult(MKT, GoalyMarkets.Outcome.AWAY, 20000); // wrong result
        vm.stopPrank();

        vm.startPrank(disputer);
        usdt.approve(address(settle), BOND);
        settle.dispute(MKT);
        vm.stopPrank();

        // finalize must fail while disputed
        vm.expectRevert(GoalySettlement.NotProposed.selector);
        settle.finalize(MKT);

        // governance rules the disputer was right (real result HOME) → disputer takes both bonds
        uint256 before = usdt.balanceOf(disputer);
        vm.prank(gov);
        settle.resolveDispute(MKT, GoalyMarkets.Outcome.HOME, 20000, false);
        assertEq(usdt.balanceOf(disputer), before + 2 * BOND, "disputer wins both bonds");

        GoalyMarkets.Market memory m = markets.markets(MKT);
        assertEq(uint8(m.result), uint8(GoalyMarkets.Outcome.HOME), "resolved to true result");
    }
}
