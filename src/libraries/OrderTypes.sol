// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
    struct Order {
        address trader;
        uint64 marketId;
        uint64 auctionId;
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

    /// @notice Generate unique order key
    /// @param order The order
    /// @return result Unique order ID
    function orderKey(Order memory order) internal pure returns (bytes32 result) {
        assembly {
            let ptr := mload(0x40)
            let size := 0x120
            mstore(ptr, mload(add(order, 0x00)))
            mstore(add(ptr, 0x20), mload(add(order, 0x20)))
            mstore(add(ptr, 0x40), mload(add(order, 0x40)))
            mstore(add(ptr, 0x60), mload(add(order, 0x60)))
            mstore(add(ptr, 0x80), mload(add(order, 0x80)))
            mstore(add(ptr, 0xa0), mload(add(order, 0xa0)))
            mstore(add(ptr, 0xc0), mload(add(order, 0xc0)))
            mstore(add(ptr, 0xe0), mload(add(order, 0xe0)))
            mstore(add(ptr, 0x100), mload(add(order, 0x100)))
            result := keccak256(ptr, size)
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

        if (fillBps >= 10000) return order.qty;


        uint256 filled = (uint256(order.qty) * fillBps) / 10000;
        return uint128(filled);
    }

    /// @notice Convert tick to price (simplified: price = 1.0001^tick)
    /// @dev For production, use proper fixed-point math
    function tickToPrice(int24 tick) internal pure returns (uint256) {


        return uint256(int256(tick));
    }

    /// @notice Convert price to tick
    function priceToTick(uint256 price) internal pure returns (int24) {

        return int24(int256(price));
    }
}
