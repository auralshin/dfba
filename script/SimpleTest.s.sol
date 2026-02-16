// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract SimpleTest is Script {
    function run() external view {
        // Get addresses from environment
        address auctionHouseAddr = vm.envAddress("AUCTION_HOUSE_ADDRESS");
        address usdcAddr = vm.envAddress("USDC_ADDRESS");
        address wethAddr = vm.envAddress("WETH_ADDRESS");
        address trader = vm.addr(vm.envUint("PRIVATE_KEY"));
        
        AuctionHouse auctionHouse = AuctionHouse(auctionHouseAddr);
        IERC20 usdc = IERC20(usdcAddr);
        IERC20 weth = IERC20(wethAddr);
        
        console.log("=== Contract Status ===");
        console.log("AuctionHouse:", auctionHouseAddr);
        console.log("USDC:", usdcAddr);
        console.log("WETH:", wethAddr);
        console.log("Trader:", trader);
        console.log("");
        
        console.log("=== Balances ===");
        console.log("USDC balance:", usdc.balanceOf(trader));
        console.log("WETH balance:", weth.balanceOf(trader));
        console.log("");
        
        console.log("=== Markets ===");
        uint64 spotMarketId = 1;
        uint64 perpMarketId = 2;
        
        uint64 spotBatchId = auctionHouse.getBatchId(spotMarketId);
        uint64 perpBatchId = auctionHouse.getBatchId(perpMarketId);
        
        console.log("Spot Market (ID 1) - Current Batch:", spotBatchId);
        console.log("Perp Market (ID 2) - Current Batch:", perpBatchId);
        console.log("");
        
        console.log("=== Market Count ===");
        console.log("Total markets:", auctionHouse.marketCount());
    }
}
