// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";

contract OrderTypesTest is Test {
    function testOrderKeyUniqueness() public {
        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Order memory order2 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 1, // Different nonce
            expiry: 1000
        });

        bytes32 key1 = OrderTypes.orderKey(order1);
        bytes32 key2 = OrderTypes.orderKey(order2);

        assertTrue(key1 != key2, "Different nonces should produce different keys");
    }

    function testOrderKeyDifferentTraders() public {
        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Order memory order2 = OrderTypes.Order({
            trader: address(0x2), // Different trader
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        bytes32 key1 = OrderTypes.orderKey(order1);
        bytes32 key2 = OrderTypes.orderKey(order2);

        assertTrue(key1 != key2, "Different traders should produce different keys");
    }

    function testOrderKeyDifferentSides() public {
        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Order memory order2 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Sell, // Different side
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        bytes32 key1 = OrderTypes.orderKey(order1);
        bytes32 key2 = OrderTypes.orderKey(order2);

        assertTrue(key1 != key2, "Different sides should produce different keys");
    }

    function testOrderKeyDifferentFlows() public {
        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Order memory order2 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker, // Different flow
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        bytes32 key1 = OrderTypes.orderKey(order1);
        bytes32 key2 = OrderTypes.orderKey(order2);

        assertTrue(key1 != key2, "Different flows should produce different keys");
    }

    function testOrderKeySame() public {
        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Order memory order2 = order1;

        bytes32 key1 = OrderTypes.orderKey(order1);
        bytes32 key2 = OrderTypes.orderKey(order2);

        assertEq(key1, key2, "Identical orders should produce same key");
    }

    function testFuzzOrderKey(
        address trader,
        uint64 marketId,
        uint64 batchId,
        bool isBuy,
        bool isMaker,
        int24 priceTick,
        uint128 qty,
        uint128 nonce,
        uint64 expiry
    ) public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader,
            marketId: marketId,
            side: isBuy ? OrderTypes.Side.Buy : OrderTypes.Side.Sell,
            flow: isMaker ? OrderTypes.Flow.Maker : OrderTypes.Flow.Taker,
            priceTick: priceTick,
            qty: qty,
            nonce: nonce,
            expiry: expiry
        });

        bytes32 key = OrderTypes.orderKey(order);

        // Key should be non-zero for most inputs
        // (extremely unlikely to get zero hash)
        if (trader != address(0) || qty != 0 || nonce != 0) {
            assertTrue(key != bytes32(0), "Key should not be zero for non-trivial inputs");
        }
    }

    /*//////////////////////////////////////////////////////////////
                      TICK/PRICE CONVERSION TESTS
    //////////////////////////////////////////////////////////////*/

    function testTickToPrice() public pure {
        // tick=0 should give price=1e18 (1.0)
        assertEq(OrderTypes.tickToPrice(0), 1e18);

        // Positive ticks increase price
        assertGt(OrderTypes.tickToPrice(100), 1e18);
        assertGt(OrderTypes.tickToPrice(1000), OrderTypes.tickToPrice(100));

        // Negative ticks decrease price (but must stay positive)
        assertLt(OrderTypes.tickToPrice(-100), 1e18);
        assertLt(OrderTypes.tickToPrice(-1000), OrderTypes.tickToPrice(-100));

        // Specific values (1.0001^tick)
        assertApproxEqAbs(OrderTypes.tickToPrice(10_000), 2_718_145_926_825_221_235, 1e12);
        assertApproxEqAbs(OrderTypes.tickToPrice(-5000), 606_530_659_712_633_423, 1e12);
    }

    /*//////////////////////////////////////////////////////////////
                      IN THE MONEY TESTS
    //////////////////////////////////////////////////////////////*/

    function testInTheMoneyNotFinalized() public pure {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 100,
            marginalFillMakerBps: 10_000,
            marginalFillTakerBps: 10_000,
            clearedQty: 1000,
            finalized: false
        });

        assertFalse(OrderTypes.inTheMoney(order, clearing));
    }

    function testInTheMoneyTakerAlwaysTrue() public pure {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 200, // Different tick
            marginalFillMakerBps: 10_000,
            marginalFillTakerBps: 10_000,
            clearedQty: 1000,
            finalized: true
        });

        assertTrue(OrderTypes.inTheMoney(order, clearing));
    }

    function testInTheMoneyBuyMaker() public pure {
        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 100,
            marginalFillMakerBps: 10_000,
            marginalFillTakerBps: 10_000,
            clearedQty: 1000,
            finalized: true
        });

        // Buy at 100, clears at 100 -> ITM
        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });
        assertTrue(OrderTypes.inTheMoney(order1, clearing));

        // Buy at 150 (higher), clears at 100 -> ITM
        OrderTypes.Order memory order2 = order1;
        order2.priceTick = 150;
        assertTrue(OrderTypes.inTheMoney(order2, clearing));

        // Buy at 50 (lower), clears at 100 -> OTM
        OrderTypes.Order memory order3 = order1;
        order3.priceTick = 50;
        assertFalse(OrderTypes.inTheMoney(order3, clearing));
    }

    function testInTheMoneySellMaker() public pure {
        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 100,
            marginalFillMakerBps: 10_000,
            marginalFillTakerBps: 10_000,
            clearedQty: 1000,
            finalized: true
        });

        // Sell at 100, clears at 100 -> ITM
        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });
        assertTrue(OrderTypes.inTheMoney(order1, clearing));

        // Sell at 50 (lower), clears at 100 -> ITM
        OrderTypes.Order memory order2 = order1;
        order2.priceTick = 50;
        assertTrue(OrderTypes.inTheMoney(order2, clearing));

        // Sell at 150 (higher), clears at 100 -> OTM
        OrderTypes.Order memory order3 = order1;
        order3.priceTick = 150;
        assertFalse(OrderTypes.inTheMoney(order3, clearing));
    }

    /*//////////////////////////////////////////////////////////////
                      FILLED QTY TESTS
    //////////////////////////////////////////////////////////////*/

    function testFilledQtyOTM() public pure {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 50, // Buy at 50
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 100, // Clears at 100
            marginalFillMakerBps: 10_000,
            marginalFillTakerBps: 10_000,
            clearedQty: 1000,
            finalized: true
        });

        assertEq(OrderTypes.filledQty(order, clearing, 1000), 0);
    }

    function testFilledQtyFullFillNonMarginal() public pure {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 150, // Buy at 150
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 100, // Clears at 100 (better price for buyer)
            marginalFillMakerBps: 5000, // Partial fill at margin
            marginalFillTakerBps: 10_000,
            clearedQty: 1000,
            finalized: true
        });

        // Non-marginal orders get fully filled
        assertEq(OrderTypes.filledQty(order, clearing, 1000), 1000);
    }

    function testFilledQtyPartialFillMarginal() public pure {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100, // Buy at exactly clearing price
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 100,
            marginalFillMakerBps: 5000, // 50% fill
            marginalFillTakerBps: 10_000,
            clearedQty: 1000,
            finalized: true
        });

        // Marginal maker gets partial fill
        assertEq(OrderTypes.filledQty(order, clearing, 1000), 500);
    }

    function testFilledQtyTakerMarginal() public pure {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 100,
            marginalFillMakerBps: 10_000,
            marginalFillTakerBps: 7500, // 75% fill for takers
            clearedQty: 1000,
            finalized: true
        });

        // Marginal taker gets partial fill based on taker bps
        assertEq(OrderTypes.filledQty(order, clearing, 1000), 750);
    }

    function testFilledQtyFullFillMarginal() public pure {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: address(0x1),
            marketId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: 1000
        });

        OrderTypes.Clearing memory clearing = OrderTypes.Clearing({
            clearingTick: 100,
            marginalFillMakerBps: 10_000, // 100% fill
            marginalFillTakerBps: 10_000,
            clearedQty: 1000,
            finalized: true
        });

        assertEq(OrderTypes.filledQty(order, clearing, 1000), 1000);
    }
}
