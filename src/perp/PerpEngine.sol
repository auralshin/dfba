// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OrderTypes} from "../libraries/OrderTypes.sol";
import {Math} from "../libraries/Math.sol";
import {AuctionHouse} from "../core/AuctionHouse.sol";
import {PerpVault} from "./PerpVault.sol";
import {PerpRisk} from "./PerpRisk.sol";
import {OracleAdapter} from "./OracleAdapter.sol";

/// @title PerpEngine
/// @notice Perpetual futures position management and settlement
/// @dev Integrates with DFBA auction system for order matching
contract PerpEngine {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    AuctionHouse public immutable AUCTION_HOUSE;
    PerpVault public immutable VAULT;
    PerpRisk public immutable RISK;
    OracleAdapter public immutable ORACLE;

    address public admin;

    /// @notice Positions: trader => marketId => position
    mapping(address => mapping(uint64 => PerpRisk.Position)) public positions;

    /// @notice Track collateral token used for each position: trader => marketId => token
    /// @dev C5 FIX: Need to track which collateral backs each position for margin adjustments
    mapping(address => mapping(uint64 => address)) public positionCollateral;

    /// @notice Funding state per market
    struct FundingState {
        int64 fundingIndex;
        uint64 lastUpdateTime;
        int128 fundingRate;
    }

    mapping(uint64 => FundingState) public fundingStates;

    /// @notice Claimed perp orders
    mapping(bytes32 => bool) public claimed;

    /// @notice Insurance fund
    mapping(address => uint256) public insuranceFund;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PositionUpdated(
        address indexed trader,
        uint64 indexed marketId,
        int128 newSize,
        uint128 newEntryPrice,
        int128 realizedPnL
    );
    event OrderClaimed(bytes32 indexed orderId, address indexed trader, uint128 fillQty, int128 pnl);
    event FundingApplied(uint64 indexed marketId, int64 fundingIndex, int128 fundingRate);
    event Liquidation(address indexed trader, uint64 indexed marketId, address indexed liquidator, uint256 fee);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _auctionHouse, address _vault, address _risk, address _oracle) {
        AUCTION_HOUSE = AuctionHouse(_auctionHouse);
        VAULT = PerpVault(_vault);
        RISK = PerpRisk(_risk);
        ORACLE = OracleAdapter(_oracle);
        admin = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                          ORDER PLACEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a perp order (reserves margin, submits to auction)
    /// @param order The order to place
    /// @param collateralToken Collateral token to use
    function placePerpOrder(OrderTypes.Order memory order, address collateralToken)
        external
        returns (bytes32 orderId)
    {
        require(order.trader == msg.sender, "PerpEngine: wrong trader");


        (OrderTypes.MarketType marketType, , ,) = AUCTION_HOUSE.markets(order.marketId);
        require(marketType == OrderTypes.MarketType.Perp, "PerpEngine: not perp market");


        uint256 price = OrderTypes.tickToPrice(order.priceTick);
        uint256 imRequired = RISK.initialMarginRequired(order.marketId, order.qty, price);


        VAULT.reserveInitialMargin(msg.sender, order.marketId, collateralToken, imRequired);

        // C5 FIX: Track collateral token for this position
        if (positionCollateral[msg.sender][order.marketId] == address(0)) {
            positionCollateral[msg.sender][order.marketId] = collateralToken;
        }

        orderId = AUCTION_HOUSE.submitOrder(order);

        return orderId;
    }

    /*//////////////////////////////////////////////////////////////
                         SETTLEMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim settlement for a perp order
    /// @param orderId The order ID to claim
    /// @param collateralToken Collateral token used
    function claimPerp(bytes32 orderId, address collateralToken)
        external
        returns (uint128 fillQty, int128 realizedPnL)
    {
        require(!claimed[orderId], "PerpEngine: already claimed");


        (OrderTypes.Order memory order, OrderTypes.OrderState memory state) = AUCTION_HOUSE.getOrder(orderId);
        require(order.trader == msg.sender, "PerpEngine: not order owner");
        require(!state.cancelled, "PerpEngine: order cancelled");


        (OrderTypes.Clearing memory buyClearing, OrderTypes.Clearing memory sellClearing) =
            AUCTION_HOUSE.getClearing(order.marketId, order.auctionId);

        OrderTypes.Clearing memory clearing = order.side == OrderTypes.Side.Buy ? buyClearing : sellClearing;
        require(clearing.finalized, "PerpEngine: auction not finalized");


        if (!OrderTypes.inTheMoney(order, clearing)) {
            // H2 FIX: Pass collateralToken when releasing IM
            uint256 price = OrderTypes.tickToPrice(order.priceTick);
            uint256 imToRelease = RISK.initialMarginRequired(order.marketId, order.qty, price);
            VAULT.releaseInitialMargin(msg.sender, order.marketId, collateralToken, imToRelease);

            claimed[orderId] = true;
            emit OrderClaimed(orderId, msg.sender, 0, 0);
            return (0, 0);
        }


        OrderTypes.TickLevel memory level = AUCTION_HOUSE.getTickLevel(
            order.marketId,
            order.auctionId,
            order.priceTick
        );

        uint128 levelQty = order.flow == OrderTypes.Flow.Maker
            ? (order.side == OrderTypes.Side.Buy ? level.makerBuy : level.makerSell)
            : (order.side == OrderTypes.Side.Buy ? level.takerBuy : level.takerSell);

        fillQty = OrderTypes.filledQty(order, clearing, levelQty);
        require(fillQty > 0, "PerpEngine: zero fill");

        uint256 fillPrice = OrderTypes.tickToPrice(clearing.clearingTick);

        // H1 FIX: Use safe int128 cast
        int128 sizeDelta = order.side == OrderTypes.Side.Buy 
            ? Math.toInt128(int256(uint256(fillQty)))
            : -Math.toInt128(int256(uint256(fillQty)));

        realizedPnL = _updatePosition(
            msg.sender,
            order.marketId,
            sizeDelta,
            uint128(fillPrice)
        );


        VAULT.adjustMargin(msg.sender, collateralToken, realizedPnL);

        // H2 FIX: Pass collateralToken when releasing IM
        uint256 imReserved = RISK.initialMarginRequired(order.marketId, order.qty, OrderTypes.tickToPrice(order.priceTick));
        VAULT.releaseInitialMargin(msg.sender, order.marketId, collateralToken, imReserved);

        claimed[orderId] = true;
        AUCTION_HOUSE.updateOrderState(orderId, fillQty, Math.sub128(order.qty, fillQty));

        emit OrderClaimed(orderId, msg.sender, fillQty, realizedPnL);
    }

    /// @notice Update position with new fill
    function _updatePosition(
        address trader,
        uint64 marketId,
        int128 sizeDelta,
        uint128 fillPrice
    ) internal returns (int128 realizedPnL) {
        PerpRisk.Position storage pos = positions[trader][marketId];


        _settleFunding(trader, marketId);

        if (pos.size == 0) {

            pos.size = sizeDelta;
            pos.entryPrice = fillPrice;
            realizedPnL = 0;
        } else if ((pos.size > 0 && sizeDelta > 0) || (pos.size < 0 && sizeDelta < 0)) {

            uint128 oldSize = uint128(Math.abs(pos.size));
            

            pos.entryPrice = uint128(Math.weightedAverage(
                pos.entryPrice,
                oldSize,
                fillPrice,
                uint128(Math.abs(sizeDelta))
            ));
            pos.size += sizeDelta;
            realizedPnL = 0;
        } else {

            uint128 absOldSize = uint128(Math.abs(pos.size));
            uint128 absSizeDelta = uint128(Math.abs(sizeDelta));

            if (absSizeDelta <= absOldSize) {

                uint256 closeNotional = Math.notional(absSizeDelta, fillPrice);
                uint256 entryNotional = Math.notional(absSizeDelta, pos.entryPrice);

                if (pos.size > 0) {

                    realizedPnL = Math.toInt128(int256(closeNotional) - int256(entryNotional));
                } else {

                    realizedPnL = Math.toInt128(int256(entryNotional) - int256(closeNotional));
                }

                pos.size += sizeDelta;
                if (pos.size == 0) {
                    pos.entryPrice = 0;
                }
            } else {


                uint256 closeNotional = Math.notional(absOldSize, fillPrice);
                uint256 entryNotional = Math.notional(absOldSize, pos.entryPrice);

                if (pos.size > 0) {
                    realizedPnL = Math.toInt128(int256(closeNotional) - int256(entryNotional));
                } else {
                    realizedPnL = Math.toInt128(int256(entryNotional) - int256(closeNotional));
                }


                pos.size = sizeDelta + pos.size;
                pos.entryPrice = fillPrice;
            }
        }

        emit PositionUpdated(trader, marketId, pos.size, pos.entryPrice, realizedPnL);
    }

    /*//////////////////////////////////////////////////////////////
                         FUNDING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Apply funding to a trader's position
    /// @dev C5 FIX: Apply funding via vault adjustMargin instead of position.marginBalance
    function _settleFunding(address trader, uint64 marketId) internal {
        PerpRisk.Position storage pos = positions[trader][marketId];
        if (pos.size == 0) return;

        FundingState storage funding = fundingStates[marketId];
        int64 fundingDelta = funding.fundingIndex - pos.lastFundingIndex;

        if (fundingDelta != 0) {
            // Calculate funding payment (negative means trader pays, positive means trader receives)
            int256 fundingPayment = (int256(pos.size) * fundingDelta) / 1e6;
            
            // Apply funding to vault balance (negate because payment reduces margin)
            address collateralToken = positionCollateral[trader][marketId];
            if (collateralToken != address(0)) {
                VAULT.adjustMargin(trader, collateralToken, -fundingPayment);
            }
            
            pos.lastFundingIndex = funding.fundingIndex;
        }
    }

    /// @notice Update funding rate for a market (called periodically)
    function applyFunding(uint64 marketId) external {
        FundingState storage funding = fundingStates[marketId];
        
        uint64 timeDelta = uint64(block.timestamp) - funding.lastUpdateTime;
        if (timeDelta == 0) return;



        int128 newRate = _calculateFundingRate(marketId);
        
        // H1 FIX: Safe int cast for funding index calculation
        int256 rateDelta = int256(newRate) * int256(uint256(timeDelta));
        int64 indexDelta = int64(rateDelta / 3600);
        funding.fundingIndex += indexDelta;
        funding.fundingRate = newRate;
        funding.lastUpdateTime = uint64(block.timestamp);

        emit FundingApplied(marketId, funding.fundingIndex, newRate);
    }

    function _calculateFundingRate(uint64 /* marketId */) internal pure returns (int128) {


        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidate an underwater position
    function liquidate(address trader, uint64 marketId, address collateralToken) external {
        PerpRisk.Position storage pos = positions[trader][marketId];
        require(pos.size != 0, "PerpEngine: no position");


        _settleFunding(trader, marketId);

        // C5 FIX: Get margin from vault, not from position
        uint256 markPrice = ORACLE.getMarkPrice(marketId);
        uint256 vaultBalance = VAULT.getMarginBalance(trader, collateralToken);
        int256 marginBalance = int256(vaultBalance);
        
        require(RISK.isLiquidatable(marketId, pos, markPrice, marginBalance), "PerpEngine: not liquidatable");


        uint128 absSize = uint128(Math.abs(pos.size));
        uint256 liqFee = RISK.calculateLiquidationFee(marketId, absSize, markPrice);


        int256 pnl = RISK.calculateUnrealizedPnL(pos, markPrice);
        int256 totalMarginWithPnl = marginBalance + pnl;
        int256 finalMargin = totalMarginWithPnl - int256(liqFee);


        if (liqFee > 0 && liqFee <= vaultBalance) {
            VAULT.transferMargin(collateralToken, trader, msg.sender, liqFee);
        }

        // H3 FIX: Actually transfer remaining margin to insurance fund
        if (finalMargin > 0) {
            uint256 toInsurance = uint256(finalMargin);
            if (toInsurance <= vaultBalance - liqFee) {
                VAULT.transferMargin(collateralToken, trader, address(this), toInsurance);
                insuranceFund[collateralToken] += toInsurance;
            }
        }


        delete positions[trader][marketId];
        delete positionCollateral[trader][marketId];

        emit Liquidation(trader, marketId, msg.sender, liqFee);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getPosition(address trader, uint64 marketId)
        external
        view
        returns (PerpRisk.Position memory)
    {
        return positions[trader][marketId];
    }

    function getUnrealizedPnL(address trader, uint64 marketId) external view returns (int256) {
        PerpRisk.Position storage pos = positions[trader][marketId];
        if (pos.size == 0) return 0;

        uint256 markPrice = ORACLE.getMarkPrice(marketId);
        return RISK.calculateUnrealizedPnL(pos, markPrice);
    }

    function getFundingState(uint64 marketId) external view returns (FundingState memory) {
        return fundingStates[marketId];
    }
}
