// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20Mintable {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
}

contract TestOrderMatching is Script {
    function run() external {
        // Load deployed addresses from environment
        address auctionHouseAddr = vm.envAddress("AUCTION_HOUSE_ADDRESS");
        address usdcAddr = vm.envAddress("USDC_ADDRESS");
        address wethAddr = vm.envAddress("WETH_ADDRESS");
        address spotRouterAddr = vm.envAddress("SPOT_ROUTER_ADDRESS");
        
        // Use deployer key from environment
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        
        AuctionHouse auctionHouse = AuctionHouse(auctionHouseAddr);
        IERC20Mintable usdc = IERC20Mintable(usdcAddr);
        IERC20Mintable weth = IERC20Mintable(wethAddr);
        
        uint64 spotMarketId = 1;
        
        console2.log("=== ORDER MATCHING TEST ===\n");
        console2.log("AuctionHouse:", auctionHouseAddr);
        console2.log("Deployer:", deployer);
        console2.log("USDC balance:", usdc.balanceOf(deployer));
        console2.log("WETH balance:", weth.balanceOf(deployer));
        
        // Get current batch info
        uint64 currentBatchId = auctionHouse.getBatchId(spotMarketId);
        uint64 batchEnd = auctionHouse.getBatchEnd(spotMarketId);
        
        console2.log("\nCurrent batch ID:", currentBatchId);
        console2.log("Batch ends at:", batchEnd);
        console2.log("Current time:", block.timestamp);
        
        vm.startBroadcast(deployerKey);
        
        // Grant router role if needed
        bytes32 ROUTER_ROLE = keccak256("ROUTER_ROLE");
        if (!auctionHouse.hasRole(ROUTER_ROLE, deployer)) {
            auctionHouse.grantRouterRole(deployer);
            console2.log("\nGranted ROUTER_ROLE to deployer");
        }
        
        // Approve tokens
        usdc.approve(spotRouterAddr, type(uint256).max);
        weth.approve(spotRouterAddr, type(uint256).max);
        console2.log("Tokens approved");
        
        console2.log("\n=== PLACING ORDERS ===\n");
        
        // Place Maker Buy (bid at 3000)
        OrderTypes.Order memory makerBuy = OrderTypes.Order({
            trader: deployer,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 3000,
            qty: 2 * 10**18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        (bytes32 orderId1, uint64 batchId1) = auctionHouse.submitOrder(makerBuy);
        console2.log("Order 1: Maker Buy @ 3000, qty=2");
        console2.log("  OrderID:", vm.toString(orderId1));
        console2.log("  BatchID:", batchId1);
        
        // Place Maker Sell (ask at 3005)
        OrderTypes.Order memory makerSell = OrderTypes.Order({
            trader: deployer,
            marketId: spotMarketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 3005,
            qty: 3 * 10**18,
            nonce: 2,
            expiry: uint64(block.timestamp + 1 hours)
        });
        (bytes32 orderId2, ) = auctionHouse.submitOrder(makerSell);
        console2.log("\nOrder 2: Maker Sell @ 3005, qty=3");
        console2.log("  OrderID:", vm.toString(orderId2));
        
        // Place Taker Buy (should match with makerSell)
        OrderTypes.Order memory takerBuy = OrderTypes.Order({
            trader: deployer,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker,
            priceTick: 3010,
            qty: 1 * 10**18,
            nonce: 3,
            expiry: uint64(block.timestamp + 1 hours)
        });
        (bytes32 orderId3, ) = auctionHouse.submitOrder(takerBuy);
        console2.log("\nOrder 3: Taker Buy @ 3010, qty=1 (should match with Order 2)");
        console2.log("  OrderID:", vm.toString(orderId3));
        
        vm.stopBroadcast();
        
        console2.log("\n=== NEXT STEPS ===");
        console2.log("1. Wait for batch to end (1 second on testnet)");
        console2.log("2. Run finalization:");
        console2.log("   source .env && forge script script/FinalizeBatch.s.sol --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY");
        console2.log("\n3. Check results:");
        console2.log("   source .env && forge script script/CheckMatches.s.sol --rpc-url $RPC_URL");
        console2.log("\nExpected outcome:");
        console2.log("- Order 3 (Taker Buy @ 3010) should match with Order 2 (Maker Sell @ 3005)");
        console2.log("- Clearing price should be around 3005");
        console2.log("- 1 WETH should be traded");
    }
}
