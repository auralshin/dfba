// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20Mintable {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title ContinuousTrading
 * @notice Script for continuous testing of all protocol flows
 * @dev Performs all trading flows: spot maker/taker, perp maker/taker, finalization
 */
contract ContinuousTrading is Script {
    // Contract addresses from environment
    address auctionHouseAddr = vm.envAddress("AUCTION_HOUSE_ADDRESS");
    address usdcAddr = vm.envAddress("USDC_ADDRESS");
    address wethAddr = vm.envAddress("WETH_ADDRESS");
    address spotRouterAddr = vm.envAddress("SPOT_ROUTER_ADDRESS");
    address perpRouterAddr = vm.envAddress("PERP_ROUTER_ADDRESS");
    
    // Market IDs
    uint64 spotMarketId = 1;
    uint64 perpMarketId = 2;
    
    // Use deployer key from environment for all traders (Arbitrum Sepolia)
    uint256 deployerKey = vm.envUint("PRIVATE_KEY");
    
    AuctionHouse auctionHouse;
    IERC20Mintable usdc;
    IERC20Mintable weth;
    
    uint128 nonce1 = 1;
    uint128 nonce2 = 1;
    uint128 nonce3 = 1;
    
    function run() external {
        auctionHouse = AuctionHouse(auctionHouseAddr);
        usdc = IERC20Mintable(usdcAddr);
        weth = IERC20Mintable(wethAddr);
        
        console2.log("=== CONTINUOUS TRADING CYCLE START ===\n");
        
        // Use same trader for all orders on testnet
        address trader = vm.addr(deployerKey);
        
        // Skip setup for testnet, just place orders
        console2.log("Trader:", trader);
        
        // Step 2: Place diverse orders on spot market
        placeSpotOrders();
        
        // Step 3: Place diverse orders on perp market
        placePerpOrders();
        
        // Step 4: Wait for batch to complete (simulated)
        console2.log("\n=== WAITING FOR BATCH TO COMPLETE ===");
        console2.log("Batch duration: 1 second");
        console2.log("Current time:", block.timestamp);
        console2.log("Spot batch ends:", auctionHouse.getBatchEnd(spotMarketId));
        console2.log("Perp batch ends:", auctionHouse.getBatchEnd(perpMarketId));
        
        // Step 5: Finalize spot market batch
        finalizeMarket(spotMarketId, "SPOT");
        
        // Step 6: Finalize perp market batch
        finalizeMarket(perpMarketId, "PERP");
        
        console2.log("\n=== CONTINUOUS TRADING CYCLE COMPLETE ===");
        console2.log("Run this script again to continue trading!");
    }
    
    function setupTraders() internal {
        console2.log("=== SETTING UP TRADERS ===\n");
        
        address trader1 = vm.addr(deployerKey);
        address trader2 = vm.addr(deployerKey);
        address trader3 = vm.addr(deployerKey);
        
        // Grant router roles to traders
        bytes32 ROUTER_ROLE = keccak256("ROUTER_ROLE");
        vm.startBroadcast(deployerKey);
        
        if (!auctionHouse.hasRole(ROUTER_ROLE, trader1)) {
            auctionHouse.grantRouterRole(trader1);
            console2.log("Granted ROUTER_ROLE to trader1:", trader1);
        }
        if (!auctionHouse.hasRole(ROUTER_ROLE, trader2)) {
            auctionHouse.grantRouterRole(trader2);
            console2.log("Granted ROUTER_ROLE to trader2:", trader2);
        }
        if (!auctionHouse.hasRole(ROUTER_ROLE, trader3)) {
            auctionHouse.grantRouterRole(trader3);
            console2.log("Granted ROUTER_ROLE to trader3:", trader3);
        }
        
        vm.stopBroadcast();
        
        // Setup each trader
        setupTrader(trader1, deployerKey, "Trader 1");
        setupTrader(trader2, deployerKey, "Trader 2");
        setupTrader(trader3, deployerKey, "Trader 3");
        
        console2.log("");
    }
    
    function setupTrader(address trader, uint256 traderKey, string memory name) internal {
        vm.startBroadcast(traderKey);
        
        // Mint tokens if needed
        if (usdc.balanceOf(trader) < 10_000 * 10**18) {
            usdc.mint(trader, 100_000 * 10**18);
        }
        if (weth.balanceOf(trader) < 10 * 10**18) {
            weth.mint(trader, 50 * 10**18);
        }
        
        // Approve routers
        if (usdc.allowance(trader, spotRouterAddr) < 1000 * 10**18) {
            usdc.approve(spotRouterAddr, type(uint256).max);
            usdc.approve(perpRouterAddr, type(uint256).max);
        }
        if (weth.allowance(trader, spotRouterAddr) < 10 * 10**18) {
            weth.approve(spotRouterAddr, type(uint256).max);
            weth.approve(perpRouterAddr, type(uint256).max);
        }
        
        console2.log(name, "setup complete");
        console2.log("  Address:", trader);
        console2.log("  USDC:", usdc.balanceOf(trader) / 10**18);
        console2.log("  WETH:", weth.balanceOf(trader) / 10**18);
        
        vm.stopBroadcast();
    }
    
    function placeSpotOrders() internal {
        console2.log("\n=== PLACING SPOT MARKET ORDERS ===\n");
        
        address trader = vm.addr(deployerKey);
        
        // Place orders as single trader
        vm.startBroadcast(deployerKey);
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Maker,
            priceTick: 2995, qty: 3 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Maker,
            priceTick: 2998, qty: 2 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Maker,
            priceTick: 2992, qty: 4 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Maker,
            priceTick: 3000, qty: 5 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        console2.log("4 SPOT Maker Buys placed");
        
        // Maker Sells (creating ask ladder)
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Maker,
            priceTick: 3005, qty: 5 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Maker,
            priceTick: 3008, qty: 3 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Maker,
            priceTick: 3012, qty: 2 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Maker,
            priceTick: 3002, qty: 4 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        console2.log("4 SPOT Maker Sells placed");
        
        // Taker orders (aggressive market orders)
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Taker,
            priceTick: 3010, qty: 4 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Taker,
            priceTick: 3015, qty: 2 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Taker,
            priceTick: 2990, qty: 3 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader, marketId: spotMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Taker,
            priceTick: 2985, qty: 1 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        console2.log("4 SPOT Taker orders placed");
        vm.stopBroadcast();
        
        console2.log("Total: 12 SPOT orders placed");
    }
    
    function placePerpOrders() internal {
        console2.log("\n=== PLACING PERP MARKET ORDERS ===\n");
        
        address trader1 = vm.addr(deployerKey);
        address trader2 = vm.addr(deployerKey);
        address trader3 = vm.addr(deployerKey);
        
        // Trader 1: Multiple Maker Longs (creating bid ladder)
        vm.startBroadcast(deployerKey);
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1, marketId: perpMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Maker,
            priceTick: 2990, qty: 2 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1, marketId: perpMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Maker,
            priceTick: 2995, qty: 3 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1, marketId: perpMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Maker,
            priceTick: 2988, qty: 1 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader1, marketId: perpMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Maker,
            priceTick: 2997, qty: 4 * 10**18, nonce: nonce1++, expiry: uint64(block.timestamp + 1 hours)
        }));
        console2.log("Trader1: 4 PERP Maker Longs");
        vm.stopBroadcast();
        
        // Trader 2: Multiple Maker Shorts (creating ask ladder)
        vm.startBroadcast(deployerKey);
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader2, marketId: perpMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Maker,
            priceTick: 3010, qty: 3 * 10**18, nonce: nonce2++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader2, marketId: perpMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Maker,
            priceTick: 3005, qty: 2 * 10**18, nonce: nonce2++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader2, marketId: perpMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Maker,
            priceTick: 3015, qty: 1 * 10**18, nonce: nonce2++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader2, marketId: perpMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Maker,
            priceTick: 3003, qty: 5 * 10**18, nonce: nonce2++, expiry: uint64(block.timestamp + 1 hours)
        }));
        console2.log("Trader2: 4 PERP Maker Shorts");
        vm.stopBroadcast();
        
        // Trader 3: Multiple Taker orders (aggressive)
        vm.startBroadcast(deployerKey);
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader3, marketId: perpMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Taker,
            priceTick: 3015, qty: 2 * 10**18, nonce: nonce3++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader3, marketId: perpMarketId, side: OrderTypes.Side.Buy, flow: OrderTypes.Flow.Taker,
            priceTick: 3020, qty: 3 * 10**18, nonce: nonce3++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader3, marketId: perpMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Taker,
            priceTick: 2985, qty: 1 * 10**18, nonce: nonce3++, expiry: uint64(block.timestamp + 1 hours)
        }));
        auctionHouse.submitOrder(OrderTypes.Order({
            trader: trader3, marketId: perpMarketId, side: OrderTypes.Side.Sell, flow: OrderTypes.Flow.Taker,
            priceTick: 2980, qty: 2 * 10**18, nonce: nonce3++, expiry: uint64(block.timestamp + 1 hours)
        }));
        console2.log("Trader3: 4 PERP Taker orders");
        vm.stopBroadcast();
        
        console2.log("Total: 12 PERP orders placed");
    }
    
    // Note: finalizeMarket function is now deprecated - DFBA uses auto-settlement
    // Batches are automatically finalized when new orders are submitted
    // Keeping this function for manual testing purposes only
    function finalizeMarket(uint64 marketId, string memory marketName) internal {
        console2.log("\n=== MANUAL FINALIZATION (DEPRECATED) ===");
        console2.log("Note: Auto-settlement handles this automatically on next order");
        console2.log("Market:", marketName);
        
        uint64 currentBatchId = auctionHouse.getBatchId(marketId);
        
        if (currentBatchId == 0) {
            console2.log("No batches to finalize yet");
            return;
        }
        
        uint64 batchToFinalize = currentBatchId > 0 ? currentBatchId - 1 : 0;
        console2.log("Finalizing batch:", batchToFinalize);
        console2.log("Current batch:", currentBatchId);
        
        vm.startBroadcast(deployerKey);
        
        bool done = false;
        uint256 iterations = 0;
        uint256 maxIterations = 100;
        
        while (!done && iterations < maxIterations) {
            try auctionHouse.finalizeStep(marketId, batchToFinalize, 100) returns (
                AuctionHouse.FinalizePhase phase,
                bool batchDone
            ) {
                done = batchDone;
                iterations++;
                
                if (iterations % 10 == 0 || done) {
                    console2.log("  Iteration:");
                    console2.log(iterations);
                }
                
                if (!done && iterations >= maxIterations) {
                    console2.log("  WARNING: Hit max iterations");
                    break;
                }
            } catch {
                console2.log("  Error during finalization");
                break;
            }
        }
        
        vm.stopBroadcast();
        
        if (done) {
            console2.log(marketName);
            console2.log("Batch finalized:");
            console2.log(batchToFinalize);
            console2.log("Iterations:");
            console2.log(iterations);
        } else {
            console2.log(marketName);
            console2.log("Finalization incomplete");
        }
    }
}
