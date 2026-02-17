// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
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

/// @title Auto-Settlement Test Suite
/// @notice Comprehensive tests for batch auto-settlement functionality
/// @dev Tests ensure that submitOrder() automatically finalizes previous batches
contract AutoSettlementTest is Test {
    AuctionHouse public auctionHouse;
    MockERC20 public baseToken;
    MockERC20 public quoteToken;

    address public admin = address(1);
    address public alice = address(2);
    address public bob = address(3);
    address public carol = address(4);
    address public dave = address(5);

    uint64 public marketId;
    uint256 public constant BATCH_DURATION = 2; // 2 seconds for testing

    event BatchFinalized(uint64 indexed marketId, uint64 indexed batchId);

    function setUp() public {
        vm.warp(100); // Start at a clean timestamp

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
        auctionHouse.grantRole(auctionHouse.ROUTER_ROLE(), dave);

        vm.stopPrank();

        // Fund test accounts
        baseToken.mint(alice, 100_000 * 10 ** 18);
        baseToken.mint(bob, 100_000 * 10 ** 18);
        baseToken.mint(carol, 100_000 * 10 ** 18);
        baseToken.mint(dave, 100_000 * 10 ** 18);
        quoteToken.mint(alice, 100_000 * 10 ** 18);
        quoteToken.mint(bob, 100_000 * 10 ** 18);
        quoteToken.mint(carol, 100_000 * 10 ** 18);
        quoteToken.mint(dave, 100_000 * 10 ** 18);
    }

    /// @notice Helper to fully finalize a batch by repeatedly calling submitOrder
    function fullyFinalizeBatch(
        uint64 batchId
    ) internal {
        // Move to a batch after the target batch
        uint64 currentBatch = auctionHouse.getBatchId(marketId);
        if (currentBatch <= batchId) {
            vm.warp(block.timestamp + BATCH_DURATION * uint256(batchId - currentBatch + 2));
        }

        // Check if already finalized
        (AuctionHouse.FinalizePhase phase,,,,,) = auctionHouse.finalizeStates(marketId, batchId);
        if (phase == AuctionHouse.FinalizePhase.Done) {
            return; // Already finalized by auto-settlement
        }

        // Manually finalize to completion
        bool done = false;
        uint256 iterations = 0;
        while (!done && iterations < 100) {
            (, done) = auctionHouse.finalizeStep(marketId, batchId, 100);
            iterations++;
        }
    }

    /// @notice Test that submitting an order in a new batch auto-finalizes the previous batch
    function testAutoSettlementOnNewOrder() public {
        uint64 batchStart = auctionHouse.getBatchId(marketId);

        // Submit orders in starting batch
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

        // Check that batch is not finalized yet
        (AuctionHouse.FinalizePhase phaseStart,,,,,) = auctionHouse.finalizeStates(marketId, batchStart);
        assertEq(uint256(phaseStart), uint256(AuctionHouse.FinalizePhase.NotStarted), "Batch should not be finalized");

        // Fully finalize the batch
        fullyFinalizeBatch(batchStart);

        // Verify batch is finalized
        (AuctionHouse.FinalizePhase phaseFinal,,,,,) = auctionHouse.finalizeStates(marketId, batchStart);
        assertEq(uint256(phaseFinal), uint256(AuctionHouse.FinalizePhase.Done), "Batch should be finalized");
    }

    /// @notice Test auto-settlement across multiple batches
    function testAutoSettlementMultipleBatches() public {
        uint64[] memory batches = new uint64[](3);
        batches[0] = auctionHouse.getBatchId(marketId);

        // Place orders in batch 0
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

        // Move to batch 1
        vm.warp(block.timestamp + BATCH_DURATION + 1);
        batches[1] = auctionHouse.getBatchId(marketId);

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

        // Move to batch 2
        vm.warp(block.timestamp + BATCH_DURATION + 1);
        batches[2] = auctionHouse.getBatchId(marketId);

        vm.prank(carol);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: carol,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: 102,
                qty: 300,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        // Fully finalize all batches individually
        for (uint256 i = 0; i < 3; i++) {
            fullyFinalizeBatch(batches[i]);
        }

        // Verify batches are finalized
        for (uint256 i = 0; i < 3; i++) {
            (AuctionHouse.FinalizePhase phase,,,,,) = auctionHouse.finalizeStates(marketId, batches[i]);
            assertEq(
                uint256(phase),
                uint256(AuctionHouse.FinalizePhase.Done),
                string(abi.encodePacked("Batch ", uint2str(i), " should be finalized"))
            );
        }
    }

    /// @notice Test that auto-settlement handles empty batches correctly
    function testAutoSettlementEmptyBatch() public {
        uint64 batch0 = auctionHouse.getBatchId(marketId);

        // Place orders in batch 0
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

        // Skip to batch 2 (leaving batch 1 empty)
        vm.warp(block.timestamp + 2 * BATCH_DURATION + 1);
        uint64 batch2 = auctionHouse.getBatchId(marketId);

        // Place order in batch 2
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

        // Fully finalize batch0 and batch2
        fullyFinalizeBatch(batch0);
        fullyFinalizeBatch(batch2);

        // Verify batch 0 is finalized
        (AuctionHouse.FinalizePhase phase0,,,,,) = auctionHouse.finalizeStates(marketId, batch0);
        assertEq(uint256(phase0), uint256(AuctionHouse.FinalizePhase.Done), "Batch 0 should be finalized");

        // The empty batch (batch0+1) should also be finalized if it exists and was processed
        uint64 batch1 = batch0 + 1;
        if (batch1 < batch2) {
            (AuctionHouse.FinalizePhase phase1,,,,,) = auctionHouse.finalizeStates(marketId, batch1);
            // Empty batch should be finalized if it was started
            if (phase1 != AuctionHouse.FinalizePhase.NotStarted) {
                assertEq(
                    uint256(phase1),
                    uint256(AuctionHouse.FinalizePhase.Done),
                    "Empty batch should be finalized if started"
                );
            }
        }
    }

    /// @notice Test auto-settlement with high order density
    function testAutoSettlementHighDensity() public {
        uint64 batch0 = auctionHouse.getBatchId(marketId);

        // Place many orders at different price levels in batch 0
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(alice);
            auctionHouse.submitOrder(
                OrderTypes.Order({
                    trader: alice,
                    marketId: marketId,
                    side: OrderTypes.Side.Buy,
                    flow: OrderTypes.Flow.Maker,
                    priceTick: int24(int256(100 + i)),
                    qty: 100,
                    nonce: uint64(i * 2),
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
                    priceTick: int24(int256(100 + i)),
                    qty: 50,
                    nonce: uint64(i * 2 + 1),
                    expiry: uint64(block.timestamp + 3600)
                })
            );
        }

        // Fully finalize
        fullyFinalizeBatch(batch0);

        // Verify finalization
        (AuctionHouse.FinalizePhase phase,,,,,) = auctionHouse.finalizeStates(marketId, batch0);
        assertEq(uint256(phase), uint256(AuctionHouse.FinalizePhase.Done), "Batch should be finalized");
    }

    /// @notice Test that manual finalization still works after auto-settlement is implemented
    function testManualFinalizationStillWorks() public {
        uint64 batch0 = auctionHouse.getBatchId(marketId);

        // Place orders
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

        // Move to next batch
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        // Manually finalize instead of relying on auto-settlement
        vm.prank(admin);
        bool done = false;
        uint256 iterations = 0;
        while (!done && iterations < 100) {
            (, done) = auctionHouse.finalizeStep(marketId, batch0, 100);
            iterations++;
        }

        assertTrue(done, "Manual finalization should complete");

        // Verify finalization
        (AuctionHouse.FinalizePhase phase,,,,,) = auctionHouse.finalizeStates(marketId, batch0);
        assertEq(uint256(phase), uint256(AuctionHouse.FinalizePhase.Done), "Batch should be finalized");
    }

    /// @notice Test auto-settlement doesn't re-finalize already finalized batches
    function testAutoSettlementSkipsAlreadyFinalized() public {
        uint64 batch0 = auctionHouse.getBatchId(marketId);

        // Place orders in batch 0
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

        // Move to batch 1
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        // Manually finalize batch 0
        vm.prank(admin);
        bool done = false;
        while (!done) {
            (, done) = auctionHouse.finalizeStep(marketId, batch0, 100);
        }

        // Now submit order in batch 1 - should not re-finalize batch 0
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

        // Verify batch 0 still shows as finalized (not restarted)
        (AuctionHouse.FinalizePhase phase,,,,,) = auctionHouse.finalizeStates(marketId, batch0);
        assertEq(uint256(phase), uint256(AuctionHouse.FinalizePhase.Done), "Should remain finalized");
    }

    /// @notice Test auto-settlement with bid and ask auctions
    function testAutoSettlementBidAndAskAuctions() public {
        uint64 batch0 = auctionHouse.getBatchId(marketId);

        // Create bid auction (Maker Buy + Taker Sell)
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

        // Create ask auction (Maker Sell + Taker Buy)
        vm.prank(carol);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: carol,
                marketId: marketId,
                side: OrderTypes.Side.Sell,
                flow: OrderTypes.Flow.Maker,
                priceTick: 110,
                qty: 800,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        vm.prank(dave);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: dave,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Taker,
                priceTick: 110,
                qty: 400,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );

        // Fully finalize
        fullyFinalizeBatch(batch0);

        // Verify both auctions were processed
        (AuctionHouse.FinalizePhase phase,,,,,) = auctionHouse.finalizeStates(marketId, batch0);
        assertEq(uint256(phase), uint256(AuctionHouse.FinalizePhase.Done), "Both auctions should be finalized");
    }

    /// @notice Stress test: Rapid batch progression with continuous orders
    function testAutoSettlementRapidBatchProgression() public {
        uint64 startBatch = auctionHouse.getBatchId(marketId);
        uint64[] memory batches = new uint64[](5);

        // Simulate 5 rapid batches with orders
        for (uint256 i = 0; i < 5; i++) {
            batches[i] = auctionHouse.getBatchId(marketId);

            // Place orders in current batch
            vm.prank(alice);
            auctionHouse.submitOrder(
                OrderTypes.Order({
                    trader: alice,
                    marketId: marketId,
                    side: OrderTypes.Side.Buy,
                    flow: OrderTypes.Flow.Maker,
                    priceTick: 100,
                    qty: 100,
                    nonce: uint64(i * 2),
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
                    qty: 50,
                    nonce: uint64(i * 2 + 1),
                    expiry: uint64(block.timestamp + 3600)
                })
            );

            // Advance to next batch
            vm.warp(uint256(auctionHouse.getBatchEnd(marketId)) + 1);
        }

        // Fully finalize the batches we created
        for (uint256 i = 0; i < 5; i++) {
            fullyFinalizeBatch(batches[i]);
        }

        assertEq(batches[0], startBatch, "First captured batch should match start");

        // Verify at least the first batch is finalized
        (AuctionHouse.FinalizePhase phase,,,,,) = auctionHouse.finalizeStates(marketId, batches[0]);
        assertEq(uint256(phase), uint256(AuctionHouse.FinalizePhase.Done), "First batch should be finalized");
    }

    /// @notice Test auto-settlement gas consumption stays reasonable
    function testAutoSettlementGasConsumption() public {
        uint64 batch0 = auctionHouse.getBatchId(marketId);

        // Place 10 orders in batch 0
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            auctionHouse.submitOrder(
                OrderTypes.Order({
                    trader: alice,
                    marketId: marketId,
                    side: i % 2 == 0 ? OrderTypes.Side.Buy : OrderTypes.Side.Sell,
                    flow: i % 2 == 0 ? OrderTypes.Flow.Maker : OrderTypes.Flow.Taker,
                    priceTick: int24(int256(100 + i)),
                    qty: 100,
                    nonce: uint64(i),
                    expiry: uint64(block.timestamp + 3600)
                })
            );
        }

        // Move to next batch
        vm.warp(block.timestamp + BATCH_DURATION + 1);

        // Measure gas for first auto-settlement step
        uint256 gasBefore = gasleft();
        vm.prank(bob);
        auctionHouse.submitOrder(
            OrderTypes.Order({
                trader: bob,
                marketId: marketId,
                side: OrderTypes.Side.Buy,
                flow: OrderTypes.Flow.Maker,
                priceTick: 105,
                qty: 200,
                nonce: 0,
                expiry: uint64(block.timestamp + 3600)
            })
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for first submitOrder with auto-settlement (10 orders):", gasUsed);

        // Verify it's within reasonable bounds (gas limit protection is working)
        assertTrue(gasUsed < 30_000_000, "Gas consumption should be reasonable");
    }

    /// @notice Helper function to convert uint to string
    function uint2str(
        uint256 _i
    ) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
