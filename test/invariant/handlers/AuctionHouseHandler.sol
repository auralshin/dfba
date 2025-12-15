// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";
import {AuctionHouse} from "../../../src/core/AuctionHouse.sol";
import {OrderTypes} from "../../../src/libraries/OrderTypes.sol";

/// @title AuctionHouseHandler
/// @notice Handler for invariant testing of AuctionHouse
contract AuctionHouseHandler is CommonBase, StdCheats, StdUtils {
    AuctionHouse public auctionHouse;
    uint64 public marketId;
    
    // Ghost variables for tracking
    uint256 public ghost_totalOrders;
    uint256 public ghost_totalMakerQty;
    uint256 public ghost_totalTakerQty;
    uint256 public ghost_totalMakerBuy;
    uint256 public ghost_totalMakerSell;
    uint256 public ghost_totalTakerBuy;
    uint256 public ghost_totalTakerSell;
    uint256 public ghost_totalClearedBuy;
    uint256 public ghost_totalClearedSell;
    uint256 public ghost_finalizations;
    
    // Call counters
    uint256 public calls_submitOrder;
    uint256 public calls_finalizeAuction;
    uint256 public calls_warpTime;
    
    // Order tracking
    mapping(bytes32 => bool) public submittedOrders;
    bytes32[] public orderIds;
    
    constructor(AuctionHouse _auctionHouse, uint64 _marketId) {
        auctionHouse = _auctionHouse;
        marketId = _marketId;
    }

    /// @notice Submit a random order
    function submitOrder(
        uint256 traderSeed,
        bool isBuy,
        bool isMaker,
        uint256 priceSeed,
        uint256 qtySeed,
        uint256 nonceSeed
    ) public {
        calls_submitOrder++;
        
        // Generate trader address
        address trader = address(uint160(bound(traderSeed, 1, 1000)));
        
        // Get current auction ID
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        
        // Bound price to reasonable range
        int24 priceTick = int24(int256(bound(priceSeed, 900, 1100)));
        
        // Bound quantity
        uint128 qty = uint128(bound(qtySeed, 1, 1000 ether));
        
        // Bound nonce
        uint128 nonce = uint128(bound(nonceSeed, 1, type(uint64).max));
        
        // Create order
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader,
            marketId: marketId,
            auctionId: auctionId,
            side: isBuy ? OrderTypes.Side.Buy : OrderTypes.Side.Sell,
            flow: isMaker ? OrderTypes.Flow.Maker : OrderTypes.Flow.Taker,
            priceTick: priceTick,
            qty: qty,
            nonce: nonce,
            expiry: 0
        });
        
        vm.prank(trader);
        try auctionHouse.submitOrder(order) returns (bytes32 orderId) {
            ghost_totalOrders++;
            submittedOrders[orderId] = true;
            orderIds.push(orderId);
            
            // Track quantities
            if (isMaker) {
                ghost_totalMakerQty += qty;
                if (isBuy) {
                    ghost_totalMakerBuy += qty;
                } else {
                    ghost_totalMakerSell += qty;
                }
            } else {
                ghost_totalTakerQty += qty;
                if (isBuy) {
                    ghost_totalTakerBuy += qty;
                } else {
                    ghost_totalTakerSell += qty;
                }
            }
        } catch {
            // Order submission failed, ignore
        }
    }

    /// @notice Finalize current auction
    function finalizeAuction() public {
        calls_finalizeAuction++;
        
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        
        // Warp time to end auction
        vm.warp(block.timestamp + auctionHouse.AUCTION_DURATION() + 1);
        
        try auctionHouse.finalizeAuction(marketId, auctionId) {
            ghost_finalizations++;
            
            // Get clearing results
            (OrderTypes.Clearing memory buyClearing, OrderTypes.Clearing memory sellClearing) = 
                auctionHouse.getClearing(marketId, auctionId);
            
            if (buyClearing.finalized) {
                ghost_totalClearedBuy += buyClearing.clearedQty;
            }
            if (sellClearing.finalized) {
                ghost_totalClearedSell += sellClearing.clearedQty;
            }
            
            // Reset auction quantities for next auction
            ghost_totalMakerBuy = 0;
            ghost_totalMakerSell = 0;
            ghost_totalTakerBuy = 0;
            ghost_totalTakerSell = 0;
        } catch {
            // Finalization failed, ignore
        }
    }

    /// @notice Warp time forward
    function warpTime(uint256 timeDelta) public {
        calls_warpTime++;
        uint256 timeToWarp = bound(timeDelta, 1, 100);
        vm.warp(block.timestamp + timeToWarp);
    }

    /// @notice Print call summary
    function callSummary() external view {
        console.log("\n=== Call Summary ===");
        console.log("submitOrder calls:", calls_submitOrder);
        console.log("finalizeAuction calls:", calls_finalizeAuction);
        console.log("warpTime calls:", calls_warpTime);
        console.log("\n=== Ghost Variables ===");
        console.log("Total orders:", ghost_totalOrders);
        console.log("Total maker qty:", ghost_totalMakerQty);
        console.log("Total taker qty:", ghost_totalTakerQty);
        console.log("Total cleared buy:", ghost_totalClearedBuy);
        console.log("Total cleared sell:", ghost_totalClearedSell);
        console.log("Total finalizations:", ghost_finalizations);
    }
}
