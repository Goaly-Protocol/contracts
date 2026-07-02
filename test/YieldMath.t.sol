// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {YieldMath} from "../src/libraries/YieldMath.sol";

contract YieldMathTest is Test {
    function test_AccruedYield() public pure {
        assertEq(YieldMath.accruedYield(105, 100), 5);
        assertEq(YieldMath.accruedYield(100, 100), 0);
        assertEq(YieldMath.accruedYield(90, 100), 0); // never negative
    }

    function test_Outstanding() public pure {
        assertEq(YieldMath.outstandingDebt(5, 2), 3);
        assertEq(YieldMath.outstandingDebt(5, 5), 0);
        assertEq(YieldMath.outstandingDebt(5, 9), 0); // never negative
    }

    function testFuzz_OutstandingNeverExceedsDebt(uint256 debt, uint256 accrued) public pure {
        assertLe(YieldMath.outstandingDebt(debt, accrued), debt);
    }

    function testFuzz_AccruedYieldMonotonic(uint128 principal, uint128 extra) public pure {
        uint256 value = uint256(principal) + uint256(extra);
        assertEq(YieldMath.accruedYield(value, principal), extra);
    }
}
