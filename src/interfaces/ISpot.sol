// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISpotVault
/// @notice Interface for spot trading vault
interface ISpotVault {
    function deposit(address token, uint256 amount, address to) external;
    
    function withdraw(address token, uint256 amount, address to) external;
    
    function debitCredit(address token, address from, address to, uint256 amount) external;
    
    function balanceOf(address user, address token) external view returns (uint256);
}

/// @title ISpotSettlement
/// @notice Interface for spot order settlement
interface ISpotSettlement {
    function claimSpot(bytes32 orderId) external returns (uint128 fillQty, uint256 fillPrice);
    
    function batchClaimSpot(bytes32[] calldata orderIds) external;
    
    function previewClaim(bytes32 orderId)
        external
        view
        returns (uint128 fillQty, uint256 fillPrice, uint256 notional, uint256 fee);
}

/// @title IFeeModel
/// @notice Interface for fee calculations
interface IFeeModel {
    function feeFor(uint64 marketId, bool isMaker, uint256 notional)
        external
        view
        returns (uint256 fee, address recipient);
    
    function setMarketFees(uint64 marketId, uint16 makerFeeBps, uint16 takerFeeBps, address feeRecipient) external;
}
