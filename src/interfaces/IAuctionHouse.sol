// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OrderTypes} from "../libraries/OrderTypes.sol";

/// @title IAuctionHouse
/// @notice Interface for the core DFBA auction engine
interface IAuctionHouse {
    function getAuctionId(uint64 marketId) external view returns (uint64);
    
    function submitOrder(OrderTypes.Order memory order) external returns (bytes32 orderId);
    
    function cancelOrder(bytes32 orderId) external;
    
    function finalizeAuction(uint64 marketId, uint64 auctionId) external;
    
    function getClearing(uint64 marketId, uint64 auctionId)
        external
        view
        returns (OrderTypes.Clearing memory buyClearing, OrderTypes.Clearing memory sellClearing);
    
    function getOrder(bytes32 orderId)
        external
        view
        returns (OrderTypes.Order memory, OrderTypes.OrderState memory);
    
    function updateOrderState(bytes32 orderId, uint128 claimedQty, uint128 remainingQty) external;
}
