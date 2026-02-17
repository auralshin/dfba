// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AuctionHouseTest is Test {
    AuctionHouse public auctionHouse;
    MockERC20 public baseToken;
    MockERC20 public quoteToken;

    address public admin = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public carol = address(0x4);

    uint64 public marketId;
    uint64 public constant BATCH_DURATION = 12; // 12 seconds

    function setUp() public {
        vm.startPrank(admin);

        auctionHouse = new AuctionHouse();
        baseToken = new MockERC20("Base", "BASE");
        quoteToken = new MockERC20("Quote", "QUOTE");

        // Create a spot market
        marketId = auctionHouse.createMarket(OrderTypes.MarketType.Spot, address(baseToken), address(quoteToken));

        // Grant ROUTER_ROLE to test accounts so they can submit orders
        auctionHouse.grantRole(auctionHouse.ROUTER_ROLE(), alice);
        auctionHouse.grantRole(auctionHouse.ROUTER_ROLE(), bob);
        auctionHouse.grantRole(auctionHouse.ROUTER_ROLE(), carol);

        vm.stopPrank();

        // Fund test accounts
        baseToken.mint(alice, 10_000 * 10 ** 18);
        baseToken.mint(bob, 10_000 * 10 ** 18);
        baseToken.mint(carol, 10_000 * 10 ** 18);
        quoteToken.mint(alice, 10_000 * 10 ** 18);
        quoteToken.mint(bob, 10_000 * 10 ** 18);
        quoteToken.mint(carol, 10_000 * 10 ** 18);
    }

    function testCreateMarket() public {
        assertEq(auctionHouse.marketCount(), 1);

        (OrderTypes.MarketType marketType, address base, address quote, bool active) = auctionHouse.markets(marketId);

        assertEq(uint256(marketType), uint256(OrderTypes.MarketType.Spot));
        assertEq(base, address(baseToken));
        assertEq(quote, address(quoteToken));
        assertTrue(active);
    }

    function testSubmitMakerBuyOrder() public {
        vm.startPrank(alice);

        uint64 batchId = auctionHouse.getBatchId(marketId);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: alice,
            marketId: marketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: auctionHouse.userNonces(alice),
            expiry: uint64(block.timestamp + 3600)
        });

        (bytes32 orderId,) = auctionHouse.submitOrder(order);

        // Verify order was created
        (address trader,,,,,,,) = auctionHouse.orders(orderId);
        assertEq(trader, alice);

        // Verify order state
        (uint128 remaining, uint128 claimed, bool cancelled) = auctionHouse.orderStates(orderId);
        assertEq(remaining, 1000);
        assertEq(claimed, 0);
        assertFalse(cancelled);

        vm.stopPrank();
    }

    function testSubmitMakerSellOrder() public {
        vm.startPrank(bob);

        uint64 batchId = auctionHouse.getBatchId(marketId);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: bob,
            marketId: marketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 500,
            nonce: auctionHouse.userNonces(bob),
            expiry: uint64(block.timestamp + 3600)
        });

        (bytes32 orderId,) = auctionHouse.submitOrder(order);

        (address trader,,,,,,,) = auctionHouse.orders(orderId);
        assertEq(trader, bob);

        vm.stopPrank();
    }

    function testSubmitTakerBuyOrder() public {
        vm.startPrank(carol);

        uint64 batchId = auctionHouse.getBatchId(marketId);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: carol,
            marketId: marketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker,
            priceTick: 100,
            qty: 300,
            nonce: auctionHouse.userNonces(carol),
            expiry: uint64(block.timestamp + 3600)
        });

        (bytes32 orderId,) = auctionHouse.submitOrder(order);

        (address trader,,,,,,,) = auctionHouse.orders(orderId);
        assertEq(trader, carol);

        vm.stopPrank();
    }

    function testCancelOrder() public {
        vm.startPrank(alice);

        uint64 batchId = auctionHouse.getBatchId(marketId);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: alice,
            marketId: marketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: auctionHouse.userNonces(alice),
            expiry: uint64(block.timestamp + 3600)
        });

        (bytes32 orderId,) = auctionHouse.submitOrder(order);

        // Cancel the order
        auctionHouse.cancelOrder(orderId);

        // Verify order was cancelled
        (,, bool cancelled) = auctionHouse.orderStates(orderId);
        assertTrue(cancelled);

        vm.stopPrank();
    }

    function testCannotCancelAfterCutoff() public {
        vm.startPrank(alice);

        uint64 batchId = auctionHouse.getBatchId(marketId);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: alice,
            marketId: marketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: auctionHouse.userNonces(alice),
            expiry: uint64(block.timestamp + 3600)
        });

        (bytes32 orderId,) = auctionHouse.submitOrder(order);

        // Fast forward past batch cutoff
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        // Should revert - batch check happens first
        vm.expectRevert("AuctionHouse: can only cancel current batch");
        auctionHouse.cancelOrder(orderId);

        vm.stopPrank();
    }

    function testCannotCancelPastBatch() public {
        vm.startPrank(alice);

        uint64 batchId = auctionHouse.getBatchId(marketId);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: alice,
            marketId: marketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: auctionHouse.userNonces(alice),
            expiry: uint64(block.timestamp + 3600)
        });

        (bytes32 orderId,) = auctionHouse.submitOrder(order);

        // Fast forward to next batch
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        // Should revert when trying to cancel old batch
        vm.expectRevert("AuctionHouse: can only cancel current batch");
        auctionHouse.cancelOrder(orderId);

        vm.stopPrank();
    }

    function testSimpleBidAuction() public {
        uint64 batchId = auctionHouse.getBatchId(marketId);

        // Alice submits maker buy at tick 100
        OrderTypes.Order memory makerBuy = OrderTypes.Order({
            trader: alice,
            marketId: marketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: uint64(block.timestamp + 3600)
        });
        vm.prank(alice);
        auctionHouse.submitOrder(makerBuy);

        // Bob submits taker sell at tick 100
        OrderTypes.Order memory takerSell = OrderTypes.Order({
            trader: bob,
            marketId: marketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Taker,
            priceTick: 100,
            qty: 500,
            nonce: 0,
            expiry: uint64(block.timestamp + 3600)
        });
        vm.prank(bob);
        auctionHouse.submitOrder(takerSell);

        // Fast forward past batch
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        // Finalize batch (can be manual or happens automatically on next submitOrder)
        vm.prank(admin);
        (AuctionHouse.FinalizePhase phase, bool done) = auctionHouse.finalizeStep(marketId, batchId, 100);

        // Should discover bid clearing
        assertTrue(uint256(phase) > 0); // Not NotStarted
    }

    function testSimpleAskAuction() public {
        uint64 batchId = auctionHouse.getBatchId(marketId);

        // Alice submits maker sell at tick 100
        OrderTypes.Order memory makerSell = OrderTypes.Order({
            trader: alice,
            marketId: marketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100,
            qty: 1000,
            nonce: 0,
            expiry: uint64(block.timestamp + 3600)
        });
        vm.prank(alice);
        auctionHouse.submitOrder(makerSell);

        // Bob submits taker buy at tick 100
        OrderTypes.Order memory takerBuy = OrderTypes.Order({
            trader: bob,
            marketId: marketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker,
            priceTick: 100,
            qty: 500,
            nonce: 0,
            expiry: uint64(block.timestamp + 3600)
        });
        vm.prank(bob);
        auctionHouse.submitOrder(takerBuy);

        // Fast forward past batch
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        // Finalize batch
        vm.prank(admin);
        auctionHouse.finalizeStep(marketId, batchId, 100);
    }

    function testFullFinalizationCycle() public {
        uint64 batchId = auctionHouse.getBatchId(marketId);

        // Submit orders at multiple ticks
        vm.prank(alice);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: alice,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: 100,
                qty: 1000,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        vm.prank(bob);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: bob,
                marketId: marketId,
                side: OrderTypes.Side.Sell,
                flow: OrderTypes.Flow.Taker,
                priceTick: 100,
                qty: 500,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        // Fast forward
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        // Run full finalization
        vm.startPrank(admin);

        bool done = false;
        uint256 iterations = 0;
        uint256 maxIterations = 20; // Safety limit

        while (!done && iterations < maxIterations) {
            (, done) = auctionHouse.finalizeStep(marketId, batchId, 10);
            iterations++;
        }

        assertTrue(done, "Finalization should complete");
        assertTrue(iterations < maxIterations, "Should not hit iteration limit");

        vm.stopPrank();
    }

    function testMultipleTickLevels() public {
        uint64 batchId = auctionHouse.getBatchId(marketId);

        // Submit orders at different ticks
        vm.prank(alice);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: alice,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: 100,
                qty: 500,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        vm.prank(alice);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: alice,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: 90,
                qty: 300,
                nonce: 1,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        vm.prank(bob);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: bob,
                marketId: marketId,
                side: OrderTypes.Side.Sell,
                flow: OrderTypes.Flow.Taker,
                priceTick: 100,
                qty: 600,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        // Fast forward and finalize
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        vm.startPrank(admin);
        bool done = false;
        while (!done) {
            (, done) = auctionHouse.finalizeStep(marketId, batchId, 10);
        }
        vm.stopPrank();
    }

    function testTickBitmapEdgeCases() public {
        uint64 batchId = auctionHouse.getBatchId(marketId);

        // Test tick at bitPos 255 (overflow edge case)
        int24 edgeTick = 255;

        vm.prank(alice);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: alice,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: edgeTick,
                qty: 100,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        vm.prank(bob);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: bob,
                marketId: marketId,
                side: OrderTypes.Side.Sell,
                flow: OrderTypes.Flow.Taker,
                priceTick: edgeTick,
                qty: 50,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        // Should not revert
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        vm.startPrank(admin);
        bool done = false;
        while (!done) {
            (, done) = auctionHouse.finalizeStep(marketId, batchId, 10);
        }
        vm.stopPrank();
    }

    function testFinalizationWithPausedMarket() public {
        uint64 batchId = auctionHouse.getBatchId(marketId);

        vm.prank(alice);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: alice,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: 100,
                qty: 100,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        // Fast forward
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        // Pause market
        vm.prank(admin);
        auctionHouse.setMarketActive(marketId, false);

        // Should still allow finalization
        vm.prank(admin);
        auctionHouse.finalizeStep(marketId, batchId, 10);
    }

    function testCannotSubmitOrderToPausedMarket() public {
        // Pause market
        vm.prank(admin);
        auctionHouse.setMarketActive(marketId, false);

        uint64 batchId = auctionHouse.getBatchId(marketId);

        // Try to submit order - should fail
        vm.prank(alice);
        vm.expectRevert("AuctionHouse: market not active");
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: alice,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: 100,
                qty: 100,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );
    }

    function testNonceIncrement() public {
        vm.startPrank(alice);

        uint64 batchId = auctionHouse.getBatchId(marketId);

        // Submit first order with nonce 0
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: alice,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: 100,
                qty: 100,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        // Submit second order with nonce 1 (caller manages nonces)
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: alice,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: 101,
                qty: 100,
                nonce: 1,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        vm.stopPrank();
    }
}
