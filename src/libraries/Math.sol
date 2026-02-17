// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DFBAMath
/// @notice Domain-specific math utilities for DFBA not covered by OpenZeppelin
library DFBAMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    /// @notice Apply basis points (round down)
    function applyBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, bps, BPS);
    }

    /// @notice Apply basis points (round up)
    function applyBpsUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, bps, BPS, Math.Rounding.Ceil);
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
        return Math.mulDiv(qty, price, WAD);
    }
}
