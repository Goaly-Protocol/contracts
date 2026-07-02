// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {GoalyVaultComposer} from "../src/GoalyVaultComposer.sol";
import {IGoalyVault} from "../src/interfaces/IGoalyVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract GoalyVaultComposerTest is Test {
    MockERC20 internal usdt0;
    MockERC4626 internal morpho;
    GoalyVault internal vault;
    GoalyVaultComposer internal composer;

    address internal endpoint = address(0xE9D);
    address internal oft = address(0x0F7);
    address internal user = address(0xBEEF); // origin-chain user's hub address
    uint256 internal constant UNIT = 1e6;

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        morpho = new MockERC4626(usdt0);
        vault = new GoalyVault(IERC20(address(usdt0)), IERC4626(address(morpho)));
        composer = new GoalyVaultComposer(IERC20(address(usdt0)), IGoalyVault(address(vault)), endpoint, oft);
    }

    /// Build a LayerZero OFT compose message: nonce|srcEid|amountLD|composeFrom|composeMsg.
    function _composeMessage(uint256 amount, address recipient) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint64(1), // nonce
            uint32(30_111), // srcEid (e.g. Optimism)
            uint256(amount), // amountLD
            bytes32(uint256(uint160(recipient))), // composeFrom
            abi.encode(recipient) // composeMsg (Goaly payload)
        );
    }

    function test_ComposeDepositsForOriginUser() public {
        uint256 amount = 100 * UNIT;
        // The USDT0 OFT delivers tokens to the composer before lzCompose.
        usdt0.mint(address(composer), amount);

        vm.prank(endpoint);
        composer.lzCompose(oft, keccak256("guid"), _composeMessage(amount, user), address(0), "");

        assertEq(vault.principalOf(user), amount);
        assertGt(vault.sharesOf(user), 0);
    }

    function test_OnlyEndpointCanCompose() public {
        usdt0.mint(address(composer), 100 * UNIT);
        vm.expectRevert(GoalyVaultComposer.NotEndpoint.selector);
        composer.lzCompose(oft, keccak256("g"), _composeMessage(100 * UNIT, user), address(0), "");
    }

    function test_RejectsUnexpectedOft() public {
        usdt0.mint(address(composer), 100 * UNIT);
        vm.prank(endpoint);
        vm.expectRevert(GoalyVaultComposer.UnexpectedOft.selector);
        composer.lzCompose(address(0xBAD), keccak256("g"), _composeMessage(100 * UNIT, user), address(0), "");
    }
}
