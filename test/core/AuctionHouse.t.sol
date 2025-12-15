// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AuctionHouse} from "../../src/core/AuctionHouse.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title AuctionHouse Comprehensive Test Suite
/// @notice Tests both functionality AND security properties
contract AuctionHouseTest is Test {
    AuctionHouse public auctionHouse;
    MockERC20 public baseToken;
    MockERC20 public quoteToken;
    
    address public admin = address(this);
    address public trader1 = address(0x1);
    address public trader2 = address(0x2);
    address public attacker = address(0x666);
    
    uint64 public marketId;

    function setUp() public {
        auctionHouse = new AuctionHouse();
        baseToken = new MockERC20("Base", "BASE");
        quoteToken = new MockERC20("Quote", "QUOTE");
        
        marketId = auctionHouse.createMarket(
            OrderTypes.MarketType.Spot,
            address(baseToken),
            address(quoteToken)
        );
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_submitOrder() public {
        vm.startPrank(trader1);
        
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionHouse.getAuctionId(marketId),
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });
        
        bytes32 orderId = auctionHouse.submitOrder(order);
        
        (OrderTypes.Order memory storedOrder,) = auctionHouse.getOrder(orderId);
        
        assertEq(storedOrder.trader, trader1);
        assertEq(storedOrder.qty, 100);
        vm.stopPrank();
    }

    function test_finalizeAuction() public {
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        
        vm.prank(trader1);
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        }));
        
        vm.prank(trader2);
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader2,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 900,
            qty: 100,
            nonce: 1,
            expiry: 0
        }));
        
        vm.warp(block.timestamp + auctionHouse.AUCTION_DURATION() + 1);
        auctionHouse.finalizeAuction(marketId, auctionId);
        
        (OrderTypes.Clearing memory buyClearing,) = auctionHouse.getClearing(marketId, auctionId);
        assertTrue(buyClearing.finalized);
        assertGt(buyClearing.clearedQty, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SECURITY: ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice C3: Only trader can submit their own orders
    function test_security_cannotSubmitOthersOrder() public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,  // Order for trader1
            marketId: marketId,
            auctionId: auctionHouse.getAuctionId(marketId),
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });
        
        vm.prank(attacker);  // But attacker tries to submit
        vm.expectRevert("AuctionHouse: unauthorized trader");
        auctionHouse.submitOrder(order);
    }

    function test_security_onlyAdminCanCreateMarket() public {
        vm.prank(attacker);
        vm.expectRevert("AuctionHouse: not admin");
        auctionHouse.createMarket(
            OrderTypes.MarketType.Spot,
            address(baseToken),
            address(quoteToken)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    SECURITY: TIMING ATTACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice C1: Cannot submit orders after auction expires
    function test_security_cannotSubmitAfterAuctionExpired() public {
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        
        // Warp past auction duration
        vm.warp(block.timestamp + auctionHouse.AUCTION_DURATION() + 1);
        
        vm.prank(trader1);
        vm.expectRevert("AuctionHouse: auction expired");
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        }));
    }

    function test_security_cannotFinalizeBeforeAuctionEnds() public {
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        
        vm.prank(trader1);
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        }));
        
        // Try to finalize immediately (before duration)
        vm.expectRevert("AuctionHouse: auction not ended");
        auctionHouse.finalizeAuction(marketId, auctionId);
    }

    /*//////////////////////////////////////////////////////////////
                SECURITY: STATE MANIPULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice C2: Cancellation must update tick aggregates
    function test_security_cancelUpdatesAggregates() public {
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        
        vm.startPrank(trader1);
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });
        
        bytes32 orderId = auctionHouse.submitOrder(order);
        
        // Check aggregates before cancel
        OrderTypes.TickLevel memory levelBefore = auctionHouse.getTickLevel(marketId, auctionId, 1000);
        assertEq(levelBefore.makerBuy, 100);
        
        // Cancel order
        auctionHouse.cancelOrder(orderId);
        
        // Verify aggregates decreased
        OrderTypes.TickLevel memory levelAfter = auctionHouse.getTickLevel(marketId, auctionId, 1000);
        assertEq(levelAfter.makerBuy, 0, "Aggregates should decrease on cancel");
        vm.stopPrank();
    }

    /// @notice Verify duplicate orders are rejected
    function test_security_cannotSubmitDuplicateOrder() public {
        vm.startPrank(trader1);
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionHouse.getAuctionId(marketId),
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        });
        
        auctionHouse.submitOrder(order);
        
        vm.expectRevert("AuctionHouse: duplicate order");
        auctionHouse.submitOrder(order);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    SECURITY: EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Zero quantity should be rejected
    function test_security_zeroQuantityRejected() public {
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        
        vm.prank(trader1);
        vm.expectRevert("AuctionHouse: qty must be positive");
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 0,  // Zero!
            nonce: 1,
            expiry: 0
        }));
    }

    function test_security_invalidMarketRejected() public {
        vm.prank(trader1);
        vm.expectRevert("AuctionHouse: market not active");
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1,
            marketId: 999,  // Invalid!
            auctionId: 1,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        }));
    }

    function test_security_priceTick_outOfRange() public {
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        int24 maxTick = auctionHouse.MAX_TICK();
        int24 minTick = auctionHouse.MIN_TICK();
        
        vm.startPrank(trader1);
        
        // Too high
        vm.expectRevert("AuctionHouse: tick out of range");
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: maxTick + 1,
            qty: 100,
            nonce: 1,
            expiry: 0
        }));
        
        // Too low
        vm.expectRevert("AuctionHouse: tick out of range");
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: minTick - 1,
            qty: 100,
            nonce: 2,
            expiry: 0
        }));
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    SECURITY: ECONOMIC ATTACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that canceling doesn't allow price manipulation
    function test_security_cancelDoesNotManipulateClearing() public {
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        
        // Attacker submits large buy order
        vm.prank(attacker);
        bytes32 attackOrderId = auctionHouse.submitOrder(OrderTypes.Order({
            trader: attacker,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker,
            priceTick: 2000,  // High price
            qty: 1000,
            nonce: 1,
            expiry: 0
        }));
        
        // Legitimate trader submits sell order
        vm.prank(trader1);
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1,
            marketId: marketId,
            auctionId: auctionId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 1000,
            qty: 100,
            nonce: 1,
            expiry: 0
        }));
        
        // Attacker cancels to avoid execution but still manipulated demand
        vm.prank(attacker);
        auctionHouse.cancelOrder(attackOrderId);
        
        // Verify aggregates were properly updated (cancel fix prevents manipulation)
        OrderTypes.TickLevel memory level = auctionHouse.getTickLevel(marketId, auctionId, 2000);
        assertEq(level.takerBuy, 0, "Canceled order should not affect aggregates");
    }
}
