// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TickBitmap} from "../../src/libraries/TickBitmap.sol";

contract TickBitmapTest is Test {
    mapping(int16 => uint256) private bitmap;

    function test_setTickActive() public {
        int24 tick = 100;
        
        assertFalse(TickBitmap.isTickActive(bitmap, tick), "Tick should start inactive");
        
        TickBitmap.setTickActive(bitmap, tick);
        
        assertTrue(TickBitmap.isTickActive(bitmap, tick), "Tick should be active after setting");
    }

    function test_clearTick() public {
        int24 tick = 100;
        
        TickBitmap.setTickActive(bitmap, tick);
        assertTrue(TickBitmap.isTickActive(bitmap, tick), "Tick should be active");
        
        TickBitmap.clearTick(bitmap, tick);
        assertFalse(TickBitmap.isTickActive(bitmap, tick), "Tick should be inactive after clearing");
    }

    function test_nextActiveTick_sameWord() public {
        TickBitmap.setTickActive(bitmap, 100);
        TickBitmap.setTickActive(bitmap, 105);
        
        (int24 next, bool found) = TickBitmap.nextActiveTick(bitmap, 100, 200);
        
        assertTrue(found, "Should find tick");
        assertEq(next, 100, "Should find tick at 100");
        
        (next, found) = TickBitmap.nextActiveTick(bitmap, 101, 200);
        assertTrue(found, "Should find next tick");
        assertEq(next, 105, "Should find tick at 105");
    }

    function test_nextActiveTick_differentWord() public {
        TickBitmap.setTickActive(bitmap, 100);
        TickBitmap.setTickActive(bitmap, 300); // Different word (100 >> 8 != 300 >> 8)
        
        (int24 next, bool found) = TickBitmap.nextActiveTick(bitmap, 101, 500);
        
        assertTrue(found, "Should find tick in next word");
        assertEq(next, 300, "Should find tick at 300");
    }

    function test_nextActiveTick_notFound() public {
        TickBitmap.setTickActive(bitmap, 100);
        
        (int24 next, bool found) = TickBitmap.nextActiveTick(bitmap, 101, 200);
        
        assertFalse(found, "Should not find tick beyond maxTick");
    }

    function test_prevActiveTick_sameWord() public {
        TickBitmap.setTickActive(bitmap, 100);
        TickBitmap.setTickActive(bitmap, 105);
        
        (int24 prev, bool found) = TickBitmap.prevActiveTick(bitmap, 105, 0);
        
        assertTrue(found, "Should find tick");
        assertEq(prev, 105, "Should find tick at 105");
        
        (prev, found) = TickBitmap.prevActiveTick(bitmap, 104, 0);
        assertTrue(found, "Should find previous tick");
        assertEq(prev, 100, "Should find tick at 100");
    }

    function test_prevActiveTick_differentWord() public {
        TickBitmap.setTickActive(bitmap, 100);
        TickBitmap.setTickActive(bitmap, 300);
        
        (int24 prev, bool found) = TickBitmap.prevActiveTick(bitmap, 299, 0);
        
        assertTrue(found, "Should find tick in previous word");
        assertEq(prev, 100, "Should find tick at 100");
    }

    function test_prevActiveTick_notFound() public {
        TickBitmap.setTickActive(bitmap, 100);
        
        (int24 prev, bool found) = TickBitmap.prevActiveTick(bitmap, 99, 0);
        
        assertFalse(found, "Should not find tick below minTick");
    }

    function test_position() public {
        int24 tick = 1000;
        (int16 wordPos, uint8 bitPos) = TickBitmap.position(tick);
        
        assertEq(wordPos, int16(tick >> 8), "Word position should be tick >> 8");
        assertEq(bitPos, uint8(uint24(tick) & 0xFF), "Bit position should be tick & 0xFF");
    }

    function test_multipleTicks() public {
        int24[] memory ticks = new int24[](5);
        ticks[0] = 100;
        ticks[1] = 200;
        ticks[2] = 300;
        ticks[3] = 400;
        ticks[4] = 500;
        
        for (uint i = 0; i < ticks.length; i++) {
            TickBitmap.setTickActive(bitmap, ticks[i]);
        }
        
        for (uint i = 0; i < ticks.length; i++) {
            assertTrue(TickBitmap.isTickActive(bitmap, ticks[i]), "All ticks should be active");
        }
        
        // Test iteration
        (int24 current, bool found) = TickBitmap.nextActiveTick(bitmap, 100, 600);
        assertTrue(found, "Should find first tick");
        assertEq(current, 100, "First tick should be 100");
        
        for (uint i = 1; i < ticks.length; i++) {
            (current, found) = TickBitmap.nextActiveTick(bitmap, current + 1, 600);
            assertTrue(found, "Should find next tick");
            assertEq(current, ticks[i], "Should find correct tick");
        }
    }
}
