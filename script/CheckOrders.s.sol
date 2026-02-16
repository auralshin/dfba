// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";

contract CheckOrders is Script {
    function run() external view {
        // Contract addresses
        address auctionHouseAddr = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
        AuctionHouse auctionHouse = AuctionHouse(auctionHouseAddr);

        // Order IDs from PlaceOrders script (you'll need to update these after running PlaceOrders)
        bytes32[] memory orderIds = new bytes32[](4);
        
        // These are example IDs - get real ones from PlaceOrders output
        // For demo purposes, we'll just check the last batch
        
        uint64 marketId = 1;
        uint64 currentBatchId = auctionHouse.getBatchId(marketId);
        
        console.log("Current batch ID:", currentBatchId);
        console.log("\n=== Market Info ===");
        
        (
            OrderTypes.MarketType marketType,
            address baseToken,
            address quoteToken,
            bool active
        ) = auctionHouse.markets(marketId);
        
        console.log("Market ID:", marketId);
        console.log("Type:", uint8(marketType) == 0 ? "Spot" : "Perp");
        console.log("Base Token:", baseToken);
        console.log("Quote Token:", quoteToken);
        console.log("Active:", active);
        
        console.log("\n=== Batch Info ===");
        uint64 batchEnd = auctionHouse.getBatchEnd(marketId);
        console.log("Batch ends at:", batchEnd);
        console.log("Current time:", block.timestamp);
        
        if (block.timestamp < batchEnd) {
            console.log("Status: ACCEPTING ORDERS");
            console.log("Time left:", batchEnd - block.timestamp, "seconds");
        } else {
            console.log("Status: READY TO FINALIZE");
        }
        
        console.log("\n=== Instructions ===");
        console.log("1. Place orders:");
        console.log("   forge script script/PlaceOrders.s.sol --broadcast --rpc-url http://localhost:8545");
        console.log("\n2. Wait 1 second for batch to end (BATCH_DURATION = 1s)");
        console.log("\n3. Finalize batch:");
        console.log("   forge script script/FinalizeBatch.s.sol --broadcast --rpc-url http://localhost:8545");
        console.log("\n4. Continuous trading:");
        console.log("   ./quick-trade-loop.sh");
        console.log("\n5. Check indexer:");
        console.log("   curl http://localhost:3001/stats");
        console.log("   curl http://localhost:3001/batches?marketId=1");
    }
}
