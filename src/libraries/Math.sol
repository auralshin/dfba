// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Math
/// @notice Fixed-point math and rounding utilities for DFBA
library Math {
    uint256 internal constant BPS = 10000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    /// @notice Multiply and round down
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;
    }

    /// @notice Multiply and round up
    function mulDivUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 result = (a * b) / c;
        if ((a * b) % c != 0) {
            result += 1;
        }
        return result;
    }

    /// @notice Apply basis points (round down)
    function applyBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return mulDiv(amount, bps, BPS);
    }

    /// @notice Apply basis points (round up)
    function applyBpsUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return mulDivUp(amount, bps, BPS);
    }

    /// @notice Calculate pro-rata fill (round down to be conservative)
    function proRata(uint256 orderQty, uint256 fillBps) internal pure returns (uint128) {
        if (fillBps >= BPS) return uint128(orderQty);
        uint256 filled = applyBps(orderQty, fillBps);
        return uint128(filled);
    }

    /// @notice Safe cast to uint128
    function toUint128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "Math: overflow");
        return uint128(x);
    }

    /// @notice Safe cast to int128
    function toInt128(int256 x) internal pure returns (int128) {
        require(x >= type(int128).min && x <= type(int128).max, "Math: overflow");
        return int128(x);
    }

    /// @notice Absolute value
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /// @notice Min of two uint256
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Max of two uint256
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @notice Min of two int256
    function minInt(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    /// @notice Max of two int256
    function maxInt(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    /// @notice Safe addition for uint128
    function add128(uint128 a, uint128 b) internal pure returns (uint128) {
        uint256 sum = uint256(a) + uint256(b);
        require(sum <= type(uint128).max, "Math: overflow");
        return uint128(sum);
    }

    /// @notice Safe subtraction for uint128
    function sub128(uint128 a, uint128 b) internal pure returns (uint128) {
        require(a >= b, "Math: underflow");
        return a - b;
    }

    /// @notice Safe addition for int128
    function addInt128(int128 a, int128 b) internal pure returns (int128) {
        int256 sum = int256(a) + int256(b);
        return toInt128(sum);
    }

    /// @notice Weighted average price
    /// @param price1 First price
    /// @param qty1 First quantity
    /// @param price2 Second price
    /// @param qty2 Second quantity
    /// @return Weighted average
    function weightedAverage(
        uint256 price1,
        uint256 qty1,
        uint256 price2,
        uint256 qty2
    ) internal pure returns (uint256) {
        uint256 totalQty = qty1 + qty2;
        if (totalQty == 0) return 0;
        return (price1 * qty1 + price2 * qty2) / totalQty;
    }

    /// @notice Calculate notional value
    function notional(uint256 qty, uint256 price) internal pure returns (uint256) {
        return mulDiv(qty, price, WAD);
    }
}
