// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";

contract FinalizeBatch is Script {
    function run() external {
        // Use private key from environment or Anvil's default
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        
        // Get AuctionHouse address from environment or use default
        address auctionHouseAddr = vm.envOr("AUCTION_HOUSE_ADDRESS", address(0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0));
        AuctionHouse auctionHouse = AuctionHouse(auctionHouseAddr);
        
        console.log("Using AuctionHouse:", auctionHouseAddr);

        uint64 marketId = 1; // Spot market
        uint64 currentBatchId = auctionHouse.getBatchId(marketId);
        
        console.log("Current batch ID:", currentBatchId);
        
        // Finalize previous batch
        if (currentBatchId == 0) {
            console.log("No batches to finalize yet");
            return;
        }

        uint64 batchToFinalize = currentBatchId > 0 ? currentBatchId - 1 : 0;
        console.log("Finalizing batch:", batchToFinalize);

        vm.startBroadcast(deployerPrivateKey);

        // Run finalization in loop until done
        bool done = false;
        uint256 iterations = 0;
        uint256 maxIterations = 50;

        while (!done && iterations < maxIterations) {
            (AuctionHouse.FinalizePhase phase, bool batchDone) = auctionHouse.finalizeStep(
                marketId,
                batchToFinalize,
                100 // maxSteps per call
            );
            
            done = batchDone;
            iterations++;
            
            console.log("Finalize iteration", iterations);
            console.log("  Phase:", uint8(phase));
            console.log("  Done:", done);
            
            if (!done && iterations >= maxIterations) {
                console.log("WARNING: Hit max iterations");
                break;
            }
        }

        vm.stopBroadcast();

        if (done) {
            console.log("\n=== Batch", batchToFinalize, "finalized successfully ===");
            console.log("Iterations:", iterations);
            console.log("\nCheck order fills:");
            console.log("  forge script script/CheckOrders.s.sol --rpc-url http://localhost:8545");
        } else {
            console.log("\n=== Finalization incomplete ===");
            console.log("Run again to continue");
        }
    }
}
