// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/core/AuctionHouse.sol";
import "../src/perp/PerpEngine.sol";
import "../src/perp/PerpVault.sol";
import "../src/perp/PerpRisk.sol";
import "../src/perp/OracleAdapter.sol";
import "../src/spot/SpotSettlement.sol";
import "../src/spot/SpotVault.sol";
import "../src/spot/FeeModel.sol";
import "../src/libraries/OrderTypes.sol";
import "../test/mocks/MockERC20.sol";
import "../src/mocks/DummyOracle.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock USDC and WETH
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH");
        console.log("USDC deployed at:", address(usdc));
        console.log("WETH deployed at:", address(weth));

        // Deploy oracle with initial price of $2000
        DummyOracle oracle = new DummyOracle(2000 * 1e8); // 8 decimals for USD
        console.log("Oracle deployed at:", address(oracle));
        
        // Deploy OracleAdapter
        OracleAdapter oracleAdapter = new OracleAdapter();
        console.log("OracleAdapter deployed at:", address(oracleAdapter));
        
        // Set oracle for market 0 (will be perp market)
        oracleAdapter.setOracle(0, address(oracle));
        console.log("Set oracle for market 0");

        // Deploy AuctionHouse (no constructor params)
        AuctionHouse auctionHouse = new AuctionHouse();
        console.log("AuctionHouse deployed at:", address(auctionHouse));

        // Deploy PerpVault (no constructor params)
        PerpVault perpVault = new PerpVault();
        console.log("PerpVault deployed at:", address(perpVault));
        
        // Deploy PerpRisk
        PerpRisk perpRisk = new PerpRisk(address(oracleAdapter));
        console.log("PerpRisk deployed at:", address(perpRisk));

        // Deploy PerpEngine (needs auctionHouse, vault, risk, oracle)
        PerpEngine perpEngine = new PerpEngine(
            address(auctionHouse),
            address(perpVault),
            address(perpRisk),
            address(oracleAdapter)
        );
        console.log("PerpEngine deployed at:", address(perpEngine));
        
        // Deploy SpotVault (no constructor params)
        SpotVault spotVault = new SpotVault();
        console.log("SpotVault deployed at:", address(spotVault));
        
        // Deploy FeeModel
        FeeModel feeModel = new FeeModel(msg.sender); // deployer as fee recipient
        console.log("FeeModel deployed at:", address(feeModel));

        // Deploy SpotSettlement (needs auctionHouse, vault, feeModel)
        SpotSettlement spotSettlement = new SpotSettlement(
            address(auctionHouse),
            address(spotVault),
            address(feeModel)
        );
        console.log("SpotSettlement deployed at:", address(spotSettlement));

        // Authorize contracts
        perpVault.setAuthorized(address(perpEngine), true);
        spotVault.setAuthorized(address(spotSettlement), true);
        console.log("Authorized PerpEngine and SpotSettlement");

        // Create markets
        auctionHouse.createMarketWithOracle(
            OrderTypes.MarketType.Perp,
            address(weth),
            address(usdc),
            address(oracleAdapter)
        );
        console.log("Created WETH-USDC perp market (ID: 0)");
        
        auctionHouse.createMarket(
            OrderTypes.MarketType.Spot,
            address(weth),
            address(usdc)
        );
        console.log("Created WETH-USDC spot market (ID: 1)");
        
        // Add collateral to vaults
        perpVault.addCollateral(address(usdc));
        console.log("Added USDC as collateral to PerpVault");

        // Set risk params for perp market
        perpRisk.setRiskParams(0, PerpRisk.RiskParams({
            initialMarginBps: 1000,      // 10%
            maintenanceMarginBps: 500,   // 5%
            liquidationFeeBps: 100,      // 1%
            maxLeverage: 10,
            maxPositionSize: 1000 ether
        }));
        console.log("Set risk params for perp market");
        
        // Set oracle price (e.g., ETH = $2000)
        oracle.updatePrice(2000 * 1e18);
        console.log("Set ETH price to $2000");

        // Mint tokens to deployer for testing (1M USDC, 100 WETH)
        usdc.mint(msg.sender, 1_000_000 * 1e6);
        weth.mint(msg.sender, 100 ether);
        console.log("Minted tokens to deployer:", msg.sender);

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("USDC:", address(usdc));
        console.log("WETH:", address(weth));
        console.log("Oracle:", address(oracle));
        console.log("OracleAdapter:", address(oracleAdapter));
        console.log("AuctionHouse:", address(auctionHouse));
        console.log("PerpEngine:", address(perpEngine));
        console.log("PerpVault:", address(perpVault));
        console.log("PerpRisk:", address(perpRisk));
        console.log("SpotSettlement:", address(spotSettlement));
        console.log("SpotVault:", address(spotVault));
        console.log("FeeModel:", address(feeModel));
    }
}
