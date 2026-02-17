// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DFBAMath} from "../src/libraries/Math.sol";

contract MathTest is Test {
    using DFBAMath for uint256;

    function testMin() public pure {
        assertEq(Math.min(5, 10), 5);
        assertEq(Math.min(10, 5), 5);
        assertEq(Math.min(7, 7), 7);
        assertEq(Math.min(0, 100), 0);
    }

    function testFuzzMin(uint256 a, uint256 b) public pure {
        uint256 result = Math.min(a, b);
        assertTrue(result <= a);
        assertTrue(result <= b);
        assertTrue(result == a || result == b);
    }

    /*//////////////////////////////////////////////////////////////
                          DFBA MATH TESTS
    //////////////////////////////////////////////////////////////*/

    function testApplyBps() public pure {
        // 50% of 1000 = 500
        assertEq(DFBAMath.applyBps(1000, 5000), 500);

        // 1% of 1000 = 10
        assertEq(DFBAMath.applyBps(1000, 100), 10);

        // 100% of 1000 = 1000
        assertEq(DFBAMath.applyBps(1000, 10_000), 1000);

        // 0% of 1000 = 0
        assertEq(DFBAMath.applyBps(1000, 0), 0);

        // Rounds down
        assertEq(DFBAMath.applyBps(999, 3333), 332); // 33.33% of 999 = 332.6667 -> 332 (rounds down)
    }

    function testApplyBpsUp() public pure {
        // 50% of 1000 = 500
        assertEq(DFBAMath.applyBpsUp(1000, 5000), 500);

        // Rounds up
        assertEq(DFBAMath.applyBpsUp(999, 3334), 334); // 33.34% of 999 = 333.0666 -> 334
        assertEq(DFBAMath.applyBpsUp(1, 1), 1); // 0.01% of 1 = 0.0001 -> 1 (rounds up)
    }

    function testWeightedAverage() public pure {
        // Equal quantities: avg(100, 200) = 150
        assertEq(DFBAMath.weightedAverage(100, 1, 200, 1), 150);

        // Weighted: (100*2 + 200*1) / 3 = 400/3 = 133
        assertEq(DFBAMath.weightedAverage(100, 2, 200, 1), 133);

        // One-sided: all weight on first price
        assertEq(DFBAMath.weightedAverage(100, 10, 200, 0), 100);

        // Zero quantities returns 0
        assertEq(DFBAMath.weightedAverage(100, 0, 200, 0), 0);

        // Large numbers
        assertEq(DFBAMath.weightedAverage(1000 * 1e18, 50, 2000 * 1e18, 50), 1500 * 1e18);
    }

    function testNotional() public pure {
        // qty=100, price=1.0 (1e18) -> notional=100
        assertEq(DFBAMath.notional(100, 1e18), 100);

        // qty=100, price=2.0 (2e18) -> notional=200
        assertEq(DFBAMath.notional(100, 2e18), 200);

        // qty=1000, price=0.5 (0.5e18) -> notional=500
        assertEq(DFBAMath.notional(1000, 0.5e18), 500);

        // Large numbers
        assertEq(DFBAMath.notional(1_000_000 * 1e18, 3500 * 1e18), 3_500_000_000 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ApplyBps(uint128 amount, uint16 bps) public pure {
        // Bound bps to valid range [0, 10000]
        bps = uint16(bound(uint256(bps), 0, 10_000));

        uint256 result = DFBAMath.applyBps(amount, bps);

        // Result should never exceed original amount
        assertLe(result, amount);

        // 100% should give exact amount
        if (bps == 10_000) {
            assertEq(result, amount);
        }

        // 0% should give 0
        if (bps == 0) {
            assertEq(result, 0);
        }
    }

    function testFuzz_ApplyBpsUp(uint128 amount, uint16 bps) public pure {
        bps = uint16(bound(uint256(bps), 0, 10_000));

        // Skip if amount is too large to prevent overflow
        if (amount > type(uint128).max / 10_001) return;

        uint256 result = DFBAMath.applyBpsUp(amount, bps);
        uint256 resultDown = DFBAMath.applyBps(amount, bps);

        // Round up should be >= round down
        assertGe(result, resultDown);

        // Should never exceed amount (unless rounding up from fraction)
        if (bps <= 10_000) {
            assertLe(result, amount + 1); // Allow for rounding
        }
    }

    function testFuzz_WeightedAverage(uint128 price1, uint128 qty1, uint128 price2, uint128 qty2) public pure {
        // Bound to prevent overflow in price * qty calculation
        // max value for each product should be < type(uint256).max / 2
        price1 = uint128(bound(uint256(price1), 0, type(uint128).max / 2));
        qty1 = uint128(bound(uint256(qty1), 0, type(uint128).max / 2));
        price2 = uint128(bound(uint256(price2), 0, type(uint128).max / 2));
        qty2 = uint128(bound(uint256(qty2), 0, type(uint128).max / 2));

        uint256 result = DFBAMath.weightedAverage(price1, qty1, price2, qty2);

        // If both quantities are 0, result should be 0
        if (qty1 == 0 && qty2 == 0) {
            assertEq(result, 0);
            return;
        }

        // Result should be between min and max price (weighted)
        uint256 minPrice = Math.min(price1, price2);
        uint256 maxPrice = Math.max(price1, price2);

        assertGe(result, minPrice);
        assertLe(result, maxPrice);
    }

    function testFuzz_Notional(uint128 qty, uint128 price) public pure {
        // Bound to avoid overflow in multiplication
        qty = uint128(bound(uint256(qty), 0, type(uint128).max / 2));
        price = uint128(bound(uint256(price), 0, type(uint128).max / 2));

        uint256 result = DFBAMath.notional(qty, price);

        // Basic sanity checks
        if (qty == 0 || price == 0) {
            assertEq(result, 0);
        }

        // Notional should scale with price (>= due to rounding)
        if (price > 1e18 && qty > 0) {
            assertGe(result, qty);
        }

        // Notional should be less than qty when price < 1e18
        if (price < 1e18 && qty > 0) {
            assertLe(result, qty);
        }
    }
}
