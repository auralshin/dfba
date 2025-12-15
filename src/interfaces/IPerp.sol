// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OrderTypes} from "../libraries/OrderTypes.sol";
import {PerpRisk} from "../perp/PerpRisk.sol";

/// @title IPerpVault
/// @notice Interface for perpetual futures margin vault
interface IPerpVault {
    function depositMargin(address token, uint256 amount, address to) external;
    
    function withdrawMargin(address token, uint256 amount, address to) external;
    
    function reserveInitialMargin(address user, uint64 marketId, address token, uint256 amount) external;

    function releaseInitialMargin(address user, uint64 marketId, uint256 amount) external;    function adjustMargin(address user, address token, int256 amount) external;
    
    function getMarginBalance(address user, address token) external view returns (uint256);
}

/// @title IPerpEngine
/// @notice Interface for perpetual futures engine
interface IPerpEngine {
    function placePerpOrder(OrderTypes.Order memory order, address collateralToken)
        external
        returns (bytes32 orderId);
    
    function claimPerp(bytes32 orderId, address collateralToken)
        external
        returns (uint128 fillQty, int128 realizedPnL);
    
    function applyFunding(uint64 marketId) external;
    
    function liquidate(address trader, uint64 marketId, address collateralToken) external;
    
    function getPosition(address trader, uint64 marketId)
        external
        view
        returns (PerpRisk.Position memory);
    
    function getUnrealizedPnL(address trader, uint64 marketId) external view returns (int256);
}

/// @title IPerpRisk
/// @notice Interface for perp risk calculations
interface IPerpRisk {
    function initialMarginRequired(uint64 marketId, uint128 size, uint256 price)
        external
        view
        returns (uint256);
    
    function maintenanceMarginRequired(uint64 marketId, uint128 size, uint256 markPrice)
        external
        view
        returns (uint256);
    
    function isLiquidatable(uint64 marketId, PerpRisk.Position memory position, uint256 markPrice)
        external
        view
        returns (bool);
}

/// @title IOracleAdapter
/// @notice Interface for price oracle
interface IOracleAdapter {
    function getIndexPrice(uint64 marketId) external view returns (uint256);
    
    function getMarkPrice(uint64 marketId) external view returns (uint256);
    
    function setOracle(uint64 marketId, address oracle) external;
}
