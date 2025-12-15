// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";

contract OrderTypesTest is Test {
    function test_orderKey_generatesDifferentKeysForDifferentOrders() public {
        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            auctionId: 100,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });

        OrderTypes.Order memory order2 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            auctionId: 100,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 2, // Different nonce
            expiry: 0
        });

        bytes32 key1 = OrderTypes.orderKey(order1);
        bytes32 key2 = OrderTypes.orderKey(order2);

        assertNotEq(key1, key2, "Different nonces should produce different keys");
    }

    function test_orderKey_consistentForSameOrder() public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            auctionId: 100,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });

        bytes32 key1 = OrderTypes.orderKey(order);
        bytes32 key2 = OrderTypes.orderKey(order);

        assertEq(key1, key2, "Same order should produce same key");
    }

    function test_inTheMoney_buyOrder() public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            auctionId: 100,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });

        OrderTypes.Clearing memory clearingAbove = OrderTypes.Clearing({
            clearingTick: 1100, // Higher than order
            marginalFillMakerBps: 10000,
            marginalFillTakerBps: 10000,
            clearedQty: 100,
            finalized: true
        });

        OrderTypes.Clearing memory clearingBelow = OrderTypes.Clearing({
            clearingTick: 900, // Lower than order
            marginalFillMakerBps: 10000,
            marginalFillTakerBps: 10000,
            clearedQty: 100,
            finalized: true
        });

        assertTrue(OrderTypes.inTheMoney(order, clearingBelow), "Buy order should fill at lower price");
        assertFalse(OrderTypes.inTheMoney(order, clearingAbove), "Buy order should not fill at higher price");
    }

    function test_inTheMoney_sellOrder() public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            auctionId: 100,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });

        OrderTypes.Clearing memory clearingAbove = OrderTypes.Clearing({
            clearingTick: 1100,
            marginalFillMakerBps: 10000,
            marginalFillTakerBps: 10000,
            clearedQty: 100,
            finalized: true
        });

        OrderTypes.Clearing memory clearingBelow = OrderTypes.Clearing({
            clearingTick: 900,
            marginalFillMakerBps: 10000,
            marginalFillTakerBps: 10000,
            clearedQty: 100,
            finalized: true
        });

        assertTrue(OrderTypes.inTheMoney(order, clearingAbove), "Sell order should fill at higher price");
        assertFalse(OrderTypes.inTheMoney(order, clearingBelow), "Sell order should not fill at lower price");
    }

    function test_filledQty_fullFill() public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            auctionId: 100,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });

        // Not at marginal tick - full fill
        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 900,
            marginalFillMakerBps: 5000, // 50%
            marginalFillTakerBps: 10000,
            clearedQty: 1000,
            finalized: true
        });

        uint128 filled = OrderTypes.filledQty(order, clearing, 0);
        assertEq(filled, 100, "Should be fully filled when not at marginal tick");
    }

    function test_filledQty_marginalFill() public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            auctionId: 100,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });

        // At marginal tick - partial fill
        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 1000,
            marginalFillMakerBps: 5000, // 50%
            marginalFillTakerBps: 10000,
            clearedQty: 500,
            finalized: true
        });

        uint128 filled = OrderTypes.filledQty(order, clearing, 0);
        assertEq(filled, 50, "Should be 50% filled at marginal tick");
    }

    function test_filledQty_noFill() public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            auctionId: 100,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });

        // Out of the money
        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 1100,
            marginalFillMakerBps: 10000,
            marginalFillTakerBps: 10000,
            clearedQty: 1000,
            finalized: true
        });

        uint128 filled = OrderTypes.filledQty(order, clearing, 0);
        assertEq(filled, 0, "Should not fill when out of the money");
    }
}
