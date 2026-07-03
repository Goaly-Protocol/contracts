// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    IMessageTransmitter
} from "@wormhole-foundation/wormhole-solidity-sdk/interfaces/cctp/IMessageTransmitter.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {GoalyWormholeReceiver, IGoalyVaultDeposit} from "../src/GoalyWormholeReceiver.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockMessageTransmitter} from "./mocks/MockMessageTransmitter.sol";

contract GoalyWormholeReceiverTest is Test {
    MockERC20 internal usdt0;
    MockERC20 internal usdc;
    MockERC4626 internal morpho;
    MockSwapRouter internal router;
    GoalyVault internal vault;
    MockMessageTransmitter internal cctp;
    GoalyWormholeReceiver internal receiver;

    address internal alice = address(0xA11CE);
    uint256 internal constant UNIT = 1e6;

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        morpho = new MockERC4626(usdt0);
        router = new MockSwapRouter(5); // 0.05% fee
        vault = new GoalyVault(IERC20(address(usdt0)), IERC4626(address(morpho)), router, 100, 50);
        cctp = new MockMessageTransmitter(usdc, 100 * UNIT); // mints 100 USDC on receiveMessage
        receiver = new GoalyWormholeReceiver(
            IMessageTransmitter(address(cctp)),
            IERC20(address(usdc)),
            IERC20(address(usdt0)),
            IGoalyVaultDeposit(address(vault)),
            router,
            100
        );
    }

    function test_ReceiveCctpUsdcSwapsAndDepositsGoUsdt() public {
        uint256 goUsdt = receiver.receiveAndDeposit(hex"00", hex"00", alice, 99 * UNIT);

        // 100 USDC minted → swapped to ~99.95 USDT0 → deposited → goUSDT minted to alice.
        assertGt(goUsdt, 99 * UNIT);
        assertEq(vault.balanceOf(alice), goUsdt);
        assertEq(vault.totalSupply(), goUsdt);
        // Alice can redeem her goUSDT 1:1 for USDT0.
        vm.prank(alice);
        vault.withdraw(goUsdt, alice);
        assertEq(usdt0.balanceOf(alice), goUsdt);
    }

    function test_RejectsZeroRecipient() public {
        vm.expectRevert(GoalyWormholeReceiver.ZeroAddress.selector);
        receiver.receiveAndDeposit(hex"00", hex"00", address(0), 0);
    }
}
