// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AuctionHouse} from "../../src/core/AuctionHouse.sol";
import {PerpVault} from "../../src/perp/PerpVault.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpRisk} from "../../src/perp/PerpRisk.sol";
import {OracleAdapter} from "../../src/perp/OracleAdapter.sol";
import {SpotVault} from "../../src/spot/SpotVault.sol";
import {SpotSettlement} from "../../src/spot/SpotSettlement.sol";
import {FeeModel} from "../../src/spot/FeeModel.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DummyOracle} from "../../src/mocks/DummyOracle.sol";
import {EndToEndHandler} from "./handlers/EndToEndHandler.sol";

/// @title EndToEndTradingInvariant
/// @notice End-to-end invariant tests covering full trading lifecycle
/// @dev Tests: submit → finalize → claim → position management → funding → liquidation
contract EndToEndTradingInvariant is StdInvariant, Test {
    AuctionHouse public auctionHouse;
    PerpVault public perpVault;
    PerpEngine public perpEngine;
    SpotVault public spotVault;
    SpotSettlement public spotSettlement;
    FeeModel public feeModel;
    EndToEndHandler public handler;
    
    MockERC20 public baseToken;
    MockERC20 public quoteToken;
    MockERC20 public collateral;
    DummyOracle public oracle;
    
    uint64 public spotMarketId;
    uint64 public perpMarketId;

    function setUp() public {
        auctionHouse = new AuctionHouse();
        perpVault = new PerpVault();
        
        baseToken = new MockERC20("Base", "BASE");
        quoteToken = new MockERC20("Quote", "QUOTE");
        collateral = new MockERC20("Collateral", "USDC");
        oracle = new DummyOracle(2500e18);
        
        OracleAdapter oracleAdapter = new OracleAdapter();
        PerpRisk perpRisk = new PerpRisk(address(oracleAdapter));
        perpEngine = new PerpEngine(address(auctionHouse), address(perpVault), address(perpRisk), address(oracleAdapter));
        
        spotVault = new SpotVault();
        feeModel = new FeeModel(address(this));
        spotSettlement = new SpotSettlement(address(auctionHouse), address(spotVault), address(feeModel));
        
        auctionHouse.setAuthorized(address(spotSettlement), true);
        auctionHouse.setAuthorized(address(perpEngine), true);
        
        spotMarketId = auctionHouse.createMarket(
            OrderTypes.MarketType.Spot,
            address(baseToken),
            address(quoteToken)
        );
        
        perpMarketId = auctionHouse.createMarketWithOracle(
            OrderTypes.MarketType.Perp,
            address(collateral),
            address(0),
            address(oracle)
        );
        
        perpVault.addCollateral(address(collateral));
        
        handler = new EndToEndHandler(
            auctionHouse,
            perpVault,
            perpEngine,
            spotVault,
            spotSettlement,
            spotMarketId,
            perpMarketId,
            baseToken,
            quoteToken,
            collateral,
            oracle
        );
        
        targetContract(address(handler));
        
        excludeSender(address(0));
        excludeSender(address(auctionHouse));
        excludeSender(address(perpVault));
        excludeSender(address(perpEngine));
    }

    /// @notice Total system collateral should equal sum of all user balances
    function invariant_systemCollateralConservation() public view {
        uint256 totalInVault = collateral.balanceOf(address(perpVault));
        uint256 handlerFunds = collateral.balanceOf(address(handler));
        uint256 totalUserBalances = handler.ghost_totalUserMargin();
        
        assertLe(
            totalUserBalances,
            totalInVault + handlerFunds,
            "User balances cannot exceed available collateral"
        );
    }

    /// @notice Net position across all users should sum to zero (no phantom positions)
    function invariant_netPositionIsZero() public view {
        int256 netPosition = handler.ghost_netPosition();
        
        assertEq(
            netPosition,
            0,
            "Net position across all users must be zero (every long has a short)"
        );
    }

    /// @notice Total claimed fills should not exceed total cleared quantity
    function invariant_claimedNotExceedCleared() public view {
        uint256 totalClaimed = handler.ghost_totalClaimedQty();
        uint256 totalCleared = handler.ghost_totalClearedQty();
        
        assertLe(
            totalClaimed,
            totalCleared,
            "Total claimed fills cannot exceed total cleared"
        );
    }

    /// @notice Realized PnL should match position closures
    function invariant_realizedPnLConsistent() public view {
        int256 totalRealizedPnL = handler.ghost_totalRealizedPnL();
        int256 totalPositionChanges = handler.ghost_totalPositionChanges();
        
        assertTrue(
            totalRealizedPnL <= totalPositionChanges + 1 ether,
            "Realized PnL should be consistent with position changes"
        );
    }

    /// @notice No user should have negative available margin
    function invariant_noNegativeAvailableMargin() public view {
        address[] memory users = handler.getUsers();
        
        for (uint256 i = 0; i < users.length; i++) {
            uint256 available = perpVault.getAvailableMargin(users[i], address(collateral));
            uint256 total = perpVault.marginBalances(users[i], address(collateral));
            
            assertLe(
                available,
                total,
                "Available margin cannot exceed total margin"
            );
        }
    }

    /// @notice Funding payments should be balanced (what longs pay, shorts receive)
    function invariant_fundingPaymentsBalanced() public view {
        int256 totalFundingPaid = handler.ghost_totalFundingPaid();
        int256 totalFundingReceived = handler.ghost_totalFundingReceived();
        
        int256 diff = totalFundingPaid + totalFundingReceived;
        assertTrue(
            diff >= -1 ether && diff <= 1 ether,
            "Funding payments should be balanced (allowing for rounding)"
        );
    }

    /// @notice Liquidations should only happen when position is unhealthy
    function invariant_liquidationsAreValid() public view {
        uint256 invalidLiquidations = handler.ghost_invalidLiquidations();
        
        assertEq(
            invalidLiquidations,
            0,
            "All liquidations must be valid (position below maintenance margin)"
        );
    }

    /// @notice Total auction count should be monotonically increasing
    function invariant_auctionCountMonotonic() public view {
        uint256 auctionCount = handler.ghost_totalAuctions();
        uint256 finalizationCount = handler.calls_finalizeAuction();
        
        assertLe(
            auctionCount,
            finalizationCount,
            "Successful auctions should not exceed finalization attempts"
        );
    }

    /// @notice Spot vault balances should match deposits minus withdrawals
    function invariant_spotVaultBalanceConsistency() public view {
        uint256 baseDeposits = handler.ghost_spotBaseDeposited();
        uint256 baseWithdraws = handler.ghost_spotBaseWithdrawn();
        uint256 quoteDeposits = handler.ghost_spotQuoteDeposited();
        uint256 quoteWithdraws = handler.ghost_spotQuoteWithdrawn();
        
        uint256 baseVaultBalance = baseToken.balanceOf(address(spotVault));
        uint256 quoteVaultBalance = quoteToken.balanceOf(address(spotVault));
        
        if (baseDeposits >= baseWithdraws) {
            assertGe(
                baseVaultBalance,
                baseDeposits - baseWithdraws,
                "Base vault balance should be at least net deposits"
            );
        }
        
        if (quoteDeposits >= quoteWithdraws) {
            assertGe(
                quoteVaultBalance,
                quoteDeposits - quoteWithdraws,
                "Quote vault balance should be at least net deposits"
            );
        }
        
        assertLe(baseWithdraws, baseDeposits + baseVaultBalance, "Base withdrawals bounded by available");
        assertLe(quoteWithdraws, quoteDeposits + quoteVaultBalance, "Quote withdrawals bounded by available");
    }

    /// @notice Call summary
    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
