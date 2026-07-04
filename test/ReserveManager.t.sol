// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IOFT} from "../src/interfaces/IOFT.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOFT} from "./mocks/MockOFT.sol";

contract ReserveManagerTest is Test {
    MockERC20 usdt;
    MockOFT oft;
    ReserveManager reserve;

    address gov = makeAddr("gov");
    address agent = makeAddr("agent");

    function setUp() public {
        usdt = new MockERC20("Tether USDT0", "USDT0", 6);
        oft = new MockOFT(usdt);
        reserve = new ReserveManager(IOFT(address(oft)), gov);
        vm.startPrank(gov);
        reserve.grantRole(reserve.KEEPER_ROLE(), agent);
        vm.stopPrank();

        usdt.mint(address(reserve), 500e6); // surplus parked here
    }

    function test_keeperBridgesSurplus() public {
        vm.deal(agent, 1 ether);
        bytes32 to = bytes32(uint256(uint160(address(0xBEEF))));
        vm.prank(agent);
        reserve.bridgeSurplus{value: 0.001 ether}(30101, to, 200e6, 199e6, "");

        assertEq(reserve.balance(), 300e6, "surplus reduced by bridged amount");
        assertEq(oft.lastAmount(), 200e6, "oft received the bridge amount");
    }

    function test_onlyKeeperCanBridge() public {
        vm.deal(address(this), 1 ether);
        bytes32 to = bytes32(uint256(uint160(address(0xBEEF))));
        vm.expectRevert();
        reserve.bridgeSurplus{value: 0.001 ether}(30101, to, 200e6, 199e6, "");
    }

    function test_governanceRecall() public {
        vm.prank(gov);
        reserve.recall(gov, 500e6);
        assertEq(usdt.balanceOf(gov), 500e6);
        assertEq(reserve.balance(), 0);
    }
}
