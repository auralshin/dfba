// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OrderTypes} from "../libraries/OrderTypes.sol";
import {TickBitmap} from "../libraries/TickBitmap.sol";
import {ClearingEngine} from "../libraries/ClearingEngine.sol";
import {Math} from "../libraries/Math.sol";

/// @title AuctionHouse
/// @notice Core DFBA engine: accepts orders, stores per-tick aggregates, computes clearing
/// @dev Supports both spot and perp markets
contract AuctionHouse {
    using TickBitmap for mapping(int16 => uint256);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant AUCTION_DURATION = 12 seconds;
    uint256 public constant MAX_TICKS_PER_FINALIZE = 1000;
    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = 887272;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Market configuration
    struct Market {
        OrderTypes.MarketType marketType;
        address baseToken;
        address quoteToken;
        bool active;
    }

    /// @notice Auction state per market
    struct AuctionState {
        uint64 auctionId;
        uint64 startTime;
        bool finalized;
        OrderTypes.Clearing buyClearing;
        OrderTypes.Clearing sellClearing;
    }

    /// @notice Per-auction aggregates
    struct AuctionAggregates {
        mapping(int24 => OrderTypes.TickLevel) tickLevels;
        mapping(int16 => uint256) tickBitmap;
        uint128 totalMakerBuy;
        uint128 totalMakerSell;
        uint128 totalTakerBuy;
        uint128 totalTakerSell;
        int24 minActiveTick;
        int24 maxActiveTick;
        uint256 orderCount;
    }

    /// @notice Markets
    mapping(uint64 => Market) public markets;
    uint64 public marketCount;

    /// @notice Current auction state per market
    mapping(uint64 => AuctionState) public auctions;

    /// @notice Historical auction states
    mapping(uint64 => mapping(uint64 => AuctionState)) public historicalAuctions;

    /// @notice Auction aggregates: marketId => auctionId => aggregates
    mapping(uint64 => mapping(uint64 => AuctionAggregates)) internal auctionData;

    /// @notice Orders: orderId => order
    mapping(bytes32 => OrderTypes.Order) public orders;

    /// @notice Order state: orderId => state
    mapping(bytes32 => OrderTypes.OrderState) public orderStates;

    /// @notice User nonces for order uniqueness
    mapping(address => uint128) public userNonces;

    /// @notice Authorized settlement contracts
    mapping(address => bool) public authorized;

    /// @notice Oracle addresses per market (for perps)
    mapping(uint64 => address) public marketOracles;

    /// @notice Admin
    address public admin;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarketCreated(uint64 indexed marketId, OrderTypes.MarketType marketType, address baseToken, address quoteToken);
    event MarketStatusUpdated(uint64 indexed marketId, bool active);
    event OracleSet(uint64 indexed marketId, address indexed oracle);
    event OrderSubmitted(bytes32 indexed orderId, address indexed trader, uint64 indexed marketId, uint64 auctionId);
    event OrderCancelled(bytes32 indexed orderId, address indexed trader);
    event AuctionFinalized(uint64 indexed marketId, uint64 indexed auctionId);
    event AuthorizedUpdated(address indexed account, bool authorized);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdmin() internal view {
        require(msg.sender == admin, "AuctionHouse: not admin");
    }

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    function _onlyAuthorized() internal view {
        require(authorized[msg.sender], "AuctionHouse: not authorized");
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        admin = msg.sender;
        authorized[msg.sender] = true;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createMarket(
        OrderTypes.MarketType marketType,
        address baseToken,
        address quoteToken
    ) external onlyAdmin returns (uint64 marketId) {
        return createMarketWithOracle(marketType, baseToken, quoteToken, address(0));
    }

    /// @notice Create market with oracle (for perps)
    function createMarketWithOracle(
        OrderTypes.MarketType marketType,
        address baseToken,
        address quoteToken,
        address oracle
    ) public onlyAdmin returns (uint64 marketId) {
        require(baseToken != address(0), "AuctionHouse: zero base token");
        require(_isContract(baseToken), "AuctionHouse: base token not contract");
        
        if (marketType == OrderTypes.MarketType.Spot) {
            require(quoteToken != address(0), "AuctionHouse: zero quote token");
            require(_isContract(quoteToken), "AuctionHouse: quote token not contract");
        }
        

        if (oracle != address(0)) {
            require(_isContract(oracle), "AuctionHouse: oracle not contract");
        }

        marketId = ++marketCount;
        markets[marketId] = Market({
            marketType: marketType,
            baseToken: baseToken,
            quoteToken: quoteToken,
            active: true
        });

        if (oracle != address(0)) {
            marketOracles[marketId] = oracle;
            emit OracleSet(marketId, oracle);
        }

        auctions[marketId] = AuctionState({
            auctionId: 1,
            startTime: uint64(block.timestamp),
            finalized: false,
            buyClearing: OrderTypes.Clearing(0, 0, 0, 0, false),
            sellClearing: OrderTypes.Clearing(0, 0, 0, 0, false)
        });

        emit MarketCreated(marketId, marketType, baseToken, quoteToken);
    }

    function setAuthorized(address account, bool _authorized) external onlyAdmin {
        authorized[account] = _authorized;
        emit AuthorizedUpdated(account, _authorized);
    }

    /// @notice Pause or unpause a market
    function setMarketActive(uint64 marketId, bool active) external onlyAdmin {
        require(marketId > 0 && marketId <= marketCount, "AuctionHouse: invalid market");
        markets[marketId].active = active;
        emit MarketStatusUpdated(marketId, active);
    }

    /// @notice Set or update oracle for a market
    function setMarketOracle(uint64 marketId, address oracle) external onlyAdmin {
        require(marketId > 0 && marketId <= marketCount, "AuctionHouse: invalid market");
        if (oracle != address(0)) {
            require(_isContract(oracle), "AuctionHouse: oracle not contract");
        }
        marketOracles[marketId] = oracle;
        emit OracleSet(marketId, oracle);
    }

    /// @notice Helper to check if address is a contract
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    /*//////////////////////////////////////////////////////////////
                          CORE ORDER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Get current auction ID for a market
    function getAuctionId(uint64 marketId) public view returns (uint64) {
        AuctionState storage auction = auctions[marketId];
        uint64 elapsed = uint64(block.timestamp) - auction.startTime;
        
        if (elapsed >= AUCTION_DURATION && !auction.finalized) {
            return auction.auctionId;
        }
        
        if (auction.finalized) {
            return auction.auctionId + 1;
        }
        
        return auction.auctionId;
    }

    /// @notice Submit an order
    function submitOrder(OrderTypes.Order memory order) external returns (bytes32 orderId) {
        Market storage market = markets[order.marketId];
        require(market.active, "AuctionHouse: market not active");
        

        uint64 currentAuctionId = getAuctionId(order.marketId);
        require(order.auctionId == currentAuctionId, "AuctionHouse: invalid auction");
        
        // C1 FIX: Enforce auction duration - orders cannot be submitted after time elapsed
        AuctionState storage auction = auctions[order.marketId];
        require(block.timestamp < auction.startTime + AUCTION_DURATION, "AuctionHouse: auction expired");
        
        // C3 FIX: Authenticate order submission - only trader can submit their own orders
        require(order.trader == msg.sender, "AuctionHouse: unauthorized trader");

        require(order.expiry == 0 || order.expiry >= block.timestamp, "AuctionHouse: expired");
        
        // Additional validation: qty must be positive
        require(order.qty > 0, "AuctionHouse: qty must be positive");

        require(order.priceTick >= MIN_TICK && order.priceTick <= MAX_TICK, "AuctionHouse: tick out of range");
        
        orderId = OrderTypes.orderKey(order);
        require(orders[orderId].trader == address(0), "AuctionHouse: duplicate order");
        

        orders[orderId] = order;
        orderStates[orderId] = OrderTypes.OrderState({
            remainingQty: order.qty,
            claimedQty: 0,
            cancelled: false
        });
        
        AuctionAggregates storage agg = auctionData[order.marketId][order.auctionId];
        OrderTypes.TickLevel storage level = agg.tickLevels[order.priceTick];
        
        if (order.flow == OrderTypes.Flow.Maker) {
            if (order.side == OrderTypes.Side.Buy) {
                level.makerBuy = Math.add128(level.makerBuy, order.qty);
                agg.totalMakerBuy = Math.add128(agg.totalMakerBuy, order.qty);
            } else {
                level.makerSell = Math.add128(level.makerSell, order.qty);
                agg.totalMakerSell = Math.add128(agg.totalMakerSell, order.qty);
            }
        } else {
            if (order.side == OrderTypes.Side.Buy) {
                level.takerBuy = Math.add128(level.takerBuy, order.qty);
                agg.totalTakerBuy = Math.add128(agg.totalTakerBuy, order.qty);
            } else {
                level.takerSell = Math.add128(level.takerSell, order.qty);
                agg.totalTakerSell = Math.add128(agg.totalTakerSell, order.qty);
            }
        }
        
        agg.tickBitmap.setTickActive(order.priceTick);
        
        if (agg.orderCount == 0) {
            agg.minActiveTick = order.priceTick;
            agg.maxActiveTick = order.priceTick;
        } else {
            if (order.priceTick < agg.minActiveTick) agg.minActiveTick = order.priceTick;
            if (order.priceTick > agg.maxActiveTick) agg.maxActiveTick = order.priceTick;
        }
        
        agg.orderCount++;
        
        emit OrderSubmitted(orderId, order.trader, order.marketId, order.auctionId);
    }

    /// @notice Cancel an order
    function cancelOrder(bytes32 orderId) external {
        OrderTypes.Order storage order = orders[orderId];
        require(order.trader == msg.sender, "AuctionHouse: not order owner");
        
        OrderTypes.OrderState storage state = orderStates[orderId];
        require(!state.cancelled, "AuctionHouse: already cancelled");
        require(state.claimedQty == 0, "AuctionHouse: already claimed");
        
        // C2 FIX: Update aggregates when cancelling - decrement tick levels and totals
        AuctionAggregates storage agg = auctionData[order.marketId][order.auctionId];
        OrderTypes.TickLevel storage level = agg.tickLevels[order.priceTick];
        
        uint128 remainingQty = state.remainingQty;
        
        if (order.flow == OrderTypes.Flow.Maker) {
            if (order.side == OrderTypes.Side.Buy) {
                level.makerBuy = Math.sub128(level.makerBuy, remainingQty);
                agg.totalMakerBuy = Math.sub128(agg.totalMakerBuy, remainingQty);
            } else {
                level.makerSell = Math.sub128(level.makerSell, remainingQty);
                agg.totalMakerSell = Math.sub128(agg.totalMakerSell, remainingQty);
            }
        } else {
            if (order.side == OrderTypes.Side.Buy) {
                level.takerBuy = Math.sub128(level.takerBuy, remainingQty);
                agg.totalTakerBuy = Math.sub128(agg.totalTakerBuy, remainingQty);
            } else {
                level.takerSell = Math.sub128(level.takerSell, remainingQty);
                agg.totalTakerSell = Math.sub128(agg.totalTakerSell, remainingQty);
            }
        }
        
        // If tick level is now empty, clear it from bitmap
        if (level.makerBuy == 0 && level.makerSell == 0 && level.takerBuy == 0 && level.takerSell == 0) {
            agg.tickBitmap.clearTick(order.priceTick);
        }
        
        state.cancelled = true;
        state.remainingQty = 0;
        
        emit OrderCancelled(orderId, order.trader);
    }

    /*//////////////////////////////////////////////////////////////
                        AUCTION FINALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalize an auction (compute clearing)
    function finalizeAuction(uint64 marketId, uint64 auctionId) external {
        Market storage market = markets[marketId];
        require(market.active, "AuctionHouse: market not active");
        
        AuctionState storage auction = auctions[marketId];
        require(auction.auctionId == auctionId, "AuctionHouse: wrong auction");
        require(!auction.finalized, "AuctionHouse: already finalized");
        
        uint64 elapsed = uint64(block.timestamp) - auction.startTime;
        require(elapsed >= AUCTION_DURATION, "AuctionHouse: auction not ended");
        
        AuctionAggregates storage agg = auctionData[marketId][auctionId];
        
        ClearingEngine.ClearingResult memory buyResult = _computeBuyClearing(agg);
        auction.buyClearing = OrderTypes.Clearing({
            clearingTick: buyResult.clearingTick,
            marginalFillMakerBps: buyResult.marginalFillMakerBps,
            marginalFillTakerBps: buyResult.marginalFillTakerBps,
            clearedQty: buyResult.clearedQty,
            finalized: true
        });
        
        ClearingEngine.ClearingResult memory sellResult = _computeSellClearing(agg);
        auction.sellClearing = OrderTypes.Clearing({
            clearingTick: sellResult.clearingTick,
            marginalFillMakerBps: sellResult.marginalFillMakerBps,
            marginalFillTakerBps: sellResult.marginalFillTakerBps,
            clearedQty: sellResult.clearedQty,
            finalized: true
        });
        
        auction.finalized = true;
        
        historicalAuctions[marketId][auctionId] = auction;
        auctions[marketId] = AuctionState({
            auctionId: auctionId + 1,
            startTime: uint64(block.timestamp),
            finalized: false,
            buyClearing: OrderTypes.Clearing(0, 0, 0, 0, false),
            sellClearing: OrderTypes.Clearing(0, 0, 0, 0, false)
        });
        
        emit AuctionFinalized(marketId, auctionId);
    }

    function _computeBuyClearing(AuctionAggregates storage agg)
        internal
        view
        returns (ClearingEngine.ClearingResult memory)
    {
        return ClearingEngine.computeBuyClearing(
            agg.tickLevels,
            agg.tickBitmap,
            agg.totalMakerBuy,
            agg.totalMakerSell,
            agg.totalTakerBuy,
            agg.totalTakerSell,
            agg.minActiveTick,
            agg.maxActiveTick,
            MAX_TICKS_PER_FINALIZE
        );
    }

    function _computeSellClearing(AuctionAggregates storage agg)
        internal
        view
        returns (ClearingEngine.ClearingResult memory)
    {
        return ClearingEngine.computeSellClearing(
            agg.tickLevels,
            agg.tickBitmap,
            agg.totalMakerBuy,
            agg.totalMakerSell,
            agg.totalTakerBuy,
            agg.totalTakerSell,
            agg.minActiveTick,
            agg.maxActiveTick,
            MAX_TICKS_PER_FINALIZE
        );
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getClearing(uint64 marketId, uint64 auctionId)
        external
        view
        returns (OrderTypes.Clearing memory buyClearing, OrderTypes.Clearing memory sellClearing)
    {
        // Fix: Check if auctionId is current auction first
        AuctionState storage currentAuction = auctions[marketId];
        if (currentAuction.auctionId == auctionId) {
            return (currentAuction.buyClearing, currentAuction.sellClearing);
        }
        
        // Otherwise, look up historical auction
        AuctionState storage auction = historicalAuctions[marketId][auctionId];
        return (auction.buyClearing, auction.sellClearing);
    }

    function getOrder(bytes32 orderId) external view returns (OrderTypes.Order memory, OrderTypes.OrderState memory) {
        return (orders[orderId], orderStates[orderId]);
    }

    function getTickLevel(uint64 marketId, uint64 auctionId, int24 tick)
        external
        view
        returns (OrderTypes.TickLevel memory)
    {
        return auctionData[marketId][auctionId].tickLevels[tick];
    }

    /// @notice Update order state (settlement contracts only)
    function updateOrderState(bytes32 orderId, uint128 claimedQty, uint128 remainingQty)
        external
        onlyAuthorized
    {
        OrderTypes.OrderState storage state = orderStates[orderId];
        state.claimedQty = claimedQty;
        state.remainingQty = remainingQty;
    }
}
