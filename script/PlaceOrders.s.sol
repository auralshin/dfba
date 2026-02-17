// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {console2} from "forge-std/console2.sol";

// Simple ERC20 interface for minting
interface IERC20Mintable {
    function balanceOf(
        address account
    ) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
}

contract PlaceOrders is Script {
    function run() external {
        // Use deployer's private key from environment
        uint256 traderPrivateKey = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(traderPrivateKey);

        // Contract addresses from environment
        address auctionHouseAddr = vm.envAddress("AUCTION_HOUSE_ADDRESS");
        address usdcAddr = vm.envAddress("USDC_ADDRESS");
        address wethAddr = vm.envAddress("WETH_ADDRESS");
        address spotRouterAddr = vm.envAddress("SPOT_ROUTER_ADDRESS");

        AuctionHouse auctionHouse = AuctionHouse(auctionHouseAddr);
        IERC20Mintable usdc = IERC20Mintable(usdcAddr);
        IERC20Mintable weth = IERC20Mintable(wethAddr);

        console2.log("Trader:", trader);
        console2.log("USDC balance:", usdc.balanceOf(trader));
        console2.log("WETH balance:", weth.balanceOf(trader));

        vm.startBroadcast(traderPrivateKey);

        // 1. Mint tokens to trader if needed
        if (usdc.balanceOf(trader) == 0) {
            usdc.mint(trader, 100_000 * 10 ** 18); // 100k USDC
            console2.log("Minted 100k USDC to trader");
        }
        if (weth.balanceOf(trader) == 0) {
            weth.mint(trader, 50 * 10 ** 18); // 50 WETH
            console2.log("Minted 50 WETH to trader");
        }

        // 2. Approve AuctionHouse (via SpotRouter)
        if (usdc.allowance(trader, spotRouterAddr) == 0) {
            usdc.approve(spotRouterAddr, type(uint256).max);
            console2.log("Approved USDC");
        }
        if (weth.allowance(trader, spotRouterAddr) == 0) {
            weth.approve(spotRouterAddr, type(uint256).max);
            console2.log("Approved WETH");
        }

        // 3. Get current batch ID for each order submission
        uint64 marketId = 1; // Spot market

        // 4. Grant trader ROUTER_ROLE if not already granted
        vm.stopBroadcast();

        // Use deployer to grant role (skip if already has role)
        bytes32 ROUTER_ROLE = keccak256("ROUTER_ROLE");
        if (!auctionHouse.hasRole(ROUTER_ROLE, trader)) {
            uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
            vm.startBroadcast(deployerKey);
            auctionHouse.grantRouterRole(trader);
            console2.log("Granted ROUTER_ROLE to trader");
            vm.stopBroadcast();
        } else {
            console2.log("Trader already has ROUTER_ROLE");
        }

        // Back to trader
        vm.startBroadcast(traderPrivateKey);

        // 5. Place Maker Buy Order (bid at 3000)
        // Note: batchId is now automatically assigned by AuctionHouse based on block.timestamp
        OrderTypes.Order memory makerBuy = OrderTypes.Order({
            trader: trader,
            marketId: marketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 3000,
            qty: 5 * 10 ** 18, // Buy 5 WETH
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        (bytes32 orderId1, uint64 batchId1) = auctionHouse.submitOrder(makerBuy);
        console2.log("Maker Buy order submitted:");
        console2.log("  Order ID:", vm.toString(orderId1));
        console2.log("  Batch ID:", batchId1);
        console2.log("  Price: 3000");
        console2.log("  Qty: 5");

        // 6. Place Maker Sell Order (ask at 3010)
        OrderTypes.Order memory makerSell = OrderTypes.Order({
            trader: trader,
            marketId: marketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 3010,
            qty: 3 * 10 ** 18, // Sell 3 WETH
            nonce: 2,
            expiry: uint64(block.timestamp + 1 hours)
        });
        (bytes32 orderId2,) = auctionHouse.submitOrder(makerSell);
        console2.log("Maker Sell order submitted:");
        console2.log("  Order ID:", vm.toString(orderId2));
        console2.log("  Price: 3010");
        console2.log("  Qty: 3");

        // 7. Place Taker Buy Order (market buy)
        OrderTypes.Order memory takerBuy = OrderTypes.Order({
            trader: trader,
            marketId: marketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Taker,
            priceTick: 3020, // Max price willing to pay
            qty: 2 * 10 ** 18, // Buy 2 WETH
            nonce: 3,
            expiry: uint64(block.timestamp + 1 hours)
        });
        (bytes32 orderId3,) = auctionHouse.submitOrder(takerBuy);
        console2.log("Taker Buy order submitted:");
        console2.log("  Order ID:", vm.toString(orderId3));
        console2.log("  Price: 3020");
        console2.log("  Qty: 2");

        // 8. Place Taker Sell Order (market sell)
        OrderTypes.Order memory takerSell = OrderTypes.Order({
            trader: trader,
            marketId: marketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Taker,
            priceTick: 2990, // Min price willing to accept
            qty: 1 * 10 ** 18, // Sell 1 WETH
            nonce: 4,
            expiry: uint64(block.timestamp + 1 hours)
        });
        (bytes32 orderId4,) = auctionHouse.submitOrder(takerSell);
        console2.log("Taker Sell order submitted:");
        console2.log("  Order ID:", vm.toString(orderId4));
        console2.log("  Price: 2990");
        console2.log("  Qty: 1");

        vm.stopBroadcast();

        console2.log("\n=== Summary ===");
        console2.log("4 orders placed");
        console2.log("Wait 12+ seconds for batch to end, then finalize");
        console2.log("\nTo finalize, run:");
        console2.log("  forge script script/FinalizeBatch.s.sol --broadcast --rpc-url http://localhost:8545");
    }
}
