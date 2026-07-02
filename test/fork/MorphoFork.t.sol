// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GoalYieldVault} from "../../src/GoalYieldVault.sol";

// Integration test against the REAL Morpho "Gauntlet USDT0 Core" vault on Arbitrum One.
// Runs only when ARBITRUM_RPC_URL is set (otherwise it no-ops), so `forge test` stays green
// offline. Run explicitly via the package's test:integration script.
contract MorphoForkTest is Test {
    address internal constant MORPHO_VAULT = 0x139250CdB310D657eAC506c7C7FC6AcDE34Af1ec;

    GoalYieldVault internal vault;
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
        vault = new GoalYieldVault(IERC20(usdt0), morpho);
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
        uint256 shares = vault.deposit(amount);
        vm.stopPrank();

        assertGt(shares, 0, "no shares minted");
        assertEq(vault.principalOf(user), amount);
        // Freshly minted shares should be worth ~the deposited principal (minus rounding).
        assertApproxEqAbs(morpho.convertToAssets(vault.sharesOf(user)), amount, 5);
    }
}
