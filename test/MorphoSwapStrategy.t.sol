// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../src/GoalyVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MorphoSwapStrategy} from "../src/strategies/MorphoSwapStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

/// @notice Players stake/withdraw pure USDT0, but the vault earns yield in a USDC Morpho vault via the
///         cross-asset strategy. Proves the round-trip (USDT0 → USDC → yield → USDT0) is no-loss once
///         the yield covers the swap spread — the old cross-asset stranding cannot recur.
contract MorphoSwapStrategyTest is Test {
    MockERC20 usdt0;
    MockERC20 usdc;
    MockERC4626 usdcVault;
    MockSwapRouter router;
    GoalyVault vault;
    MorphoSwapStrategy strat;

    address agent = makeAddr("agent");
    address user = makeAddr("user");

    function setUp() public {
        usdt0 = new MockERC20("Tether USDT0", "USDT0", 6);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdcVault = new MockERC4626(usdc);
        router = new MockSwapRouter(5); // 0.05% stable swap fee

        vault = GoalyVault(
            address(
                new ERC1967Proxy(
                    address(new GoalyVault()),
                    abi.encodeCall(
                        GoalyVault.initialize,
                        (IERC20(address(usdt0)), "Goaly Vault USDT", "gvUSDT", address(this), 1000)
                    )
                )
            )
        );
        strat = new MorphoSwapStrategy(
            IERC20(address(usdt0)), IERC4626(address(usdcVault)), router, address(vault), 100, 50
        );
        vault.addStrategy(strat);
        vault.grantRole(vault.AGENT_ROLE(), agent);

        usdt0.mint(user, 1000e6);
        vm.startPrank(user);
        usdt0.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();
    }

    function test_stakeUsdt_yieldInUsdc_withdrawUsdt_noLoss() public {
        // Agent moves 800 USDT0 into the USDC strategy (buffer 10% = 100 must stay idle).
        vm.prank(agent);
        vault.allocate(strat, 800e6);
        // ~799.6 USDC now supplied to the USDC vault.
        assertApproxEqAbs(strat.totalAssets(), 800e6, 1e6, "position ~ 800 in USDC");

        // Yield accrues in the USDC vault (10%).
        usdcVault.accrue(80e6);

        // User withdraws 900 USDT0 back — served from idle (200) + the strategy (700, swapped back).
        uint256 before = usdt0.balanceOf(user);
        vm.prank(user);
        vault.withdraw(900e6, user, user);
        assertEq(usdt0.balanceOf(user) - before, 900e6, "user gets pure USDT0 back, 1:1");

        // Vault still solvent for the user's remaining shares.
        assertGe(vault.totalAssets(), vault.convertToAssets(vault.balanceOf(user)), "solvent");
    }
}
