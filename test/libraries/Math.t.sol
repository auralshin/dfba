// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "../../src/libraries/Math.sol";

// Helper contract to test library reverts
contract MathWrapper {
    function toUint128(uint256 x) external pure returns (uint128) {
        return Math.toUint128(x);
    }
    
    function toInt128(int256 x) external pure returns (int128) {
        return Math.toInt128(x);
    }
}

contract MathTest is Test {
    MathWrapper wrapper;
    
    function setUp() public {
        wrapper = new MathWrapper();
    }
    
    function test_mulDiv_basic() public {
        uint256 result = Math.mulDiv(100, 50, 10);
        assertEq(result, 500, "100 * 50 / 10 = 500");
    }

    function test_mulDiv_roundsDown() public {
        uint256 result = Math.mulDiv(100, 3, 10);
        assertEq(result, 30, "Should round down: 100 * 3 / 10 = 30");
    }

    function test_mulDivUp_roundsUp() public {
        uint256 result = Math.mulDivUp(100, 3, 10);
        assertEq(result, 30, "100 * 3 / 10 = 30 (exact)");
        
        result = Math.mulDivUp(101, 3, 10);
        assertEq(result, 31, "Should round up: 101 * 3 / 10 = 30.3 -> 31");
    }

    function test_mulDiv_largeNumbers() public {
        uint256 result = Math.mulDiv(type(uint128).max, type(uint128).max, type(uint128).max);
        assertEq(result, type(uint128).max, "Should handle large numbers");
    }

    function test_applyBps() public {
        uint256 result = Math.applyBps(1000, 5000); // 50%
        assertEq(result, 500, "50% of 1000 = 500");
        
        result = Math.applyBps(1000, 100); // 1%
        assertEq(result, 10, "1% of 1000 = 10");
        
        result = Math.applyBps(1000, 10000); // 100%
        assertEq(result, 1000, "100% of 1000 = 1000");
    }

    function test_proRata() public {
        uint128 result = Math.proRata(100, 5000); // 50%
        assertEq(result, 50, "50% of 100 = 50");
        
        result = Math.proRata(100, 2500); // 25%
        assertEq(result, 25, "25% of 100 = 25");
        
        result = Math.proRata(100, 10000); // 100%
        assertEq(result, 100, "100% of 100 = 100");
    }

    function test_abs_positive() public {
        uint256 result = Math.abs(100);
        assertEq(result, 100, "abs(100) = 100");
    }

    function test_abs_negative() public {
        uint256 result = Math.abs(-100);
        assertEq(result, 100, "abs(-100) = 100");
    }

    function test_abs_zero() public {
        uint256 result = Math.abs(0);
        assertEq(result, 0, "abs(0) = 0");
    }

    function test_toUint128() public {
        uint128 result = Math.toUint128(100);
        assertEq(result, 100, "Should convert uint256 to uint128");
    }

    function test_toUint128_reverts() public {
        vm.expectRevert(bytes("Math: overflow"));
        wrapper.toUint128(uint256(type(uint128).max) + 1);
    }

    function test_toInt128_positive() public {
        int128 result = Math.toInt128(100);
        assertEq(result, 100, "Should convert int256 to int128");
    }

    function test_toInt128_negative() public {
        int128 result = Math.toInt128(-100);
        assertEq(result, -100, "Should convert negative int256 to int128");
    }

    function test_toInt128_reverts() public {
        vm.expectRevert(bytes("Math: overflow"));
        wrapper.toInt128(int256(type(int128).max) + 1);
    }

    function test_toInt128_revertsUnderflow() public {
        vm.expectRevert(bytes("Math: overflow"));
        wrapper.toInt128(int256(type(int128).min) - 1);
    }

    function test_weightedAverage() public {
        // (1000 * 100 + 2000 * 200) / (100 + 200) = 1666.666... -> 1666
        uint256 result = Math.weightedAverage(1000, 100, 2000, 200);
        assertEq(result, 1666, "Weighted average should be 1666");
    }

    function test_weightedAverage_equalWeights() public {
        uint256 result = Math.weightedAverage(1000, 100, 2000, 100);
        assertEq(result, 1500, "Equal weights: (1000 + 2000) / 2 = 1500");
    }

    function test_weightedAverage_zeroWeight() public {
        uint256 result = Math.weightedAverage(1000, 0, 2000, 100);
        assertEq(result, 2000, "Zero first weight should return second value");
        
        result = Math.weightedAverage(1000, 100, 2000, 0);
        assertEq(result, 1000, "Zero second weight should return first value");
    }

    function test_min() public {
        assertEq(Math.min(100, 200), 100, "min(100, 200) = 100");
        assertEq(Math.min(200, 100), 100, "min(200, 100) = 100");
        assertEq(Math.min(100, 100), 100, "min(100, 100) = 100");
    }

    function test_max() public {
        assertEq(Math.max(100, 200), 200, "max(100, 200) = 200");
        assertEq(Math.max(200, 100), 200, "max(200, 100) = 200");
        assertEq(Math.max(100, 100), 100, "max(100, 100) = 100");
    }
}
