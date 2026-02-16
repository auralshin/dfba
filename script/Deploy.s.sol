// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {SpotRouter} from "../src/core/SpotRouter.sol";
import {PerpRouter} from "../src/core/PerpRouter.sol";
import {CoreVault} from "../src/core/CoreVault.sol";
import {PerpRisk} from "../src/perp/PerpRisk.sol";
import {DummyOracle} from "../src/mocks/DummyOracle.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {MockERC20} from "../test/AuctionHouse.t.sol";

contract Deploy is Script {
    function run() external {
        // Use private key from environment or Anvil's default
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying with address:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock tokens (MockERC20 only takes 2 params)
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH");
        console.log("USDC deployed at:", address(usdc));
        console.log("WETH deployed at:", address(weth));

        // 2. Deploy AuctionHouse
        AuctionHouse auctionHouse = new AuctionHouse();
        console.log("AuctionHouse deployed at:", address(auctionHouse));

        // 3. Deploy CoreVault (needed for routers)
        CoreVault vault = new CoreVault();
        console.log("CoreVault deployed at:", address(vault));

        // 4. Deploy Oracle (for perp markets) - needs initial price
        DummyOracle oracle = new DummyOracle(3000e8); // $3000 for ETH/USD
        console.log("Oracle deployed at:", address(oracle));

        // 5. Deploy PerpRisk (needs oracle)
        PerpRisk perpRisk = new PerpRisk(address(oracle));
        console.log("PerpRisk deployed at:", address(perpRisk));

        // 6. Deploy Routers (need vault and auctionHouse)
        SpotRouter spotRouter = new SpotRouter(address(vault), address(auctionHouse));
        console.log("SpotRouter deployed at:", address(spotRouter));

        PerpRouter perpRouter = new PerpRouter(address(vault), address(auctionHouse), address(perpRisk));
        console.log("PerpRouter deployed at:", address(perpRouter));

        // 7. Grant ROUTER_ROLE to routers
        auctionHouse.grantRouterRole(address(spotRouter));
        auctionHouse.grantRouterRole(address(perpRouter));
        console.log("Router roles granted");

        // 8. Create a spot market (WETH/USDC)
        uint64 spotMarketId = auctionHouse.createMarket(
            OrderTypes.MarketType.Spot,
            address(weth),
            address(usdc)
        );
        console.log("Spot market created with ID:", spotMarketId);

        // 9. Create a perp market (ETH-PERP/USDC)
        uint64 perpMarketId = auctionHouse.createMarketWithOracle(
            OrderTypes.MarketType.Perp,
            address(weth),
            address(usdc),
            address(oracle)
        );
        console.log("Perp market created with ID:", perpMarketId);

        // 10. Mint tokens to deployer for testing
        usdc.mint(deployer, 1_000_000 * 10**18); // 1M USDC (MockERC20 has 18 decimals)
        weth.mint(deployer, 1000 * 10**18); // 1000 WETH
        console.log("Tokens minted to deployer");

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("AuctionHouse:", address(auctionHouse));
        console.log("CoreVault:", address(vault));
        console.log("SpotRouter:", address(spotRouter));
        console.log("PerpRouter:", address(perpRouter));
        console.log("PerpRisk:", address(perpRisk));
        console.log("USDC:", address(usdc));
        console.log("WETH:", address(weth));
        console.log("Oracle:", address(oracle));
        console.log("Spot Market ID:", spotMarketId);
        console.log("Perp Market ID:", perpMarketId);
        console.log("\n=== Copy to indexer/.env ===");
        console.log("AUCTION_HOUSE_ADDRESS=%s", address(auctionHouse));
    }
}
