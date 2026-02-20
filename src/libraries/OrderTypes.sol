// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DFBAMath} from "./Math.sol";
/// @title OrderTypes
/// @notice Core types and utilities for DFBA orders (spot + perps)

library OrderTypes {
    /// @notice Market type
    enum MarketType {
        Spot,
        Perp
    }

    /// @notice Order side
    enum Side {
        Buy,
        Sell
    }

    /// @notice Flow type (maker = limit, taker = market)
    enum Flow {
        Maker,
        Taker
    }

    /// @notice Order struct
    /// @dev batchId is assigned at submission time, not part of Order struct
    struct Order {
        address trader;
        uint64 marketId;
        Side side;
        Flow flow;
        int24 priceTick;
        uint128 qty;
        uint128 nonce;
        uint64 expiry;
    }

    /// @notice Order state for tracking fills/cancellations
    struct OrderState {
        uint128 remainingQty;
        uint128 claimedQty;
        bool cancelled;
    }

    /// @notice Clearing result for buy or sell auction
    struct Clearing {
        int24 clearingTick;
        uint16 marginalFillMakerBps;
        uint16 marginalFillTakerBps;
        uint128 clearedQty;
        bool finalized;
    }

    /// @notice Per-tick aggregate totals
    struct TickLevel {
        uint128 makerBuy;
        uint128 makerSell;
        uint128 takerBuy;
        uint128 takerSell;
    }

    function orderKey(
        Order memory order
    ) internal pure returns (bytes32 key) {
        // Pull fields into stack vars so we don't rely on struct memory layout/packing.
        address trader = order.trader;
        uint256 marketId = uint256(order.marketId);
        uint256 side = uint256(uint8(order.side)); // if enum/uint8
        uint256 flow = uint256(uint8(order.flow)); // if enum/uint8
        int256 priceTick = int256(order.priceTick); // keep signed if it’s signed
        uint256 qty = uint256(order.qty);
        uint256 nonce = uint256(order.nonce);
        uint256 expiry = uint256(order.expiry);

        assembly {
            let ptr := mload(0x40)

            // abi.encode(...) places each argument in its own 32-byte word.
            mstore(ptr, trader)
            mstore(add(ptr, 0x20), marketId)
            mstore(add(ptr, 0x40), side)
            mstore(add(ptr, 0x60), flow)
            mstore(add(ptr, 0x80), priceTick)
            mstore(add(ptr, 0xA0), qty)
            mstore(add(ptr, 0xC0), nonce)
            mstore(add(ptr, 0xE0), expiry)

            key := keccak256(ptr, 0x100)

            // advance free memory pointer (optional here since it's pure, but good hygiene)
            mstore(0x40, add(ptr, 0x100))
        }
    }

    /// @notice Check if order is in the money (would fill at clearing)
    /// @param order The order
    /// @param clearing The clearing result
    /// @return True if order fills
    function inTheMoney(Order memory order, Clearing memory clearing) internal pure returns (bool) {
        if (!clearing.finalized) return false;

        if (order.flow == Flow.Taker) {
            return true;
        }

        if (order.side == Side.Buy) {
            return order.priceTick >= clearing.clearingTick;
        } else {
            return order.priceTick <= clearing.clearingTick;
        }
    }

    /// @notice Compute filled quantity for an order
    /// @param order The order
    /// @param clearing The clearing result
    /// @return Filled quantity
    function filledQty(
        Order memory order,
        Clearing memory clearing,
        uint128 /* levelQty */
    ) internal pure returns (uint128) {
        if (!inTheMoney(order, clearing)) return 0;

        bool isMarginal = (order.priceTick == clearing.clearingTick);

        if (!isMarginal) {
            return order.qty;
        }

        uint256 fillBps;
        if (order.flow == Flow.Maker) {
            fillBps = clearing.marginalFillMakerBps;
        } else {
            fillBps = clearing.marginalFillTakerBps;
        }

        if (fillBps >= 10_000) return order.qty;

        uint256 filled = (uint256(order.qty) * fillBps) / 10_000;
        return uint128(filled);
    }

    /// @notice Convert tick to price using 1.0001^tick formula with WAD precision
    /// @dev Returns price in WAD (1e18) precision
    /// @dev For simplicity using approximation: price ≈ 1e18 * (1 + tick/10000) for small ticks
    /// @dev Production should use proper exponential or lookup table
    function tickToPrice(
        int24 tick
    ) internal pure returns (uint256) {
        if (tick == 0) return DFBAMath.WAD;

        int256 signedTick = int256(tick);
        uint256 absTick = uint256(signedTick < 0 ? -signedTick : signedTick);
        uint256 ratio = DFBAMath.rpow(DFBAMath.ONE_P0001, absTick, DFBAMath.WAD);

        if (signedTick < 0) {
            return Math.mulDiv(DFBAMath.WAD, DFBAMath.WAD, ratio, Math.Rounding.Ceil);
        }

        return ratio;
    }

    /// @notice Convert price to tick
    function priceToTick(
        uint256 price
    ) internal pure returns (int24) {
        return int24(int256(price));
    }
}
