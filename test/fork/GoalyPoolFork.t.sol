// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalyPool} from "../../src/GoalyPool.sol";
import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";

/// Integration test against real Arbitrum: predict staking USDT0, migrate the backing to the real
/// Gauntlet USDC Core vault via the real Uniswap pool, then claim back full USDT0 (no-loss).
contract GoalyPoolForkTest is Test {
    address internal constant MORPHO_USDT0 = 0x139250CdB310D657eAC506c7C7FC6AcDE34Af1ec;
    address internal constant MORPHO_USDC = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65;
    address internal constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    GoalyPool internal pool;
    address internal usdt0;
    bool internal active;
    address internal alice = address(0xA11CE);
    bytes32 internal constant M = keccak256("fork-match");

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        active = true;
        usdt0 = IERC4626(MORPHO_USDT0).asset();
        pool = new GoalyPool(
            IERC20(usdt0), IERC4626(MORPHO_USDT0), ISwapRouter(UNISWAP_ROUTER), 100, 50, 250, 5000
        );
        pool.createMarket(M, uint64(block.timestamp + 1 days));
    }

    function test_Fork_PredictMigrateCrossAssetClaimNoLoss() public {
        if (!active) {
            emit log("skipping fork test: set ARBITRUM_RPC_URL to run");
            return;
        }

        uint256 amount = 1000e6; // 1,000 USDT0
        deal(usdt0, alice, amount);
        vm.startPrank(alice);
        IERC20(usdt0).approve(address(pool), amount);
        pool.placePrediction(M, GoalyPool.Outcome.HOME, IERC20(usdt0), amount, 0);
        vm.stopPrank();

        // Rebalance the backing into the real USDC Morpho vault (swaps USDT0 → USDC on Uniswap).
        pool.migrateYieldVault(IERC4626(MORPHO_USDC));
        assertEq(address(pool.yieldAsset()), USDC);

        // Seed a small USDC surplus so the round-trip swap cost is covered (simulated yield).
        deal(USDC, address(this), 20e6);
        IERC20(USDC).approve(MORPHO_USDC, 20e6);
        IERC4626(MORPHO_USDC).deposit(20e6, address(pool));

        pool.settleMarket(M, GoalyPool.Outcome.HOME, 10_000);
        vm.prank(alice);
        (uint256 stakeBack,) = pool.claim(M, IERC20(usdt0), 0);
        assertEq(stakeBack, amount);
        assertEq(IERC20(usdt0).balanceOf(alice), amount); // full USDT0 back despite USDC backing
    }
}
