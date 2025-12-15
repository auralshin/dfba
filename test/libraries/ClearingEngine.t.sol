// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ClearingEngine} from "../../src/libraries/ClearingEngine.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";
import {TickBitmap} from "../../src/libraries/TickBitmap.sol";

contract ClearingEngineTest is Test {
    mapping(int24 => OrderTypes.TickLevel) public tickLevels;
    mapping(int16 => uint256) public tickBitmap;

    function setUp() public {
        // Setup some test tick levels
        _addTickLevel(900, 100, 0, 50, 0);   // Maker sell at 900
        _addTickLevel(950, 150, 0, 75, 0);   // Maker sell at 950
        _addTickLevel(1000, 200, 0, 100, 0); // Maker sell at 1000
        _addTickLevel(1050, 0, 150, 0, 80);  // Maker buy at 1050
        _addTickLevel(1100, 0, 100, 0, 60);  // Maker buy at 1100
    }

    function _addTickLevel(
        int24 tick,
        uint128 makerSell,
        uint128 makerBuy,
        uint128 takerSell,
        uint128 takerBuy
    ) internal {
        tickLevels[tick] = OrderTypes.TickLevel({
            makerBuy: makerBuy,
            makerSell: makerSell,
            takerBuy: takerBuy,
            takerSell: takerSell
        });
        
        if (makerSell > 0 || makerBuy > 0 || takerSell > 0 || takerBuy > 0) {
            TickBitmap.setTickActive(tickBitmap, tick);
        }
    }

    function test_computeBuyClearing_fullMatch() public {
        // Taker wants to buy 100, maker willing to sell 100 at 900
        ClearingEngine.ClearingResult memory result = ClearingEngine.computeBuyClearing(
            tickLevels,
            tickBitmap,
            0,    // totalMakerBuy (unused)
            0,    // totalMakerSell (unused)
            100,  // totalTakerBuy
            0,    // totalTakerSell (unused)
            900,  // minActiveTick
            1100, // maxActiveTick
            1000  // maxIterations
        );

        assertEq(result.clearingTick, 900, "Should clear at lowest sell price");
        assertEq(result.clearedQty, 100, "Should clear 100 qty");
    }

    function test_computeBuyClearing_partialMatch() public {
        // Taker wants to buy 500, but only 450 available (100+150+200)
        ClearingEngine.ClearingResult memory result = ClearingEngine.computeBuyClearing(
            tickLevels,
            tickBitmap,
            0,
            0,
            500,  // totalTakerBuy
            0,
            900,
            1100,
            1000
        );

        // When supply is insufficient, clearing happens at maxActiveTick with pro-rata fill
        assertEq(result.clearingTick, 1100, "Should clear at maxActiveTick when supply insufficient");
        assertEq(result.clearedQty, 450, "Should clear accumulated supply");
        assertEq(result.marginalFillTakerBps, 9000, "Takers should get 90% fill (450/500)");
    }

    function test_computeSellClearing_fullMatch() public {
        // Taker wants to sell 100, maker willing to buy 100 at 1100
        ClearingEngine.ClearingResult memory result = ClearingEngine.computeSellClearing(
            tickLevels,
            tickBitmap,
            0,
            0,
            0,
            100,  // totalTakerSell
            900,
            1100,
            1000
        );

        assertEq(result.clearingTick, 1100, "Should clear at highest buy price");
        assertEq(result.clearedQty, 100, "Should clear 100 qty");
    }

    function test_computeBuyClearing_noMatch() public {
        // Taker wants to buy, but no maker sells
        mapping(int24 => OrderTypes.TickLevel) storage emptyLevels = tickLevels;
        mapping(int16 => uint256) storage emptyBitmap = tickBitmap;
        
        // Clear existing levels
        delete tickLevels[900];
        delete tickLevels[950];
        delete tickLevels[1000];
        
        ClearingEngine.ClearingResult memory result = ClearingEngine.computeBuyClearing(
            emptyLevels,
            emptyBitmap,
            0,
            0,
            100,
            0,
            900,
            1100,
            1000
        );

        assertEq(result.clearedQty, 0, "Should clear 0 qty");
    }

    function test_computeBuyClearing_marginalFill() public {
        // Taker wants 120, maker has 100 at tick 900
        // Should result in marginal fill at tick 900
        ClearingEngine.ClearingResult memory result = ClearingEngine.computeBuyClearing(
            tickLevels,
            tickBitmap,
            0,
            0,
            120,  // Want more than available at first tick
            0,
            900,
            900,  // Only check first tick
            1000
        );

        assertEq(result.clearingTick, 900, "Should clear at tick 900");
        // Marginal fill BPS should be calculated
        assertLt(result.marginalFillTakerBps, 10000, "Taker should have marginal fill");
    }
}
