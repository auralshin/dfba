// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";
import {AuctionHouse} from "../../../src/core/AuctionHouse.sol";
import {PerpVault} from "../../../src/perp/PerpVault.sol";
import {PerpEngine} from "../../../src/perp/PerpEngine.sol";
import {SpotVault} from "../../../src/spot/SpotVault.sol";
import {SpotSettlement} from "../../../src/spot/SpotSettlement.sol";
import {OrderTypes} from "../../../src/libraries/OrderTypes.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {DummyOracle} from "../../../src/mocks/DummyOracle.sol";

/// @title EndToEndHandler
/// @notice Handler for end-to-end trading invariant tests
/// @dev Simulates full trading lifecycle: deposit → trade → finalize → claim → manage positions
contract EndToEndHandler is CommonBase, StdCheats, StdUtils {
    AuctionHouse public auctionHouse;
    PerpVault public perpVault;
    PerpEngine public perpEngine;
    SpotVault public spotVault;
    SpotSettlement public spotSettlement;
    
    uint64 public spotMarketId;
    uint64 public perpMarketId;
    
    MockERC20 public baseToken;
    MockERC20 public quoteToken;
    MockERC20 public collateral;
    DummyOracle public oracle;
    
    uint256 public constant INITIAL_BALANCE = 1_000_000 ether;
    
    address[] public users;
    mapping(address => bool) public isUser;
    mapping(address => int256) public userPositionSize;
    
    bytes32[] public pendingOrders;
    bytes32[] public claimedOrders;
    
    uint256 public ghost_totalUserMargin;
    int256 public ghost_netPosition;
    uint256 public ghost_totalClaimedQty;
    uint256 public ghost_totalClearedQty;
    int256 public ghost_totalRealizedPnL;
    int256 public ghost_totalPositionChanges;
    int256 public ghost_totalFundingPaid;
    int256 public ghost_totalFundingReceived;
    uint256 public ghost_invalidLiquidations;
    uint256 public ghost_totalAuctions;
    uint256 public ghost_spotBaseDeposited;
    uint256 public ghost_spotBaseWithdrawn;
    uint256 public ghost_spotQuoteDeposited;
    uint256 public ghost_spotQuoteWithdrawn;
    
    uint256 public calls_depositMargin;
    uint256 public calls_withdrawMargin;
    uint256 public calls_submitPerpOrder;
    uint256 public calls_submitSpotOrder;
    uint256 public calls_finalizeAuction;
    uint256 public calls_claimPerp;
    uint256 public calls_claimSpot;
    uint256 public calls_closePosition;
    uint256 public calls_applyFunding;
    uint256 public calls_liquidate;
    uint256 public calls_depositSpot;
    uint256 public calls_withdrawSpot;

    constructor(
        AuctionHouse _auctionHouse,
        PerpVault _perpVault,
        PerpEngine _perpEngine,
        SpotVault _spotVault,
        SpotSettlement _spotSettlement,
        uint64 _spotMarketId,
        uint64 _perpMarketId,
        MockERC20 _baseToken,
        MockERC20 _quoteToken,
        MockERC20 _collateral,
        DummyOracle _oracle
    ) {
        auctionHouse = _auctionHouse;
        perpVault = _perpVault;
        perpEngine = _perpEngine;
        spotVault = _spotVault;
        spotSettlement = _spotSettlement;
        spotMarketId = _spotMarketId;
        perpMarketId = _perpMarketId;
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        collateral = _collateral;
        oracle = _oracle;
        
        collateral.mint(address(this), INITIAL_BALANCE);
        baseToken.mint(address(this), INITIAL_BALANCE);
        quoteToken.mint(address(this), INITIAL_BALANCE);
    }

    function depositMargin(uint256 userSeed, uint256 amountSeed) public {
        calls_depositMargin++;
        
        address user = _getUser(userSeed);
        uint256 amount = bound(amountSeed, 1 ether, 10_000 ether);
        
        uint256 balance = collateral.balanceOf(address(this));
        if (balance < amount) return;
        
        collateral.approve(address(perpVault), amount);
        
        vm.prank(address(this));
        try perpVault.depositMargin(address(collateral), amount, user) {
            ghost_totalUserMargin += amount;
        } catch {}
    }

    function withdrawMargin(uint256 userSeed, uint256 amountSeed) public {
        calls_withdrawMargin++;
        
        address user = _getUser(userSeed);
        uint256 available = perpVault.getAvailableMargin(user, address(collateral));
        
        if (available == 0) return;
        
        uint256 amount = bound(amountSeed, 1, available);
        
        vm.prank(user);
        try perpVault.withdrawMargin(address(collateral), amount, user) {
            ghost_totalUserMargin -= amount;
        } catch {}
    }

    function submitPerpOrder(
        uint256 userSeed,
        bool isBuy,
        uint256 priceSeed,
        uint256 sizeSeed
    ) public {
        calls_submitPerpOrder++;
        
        address user = _getUser(userSeed);
        uint64 auctionId = auctionHouse.getAuctionId(perpMarketId);
        
        int24 priceTick = int24(int256(bound(priceSeed, 2400, 2600)));
        uint128 size = uint128(bound(sizeSeed, 0.01 ether, 10 ether));
        
        uint256 available = perpVault.getAvailableMargin(user, address(collateral));
        if (available < 100 ether) return;
        
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: user,
            marketId: perpMarketId,
            auctionId: auctionId,
            side: isBuy ? OrderTypes.Side.Buy : OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Taker,
            priceTick: priceTick,
            qty: size,
            nonce: uint128(block.timestamp + userSeed),
            expiry: 0
        });
        
        vm.prank(user);
        try perpEngine.placePerpOrder(order, address(collateral)) returns (bytes32 orderId) {
            pendingOrders.push(orderId);
        } catch {}
    }

    function submitSpotOrder(
        uint256 userSeed,
        bool isBuy,
        uint256 priceSeed,
        uint256 sizeSeed
    ) public {
        calls_submitSpotOrder++;
        
        address user = _getUser(userSeed);
        uint64 auctionId = auctionHouse.getAuctionId(spotMarketId);
        
        int24 priceTick = int24(int256(bound(priceSeed, 2400, 2600)));
        uint128 size = uint128(bound(sizeSeed, 0.1 ether, 5 ether));
        
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: user,
            marketId: spotMarketId,
            auctionId: auctionId,
            side: isBuy ? OrderTypes.Side.Buy : OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Taker,
            priceTick: priceTick,
            qty: size,
            nonce: uint128(block.timestamp + userSeed + 1000),
            expiry: 0
        });
        
        vm.prank(user);
        try auctionHouse.submitOrder(order) returns (bytes32 orderId) {
            pendingOrders.push(orderId);
        } catch {}
    }

    function finalizeAuction(bool isPerp) public {
        calls_finalizeAuction++;
        
        uint64 marketId = isPerp ? perpMarketId : spotMarketId;
        uint64 auctionId = auctionHouse.getAuctionId(marketId);
        
        vm.warp(block.timestamp + auctionHouse.AUCTION_DURATION() + 1);
        
        try auctionHouse.finalizeAuction(marketId, auctionId) {
            ghost_totalAuctions++;
            
            (OrderTypes.Clearing memory buyClearing, OrderTypes.Clearing memory sellClearing) = 
                auctionHouse.getClearing(marketId, auctionId);
            
            if (buyClearing.finalized) {
                ghost_totalClearedQty += buyClearing.clearedQty;
            }
            if (sellClearing.finalized) {
                ghost_totalClearedQty += sellClearing.clearedQty;
            }
        } catch {}
    }

    function claimPerpOrder(uint256 orderIndexSeed) public {
        calls_claimPerp++;
        
        if (pendingOrders.length == 0) return;
        
        uint256 index = bound(orderIndexSeed, 0, pendingOrders.length - 1);
        bytes32 orderId = pendingOrders[index];
        
        (OrderTypes.Order memory order, OrderTypes.OrderState memory state) = auctionHouse.getOrder(orderId);
        
        if (state.cancelled || state.claimedQty > 0) return;
        if (order.marketId != perpMarketId) return;
        
        int256 oldSize = userPositionSize[order.trader];
        
        vm.prank(order.trader);
        try perpEngine.claimPerp(orderId, address(collateral)) returns (uint128 fillQty, int128 realizedPnL) {
            if (fillQty > 0) {
                ghost_totalClaimedQty += fillQty;
                claimedOrders.push(orderId);
                
                int256 sizeChange = order.side == OrderTypes.Side.Buy 
                    ? int256(uint256(fillQty))
                    : -int256(uint256(fillQty));
                
                userPositionSize[order.trader] += sizeChange;
                ghost_netPosition += sizeChange;
                ghost_totalPositionChanges += sizeChange > 0 ? sizeChange : -sizeChange;
            }
        } catch {}
    }

    function claimSpotOrder(uint256 orderIndexSeed) public {
        calls_claimSpot++;
        
        if (pendingOrders.length == 0) return;
        
        uint256 index = bound(orderIndexSeed, 0, pendingOrders.length - 1);
        bytes32 orderId = pendingOrders[index];
        
        (OrderTypes.Order memory order, OrderTypes.OrderState memory state) = auctionHouse.getOrder(orderId);
        
        if (state.cancelled || state.claimedQty > 0) return;
        if (order.marketId != spotMarketId) return;
        
        vm.prank(order.trader);
        try spotSettlement.claimSpot(orderId) returns (uint128 fillQty, uint256) {
            if (fillQty > 0) {
                ghost_totalClaimedQty += fillQty;
                claimedOrders.push(orderId);
            }
        } catch {}
    }

    function closePosition(uint256 userSeed) public {
        calls_closePosition++;
        
        address user = _getUser(userSeed);
        int256 positionSize = userPositionSize[user];
        
        if (positionSize == 0) return;
        
        uint64 auctionId = auctionHouse.getAuctionId(perpMarketId);
        
        bool isBuy = positionSize < 0;
        uint128 size = uint128(positionSize > 0 ? uint256(positionSize) : uint256(-positionSize));
        
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: user,
            marketId: perpMarketId,
            auctionId: auctionId,
            side: isBuy ? OrderTypes.Side.Buy : OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Taker,
            priceTick: 2500,
            qty: size,
            nonce: uint128(block.timestamp + uint160(user)),
            expiry: 0
        });
        
        vm.prank(user);
        try perpEngine.placePerpOrder(order, address(collateral)) returns (bytes32 orderId) {
            pendingOrders.push(orderId);
        } catch {}
    }

    function applyFunding(uint256 userSeed) public {
        calls_applyFunding++;
        
        address user = _getUser(userSeed);
        int256 positionSize = userPositionSize[user];
        
        if (positionSize == 0) return;
        
        try perpEngine.applyFunding(perpMarketId) {
            if (positionSize > 0) {
                ghost_totalFundingPaid += 1;
            } else {
                ghost_totalFundingReceived += 1;
            }
        } catch {}
    }

    function liquidate(uint256 userSeed, uint256 liquidatorSeed) public {
        calls_liquidate++;
        
        address user = _getUser(userSeed);
        address liquidator = _getUser(liquidatorSeed);
        
        if (user == liquidator) return;
        
        int256 positionSize = userPositionSize[user];
        if (positionSize == 0) return;
        
        vm.prank(liquidator);
        try perpEngine.liquidate(user, perpMarketId, address(collateral)) {
            userPositionSize[user] = 0;
        } catch {}
    }

    function depositSpot(uint256 userSeed, bool isBase, uint256 amountSeed) public {
        calls_depositSpot++;
        
        address user = _getUser(userSeed);
        uint256 amount = bound(amountSeed, 1 ether, 1000 ether);
        
        if (isBase) {
            uint256 balance = baseToken.balanceOf(address(this));
            if (balance < amount) return;
            
            baseToken.approve(address(spotVault), amount);
            vm.prank(address(this));
            try spotVault.deposit(address(baseToken), amount, user) {
                ghost_spotBaseDeposited += amount;
            } catch {}
        } else {
            uint256 balance = quoteToken.balanceOf(address(this));
            if (balance < amount) return;
            
            quoteToken.approve(address(spotVault), amount);
            vm.prank(address(this));
            try spotVault.deposit(address(quoteToken), amount, user) {
                ghost_spotQuoteDeposited += amount;
            } catch {}
        }
    }

    function withdrawSpot(uint256 userSeed, bool isBase, uint256 amountSeed) public {
        calls_withdrawSpot++;
        
        address user = _getUser(userSeed);
        address token = isBase ? address(baseToken) : address(quoteToken);
        
        uint256 balance = spotVault.balances(user, token);
        if (balance == 0) return;
        
        uint256 amount = bound(amountSeed, 1, balance);
        
        vm.prank(user);
        try spotVault.withdraw(token, amount, user) {
            if (isBase) {
                ghost_spotBaseWithdrawn += amount;
            } else {
                ghost_spotQuoteWithdrawn += amount;
            }
        } catch {}
    }

    function updateOraclePrice(uint256 priceSeed) public {
        uint256 newPrice = bound(priceSeed, 2000e18, 3000e18);
        oracle.updatePrice(newPrice);
    }

    function _getUser(uint256 seed) internal returns (address) {
        uint256 index = bound(seed, 0, 9);
        
        if (index < users.length) {
            return users[index];
        }
        
        address newUser = address(uint160(0x1000 + users.length));
        users.push(newUser);
        isUser[newUser] = true;
        return newUser;
    }

    function getUsers() external view returns (address[] memory) {
        return users;
    }

    function callSummary() external view {
        console.log("\n=== End-to-End Trading Call Summary ===");
        console.log("Margin operations:");
        console.log("  depositMargin:", calls_depositMargin);
        console.log("  withdrawMargin:", calls_withdrawMargin);
        console.log("\nTrading:");
        console.log("  submitPerpOrder:", calls_submitPerpOrder);
        console.log("  submitSpotOrder:", calls_submitSpotOrder);
        console.log("  finalizeAuction:", calls_finalizeAuction);
        console.log("  claimPerp:", calls_claimPerp);
        console.log("  claimSpot:", calls_claimSpot);
        console.log("\nPosition management:");
        console.log("  closePosition:", calls_closePosition);
        console.log("  applyFunding:", calls_applyFunding);
        console.log("  liquidate:", calls_liquidate);
        console.log("\nSpot operations:");
        console.log("  depositSpot:", calls_depositSpot);
        console.log("  withdrawSpot:", calls_withdrawSpot);
        console.log("\n=== Ghost Variables ===");
        console.log("Total user margin:", ghost_totalUserMargin);
        console.log("Net position:", uint256(ghost_netPosition > 0 ? ghost_netPosition : -ghost_netPosition));
        console.log("Total claimed qty:", ghost_totalClaimedQty);
        console.log("Total cleared qty:", ghost_totalClearedQty);
        console.log("Total auctions:", ghost_totalAuctions);
        console.log("Invalid liquidations:", ghost_invalidLiquidations);
        console.log("Pending orders:", pendingOrders.length);
        console.log("Claimed orders:", claimedOrders.length);
        console.log("Active users:", users.length);
    }
}
