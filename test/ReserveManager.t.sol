// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenMessenger} from "../src/interfaces/ICCTP.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";

contract ReserveManagerTest is Test {
    MockERC20 usdc;
    MockTokenMessenger cctp;
    ReserveManager reserve;

    address gov = makeAddr("gov");
    address agent = makeAddr("agent");

    uint32 constant ETHEREUM_DOMAIN = 0;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        cctp = new MockTokenMessenger();
        reserve = new ReserveManager(ITokenMessenger(address(cctp)), IERC20(address(usdc)), gov);
        vm.startPrank(gov);
        reserve.grantRole(reserve.KEEPER_ROLE(), agent);
        vm.stopPrank();

        usdc.mint(address(reserve), 500e6); // surplus parked here
    }

    function test_keeperBridgesSurplus() public {
        bytes32 to = bytes32(uint256(uint160(address(0xBEEF))));
        vm.prank(agent);
        reserve.bridgeSurplus(ETHEREUM_DOMAIN, to, 200e6);

        assertEq(reserve.balance(), 300e6, "surplus reduced by bridged amount");
        assertEq(cctp.lastAmount(), 200e6, "CCTP burned the bridge amount");
        assertEq(cctp.lastDomain(), ETHEREUM_DOMAIN, "bridged to the right domain");
    }

    function test_onlyKeeperCanBridge() public {
        bytes32 to = bytes32(uint256(uint160(address(0xBEEF))));
        vm.expectRevert();
        reserve.bridgeSurplus(ETHEREUM_DOMAIN, to, 200e6);
    }

    function test_governanceRecall() public {
        vm.prank(gov);
        reserve.recall(gov, 500e6);
        assertEq(usdc.balanceOf(gov), 500e6);
        assertEq(reserve.balance(), 0);
    }
}
