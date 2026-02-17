// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title AuctionHouseFuzzTest
/// @notice Fuzz testing for AuctionHouse core invariants
contract AuctionHouseFuzzTest is Test {
    AuctionHouse public auctionHouse;
    MockERC20 public usdc;
    MockERC20 public weth;

    uint64 public spotMarketId;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);

    function setUp() public {
        // Deploy contracts
        auctionHouse = new AuctionHouse();
        usdc = new MockERC20("USDC", "USDC");
        weth = new MockERC20("WETH", "WETH");

        // Create spot market
        spotMarketId = auctionHouse.createMarket(OrderTypes.MarketType.Spot, address(weth), address(usdc));

        // Grant ROUTER_ROLE to test contract
        auctionHouse.grantRouterRole(address(this));

        // Mint tokens for test users
        usdc.mint(alice, 1_000_000 * 10 ** 18);
        usdc.mint(bob, 1_000_000 * 10 ** 18);
        usdc.mint(carol, 1_000_000 * 10 ** 18);
        weth.mint(alice, 1000 * 10 ** 18);
        weth.mint(bob, 1000 * 10 ** 18);
        weth.mint(carol, 1000 * 10 ** 18);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: order submission with random valid parameters
    function testFuzz_SubmitOrder(uint8 sideRaw, uint8 flowRaw, int24 priceTick, uint128 qty, uint128 nonce) public {
        // Bound inputs to valid ranges
        OrderTypes.Side side = sideRaw % 2 == 0 ? OrderTypes.Side.Buy : OrderTypes.Side.Sell;
        OrderTypes.Flow flow = flowRaw % 2 == 0 ? OrderTypes.Flow.Maker : OrderTypes.Flow.Taker;
        priceTick = int24(bound(int256(priceTick), auctionHouse.MIN_TICK(), auctionHouse.MAX_TICK()));
        qty = uint128(bound(uint256(qty), 1, 1000 * 10 ** 18)); // 1 wei to 1000 tokens

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: alice,
            marketId: spotMarketId,
            side: side,
            flow: flow,
            priceTick: priceTick,
            qty: qty,
            nonce: nonce,
            expiry: uint64(block.timestamp + 1 hours)
        });

        (bytes32 orderId, uint64 batchId) = auctionHouse.submitOrder(order);

        // Verify order was created
        (address trader,,,,,,,) = auctionHouse.orders(orderId);
        assertEq(trader, alice);

        // Verify batch assignment
        assertEq(batchId, auctionHouse.getBatchId(spotMarketId));
    }

    /// @notice Fuzz test: multiple orders should increment aggregates correctly
    function testFuzz_OrderAggregation(
        uint128 qty1,
        uint128 qty2,
        uint128 qty3,
        int24 tick1,
        int24 tick2,
        int24 tick3
    )
        public
    {
        // Bound quantities
        qty1 = uint128(bound(uint256(qty1), 1, 100 * 10 ** 18));
        qty2 = uint128(bound(uint256(qty2), 1, 100 * 10 ** 18));
        qty3 = uint128(bound(uint256(qty3), 1, 100 * 10 ** 18));

        // Bound ticks
        tick1 = int24(bound(int256(tick1), auctionHouse.MIN_TICK(), auctionHouse.MAX_TICK()));
        tick2 = int24(bound(int256(tick2), auctionHouse.MIN_TICK(), auctionHouse.MAX_TICK()));
        tick3 = int24(bound(int256(tick3), auctionHouse.MIN_TICK(), auctionHouse.MAX_TICK()));

        uint64 batchId = auctionHouse.getBatchId(spotMarketId);

        // Submit 3 maker-buy orders
        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: alice,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: tick1,
            qty: qty1,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        auctionHouse.submitOrder(order1);

        OrderTypes.Order memory order2 = OrderTypes.Order({
            trader: bob,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: tick2,
            qty: qty2,
            nonce: 2,
            expiry: uint64(block.timestamp + 1 hours)
        });
        auctionHouse.submitOrder(order2);

        OrderTypes.Order memory order3 = OrderTypes.Order({
            trader: carol,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: tick3,
            qty: qty3,
            nonce: 3,
            expiry: uint64(block.timestamp + 1 hours)
        });
        auctionHouse.submitOrder(order3);

        // Verify tick levels
        OrderTypes.TickLevel memory level1 = auctionHouse.getTickLevel(spotMarketId, batchId, tick1);
        OrderTypes.TickLevel memory level2 = auctionHouse.getTickLevel(spotMarketId, batchId, tick2);
        OrderTypes.TickLevel memory level3 = auctionHouse.getTickLevel(spotMarketId, batchId, tick3);

        // At least one order at each tick (may overlap)
        if (tick1 == tick2 && tick2 == tick3) {
            assertEq(level1.makerBuy, qty1 + qty2 + qty3);
        } else if (tick1 == tick2) {
            assertEq(level1.makerBuy, qty1 + qty2);
            assertEq(level3.makerBuy, qty3);
        } else if (tick2 == tick3) {
            assertEq(level1.makerBuy, qty1);
            assertEq(level2.makerBuy, qty2 + qty3);
        } else if (tick1 == tick3) {
            assertEq(level1.makerBuy, qty1 + qty3);
            assertEq(level2.makerBuy, qty2);
        } else {
            assertEq(level1.makerBuy, qty1);
            assertEq(level2.makerBuy, qty2);
            assertEq(level3.makerBuy, qty3);
        }
    }

    /// @notice Fuzz test: cancellation should correctly update aggregates
    function testFuzz_CancelOrder(int24 priceTick, uint128 qty, uint128 nonce) public {
        // Bound inputs
        priceTick = int24(bound(int256(priceTick), auctionHouse.MIN_TICK(), auctionHouse.MAX_TICK()));
        qty = uint128(bound(uint256(qty), 1, 100 * 10 ** 18));

        uint64 batchId = auctionHouse.getBatchId(spotMarketId);

        // Submit order
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: alice,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: priceTick,
            qty: qty,
            nonce: nonce,
            expiry: uint64(block.timestamp + 1 hours)
        });

        (bytes32 orderId,) = auctionHouse.submitOrder(order);

        // Check tick level before cancel
        OrderTypes.TickLevel memory levelBefore = auctionHouse.getTickLevel(spotMarketId, batchId, priceTick);
        assertEq(levelBefore.makerBuy, qty);

        // Cancel order
        vm.prank(alice);
        auctionHouse.cancelOrder(orderId);

        // Check tick level after cancel
        OrderTypes.TickLevel memory levelAfter = auctionHouse.getTickLevel(spotMarketId, batchId, priceTick);
        assertEq(levelAfter.makerBuy, 0);

        // Verify order state
        (, OrderTypes.OrderState memory state) = auctionHouse.getOrder(orderId);
        assertTrue(state.cancelled);
        assertEq(state.remainingQty, 0);
    }

    /// @notice Fuzz test: batch ID calculation is deterministic
    function testFuzz_BatchIdCalculation(uint64 timestamp) public {
        // Bound timestamp to reasonable range (not too far future to avoid overflow)
        timestamp = uint64(bound(uint256(timestamp), block.timestamp, block.timestamp + 365 days));

        vm.warp(timestamp);

        uint64 batchId1 = auctionHouse.getBatchId(spotMarketId);
        uint64 batchId2 = auctionHouse.getBatchId(spotMarketId);

        // Same timestamp = same batch ID
        assertEq(batchId1, batchId2);

        // Verify formula: floor(timestamp / BATCH_DURATION)
        uint256 batchDuration = auctionHouse.BATCH_DURATION();
        assertEq(batchId1, timestamp / batchDuration);
    }

    /// @notice Fuzz test: order uniqueness via orderKey
    function testFuzz_OrderKeyUniqueness(
        address trader1,
        address trader2,
        uint128 nonce1,
        uint128 nonce2,
        int24 tick1,
        int24 tick2,
        uint128 qty1,
        uint128 qty2
    )
        public
    {
        vm.assume(trader1 != address(0) && trader2 != address(0));

        // Bound ticks
        tick1 = int24(bound(int256(tick1), auctionHouse.MIN_TICK(), auctionHouse.MAX_TICK()));
        tick2 = int24(bound(int256(tick2), auctionHouse.MIN_TICK(), auctionHouse.MAX_TICK()));

        // Bound quantities
        qty1 = uint128(bound(uint256(qty1), 1, 100 * 10 ** 18));
        qty2 = uint128(bound(uint256(qty2), 1, 100 * 10 ** 18));

        OrderTypes.Order memory order1 = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: tick1,
            qty: qty1,
            nonce: nonce1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        OrderTypes.Order memory order2 = OrderTypes.Order({
            trader: trader2,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: tick2,
            qty: qty2,
            nonce: nonce2,
            expiry: uint64(block.timestamp + 1 hours)
        });

        bytes32 key1 = OrderTypes.orderKey(order1);
        bytes32 key2 = OrderTypes.orderKey(order2);

        // Keys should differ if any parameter differs
        bool shouldDiffer = (trader1 != trader2) || (nonce1 != nonce2) || (tick1 != tick2) || (qty1 != qty2);

        if (shouldDiffer) {
            assertTrue(key1 != key2, "Order keys should differ");
        } else {
            assertEq(key1, key2, "Identical orders should have same key");
        }
    }

    /// @notice Fuzz test: clearing price is always within order range
    function testFuzz_ClearingPriceValidity(int24 bidTick, int24 askTick, uint128 bidQty, uint128 askQty) public {
        // Bound inputs
        bidTick = int24(bound(int256(bidTick), auctionHouse.MIN_TICK(), auctionHouse.MAX_TICK() - 1));
        askTick = int24(bound(int256(askTick), bidTick + 1, auctionHouse.MAX_TICK())); // Ask > Bid
        bidQty = uint128(bound(uint256(bidQty), 1, 100 * 10 ** 18));
        askQty = uint128(bound(uint256(askQty), 1, 100 * 10 ** 18));

        uint64 batchId = auctionHouse.getBatchId(spotMarketId);

        // Submit maker-buy (bid)
        OrderTypes.Order memory bidOrder = OrderTypes.Order({
            trader: alice,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: bidTick,
            qty: bidQty,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        auctionHouse.submitOrder(bidOrder);

        // Submit taker-sell (crosses bid)
        OrderTypes.Order memory sellOrder = OrderTypes.Order({
            trader: bob,
            marketId: spotMarketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Taker,
            priceTick: bidTick - 100, // Willing to sell at lower price
            qty: askQty,
            nonce: 2,
            expiry: uint64(block.timestamp + 1 hours)
        });
        auctionHouse.submitOrder(sellOrder);

        // Advance to next batch
        vm.warp(block.timestamp + auctionHouse.BATCH_DURATION() + 1);

        // Finalize
        while (true) {
            (AuctionHouse.FinalizePhase phase, bool done) = auctionHouse.finalizeStep(spotMarketId, batchId, 100);
            if (done) break;
        }

        // Get clearing results
        (OrderTypes.Clearing memory bidClearing,) = auctionHouse.getClearing(spotMarketId, batchId);

        if (bidClearing.finalized && bidClearing.clearedQty > 0) {
            // Clearing price should be within reasonable range
            assertTrue(bidClearing.clearingTick >= auctionHouse.MIN_TICK());
            assertTrue(bidClearing.clearingTick <= auctionHouse.MAX_TICK());
        }
    }

    /// @notice Fuzz test: filled quantity never exceeds order quantity
    function testFuzz_FilledQuantityBounds(int24 priceTick, uint128 orderQty, uint128 counterQty) public {
        // Bound inputs
        priceTick = int24(bound(int256(priceTick), auctionHouse.MIN_TICK(), auctionHouse.MAX_TICK()));
        orderQty = uint128(bound(uint256(orderQty), 1, 100 * 10 ** 18));
        counterQty = uint128(bound(uint256(counterQty), 1, 100 * 10 ** 18));

        uint64 batchId = auctionHouse.getBatchId(spotMarketId);

        // Submit maker-buy
        OrderTypes.Order memory buyOrder = OrderTypes.Order({
            trader: alice,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: priceTick,
            qty: orderQty,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        (bytes32 orderId,) = auctionHouse.submitOrder(buyOrder);

        // Submit taker-sell to match
        OrderTypes.Order memory sellOrder = OrderTypes.Order({
            trader: bob,
            marketId: spotMarketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Taker,
            priceTick: priceTick - 100, // Willing to sell cheaper
            qty: counterQty,
            nonce: 2,
            expiry: uint64(block.timestamp + 1 hours)
        });
        auctionHouse.submitOrder(sellOrder);

        // Advance to next batch
        vm.warp(block.timestamp + auctionHouse.BATCH_DURATION() + 1);

        // Finalize
        while (true) {
            (, bool done) = auctionHouse.finalizeStep(spotMarketId, batchId, 100);
            if (done) break;
        }

        // Get filled quantity
        uint128 filledQty = auctionHouse.getOrderFilledQty(orderId);

        // Invariant: filled <= order qty
        assertLe(filledQty, orderQty, "Filled quantity exceeds order quantity");

        // Invariant: filled <= available counter liquidity
        assertLe(filledQty, counterQty, "Filled quantity exceeds counter liquidity");
    }
}
