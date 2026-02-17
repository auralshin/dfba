// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OrderTypes} from "../libraries/OrderTypes.sol";

/// @title IAuctionHouse
/// @notice Interface for the core DFBA auction engine
/// @dev Implements auto-settlement: submitOrder() automatically finalizes previous batches
///      This eliminates the need for external keepers or manual finalization
interface IAuctionHouse {
    function getAuctionId(uint64 marketId) external view returns (uint64);

    /// @notice Submit an order to the auction house
    /// @dev Automatically triggers settlement of previous batch if needed
    /// @param order The order to submit
    /// @return orderId Unique identifier for the order
    /// @return batchId The batch this order was assigned to
    function submitOrder(OrderTypes.Order memory order) external returns (bytes32 orderId, uint64 batchId);

    function cancelOrder(bytes32 orderId) external;

    function finalizeAuction(uint64 marketId, uint64 auctionId) external;

    function getClearing(
        uint64 marketId,
        uint64 auctionId
    )
        external
        view
        returns (OrderTypes.Clearing memory buyClearing, OrderTypes.Clearing memory sellClearing);

    function getOrder(bytes32 orderId) external view returns (OrderTypes.Order memory, OrderTypes.OrderState memory);

    function updateOrderState(bytes32 orderId, uint128 claimedQty, uint128 remainingQty) external;
}
