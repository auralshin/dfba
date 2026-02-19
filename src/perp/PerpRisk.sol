// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DFBAMath} from "../libraries/Math.sol";
import {OrderTypes} from "../libraries/OrderTypes.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OracleAdapter} from "./OracleAdapter.sol";
import {IOracleSource} from "../interfaces/IOracleSource.sol";

interface ICoreVault {
    function balances(address user, uint256 subaccountId, address token) external view returns (uint256);
}

interface IPerpRouterPositions {
    function getPosition(address user, uint64 marketId) external view returns (int256);

    function getEntryPrice(address user, uint64 marketId) external view returns (uint256);
}

interface IAuctionHouse {
    function marketCount() external view returns (uint64);

    function markets(uint64 marketId)
        external
        view
        returns (OrderTypes.MarketType marketType, address baseToken, address quoteToken, bool active);

    function marketOracles(uint64 marketId) external view returns (address);
}

interface IOraclePriceNoMarket {
    function getPrice() external view returns (uint256);
}

interface IOracleMarkPrice {
    function getMarkPrice(uint64 marketId) external view returns (uint256);
}

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

    /// @notice Core vault reference for margin balances
    ICoreVault public vault;

    /// @notice Perp router reference for positions
    IPerpRouterPositions public perpRouter;

    /// @notice Auction house reference for markets/oracles
    IAuctionHouse public auctionHouse;

    /// @notice Admin
    address public admin;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RiskParamsUpdated(uint64 indexed marketId, RiskParams params);
    event DependenciesUpdated(address indexed vault, address indexed perpRouter, address indexed auctionHouse);

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

    constructor(
        address _oracle
    ) {
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

    function setDependencies(address _vault, address _perpRouter, address _auctionHouse) external onlyAdmin {
        require(_vault != address(0), "PerpRisk: zero vault");
        require(_perpRouter != address(0), "PerpRisk: zero router");
        require(_auctionHouse != address(0), "PerpRisk: zero auction house");

        vault = ICoreVault(_vault);
        perpRouter = IPerpRouterPositions(_perpRouter);
        auctionHouse = IAuctionHouse(_auctionHouse);

        emit DependenciesUpdated(_vault, _perpRouter, _auctionHouse);
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
    ) external view returns (uint256) {
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
    ) external view returns (bool) {
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
    ) external view returns (uint256) {
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
                          WITHDRAWAL CHECKS
    //////////////////////////////////////////////////////////////*/

    function canWithdraw(
        address user,
        uint256 subaccountId,
        address token,
        uint256 amount
    ) external view returns (bool) {
        require(address(vault) != address(0), "PerpRisk: vault not set");
        require(address(perpRouter) != address(0), "PerpRisk: router not set");
        require(address(auctionHouse) != address(0), "PerpRisk: auction not set");

        uint256 balance = vault.balances(user, subaccountId, token);
        if (amount > balance) return false;
        uint256 postBalance = balance - amount;

        uint256 totalMmRequired = 0;
        int256 unrealizedPnl = 0;
        uint64 marketCount = auctionHouse.marketCount();
        for (uint64 marketId = 1; marketId <= marketCount; marketId++) {
            (OrderTypes.MarketType marketType,, address quoteToken,) = auctionHouse.markets(marketId);
            if (marketType != OrderTypes.MarketType.Perp || quoteToken != token) continue;

            int256 position = perpRouter.getPosition(user, marketId);
            if (position == 0) continue;

            uint128 absSize = SafeCast.toUint128(SignedMath.abs(position));
            uint256 markPrice = _getMarkPrice(marketId);
            totalMmRequired += this.maintenanceMarginRequired(marketId, absSize, markPrice);

            uint256 entryPrice = perpRouter.getEntryPrice(user, marketId);
            if (entryPrice == 0) return false;

            unrealizedPnl += _calculateUnrealizedPnl(position, entryPrice, markPrice);
        }

        int256 equity = int256(postBalance) + unrealizedPnl;
        if (equity <= 0) return false;

        return equity >= int256(totalMmRequired);
    }

    function _calculateUnrealizedPnl(
        int256 position,
        uint256 entryPrice,
        uint256 markPrice
    ) internal pure returns (int256) {
        uint256 absSize = uint256(position >= 0 ? position : -position);
        uint256 entryValue = (absSize * entryPrice) / DFBAMath.WAD;
        uint256 markValue = (absSize * markPrice) / DFBAMath.WAD;

        if (position >= 0) {
            return int256(markValue) - int256(entryValue);
        }

        return int256(entryValue) - int256(markValue);
    }

    function _getMarkPrice(
        uint64 marketId
    ) internal view returns (uint256) {
        address oracle = auctionHouse.marketOracles(marketId);
        require(oracle != address(0), "PerpRisk: oracle missing");

        try IOracleSource(oracle).getPrice(marketId) returns (uint256 price) {
            return price;
        } catch {}

        try IOraclePriceNoMarket(oracle).getPrice() returns (uint256 price) {
            return price;
        } catch {}

        try IOracleMarkPrice(oracle).getMarkPrice(marketId) returns (uint256 price) {
            return price;
        } catch {}

        revert("PerpRisk: oracle unsupported");
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getRiskParams(
        uint64 marketId
    ) external view returns (RiskParams memory) {
        return marketRiskParams[marketId];
    }
}
