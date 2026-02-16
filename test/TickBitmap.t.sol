// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TickBitmap} from "../src/libraries/TickBitmap.sol";

contract TickBitmapTest is Test {
    using TickBitmap for mapping(int16 => uint256);
    
    mapping(int16 => uint256) public bitmap;
    
    function testSetTickActive() public {
        TickBitmap.setTickActive(bitmap, 100);
        assertTrue(TickBitmap.isTickActive(bitmap, 100));
    }
    
    function testClearTick() public {
        TickBitmap.setTickActive(bitmap, 100);
        assertTrue(TickBitmap.isTickActive(bitmap, 100));
        
        TickBitmap.clearTick(bitmap, 100);
        assertFalse(TickBitmap.isTickActive(bitmap, 100));
    }
    
    function testNextActiveTick() public {
        TickBitmap.setTickActive(bitmap, 100);
        TickBitmap.setTickActive(bitmap, 200);
        TickBitmap.setTickActive(bitmap, 300);
        
        (int24 next, bool found) = TickBitmap.nextActiveTick(bitmap, 50, 500);
        assertTrue(found);
        assertEq(next, 100);
        
        (next, found) = TickBitmap.nextActiveTick(bitmap, 150, 500);
        assertTrue(found);
        assertEq(next, 200);
        
        (next, found) = TickBitmap.nextActiveTick(bitmap, 250, 500);
        assertTrue(found);
        assertEq(next, 300);
        
        (next, found) = TickBitmap.nextActiveTick(bitmap, 350, 500);
        assertFalse(found);
    }
    
    function testPrevActiveTick() public {
        TickBitmap.setTickActive(bitmap, 100);
        TickBitmap.setTickActive(bitmap, 200);
        TickBitmap.setTickActive(bitmap, 300);
        
        (int24 prev, bool found) = TickBitmap.prevActiveTick(bitmap, 350, 50);
        assertTrue(found);
        assertEq(prev, 300);
        
        (prev, found) = TickBitmap.prevActiveTick(bitmap, 250, 50);
        assertTrue(found);
        assertEq(prev, 200);
        
        (prev, found) = TickBitmap.prevActiveTick(bitmap, 150, 50);
        assertTrue(found);
        assertEq(prev, 100);
        
        (prev, found) = TickBitmap.prevActiveTick(bitmap, 50, 50);
        assertFalse(found);
    }
    
    function testPrevActiveTickBitPos255() public {
        // Critical edge case: tick with bitPos == 255
        int24 edgeTick = 255; // bitPos = 255, wordPos = 0
        
        TickBitmap.setTickActive(bitmap, edgeTick);
        assertTrue(TickBitmap.isTickActive(bitmap, edgeTick));
        
        // Should not overflow when searching for prev tick
        (int24 prev, bool found) = TickBitmap.prevActiveTick(bitmap, edgeTick, 0);
        assertTrue(found);
        assertEq(prev, edgeTick);
    }
    
    function testNextActiveTickBitPos255() public {
        // Critical edge case: tick with bitPos == 255
        int24 edgeTick = 255;
        
        TickBitmap.setTickActive(bitmap, edgeTick);
        
        // Should not overflow when searching for next tick
        (int24 next, bool found) = TickBitmap.nextActiveTick(bitmap, edgeTick, 1000);
        assertTrue(found);
        assertEq(next, edgeTick);
    }
    
    function testMultipleTicksInSameWord() public {
        // Ticks in same word (wordPos = 0, different bitPos)
        TickBitmap.setTickActive(bitmap, 0);
        TickBitmap.setTickActive(bitmap, 1);
        TickBitmap.setTickActive(bitmap, 2);
        TickBitmap.setTickActive(bitmap, 255); // Edge case
        
        assertTrue(TickBitmap.isTickActive(bitmap, 0));
        assertTrue(TickBitmap.isTickActive(bitmap, 1));
        assertTrue(TickBitmap.isTickActive(bitmap, 2));
        assertTrue(TickBitmap.isTickActive(bitmap, 255));
    }
    
    function testTicksAcrossWords() public {
        // Ticks in different words
        TickBitmap.setTickActive(bitmap, 0);    // wordPos = 0
        TickBitmap.setTickActive(bitmap, 256);  // wordPos = 1
        TickBitmap.setTickActive(bitmap, 512);  // wordPos = 2
        TickBitmap.setTickActive(bitmap, -256); // wordPos = -1
        
        assertTrue(TickBitmap.isTickActive(bitmap, 0));
        assertTrue(TickBitmap.isTickActive(bitmap, 256));
        assertTrue(TickBitmap.isTickActive(bitmap, 512));
        assertTrue(TickBitmap.isTickActive(bitmap, -256));
    }
    
    function testNegativeTicks() public {
        TickBitmap.setTickActive(bitmap, -100);
        TickBitmap.setTickActive(bitmap, -200);
        
        assertTrue(TickBitmap.isTickActive(bitmap, -100));
        assertTrue(TickBitmap.isTickActive(bitmap, -200));
        
        (int24 next, bool found) = TickBitmap.nextActiveTick(bitmap, -250, 0);
        assertTrue(found);
        assertEq(next, -200);
        
        (int24 prev, bool found2) = TickBitmap.prevActiveTick(bitmap, -50, -300);
        assertTrue(found2);
        assertEq(prev, -100);
    }
    
    function testPositionCalculation() public view {
        (int16 wordPos, uint8 bitPos) = TickBitmap.position(0);
        assertEq(wordPos, 0);
        assertEq(bitPos, 0);
        
        (wordPos, bitPos) = TickBitmap.position(100);
        assertEq(wordPos, 0);
        assertEq(bitPos, 100);
        
        (wordPos, bitPos) = TickBitmap.position(255);
        assertEq(wordPos, 0);
        assertEq(bitPos, 255);
        
        (wordPos, bitPos) = TickBitmap.position(256);
        assertEq(wordPos, 1);
        assertEq(bitPos, 0);
        
        (wordPos, bitPos) = TickBitmap.position(-1);
        assertEq(wordPos, -1);
        assertEq(bitPos, 255);
    }
    
    function testFuzzSetAndClear(int24 tick) public {
        // Bound tick to reasonable range
        tick = int24(bound(int256(tick), -10000, 10000));
        
        TickBitmap.setTickActive(bitmap, tick);
        assertTrue(TickBitmap.isTickActive(bitmap, tick));
        
        TickBitmap.clearTick(bitmap, tick);
        assertFalse(TickBitmap.isTickActive(bitmap, tick));
    }
    
    function testFuzzNextTick(int24 tick1, int24 tick2) public {
        tick1 = int24(bound(int256(tick1), -5000, 5000));
        tick2 = int24(bound(int256(tick2), -5000, 5000));
        
        if (tick1 > tick2) {
            (tick1, tick2) = (tick2, tick1);
        }
        
        TickBitmap.setTickActive(bitmap, tick1);
        TickBitmap.setTickActive(bitmap, tick2);
        
        (int24 next, bool found) = TickBitmap.nextActiveTick(bitmap, tick1 - 1, tick2 + 100);
        assertTrue(found);
        assertEq(next, tick1);
    }
}
