// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";

/**
 * @title Keeper
 * @notice Automated keeper that monitors and finalizes batches when ready
 * @dev In production, this would run as a continuous service (keeper bot)
 */
contract Keeper is Script {
    function run() external {
        uint256 keeperKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address auctionHouseAddr =
            vm.envOr("AUCTION_HOUSE_ADDRESS", address(0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0));

        AuctionHouse auctionHouse = AuctionHouse(auctionHouseAddr);

        console.log("=== KEEPER SERVICE ===");
        console.log("AuctionHouse:", auctionHouseAddr);
        console.log("Block time:", block.timestamp);

        // Check both markets
        checkAndFinalize(auctionHouse, 1, "SPOT", keeperKey);
        checkAndFinalize(auctionHouse, 2, "PERP", keeperKey);
    }

    function checkAndFinalize(
        AuctionHouse auctionHouse,
        uint64 marketId,
        string memory marketName,
        uint256 keeperKey
    ) internal {
        uint64 currentBatchId = auctionHouse.getBatchId(marketId);
        uint64 batchEnd = auctionHouse.getBatchEnd(marketId);

        console.log("\n===", marketName, "MARKET ===");
        console.log("Current batch:", currentBatchId);
        console.log("Batch ends:", batchEnd);
        console.log("Time now:", block.timestamp);

        // Check if previous batch needs finalization
        if (currentBatchId > 0 && block.timestamp >= batchEnd - 1) {
            uint64 batchToFinalize = currentBatchId - 1;

            console.log("Batch", batchToFinalize, "is ready for finalization");

            vm.startBroadcast(keeperKey);

            bool done = false;
            uint256 iterations = 0;
            uint256 maxIterations = 100;

            while (!done && iterations < maxIterations) {
                try auctionHouse.finalizeStep(marketId, batchToFinalize, 100) returns (
                    AuctionHouse.FinalizePhase phase, bool batchDone
                ) {
                    done = batchDone;
                    iterations++;

                    if (iterations == 1 || iterations % 10 == 0 || done) {
                        console.log("  Iteration:", iterations);
                    }
                } catch Error(string memory reason) {
                    console.log("  Already finalized or error:", reason);
                    break;
                } catch {
                    console.log("  Batch already finalized");
                    break;
                }
            }

            vm.stopBroadcast();

            if (done) {
                console.log("Finalized batch");
                console.log("Batch ID:", batchToFinalize);
                console.log("Iterations:", iterations);
            }
        } else {
            console.log("No batch ready for finalization");
            if (block.timestamp < batchEnd) {
                uint256 timeLeft = batchEnd - block.timestamp;
                console.log("Current batch ends in seconds:", timeLeft);
            }
        }
    }
}
