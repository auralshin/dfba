// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OrderTypes} from "./OrderTypes.sol";
import {TickBitmap} from "./TickBitmap.sol";
import {Math} from "./Math.sol";

/// @title ClearingEngine
/// @notice Pure implementation of DFBA uniform-price clearing algorithm
/// @dev Computes clearing price + marginal fill ratios on-chain
library ClearingEngine {
    using TickBitmap for mapping(int16 => uint256);

    /// @notice Auction aggregates for clearing computation
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

    /// @notice Clearing computation result
    struct ClearingResult {
        int24 clearingTick;
        uint16 marginalFillMakerBps;
        uint16 marginalFillTakerBps;
        uint128 clearedQty;
        uint128 demandAtClearing;
        uint128 supplyAtClearing;
    }

    /// @notice Compute buy auction clearing (taker buy vs maker sell)
    /// @dev Buy auction: takers want to buy, makers provide sell liquidity
    /// @param tickLevels Per-tick aggregates
    /// @param tickBitmap Active tick bitmap
    /// @param totalTakerBuy Total taker buy volume
    /// @param minActiveTick Minimum active tick
    /// @param maxActiveTick Maximum active tick
    /// @param maxIterations Max ticks to scan (gas limit)
    /// @return result Clearing parameters
    function computeBuyClearing(
        mapping(int24 => OrderTypes.TickLevel) storage tickLevels,
        mapping(int16 => uint256) storage tickBitmap,
        uint128 /* totalMakerBuy */,
        uint128 /* totalMakerSell */,
        uint128 totalTakerBuy,
        uint128 /* totalTakerSell */,
        int24 minActiveTick,
        int24 maxActiveTick,
        uint256 maxIterations
    ) internal view returns (ClearingResult memory result) {
        uint128 takerDemand = totalTakerBuy;
        if (takerDemand == 0) {

            return result;
        }


        uint128 cumulativeSupply = 0;
        int24 currentTick = minActiveTick;
        uint256 iterations = 0;

        while (iterations < maxIterations && currentTick <= maxActiveTick) {
            OrderTypes.TickLevel storage level = tickLevels[currentTick];
            uint128 supplyAtTick = level.makerSell;

            if (supplyAtTick > 0) {
                uint128 newSupply = Math.add128(cumulativeSupply, supplyAtTick);

                if (newSupply >= takerDemand) {

                    result.clearingTick = currentTick;
                    result.clearedQty = takerDemand;
                    result.demandAtClearing = takerDemand;
                    result.supplyAtClearing = newSupply;


                    uint128 neededFromTick = Math.sub128(takerDemand, cumulativeSupply);
                    if (neededFromTick < supplyAtTick) {

                        result.marginalFillMakerBps = uint16(
                            Math.mulDiv(neededFromTick, Math.BPS, supplyAtTick)
                        );
                    } else {

                        result.marginalFillMakerBps = uint16(Math.BPS);
                    }


                    result.marginalFillTakerBps = uint16(Math.BPS);
                    return result;
                }

                cumulativeSupply = newSupply;
            }


            (int24 nextTick, bool found) = tickBitmap.nextActiveTick(currentTick + 1, maxActiveTick);
            if (!found) break;
            currentTick = nextTick;

            iterations++;
        }


        if (cumulativeSupply > 0) {
            result.clearingTick = maxActiveTick;
            result.clearedQty = cumulativeSupply;
            result.demandAtClearing = takerDemand;
            result.supplyAtClearing = cumulativeSupply;
            result.marginalFillMakerBps = uint16(Math.BPS);
            result.marginalFillTakerBps = uint16(Math.mulDiv(cumulativeSupply, Math.BPS, takerDemand));
        }

        return result;
    }

    /// @notice Compute sell auction clearing (taker sell vs maker buy)
    /// @dev Sell auction: takers want to sell, makers provide buy liquidity
    /// @param tickLevels Per-tick aggregates
    /// @param tickBitmap Active tick bitmap
    /// @param totalTakerSell Total taker sell volume
    /// @param minActiveTick Minimum active tick
    /// @param maxActiveTick Maximum active tick
    /// @param maxIterations Max ticks to scan (gas limit)
    /// @return result Clearing parameters
    function computeSellClearing(
        mapping(int24 => OrderTypes.TickLevel) storage tickLevels,
        mapping(int16 => uint256) storage tickBitmap,
        uint128 /* totalMakerBuy */,
        uint128 /* totalMakerSell */,
        uint128 /* totalTakerBuy */,
        uint128 totalTakerSell,
        int24 minActiveTick,
        int24 maxActiveTick,
        uint256 maxIterations
    ) internal view returns (ClearingResult memory result) {
        uint128 takerSupply = totalTakerSell;
        if (takerSupply == 0) {

            return result;
        }


        uint128 cumulativeDemand = 0;
        int24 currentTick = maxActiveTick;
        uint256 iterations = 0;

        while (iterations < maxIterations && currentTick >= minActiveTick) {
            OrderTypes.TickLevel storage level = tickLevels[currentTick];
            uint128 demandAtTick = level.makerBuy;

            if (demandAtTick > 0) {
                uint128 newDemand = Math.add128(cumulativeDemand, demandAtTick);

                if (newDemand >= takerSupply) {

                    result.clearingTick = currentTick;
                    result.clearedQty = takerSupply;
                    result.demandAtClearing = newDemand;
                    result.supplyAtClearing = takerSupply;


                    uint128 neededFromTick = Math.sub128(takerSupply, cumulativeDemand);
                    if (neededFromTick < demandAtTick) {

                        result.marginalFillMakerBps = uint16(
                            Math.mulDiv(neededFromTick, Math.BPS, demandAtTick)
                        );
                    } else {

                        result.marginalFillMakerBps = uint16(Math.BPS);
                    }


                    result.marginalFillTakerBps = uint16(Math.BPS);
                    return result;
                }

                cumulativeDemand = newDemand;
            }


            (int24 prevTick, bool found) = tickBitmap.prevActiveTick(currentTick - 1, minActiveTick);
            if (!found) break;
            currentTick = prevTick;

            iterations++;
        }


        if (cumulativeDemand > 0) {
            result.clearingTick = minActiveTick;
            result.clearedQty = cumulativeDemand;
            result.demandAtClearing = cumulativeDemand;
            result.supplyAtClearing = takerSupply;
            result.marginalFillMakerBps = uint16(Math.BPS);
            result.marginalFillTakerBps = uint16(Math.mulDiv(cumulativeDemand, Math.BPS, takerSupply));
        }

        return result;
    }

    /// @notice Validate clearing result
    function isValidClearing(ClearingResult memory result) internal pure returns (bool) {
        return result.clearedQty > 0 && result.marginalFillMakerBps <= Math.BPS;
    }
}
