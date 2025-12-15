// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DummyOracle} from "../../src/mocks/DummyOracle.sol";
import {AuctionHouse} from "../../src/core/AuctionHouse.sol";
import {PerpVault} from "../../src/perp/PerpVault.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract EnhancedFeaturesTest is Test {
    DummyOracle public btcOracle;
    DummyOracle public ethOracle;
    AuctionHouse public auctionHouse;
    PerpVault public perpVault;
    MockERC20 public usdc;
    MockERC20 public weth;
    
    address public admin = address(this);
    
    function setUp() public {
        // Deploy oracles with initial prices
        btcOracle = new DummyOracle(45000_00000000); // $45,000 (8 decimals)
        ethOracle = new DummyOracle(2500_00000000);  // $2,500 (8 decimals)
        
        // Deploy core contracts
        auctionHouse = new AuctionHouse();
        perpVault = new PerpVault();
        
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC");
        weth = new MockERC20("Wrapped Ether", "WETH");
    }
    
    function test_createMarketWithOracle() public {
        // Add USDC as collateral
        perpVault.addCollateral(address(usdc));
        
        // Create BTC perp market with oracle
        uint64 marketId = auctionHouse.createMarketWithOracle(
            OrderTypes.MarketType.Perp,
            address(usdc),
            address(0),
            address(btcOracle)
        );
        
        assertEq(marketId, 1, "Market ID should be 1");
        assertEq(auctionHouse.marketOracles(marketId), address(btcOracle), "Oracle should be set");
        
        // Verify market is active
        (,, address quote, bool active) = auctionHouse.markets(marketId);
        assertTrue(active, "Market should be active");
    }
    
    function test_pauseUnpauseMarket() public {
        // Create market
        uint64 marketId = auctionHouse.createMarket(
            OrderTypes.MarketType.Spot,
            address(weth),
            address(usdc)
        );
        
        // Verify initially active
        (,,, bool active) = auctionHouse.markets(marketId);
        assertTrue(active, "Market should be active initially");
        
        // Pause market
        auctionHouse.setMarketActive(marketId, false);
        
        // Verify paused
        (,,, active) = auctionHouse.markets(marketId);
        assertFalse(active, "Market should be paused");
        
        // Unpause market
        auctionHouse.setMarketActive(marketId, true);
        
        // Verify active again
        (,,, active) = auctionHouse.markets(marketId);
        assertTrue(active, "Market should be active again");
    }
    
    function test_updateOracle() public {
        // Create market with oracle
        perpVault.addCollateral(address(usdc));
        uint64 marketId = auctionHouse.createMarketWithOracle(
            OrderTypes.MarketType.Perp,
            address(usdc),
            address(0),
            address(btcOracle)
        );
        
        // Verify initial oracle
        assertEq(auctionHouse.marketOracles(marketId), address(btcOracle));
        
        // Update to ETH oracle
        auctionHouse.setMarketOracle(marketId, address(ethOracle));
        
        // Verify updated
        assertEq(auctionHouse.marketOracles(marketId), address(ethOracle));
    }
    
    function test_oraclePrice() public {
        // Check initial BTC price
        uint256 btcPrice = btcOracle.getPrice();
        assertEq(btcPrice, 45000_00000000, "BTC price should be $45,000");
        
        // Update price
        btcOracle.updatePrice(46000_00000000);
        
        // Verify updated price
        btcPrice = btcOracle.getPrice();
        assertEq(btcPrice, 46000_00000000, "BTC price should be $46,000");
        
        // Check timestamp updated
        assertEq(btcOracle.updatedAt(), block.timestamp);
    }
    
    function test_oracleLatestRoundData() public {
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 timestamp,
            uint80 answeredInRound
        ) = btcOracle.latestRoundData();
        
        assertEq(roundId, 1, "Round ID should be 1");
        assertEq(answer, 45000_00000000, "Answer should match price");
        assertEq(timestamp, block.timestamp, "Timestamp should be current");
    }
    
    function test_oracleStaleness() public {
        // Initially not stale
        assertFalse(btcOracle.isStale(1 hours), "Should not be stale initially");
        
        // Fast forward 2 hours
        vm.warp(block.timestamp + 2 hours);
        
        // Should be stale now
        assertTrue(btcOracle.isStale(1 hours), "Should be stale after 2 hours");
        
        // Update price
        btcOracle.updatePrice(47000_00000000);
        
        // Should not be stale anymore
        assertFalse(btcOracle.isStale(1 hours), "Should not be stale after update");
    }
    
    function test_removeCollateral() public {
        // Add collateral
        perpVault.addCollateral(address(usdc));
        assertTrue(perpVault.supportedCollateral(address(usdc)), "USDC should be supported");
        
        // Remove collateral
        perpVault.removeCollateral(address(usdc));
        assertFalse(perpVault.supportedCollateral(address(usdc)), "USDC should not be supported");
    }
    
    function test_tokenValidation_revertsZeroAddress() public {
        vm.expectRevert("AuctionHouse: zero base token");
        auctionHouse.createMarket(
            OrderTypes.MarketType.Spot,
            address(0),
            address(usdc)
        );
    }
    
    function test_tokenValidation_revertsNonContract() public {
        vm.expectRevert("AuctionHouse: base token not contract");
        auctionHouse.createMarket(
            OrderTypes.MarketType.Spot,
            address(0x123), // EOA, not contract
            address(usdc)
        );
    }
    
    function test_collateralValidation_revertsZeroAddress() public {
        vm.expectRevert("PerpVault: zero address");
        perpVault.addCollateral(address(0));
    }
    
    function test_collateralValidation_revertsNonContract() public {
        vm.expectRevert("PerpVault: token not contract");
        perpVault.addCollateral(address(0x456)); // EOA, not contract
    }
    
    function test_collateralValidation_revertsDuplicate() public {
        perpVault.addCollateral(address(usdc));
        
        vm.expectRevert("PerpVault: already supported");
        perpVault.addCollateral(address(usdc));
    }
}
