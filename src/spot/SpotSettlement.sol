// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OrderTypes} from "../libraries/OrderTypes.sol";
import {Math} from "../libraries/Math.sol";
import {AuctionHouse} from "../core/AuctionHouse.sol";
import {SpotVault} from "./SpotVault.sol";
import {FeeModel} from "./FeeModel.sol";

/// @title SpotSettlement
/// @notice Applies fills for spot orders using auction clearing results
/// @dev Each user claims their own order (O(1) settlement)
contract SpotSettlement {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    AuctionHouse public immutable AUCTION_HOUSE;
    SpotVault public immutable VAULT;
    FeeModel public immutable FEE_MODEL;

    /// @notice Escrow account for locked funds
    address public constant ESCROW = address(uint160(uint256(keccak256("DFBA.Escrow"))));

    /// @notice Track locked funds per order: orderId => (baseAmount, quoteAmount)
    mapping(bytes32 => LockedFunds) public lockedFunds;

    struct LockedFunds {
        uint128 baseAmount;
        uint128 quoteAmount;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OrderClaimed(
        bytes32 indexed orderId,
        address indexed trader,
        uint128 fillQty,
        uint256 fillPrice,
        uint256 fee
    );
    event FundsLocked(
        bytes32 indexed orderId,
        address indexed trader,
        uint128 baseAmount,
        uint128 quoteAmount
    );
    event FundsRefunded(
        bytes32 indexed orderId,
        address indexed trader,
        uint128 baseAmount,
        uint128 quoteAmount
    );

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _auctionHouse, address _vault, address _feeModel) {
        AUCTION_HOUSE = AuctionHouse(_auctionHouse);
        VAULT = SpotVault(_vault);
        FEE_MODEL = FeeModel(_feeModel);
    }

    /*//////////////////////////////////////////////////////////////
                         ORDER PLACEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a spot order and lock funds in escrow
    /// @param order The order to place
    /// @return orderId The order ID
    function placeSpotOrder(OrderTypes.Order memory order)
        external
        returns (bytes32 orderId)
    {
        require(order.trader == msg.sender, "SpotSettlement: wrong trader");

        (OrderTypes.MarketType marketType, address baseToken, address quoteToken,) = 
            AUCTION_HOUSE.markets(order.marketId);
        require(marketType == OrderTypes.MarketType.Spot, "SpotSettlement: not spot market");

        // Calculate orderId first
        orderId = OrderTypes.orderKey(order);

        // Calculate funds to lock
        uint256 price = OrderTypes.tickToPrice(order.priceTick);
        uint256 notional = Math.notional(order.qty, price);
        (uint256 fee,) = FEE_MODEL.feeFor(order.marketId, order.flow == OrderTypes.Flow.Maker, notional);

        if (order.side == OrderTypes.Side.Buy) {
            // Buy order: lock quote token (notional + fee)
            uint256 totalQuote = notional + fee;
            VAULT.debitCredit(quoteToken, msg.sender, ESCROW, totalQuote);
            lockedFunds[orderId] = LockedFunds({
                baseAmount: 0,
                quoteAmount: uint128(totalQuote)
            });
        } else {
            // Sell order: lock base token
            VAULT.debitCredit(baseToken, msg.sender, ESCROW, order.qty);
            lockedFunds[orderId] = LockedFunds({
                baseAmount: order.qty,
                quoteAmount: 0
            });
        }

        // Submit order to auction
        orderId = AUCTION_HOUSE.submitOrder(order);

        emit FundsLocked(orderId, msg.sender, lockedFunds[orderId].baseAmount, lockedFunds[orderId].quoteAmount);
        return orderId;
    }

    /*//////////////////////////////////////////////////////////////
                         SETTLEMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim settlement for a spot order (internal implementation)
    /// @param orderId The order ID to claim
    /// @return fillQty Quantity filled
    /// @return fillPrice Clearing price
    function claimSpot(bytes32 orderId) external returns (uint128 fillQty, uint256 fillPrice) {
        return _claimSpot(orderId, msg.sender);
    }

    /// @notice Internal claim implementation
    function _claimSpot(bytes32 orderId, address caller) internal returns (uint128 fillQty, uint256 fillPrice) {
        (OrderTypes.Order memory order, OrderTypes.OrderState memory state) = AUCTION_HOUSE.getOrder(orderId);
        require(order.trader == caller, "SpotSettlement: not order owner");
        require(!state.cancelled, "SpotSettlement: order cancelled");
        require(state.claimedQty == 0, "SpotSettlement: already claimed");

        (OrderTypes.MarketType marketType, address baseToken, address quoteToken,) = AUCTION_HOUSE.markets(order.marketId);
        require(marketType == OrderTypes.MarketType.Spot, "SpotSettlement: not spot market");

        (OrderTypes.Clearing memory buyClearing, OrderTypes.Clearing memory sellClearing) =
            AUCTION_HOUSE.getClearing(order.marketId, order.auctionId);

        OrderTypes.Clearing memory clearing;
        if (order.side == OrderTypes.Side.Buy) {
            clearing = buyClearing;
        } else {
            clearing = sellClearing;
        }

        require(clearing.finalized, "SpotSettlement: auction not finalized");

        if (!OrderTypes.inTheMoney(order, clearing)) {
            // SPOT-H1 FIX: Set remainingQty to order.qty (unfilled), not 0
            AUCTION_HOUSE.updateOrderState(orderId, 0, order.qty);
            
            // Refund locked funds from escrow
            LockedFunds memory locked = lockedFunds[orderId];
            (OrderTypes.MarketType marketType, address baseToken, address quoteToken,) = 
                AUCTION_HOUSE.markets(order.marketId);
            
            if (order.side == OrderTypes.Side.Buy && locked.quoteAmount > 0) {
                VAULT.debitCredit(quoteToken, ESCROW, order.trader, locked.quoteAmount);
            } else if (order.side == OrderTypes.Side.Sell && locked.baseAmount > 0) {
                VAULT.debitCredit(baseToken, ESCROW, order.trader, locked.baseAmount);
            }
            
            delete lockedFunds[orderId];
            emit FundsRefunded(orderId, order.trader, locked.baseAmount, locked.quoteAmount);
            emit OrderClaimed(orderId, order.trader, 0, 0, 0);
            return (0, 0);
        }

        OrderTypes.TickLevel memory level = AUCTION_HOUSE.getTickLevel(
            order.marketId,
            order.auctionId,
            order.priceTick
        );

        uint128 levelQty;
        if (order.flow == OrderTypes.Flow.Maker) {
            levelQty = order.side == OrderTypes.Side.Buy ? level.makerBuy : level.makerSell;
        } else {
            levelQty = order.side == OrderTypes.Side.Buy ? level.takerBuy : level.takerSell;
        }

        fillQty = OrderTypes.filledQty(order, clearing, levelQty);
        require(fillQty > 0, "SpotSettlement: zero fill");

        fillPrice = OrderTypes.tickToPrice(clearing.clearingTick);

        uint256 notional = Math.notional(fillQty, fillPrice);
        bool isMaker = (order.flow == OrderTypes.Flow.Maker);
        (uint256 fee, address feeRecipient) = FEE_MODEL.feeFor(order.marketId, isMaker, notional);

        // SPOT-C1 FIX: Move funds from ESCROW to trader (real settlement)
        if (order.side == OrderTypes.Side.Buy) {
            // Buyer receives base token from escrow (counterparty's locked base)
            VAULT.debitCredit(baseToken, ESCROW, order.trader, fillQty);
            
            // Calculate partial refund if not fully filled
            uint256 actualQuoteUsed = notional + fee;
            uint256 totalQuoteLocked = lockedFunds[orderId].quoteAmount;
            if (totalQuoteLocked > actualQuoteUsed) {
                // Refund excess quote
                VAULT.debitCredit(quoteToken, ESCROW, order.trader, totalQuoteLocked - actualQuoteUsed);
            }
            
            // Transfer fee to recipient
            if (fee > 0) {
                VAULT.debitCredit(quoteToken, ESCROW, feeRecipient, fee);
            }
        } else {
            // Seller receives quote token from escrow (counterparty's locked quote)
            VAULT.debitCredit(quoteToken, ESCROW, order.trader, notional - fee);
            
            // Calculate partial refund if not fully filled
            uint128 baseLocked = lockedFunds[orderId].baseAmount;
            if (baseLocked > fillQty) {
                // Refund unsold base
                VAULT.debitCredit(baseToken, ESCROW, order.trader, baseLocked - fillQty);
            }
            
            // Transfer fee to recipient
            if (fee > 0) {
                VAULT.debitCredit(quoteToken, ESCROW, feeRecipient, fee);
            }
        }

        delete lockedFunds[orderId];
        AUCTION_HOUSE.updateOrderState(orderId, fillQty, Math.sub128(order.qty, fillQty));

        emit OrderClaimed(orderId, order.trader, fillQty, fillPrice, fee);
    }

    /// @notice Batch claim multiple orders
    /// @param orderIds Array of order IDs to claim
    function batchClaimSpot(bytes32[] calldata orderIds) external {
        for (uint256 i = 0; i < orderIds.length; i++) {
            // SPOT-C2 FIX: Use internal call to preserve msg.sender
            (, OrderTypes.OrderState memory state) = AUCTION_HOUSE.getOrder(orderIds[i]);
            if (state.claimedQty == 0 && !state.cancelled) {
                _claimSpot(orderIds[i], msg.sender);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Preview settlement for an order
    function previewClaim(bytes32 orderId)
        external
        view
        returns (
            uint128 fillQty,
            uint256 fillPrice,
            uint256 notional,
            uint256 fee
        )
    {
        (OrderTypes.Order memory order,) = AUCTION_HOUSE.getOrder(orderId);
        (OrderTypes.Clearing memory buyClearing, OrderTypes.Clearing memory sellClearing) =
            AUCTION_HOUSE.getClearing(order.marketId, order.auctionId);

        OrderTypes.Clearing memory clearing = order.side == OrderTypes.Side.Buy ? buyClearing : sellClearing;

        if (!clearing.finalized || !OrderTypes.inTheMoney(order, clearing)) {
            return (0, 0, 0, 0);
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
        fillPrice = OrderTypes.tickToPrice(clearing.clearingTick);
        notional = Math.notional(fillQty, fillPrice);
        (fee,) = FEE_MODEL.feeFor(order.marketId, order.flow == OrderTypes.Flow.Maker, notional);
    }
}
