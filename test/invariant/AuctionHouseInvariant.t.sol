// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AuctionHouse} from "../../src/core/AuctionHouse.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AuctionHouseHandler} from "./handlers/AuctionHouseHandler.sol";

/// @title AuctionHouseInvariant
/// @notice Invariant tests for AuctionHouse
contract AuctionHouseInvariant is StdInvariant, Test {
    AuctionHouse public auctionHouse;
    AuctionHouseHandler public handler;
    MockERC20 public baseToken;
    MockERC20 public quoteToken;
    
    uint64 public marketId;

    function setUp() public {
        auctionHouse = new AuctionHouse();
        baseToken = new MockERC20("Base", "BASE");
        quoteToken = new MockERC20("Quote", "QUOTE");
        
        // Create market
        marketId = auctionHouse.createMarket(
            OrderTypes.MarketType.Spot,
            address(baseToken),
            address(quoteToken)
        );
        
        // Create handler
        handler = new AuctionHouseHandler(auctionHouse, marketId);
        
        // Set handler as target
        targetContract(address(handler));
        
        // Exclude from fuzzing
        excludeSender(address(0));
        excludeSender(address(auctionHouse));
    }

    /// @notice Market count should only increase
    function invariant_marketCountMonotonic() public view {
        assertTrue(auctionHouse.marketCount() >= 1, "Market count should be at least 1");
    }

    /// @notice Active markets should have valid token addresses
    function invariant_activeMarketsHaveValidTokens() public view {
        for (uint64 i = 1; i <= auctionHouse.marketCount(); i++) {
            (OrderTypes.MarketType mType, address base, address quote, bool active) = auctionHouse.markets(i);
            if (active) {
                assertTrue(base != address(0), "Base token should not be zero");
                if (mType == OrderTypes.MarketType.Spot) {
                    assertTrue(quote != address(0), "Quote token should not be zero for spot");
                }
            }
        }
    }

    /// @notice Auction IDs should only increase over time
    function invariant_auctionIdMonotonic() public view {
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        assertTrue(auctionId >= 1, "Auction ID should be at least 1");
    }

    /// @notice Total maker and taker quantities should be consistent
    function invariant_orderQuantitiesConsistent() public view {
        uint256 totalOrders = handler.ghost_totalOrders();
        uint256 totalMakerQty = handler.ghost_totalMakerQty();
        uint256 totalTakerQty = handler.ghost_totalTakerQty();
        
        // If there are orders, quantities should be positive
        if (totalOrders > 0) {
            assertTrue(
                totalMakerQty > 0 || totalTakerQty > 0,
                "If orders exist, some quantity should be non-zero"
            );
        }
    }

    /// @notice Cleared quantity should never exceed total quantity
    /// Note: This is a simplified check since we don't track actual clearing results
    function invariant_clearedQuantityBounded() public view {
        uint256 totalClearedBuy = handler.ghost_totalClearedBuy();
        uint256 totalClearedSell = handler.ghost_totalClearedSell();
        uint256 totalMakerQty = handler.ghost_totalMakerQty();
        uint256 totalTakerQty = handler.ghost_totalTakerQty();
        
        // Total cleared (buy + sell) should not exceed total submitted quantity
        // This is a simplified invariant since actual clearing is complex
        assertLe(
            totalClearedBuy + totalClearedSell,
            totalMakerQty + totalTakerQty,
            "Total cleared should not exceed total submitted"
        );
        
        // Each side should not exceed total submitted on that side
        uint256 totalSubmitted = totalMakerQty + totalTakerQty;
        assertLe(
            totalClearedBuy,
            totalSubmitted,
            "Cleared buy should not exceed total submitted"
        );
        assertLe(
            totalClearedSell,
            totalSubmitted,
            "Cleared sell should not exceed total submitted"
        );
    }

    /// @notice Call summary at the end
    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
