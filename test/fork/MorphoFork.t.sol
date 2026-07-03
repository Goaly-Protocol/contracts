// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyVault} from "../../src/GoalyVault.sol";
import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";

// Integration test against the REAL Morpho "Gauntlet USDT0 Core" vault on Arbitrum One.
// Runs only when ARBITRUM_RPC_URL is set (otherwise it no-ops), so `forge test` stays green
// offline. Run explicitly via the package's test:integration script.
contract MorphoForkTest is Test {
    address internal constant MORPHO_VAULT = 0x139250CdB310D657eAC506c7C7FC6AcDE34Af1ec;
    // Real Arbitrum Uniswap V3 SwapRouter + a real USDC Morpho vault (for the cross-asset path).
    address internal constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant MORPHO_USDC_VAULT = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65;

    GoalyVault internal vault;
    IERC4626 internal morpho;
    address internal usdt0;
    bool internal active;

    address internal user = address(0xBEEF);

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        active = true;

        morpho = IERC4626(MORPHO_VAULT);
        usdt0 = morpho.asset();
        vault = new GoalyVault(IERC20(usdt0), morpho, ISwapRouter(UNISWAP_ROUTER), 100, 50);
    }

    function test_Fork_DepositIntoRealMorphoVault() public {
        if (!active) {
            emit log("skipping fork test: set ARBITRUM_RPC_URL to run");
            return;
        }

        uint256 amount = 100e6; // USDT0 has 6 decimals
        deal(usdt0, user, amount);

        vm.startPrank(user);
        IERC20(usdt0).approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();

        // Deposit mints goUSDT 1:1 and the vault's Morpho position is worth ~the principal.
        assertEq(vault.balanceOf(user), amount);
        assertApproxEqAbs(vault.totalAssets(), amount, 5);
    }

    /// @notice Cross-asset rebalance against the REAL Uniswap USDT0/USDC pool + a real USDC Morpho
    ///         vault: migrate the backing USDT0 → USDC, then prove goUSDT still redeems full USDT0.
    function test_Fork_CrossAssetMigrateAndNoLossWithdraw() public {
        if (!active) {
            emit log("skipping fork test: set ARBITRUM_RPC_URL to run");
            return;
        }

        address usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        uint256 amount = 1000e6; // 1,000 USDT0
        deal(usdt0, user, amount);
        vm.startPrank(user);
        IERC20(usdt0).approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();

        // Rebalance the whole backing into the real USDC Morpho vault (swaps USDT0 → USDC).
        vault.migrateYieldVault(IERC4626(MORPHO_USDC_VAULT));
        assertTrue(vault.isCrossAsset());
        assertEq(address(vault.yieldAsset()), usdc);

        // Simulate accrued yield: credit the vault a small USDC surplus so the round-trip swap cost
        // is covered and goUSDT stays strictly 1:1 (the protocol funds swaps from yield).
        deal(usdc, address(this), 20e6);
        IERC20(usdc).approve(MORPHO_USDC_VAULT, 20e6);
        IERC4626(MORPHO_USDC_VAULT).deposit(20e6, address(vault));

        // Holder redeems: gets exactly their USDT0 back despite the USDC backing (no-loss).
        vm.prank(user);
        vault.withdraw(amount, user);
        assertEq(IERC20(usdt0).balanceOf(user), amount);
        assertEq(vault.balanceOf(user), 0);
    }
}
