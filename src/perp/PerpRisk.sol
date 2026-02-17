// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DFBAMath} from "../libraries/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OracleAdapter} from "./OracleAdapter.sol";

/// @title PerpRisk
/// @notice Margin calculations and liquidation checks for perp positions
/// @dev Centralized risk management module
contract PerpRisk {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Risk parameters per market
    struct RiskParams {
        uint16 initialMarginBps;
        uint16 maintenanceMarginBps;
        uint16 liquidationFeeBps;
        uint128 maxLeverage;
        uint128 maxPositionSize;
    }

    /// @notice Position data structure
    /// @dev C5 FIX: Removed marginBalance field - use PerpVault as single source of truth
    /// Margin is tracked in PerpVault.marginBalances, not here
    struct Position {
        int128 size;
        uint128 entryPrice;
        int64 lastFundingIndex;
    }

    /// @notice Market risk parameters
    mapping(uint64 => RiskParams) public marketRiskParams;

    /// @notice Oracle adapter
    OracleAdapter public immutable ORACLE;

    /// @notice Admin
    address public admin;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RiskParamsUpdated(uint64 indexed marketId, RiskParams params);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdmin() internal view {
        require(msg.sender == admin, "PerpRisk: not admin");
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _oracle) {
        ORACLE = OracleAdapter(_oracle);
        admin = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setRiskParams(uint64 marketId, RiskParams calldata params) external onlyAdmin {
        require(params.initialMarginBps >= params.maintenanceMarginBps, "PerpRisk: IM < MM");
        require(params.initialMarginBps <= DFBAMath.BPS, "PerpRisk: invalid IM");
        require(params.maintenanceMarginBps <= DFBAMath.BPS, "PerpRisk: invalid MM");

        marketRiskParams[marketId] = params;
        emit RiskParamsUpdated(marketId, params);
    }

    /*//////////////////////////////////////////////////////////////
                       MARGIN CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate initial margin required for a new order
    /// @param marketId Market ID
    /// @param size Position size (absolute value)
    /// @param price Entry price
    /// @return Initial margin required
    function initialMarginRequired(uint64 marketId, uint128 size, uint256 price) external view returns (uint256) {
        RiskParams storage params = marketRiskParams[marketId];
        uint256 notional = DFBAMath.notional(size, price);
        return DFBAMath.applyBps(notional, params.initialMarginBps);
    }

    /// @notice Calculate maintenance margin required for a position
    /// @param marketId Market ID
    /// @param size Position size (absolute value)
    /// @param markPrice Current mark price
    /// @return Maintenance margin required
    function maintenanceMarginRequired(
        uint64 marketId,
        uint128 size,
        uint256 markPrice
    )
        external
        view
        returns (uint256)
    {
        RiskParams storage params = marketRiskParams[marketId];
        uint256 notional = DFBAMath.notional(size, markPrice);
        return DFBAMath.applyBps(notional, params.maintenanceMarginBps);
    }

    /// @notice Calculate unrealized PnL for a position
    /// @param position The position
    /// @param markPrice Current mark price
    /// @return PnL (positive for profit, negative for loss)
    function calculateUnrealizedPnL(Position memory position, uint256 markPrice) public pure returns (int256) {
        if (position.size == 0) return 0;

        uint128 absSize = SafeCast.toUint128(SignedMath.abs(position.size));
        uint256 currentValue = DFBAMath.notional(absSize, markPrice);
        uint256 entryValue = DFBAMath.notional(absSize, position.entryPrice);

        if (position.size > 0) {
            return int256(currentValue) - int256(entryValue);
        } else {
            return int256(entryValue) - int256(currentValue);
        }
    }

    /// @notice Check if a position is liquidatable
    /// @param marketId Market ID
    /// @param position The position
    /// @param markPrice Current mark price
    /// @param marginBalance Current margin balance from vault (can be negative after losses)
    /// @return True if position should be liquidated
    function isLiquidatable(
        uint64 marketId,
        Position memory position,
        uint256 markPrice,
        int256 marginBalance
    )
        external
        view
        returns (bool)
    {
        if (position.size == 0) return false;

        int256 unrealizedPnL = calculateUnrealizedPnL(position, markPrice);
        int256 totalMargin = marginBalance + unrealizedPnL;

        if (totalMargin <= 0) return true;

        uint128 absSize = SafeCast.toUint128(SignedMath.abs(position.size));
        uint256 mmRequired = this.maintenanceMarginRequired(marketId, absSize, markPrice);

        return uint256(totalMargin) < mmRequired;
    }

    /// @notice Calculate liquidation fee
    /// @param marketId Market ID
    /// @param positionSize Position size
    /// @param markPrice Mark price
    /// @return Liquidation fee
    function calculateLiquidationFee(
        uint64 marketId,
        uint128 positionSize,
        uint256 markPrice
    )
        external
        view
        returns (uint256)
    {
        RiskParams storage params = marketRiskParams[marketId];
        uint256 notional = DFBAMath.notional(positionSize, markPrice);
        return DFBAMath.applyBps(notional, params.liquidationFeeBps);
    }

    /// @notice Validate a new order doesn't exceed max position size
    /// @param marketId Market ID
    /// @param currentSize Current position size
    /// @param orderSize Order size (signed)
    /// @return True if valid
    function validatePositionSize(uint64 marketId, int128 currentSize, int128 orderSize) external view returns (bool) {
        RiskParams storage params = marketRiskParams[marketId];
        int128 newSize = currentSize + orderSize;
        return SignedMath.abs(newSize) <= params.maxPositionSize;
    }

    /// @notice Calculate maximum order size given available margin
    /// @param marketId Market ID
    /// @param availableMargin Available margin
    /// @param price Entry price
    /// @return Maximum order size
    function maxOrderSize(uint64 marketId, uint256 availableMargin, uint256 price) external view returns (uint128) {
        RiskParams storage params = marketRiskParams[marketId];

        // Prevent divide by zero
        require(params.initialMarginBps > 0, "PerpRisk: invalid IM");
        require(price > 0, "PerpRisk: invalid price");

        uint256 maxNotional = (availableMargin * DFBAMath.BPS) / params.initialMarginBps;
        uint256 size = (maxNotional * DFBAMath.WAD) / price;

        if (size > params.maxPositionSize) {
            size = params.maxPositionSize;
        }

        return SafeCast.toUint128(size);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getRiskParams(uint64 marketId) external view returns (RiskParams memory) {
        return marketRiskParams[marketId];
    }
}
