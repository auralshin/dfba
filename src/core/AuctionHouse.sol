// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OrderTypes} from "../libraries/OrderTypes.sol";
import {TickBitmap} from "../libraries/TickBitmap.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AuctionHouse
/// @notice Core DFBA engine with time-based batching and dual bid/ask auctions
/// @dev Supports both spot and perp markets
contract AuctionHouse is AccessControl {
    using TickBitmap for mapping(int16 => uint256);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    // Production uses 200ms batches on L2s with subsecond block times
    // Demo uses 1 second for compatibility with Anvil's block.timestamp updates
    uint256 public constant BATCH_DURATION = 1;
    uint256 public constant MAX_TICKS_PER_FINALIZE = 100;
    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = 887272;
    uint256 public constant Q128 = uint256(1) << 128;

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

    /// @notice Auction side for DFBA dual auctions
    enum AuctionSide {
        Bid, // Maker-Buy vs Taker-Sell
        Ask // Maker-Sell vs Taker-Buy
    }

    /// @notice Finalize phase for incremental processing
    enum FinalizePhase {
        NotStarted,
        DiscoverBid,
        ConsumeBidDemand, // MB: max -> clearing
        ConsumeBidSupply, // TS: min -> clearing
        DiscoverAsk,
        ConsumeAskSupply, // MS: min -> clearing
        ConsumeAskDemand, // TB: max -> clearing
        Done
    }

    /// @notice Auction state per market (stored per batch in historicalBatches)
    struct AuctionState {
        uint64 batchId;
        uint64 batchStart;
        uint64 batchEnd;
        OrderTypes.Clearing bidClearing;
        OrderTypes.Clearing askClearing;
    }

    /// @notice Per-tick fill fractions for THIS batch (Q128: 0..2^128)
    /// @dev We intentionally do NOT track shares; fill fractions use lvl.* as denominator.
    struct TickFillState {
        uint256 mbFillX128; // maker-buy
        uint256 msFillX128; // maker-sell
        uint256 tbFillX128; // taker-buy
        uint256 tsFillX128; // taker-sell
    }

    /// @notice Per-batch aggregates (4 curves: MB, MS, TB, TS)
    struct BatchAggregates {
        mapping(int24 => OrderTypes.TickLevel) tickLevels;
        mapping(int24 => TickFillState) tickFills;
        mapping(int16 => uint256) tickBitmap;
        uint128 totalMakerBuy; // MB curve
        uint128 totalMakerSell; // MS curve
        uint128 totalTakerBuy; // TB curve
        uint128 totalTakerSell; // TS curve
        int24 minActiveTick;
        int24 maxActiveTick;
        uint256 orderCount;
    }

    /// @notice Discovery phase state (reused for bid and ask)
    struct DiscoveryState {
        uint128 supplyPrefix; // cumulative supply <= cursorTick
        uint128 demandBelow; // cumulative demand < cursorTick
        uint128 bestMatch; // best match quantity found
        int24 bestTick; // tick with best match
    }

    /// @notice Consumption cursors for one auction side
    struct ConsumptionState {
        int24 demandCursor;
        int24 supplyCursor;
        uint128 demandRemaining;
        uint128 supplyRemaining;
    }

    /// @notice Incremental finalize checkpoint state
    struct FinalizeState {
        FinalizePhase phase;
        int24 cursorTick;
        int24 bidClearingTick;
        uint128 bidClearedQty;
        int24 askClearingTick;
        uint128 askClearedQty;
    }

    /// @notice Markets
    mapping(uint64 => Market) public markets;
    uint64 public marketCount;

    /// @notice Historical batch states (marketId => batchId => state)
    /// @dev Single source of truth for all batch results. View functions read only from here.
    mapping(uint64 => mapping(uint64 => AuctionState)) public historicalBatches;

    /// @notice Batch aggregates: marketId => batchId => aggregates
    mapping(uint64 => mapping(uint64 => BatchAggregates)) internal batchData;

    /// @notice Finalize state: marketId => batchId => state
    mapping(uint64 => mapping(uint64 => FinalizeState)) public finalizeStates;

    /// @notice Discovery state: marketId => batchId => discovery
    mapping(uint64 => mapping(uint64 => DiscoveryState))
        internal discoveryStates;

    /// @notice Bid consumption state
    mapping(uint64 => mapping(uint64 => ConsumptionState))
        internal bidConsumption;

    /// @notice Ask consumption state
    mapping(uint64 => mapping(uint64 => ConsumptionState))
        internal askConsumption;

    /// @notice Orders: orderId => order
    mapping(bytes32 => OrderTypes.Order) public orders;

    /// @notice Order batch assignment: orderId => batchId
    mapping(bytes32 => uint64) public orderBatches;

    /// @notice Order state: orderId => state
    mapping(bytes32 => OrderTypes.OrderState) public orderStates;

    /// @notice User nonces for order uniqueness
    mapping(address => uint128) public userNonces;

    /// @notice Oracle addresses per market (for perps)
    mapping(uint64 => address) public marketOracles;

    event MarketCreated(
        uint64 indexed marketId,
        OrderTypes.MarketType marketType,
        address baseToken,
        address quoteToken
    );
    event MarketStatusUpdated(uint64 indexed marketId, bool active);
    event OracleSet(uint64 indexed marketId, address indexed oracle);
    event OrderSubmitted(
        bytes32 indexed orderId,
        address indexed trader,
        uint64 indexed marketId,
        uint64 batchId
    );
    event OrderCancelled(bytes32 indexed orderId, address indexed trader);
    event BatchFinalized(
        uint64 indexed marketId,
        uint64 indexed batchId,
        AuctionSide side
    );
    event FinalizeStepCompleted(
        uint64 indexed marketId,
        uint64 indexed batchId,
        FinalizePhase phase,
        uint256 ticksProcessed
    );

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createMarket(
        OrderTypes.MarketType marketType,
        address baseToken,
        address quoteToken
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint64 marketId) {
        return
            createMarketWithOracle(
                marketType,
                baseToken,
                quoteToken,
                address(0)
            );
    }

    /// @notice Create market with oracle (for perps)
    function createMarketWithOracle(
        OrderTypes.MarketType marketType,
        address baseToken,
        address quoteToken,
        address oracle
    ) public onlyRole(DEFAULT_ADMIN_ROLE) returns (uint64 marketId) {
        require(baseToken != address(0), "AuctionHouse: zero base token");
        require(
            _isContract(baseToken),
            "AuctionHouse: base token not contract"
        );

        if (marketType == OrderTypes.MarketType.Spot) {
            require(quoteToken != address(0), "AuctionHouse: zero quote token");
            require(
                _isContract(quoteToken),
                "AuctionHouse: quote token not contract"
            );
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

        emit MarketCreated(marketId, marketType, baseToken, quoteToken);
    }

    function grantRouterRole(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(ROUTER_ROLE, account);
    }

    function revokeRouterRole(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(ROUTER_ROLE, account);
    }

    function setMarketActive(
        uint64 marketId,
        bool active
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            marketId > 0 && marketId <= marketCount,
            "AuctionHouse: invalid market"
        );
        markets[marketId].active = active;
        emit MarketStatusUpdated(marketId, active);
    }

    function setMarketOracle(
        uint64 marketId,
        address oracle
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            marketId > 0 && marketId <= marketCount,
            "AuctionHouse: invalid market"
        );
        if (oracle != address(0)) {
            require(_isContract(oracle), "AuctionHouse: oracle not contract");
        }
        marketOracles[marketId] = oracle;
        emit OracleSet(marketId, oracle);
    }

    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    /*//////////////////////////////////////////////////////////////
                          CORE ORDER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Get current batch ID for a market (time-based, liveness-safe)
    /// @dev marketId is unused (kept for interface symmetry); batchId is global time-bucket.
    function getBatchId(uint64 /*marketId*/) public view returns (uint64) {
        return uint64(block.timestamp / BATCH_DURATION);
    }

    function getBatchEnd(uint64 marketId) public view returns (uint64) {
        uint64 currentBatchId = getBatchId(marketId);
        return (currentBatchId + 1) * uint64(BATCH_DURATION);
    }

    /// @notice Submit an order (assigned to current time-batch)
    function submitOrder(
        OrderTypes.Order memory order
    ) external onlyRole(ROUTER_ROLE) returns (bytes32 orderId, uint64 batchId) {
        Market storage market = markets[order.marketId];
        require(market.active, "AuctionHouse: market not active");

        batchId = getBatchId(order.marketId);
        uint64 batchEnd = getBatchEnd(order.marketId);

        // AUTO-SETTLEMENT: if previous batch ended and not finalized, make progress
        if (batchId > 0) {
            _autoFinalizePreviousBatch(order.marketId, batchId - 1);
        }

        require(
            block.timestamp < batchEnd,
            "AuctionHouse: batch cutoff passed"
        );
        require(
            order.expiry == 0 || order.expiry >= block.timestamp,
            "AuctionHouse: expired"
        );
        require(order.qty > 0, "AuctionHouse: qty must be positive");
        require(
            order.priceTick >= MIN_TICK && order.priceTick <= MAX_TICK,
            "AuctionHouse: tick out of range"
        );

        orderId = OrderTypes.orderKey(order);
        require(
            orders[orderId].trader == address(0),
            "AuctionHouse: duplicate order"
        );

        orders[orderId] = order;
        orderBatches[orderId] = batchId;
        orderStates[orderId] = OrderTypes.OrderState({
            remainingQty: order.qty,
            claimedQty: 0,
            cancelled: false
        });

        BatchAggregates storage agg = batchData[order.marketId][batchId];
        OrderTypes.TickLevel storage level = agg.tickLevels[order.priceTick];

        // Update aggregates (MB/MS/TB/TS)
        if (order.flow == OrderTypes.Flow.Maker) {
            if (order.side == OrderTypes.Side.Buy) {
                level.makerBuy = SafeCast.toUint128(
                    uint256(level.makerBuy) + uint256(order.qty)
                );
                agg.totalMakerBuy = SafeCast.toUint128(
                    uint256(agg.totalMakerBuy) + uint256(order.qty)
                );
            } else {
                level.makerSell = SafeCast.toUint128(
                    uint256(level.makerSell) + uint256(order.qty)
                );
                agg.totalMakerSell = SafeCast.toUint128(
                    uint256(agg.totalMakerSell) + uint256(order.qty)
                );
            }
        } else {
            if (order.side == OrderTypes.Side.Buy) {
                level.takerBuy = SafeCast.toUint128(
                    uint256(level.takerBuy) + uint256(order.qty)
                );
                agg.totalTakerBuy = SafeCast.toUint128(
                    uint256(agg.totalTakerBuy) + uint256(order.qty)
                );
            } else {
                level.takerSell = SafeCast.toUint128(
                    uint256(level.takerSell) + uint256(order.qty)
                );
                agg.totalTakerSell = SafeCast.toUint128(
                    uint256(agg.totalTakerSell) + uint256(order.qty)
                );
            }
        }

        agg.tickBitmap.setTickActive(order.priceTick);

        if (agg.orderCount == 0) {
            agg.minActiveTick = order.priceTick;
            agg.maxActiveTick = order.priceTick;
        } else {
            if (order.priceTick < agg.minActiveTick)
                agg.minActiveTick = order.priceTick;
            if (order.priceTick > agg.maxActiveTick)
                agg.maxActiveTick = order.priceTick;
        }

        agg.orderCount++;

        emit OrderSubmitted(orderId, order.trader, order.marketId, batchId);
    }

    /// @notice Cancel an order (maker-only; only in current batch before cutoff)
    function cancelOrder(bytes32 orderId) external {
        OrderTypes.Order storage order = orders[orderId];
        require(order.trader == msg.sender, "AuctionHouse: not order owner");
        require(
            order.flow == OrderTypes.Flow.Maker,
            "AuctionHouse: only makers can cancel"
        );

        OrderTypes.OrderState storage state = orderStates[orderId];
        require(!state.cancelled, "AuctionHouse: already cancelled");
        require(state.claimedQty == 0, "AuctionHouse: already claimed");

        uint64 orderBatchId = orderBatches[orderId];
        uint64 currentBatchId = getBatchId(order.marketId);
        require(
            orderBatchId == currentBatchId,
            "AuctionHouse: can only cancel current batch"
        );
        require(
            block.timestamp < getBatchEnd(order.marketId),
            "AuctionHouse: batch cutoff passed"
        );

        BatchAggregates storage agg = batchData[order.marketId][orderBatchId];
        OrderTypes.TickLevel storage level = agg.tickLevels[order.priceTick];

        uint128 remainingQty = state.remainingQty;

        // Update maker curves
        if (order.side == OrderTypes.Side.Buy) {
            level.makerBuy = SafeCast.toUint128(
                uint256(level.makerBuy) - uint256(remainingQty)
            );
            agg.totalMakerBuy = SafeCast.toUint128(
                uint256(agg.totalMakerBuy) - uint256(remainingQty)
            );
        } else {
            level.makerSell = SafeCast.toUint128(
                uint256(level.makerSell) - uint256(remainingQty)
            );
            agg.totalMakerSell = SafeCast.toUint128(
                uint256(agg.totalMakerSell) - uint256(remainingQty)
            );
        }

        if (agg.orderCount > 0) {
            agg.orderCount--;
        }

        // If tick is now empty, clear bitmap and update bounds
        if (
            level.makerBuy == 0 &&
            level.makerSell == 0 &&
            level.takerBuy == 0 &&
            level.takerSell == 0
        ) {
            agg.tickBitmap.clearTick(order.priceTick);

            if (agg.orderCount == 0) {
                agg.minActiveTick = 0;
                agg.maxActiveTick = 0;
            } else {
                if (order.priceTick == agg.minActiveTick) {
                    (int24 newMin, bool found) = agg.tickBitmap.nextActiveTick(
                        order.priceTick + 1,
                        agg.maxActiveTick
                    );
                    agg.minActiveTick = found ? newMin : agg.maxActiveTick;
                }
                if (order.priceTick == agg.maxActiveTick) {
                    (int24 newMax, bool found) = agg.tickBitmap.prevActiveTick(
                        order.priceTick - 1,
                        agg.minActiveTick
                    );
                    agg.maxActiveTick = found ? newMax : agg.minActiveTick;
                }
            }
        }

        state.cancelled = true;
        state.remainingQty = 0;

        emit OrderCancelled(orderId, order.trader);
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH FINALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Auto-finalize previous batches (called by submitOrder)
    /// @dev If trading stops, batches won't auto-finalize; keepers should call finalizeStep().
    function _autoFinalizePreviousBatch(
        uint64 marketId,
        uint64 batchId
    ) internal {
        uint64 currentBatchId = getBatchId(marketId);
        if (batchId >= currentBatchId) return;

        // Find oldest unfinalized batch (bounded)
        uint64 oldestUnfinalized = batchId;
        uint256 maxBacklog = 10;
        for (uint256 i = 0; i < maxBacklog && oldestUnfinalized > 0; i++) {
            FinalizeState storage prev = finalizeStates[marketId][
                oldestUnfinalized - 1
            ];
            if (prev.phase == FinalizePhase.Done) break;
            oldestUnfinalized--;
        }

        // Finalize up to 3 old batches per tx (bounded)
        uint256 maxBatches = 3;
        for (
            uint256 i = 0;
            i < maxBatches && oldestUnfinalized <= batchId;
            i++
        ) {
            FinalizeState storage st = finalizeStates[marketId][
                oldestUnfinalized
            ];
            if (st.phase != FinalizePhase.Done) {
                _executeFinalizeStep(marketId, oldestUnfinalized, 50);
            }
            oldestUnfinalized++;
        }
    }

    function _executeFinalizeStep(
        uint64 marketId,
        uint64 batchId,
        uint256 maxSteps
    ) internal returns (uint256 ticksProcessed) {
        FinalizeState storage state = finalizeStates[marketId][batchId];
        if (state.phase == FinalizePhase.Done) return 0;

        BatchAggregates storage agg = batchData[marketId][batchId];

        if (state.phase == FinalizePhase.NotStarted) {
            // Empty batch: finalize immediately with sentinel ticks and zero qty
            if (agg.orderCount == 0) {
                state.bidClearingTick = MIN_TICK;
                state.bidClearedQty = 0;
                state.askClearingTick = MAX_TICK;
                state.askClearedQty = 0;
                state.phase = FinalizePhase.Done;
                _finalizeBatch(marketId, batchId);
                return 0;
            }

            state.phase = FinalizePhase.DiscoverBid;
            state.cursorTick = agg.minActiveTick;

            DiscoveryState storage disc = discoveryStates[marketId][batchId];
            disc.supplyPrefix = 0;
            disc.demandBelow = 0;
            disc.bestMatch = 0;
            disc.bestTick = 0;
        }

        if (state.phase == FinalizePhase.DiscoverBid) {
            (bool bidDone, uint256 ticks) = _discoverBidClearing(
                marketId,
                batchId,
                maxSteps
            );
            ticksProcessed = ticks;
            if (bidDone) {
                state.phase = FinalizePhase.ConsumeBidDemand;
                ConsumptionState storage bidCon = bidConsumption[marketId][
                    batchId
                ];
                bidCon.demandCursor = agg.maxActiveTick;
                bidCon.demandRemaining = state.bidClearedQty;
            }
        } else if (state.phase == FinalizePhase.ConsumeBidDemand) {
            if (state.bidClearedQty == 0) {
                state.phase = FinalizePhase.ConsumeBidSupply;
                ticksProcessed = 0;
            } else {
                (bool done, uint256 ticks) = _consumeBidDemand(
                    marketId,
                    batchId,
                    maxSteps
                );
                ticksProcessed = ticks;
                if (done) {
                    state.phase = FinalizePhase.ConsumeBidSupply;
                    ConsumptionState storage bidCon = bidConsumption[marketId][
                        batchId
                    ];
                    bidCon.supplyCursor = agg.minActiveTick;
                    bidCon.supplyRemaining = state.bidClearedQty;
                }
            }
        } else if (state.phase == FinalizePhase.ConsumeBidSupply) {
            if (state.bidClearedQty == 0) {
                state.phase = FinalizePhase.DiscoverAsk;
                state.cursorTick = agg.minActiveTick;
                DiscoveryState storage disc = discoveryStates[marketId][
                    batchId
                ];
                disc.supplyPrefix = 0;
                disc.demandBelow = 0;
                disc.bestMatch = 0;
                disc.bestTick = 0;
                ticksProcessed = 0;
            } else {
                (bool done, uint256 ticks) = _consumeBidSupply(
                    marketId,
                    batchId,
                    maxSteps
                );
                ticksProcessed = ticks;
                if (done) {
                    state.phase = FinalizePhase.DiscoverAsk;
                    state.cursorTick = agg.minActiveTick;
                    DiscoveryState storage disc = discoveryStates[marketId][
                        batchId
                    ];
                    disc.supplyPrefix = 0;
                    disc.demandBelow = 0;
                    disc.bestMatch = 0;
                    disc.bestTick = 0;
                }
            }
        } else if (state.phase == FinalizePhase.DiscoverAsk) {
            (bool askDone, uint256 ticks) = _discoverAskClearing(
                marketId,
                batchId,
                maxSteps
            );
            ticksProcessed = ticks;
            if (askDone) {
                state.phase = FinalizePhase.ConsumeAskSupply;
                ConsumptionState storage askCon = askConsumption[marketId][
                    batchId
                ];
                askCon.supplyCursor = agg.minActiveTick;
                askCon.supplyRemaining = state.askClearedQty;
            }
        } else if (state.phase == FinalizePhase.ConsumeAskSupply) {
            if (state.askClearedQty == 0) {
                state.phase = FinalizePhase.ConsumeAskDemand;
                ticksProcessed = 0;
            } else {
                (bool done, uint256 ticks) = _consumeAskSupply(
                    marketId,
                    batchId,
                    maxSteps
                );
                ticksProcessed = ticks;
                if (done) {
                    state.phase = FinalizePhase.ConsumeAskDemand;
                    ConsumptionState storage askCon = askConsumption[marketId][
                        batchId
                    ];
                    askCon.demandCursor = agg.maxActiveTick;
                    askCon.demandRemaining = state.askClearedQty;
                }
            }
        } else if (state.phase == FinalizePhase.ConsumeAskDemand) {
            if (state.askClearedQty == 0) {
                state.phase = FinalizePhase.Done;
                _finalizeBatch(marketId, batchId);
                ticksProcessed = 0;
            } else {
                (bool done, uint256 ticks) = _consumeAskDemand(
                    marketId,
                    batchId,
                    maxSteps
                );
                ticksProcessed = ticks;
                if (done) {
                    state.phase = FinalizePhase.Done;
                    _finalizeBatch(marketId, batchId);
                }
            }
        }

        return ticksProcessed;
    }

    function finalizeStep(
        uint64 marketId,
        uint64 batchId,
        uint256 maxSteps
    ) external returns (FinalizePhase phase, bool done) {
        require(
            marketId > 0 && marketId <= marketCount,
            "AuctionHouse: market does not exist"
        );

        uint64 currentBatchId = getBatchId(marketId);
        require(batchId < currentBatchId, "AuctionHouse: batch not ended");

        FinalizeState storage state = finalizeStates[marketId][batchId];
        require(
            state.phase != FinalizePhase.Done,
            "AuctionHouse: already finalized"
        );

        uint256 ticksProcessed = _executeFinalizeStep(
            marketId,
            batchId,
            maxSteps
        );

        emit FinalizeStepCompleted(
            marketId,
            batchId,
            state.phase,
            ticksProcessed
        );
        return (state.phase, state.phase == FinalizePhase.Done);
    }

    /// @dev When no liquidity: sets clearingTick = MIN_TICK (sentinel), clearedQty = 0
    function _discoverBidClearing(
        uint64 marketId,
        uint64 batchId,
        uint256 maxSteps
    ) internal returns (bool, uint256) {
        FinalizeState storage st = finalizeStates[marketId][batchId];
        DiscoveryState storage disc = discoveryStates[marketId][batchId];
        BatchAggregates storage agg = batchData[marketId][batchId];

        if (agg.totalMakerBuy == 0 || agg.totalTakerSell == 0) {
            st.bidClearingTick = MIN_TICK;
            st.bidClearedQty = 0;
            return (true, 0);
        }

        uint256 steps;
        int24 tick = st.cursorTick;
        uint256 totalDemand = uint256(agg.totalMakerBuy);

        while (steps < maxSteps && tick <= agg.maxActiveTick) {
            if (agg.tickBitmap.isTickActive(tick)) {
                OrderTypes.TickLevel storage lvl = agg.tickLevels[tick];
                uint256 supplyAt = uint256(lvl.takerSell);
                uint256 demandAt = uint256(lvl.makerBuy);

                uint256 demandAtOrAbove = totalDemand -
                    uint256(disc.demandBelow);

                disc.supplyPrefix = uint128(
                    uint256(disc.supplyPrefix) + supplyAt
                );

                uint256 matchQty = Math.min(
                    uint256(disc.supplyPrefix),
                    demandAtOrAbove
                );
                if (matchQty > disc.bestMatch) {
                    disc.bestMatch = uint128(matchQty);
                    disc.bestTick = tick;
                }

                disc.demandBelow = uint128(
                    uint256(disc.demandBelow) + demandAt
                );
                steps++;
            }

            (int24 nextTick, bool found) = agg.tickBitmap.nextActiveTick(
                tick + 1,
                agg.maxActiveTick
            );
            if (!found) {
                st.cursorTick = tick;
                st.bidClearingTick = disc.bestTick;
                st.bidClearedQty = disc.bestMatch;
                return (true, steps);
            }
            tick = nextTick;
        }

        st.cursorTick = tick;
        return (false, steps);
    }

    /// @dev When no liquidity: sets clearingTick = MAX_TICK (sentinel), clearedQty = 0
    function _discoverAskClearing(
        uint64 marketId,
        uint64 batchId,
        uint256 maxSteps
    ) internal returns (bool, uint256) {
        FinalizeState storage st = finalizeStates[marketId][batchId];
        DiscoveryState storage disc = discoveryStates[marketId][batchId];
        BatchAggregates storage agg = batchData[marketId][batchId];

        if (agg.totalMakerSell == 0 || agg.totalTakerBuy == 0) {
            st.askClearingTick = MAX_TICK;
            st.askClearedQty = 0;
            return (true, 0);
        }

        uint256 steps;
        int24 tick = st.cursorTick;
        uint256 totalDemand = uint256(agg.totalTakerBuy);

        while (steps < maxSteps && tick <= agg.maxActiveTick) {
            if (agg.tickBitmap.isTickActive(tick)) {
                OrderTypes.TickLevel storage lvl = agg.tickLevels[tick];
                uint256 supplyAt = uint256(lvl.makerSell);
                uint256 demandAt = uint256(lvl.takerBuy);

                uint256 demandAtOrAbove = totalDemand -
                    uint256(disc.demandBelow);

                disc.supplyPrefix = uint128(
                    uint256(disc.supplyPrefix) + supplyAt
                );

                uint256 matchQty = Math.min(
                    uint256(disc.supplyPrefix),
                    demandAtOrAbove
                );
                if (
                    matchQty > disc.bestMatch ||
                    (matchQty == disc.bestMatch && tick < disc.bestTick)
                ) {
                    disc.bestMatch = uint128(matchQty);
                    disc.bestTick = tick;
                }

                disc.demandBelow = uint128(
                    uint256(disc.demandBelow) + demandAt
                );
                steps++;
            }

            (int24 nextTick, bool found) = agg.tickBitmap.nextActiveTick(
                tick + 1,
                agg.maxActiveTick
            );
            if (!found) {
                st.cursorTick = tick;
                st.askClearingTick = disc.bestTick;
                st.askClearedQty = disc.bestMatch;
                return (true, steps);
            }
            tick = nextTick;
        }

        st.cursorTick = tick;
        return (false, steps);
    }

    function _consumeBidDemand(
        uint64 marketId,
        uint64 batchId,
        uint256 maxSteps
    ) internal returns (bool, uint256) {
        FinalizeState storage st = finalizeStates[marketId][batchId];
        ConsumptionState storage con = bidConsumption[marketId][batchId];
        BatchAggregates storage agg = batchData[marketId][batchId];

        // harden sentinel entry
        if (st.bidClearingTick == MIN_TICK) return (true, 0);

        uint256 steps;
        int24 tick = con.demandCursor;
        int24 clear = st.bidClearingTick;
        uint256 remaining = con.demandRemaining;

        while (steps < maxSteps && tick >= clear) {
            if (agg.tickBitmap.isTickActive(tick)) {
                OrderTypes.TickLevel storage lvl = agg.tickLevels[tick];
                TickFillState storage sh = agg.tickFills[tick];

                uint256 qty = uint256(lvl.makerBuy);
                if (qty > 0 && remaining > 0) {
                    uint256 exec = (tick == clear)
                        ? remaining
                        : Math.min(qty, remaining);
                    uint256 frac = (exec == qty) ? Q128 : (exec * Q128) / qty;
                    sh.mbFillX128 = frac;
                    remaining -= exec;
                }
                steps++;
            }

            if (tick == clear) break;
            (int24 prevTick, bool found) = agg.tickBitmap.prevActiveTick(
                tick - 1,
                clear
            );
            if (!found) break;
            tick = prevTick;
        }

        con.demandCursor = tick;
        con.demandRemaining = uint128(remaining);
        return (tick == clear, steps);
    }

    function _consumeBidSupply(
        uint64 marketId,
        uint64 batchId,
        uint256 maxSteps
    ) internal returns (bool, uint256) {
        FinalizeState storage st = finalizeStates[marketId][batchId];
        ConsumptionState storage con = bidConsumption[marketId][batchId];
        BatchAggregates storage agg = batchData[marketId][batchId];

        if (st.bidClearingTick == MIN_TICK) return (true, 0);

        uint256 steps;
        int24 tick = con.supplyCursor;
        int24 clear = st.bidClearingTick;
        uint256 remaining = con.supplyRemaining;

        while (steps < maxSteps && tick <= clear) {
            if (agg.tickBitmap.isTickActive(tick)) {
                OrderTypes.TickLevel storage lvl = agg.tickLevels[tick];
                TickFillState storage sh = agg.tickFills[tick];

                uint256 qty = uint256(lvl.takerSell);
                if (qty > 0 && remaining > 0) {
                    uint256 exec = (tick == clear)
                        ? remaining
                        : Math.min(qty, remaining);
                    uint256 frac = (exec == qty) ? Q128 : (exec * Q128) / qty;
                    sh.tsFillX128 = frac;
                    remaining -= exec;
                }
                steps++;
            }

            if (tick == clear) break;
            (int24 nextTick, bool found) = agg.tickBitmap.nextActiveTick(
                tick + 1,
                clear
            );
            if (!found) break;
            tick = nextTick;
        }

        con.supplyCursor = tick;
        con.supplyRemaining = uint128(remaining);
        return (tick == clear, steps);
    }

    function _consumeAskSupply(
        uint64 marketId,
        uint64 batchId,
        uint256 maxSteps
    ) internal returns (bool, uint256) {
        FinalizeState storage st = finalizeStates[marketId][batchId];
        ConsumptionState storage con = askConsumption[marketId][batchId];
        BatchAggregates storage agg = batchData[marketId][batchId];

        if (st.askClearingTick == MAX_TICK) return (true, 0);

        uint256 steps;
        int24 tick = con.supplyCursor;
        int24 clear = st.askClearingTick;
        uint256 remaining = con.supplyRemaining;

        while (steps < maxSteps && tick <= clear) {
            if (agg.tickBitmap.isTickActive(tick)) {
                OrderTypes.TickLevel storage lvl = agg.tickLevels[tick];
                TickFillState storage sh = agg.tickFills[tick];

                uint256 qty = uint256(lvl.makerSell);
                if (qty > 0 && remaining > 0) {
                    uint256 exec = (tick == clear)
                        ? remaining
                        : Math.min(qty, remaining);
                    uint256 frac = (exec == qty) ? Q128 : (exec * Q128) / qty;
                    sh.msFillX128 = frac;
                    remaining -= exec;
                }
                steps++;
            }

            if (tick == clear) break;
            (int24 nextTick, bool found) = agg.tickBitmap.nextActiveTick(
                tick + 1,
                clear
            );
            if (!found) break;
            tick = nextTick;
        }

        con.supplyCursor = tick;
        con.supplyRemaining = uint128(remaining);
        return (tick == clear, steps);
    }

    function _consumeAskDemand(
        uint64 marketId,
        uint64 batchId,
        uint256 maxSteps
    ) internal returns (bool, uint256) {
        FinalizeState storage st = finalizeStates[marketId][batchId];
        ConsumptionState storage con = askConsumption[marketId][batchId];
        BatchAggregates storage agg = batchData[marketId][batchId];

        if (st.askClearingTick == MAX_TICK) return (true, 0);

        uint256 steps;
        int24 tick = con.demandCursor;
        int24 clear = st.askClearingTick;
        uint256 remaining = con.demandRemaining;

        while (steps < maxSteps && tick >= clear) {
            if (agg.tickBitmap.isTickActive(tick)) {
                OrderTypes.TickLevel storage lvl = agg.tickLevels[tick];
                TickFillState storage sh = agg.tickFills[tick];

                uint256 qty = uint256(lvl.takerBuy);
                if (qty > 0 && remaining > 0) {
                    uint256 exec = (tick == clear)
                        ? remaining
                        : Math.min(qty, remaining);
                    uint256 frac = (exec == qty) ? Q128 : (exec * Q128) / qty;
                    sh.tbFillX128 = frac;
                    remaining -= exec;
                }
                steps++;
            }

            if (tick == clear) break;
            (int24 prevTick, bool found) = agg.tickBitmap.prevActiveTick(
                tick - 1,
                clear
            );
            if (!found) break;
            tick = prevTick;
        }

        con.demandCursor = tick;
        con.demandRemaining = uint128(remaining);
        return (tick == clear, steps);
    }

    function _finalizeBatch(uint64 marketId, uint64 batchId) internal {
        FinalizeState storage state = finalizeStates[marketId][batchId];

        AuctionState memory batchState = AuctionState({
            batchId: batchId,
            batchStart: batchId * uint64(BATCH_DURATION),
            batchEnd: (batchId + 1) * uint64(BATCH_DURATION),
            bidClearing: OrderTypes.Clearing({
                clearingTick: state.bidClearingTick,
                marginalFillMakerBps: 0,
                marginalFillTakerBps: 0,
                clearedQty: state.bidClearedQty,
                finalized: true
            }),
            askClearing: OrderTypes.Clearing({
                clearingTick: state.askClearingTick,
                marginalFillMakerBps: 0,
                marginalFillTakerBps: 0,
                clearedQty: state.askClearedQty,
                finalized: true
            })
        });

        historicalBatches[marketId][batchId] = batchState;

        emit BatchFinalized(marketId, batchId, AuctionSide.Bid);
        emit BatchFinalized(marketId, batchId, AuctionSide.Ask);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getClearing(
        uint64 marketId,
        uint64 batchId
    )
        external
        view
        returns (
            OrderTypes.Clearing memory bidClearing,
            OrderTypes.Clearing memory askClearing
        )
    {
        AuctionState storage batch = historicalBatches[marketId][batchId];
        return (batch.bidClearing, batch.askClearing);
    }

    function getOrder(
        bytes32 orderId
    )
        external
        view
        returns (OrderTypes.Order memory, OrderTypes.OrderState memory)
    {
        return (orders[orderId], orderStates[orderId]);
    }

    function getTickLevel(
        uint64 marketId,
        uint64 batchId,
        int24 tick
    ) external view returns (OrderTypes.TickLevel memory) {
        return batchData[marketId][batchId].tickLevels[tick];
    }

    function getOrderFilledQty(
        bytes32 orderId
    ) external view returns (uint128 filledQty) {
        OrderTypes.Order storage order = orders[orderId];
        if (order.trader == address(0)) return 0;

        uint64 batchId = orderBatches[orderId];
        BatchAggregates storage agg = batchData[order.marketId][batchId];
        TickFillState storage sh = agg.tickFills[order.priceTick];

        FinalizeState storage state = finalizeStates[order.marketId][batchId];
        if (state.phase != FinalizePhase.Done) return 0;

        uint256 fillX128;
        if (order.flow == OrderTypes.Flow.Maker) {
            fillX128 = (order.side == OrderTypes.Side.Buy)
                ? sh.mbFillX128
                : sh.msFillX128;
        } else {
            fillX128 = (order.side == OrderTypes.Side.Buy)
                ? sh.tbFillX128
                : sh.tsFillX128;
        }

        uint256 filled = (uint256(order.qty) * fillX128) >> 128;
        return uint128(filled);
    }

    function updateOrderState(
        bytes32 orderId,
        uint128 claimedQty,
        uint128 remainingQty
    ) external onlyRole(ROUTER_ROLE) {
        OrderTypes.OrderState storage state = orderStates[orderId];
        state.claimedQty = claimedQty;
        state.remainingQty = remainingQty;
    }
}
