// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TickBitmap
/// @notice Efficiently track which price ticks have active orders
/// @dev Similar to Uniswap v3 tick bitmap for gas-efficient iteration
library TickBitmap {
    uint256 private constant ONE = 1;

    /// @notice Get the position in the bitmap for a tick
    /// @param tick The tick
    /// @return wordPos The word position (tick >> 8)
    /// @return bitPos The bit position (tick & 0xFF)
    function position(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick) & 0xFF);
    }

    /// @notice Mark a tick as active
    /// @param self The mapping storing the bitmap
    /// @param tick The tick to activate
    function setTickActive(mapping(int16 => uint256) storage self, int24 tick) internal {
        (int16 wordPos, uint8 bitPos) = position(tick);
        self[wordPos] |= (ONE << bitPos);
    }

    /// @notice Mark a tick as inactive
    /// @param self The mapping storing the bitmap
    /// @param tick The tick to deactivate
    function clearTick(mapping(int16 => uint256) storage self, int24 tick) internal {
        (int16 wordPos, uint8 bitPos) = position(tick);
        self[wordPos] &= ~(ONE << bitPos);
    }

    /// @notice Check if a tick is active
    /// @param self The mapping storing the bitmap
    /// @param tick The tick to check
    /// @return True if tick is active
    function isTickActive(mapping(int16 => uint256) storage self, int24 tick)
        internal
        view
        returns (bool)
    {
        (int16 wordPos, uint8 bitPos) = position(tick);
        return (self[wordPos] & (ONE << bitPos)) != 0;
    }

    /// @notice Find the next active tick >= tick
    /// @param self The mapping storing the bitmap
    /// @param tick The starting tick
    /// @param maxTick The maximum tick to search
    /// @return next The next active tick
    /// @return found True if an active tick was found
    function nextActiveTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 maxTick
    ) internal view returns (int24 next, bool found) {
        if (tick > maxTick) return (0, false);

        (int16 wordPos, uint8 bitPos) = position(tick);


        uint256 word = self[wordPos];
        uint256 mask = ~((ONE << bitPos) - ONE);
        uint256 masked = word & mask;

        if (masked != 0) {

            uint8 bit = leastSignificantBit(masked);
            next = (int24(wordPos) << 8) | int24(uint24(bit));
            return (next, next <= maxTick);
        }


        int16 maxWordPos = int16(maxTick >> 8);
        for (int16 wp = wordPos + 1; wp <= maxWordPos; wp++) {
            word = self[wp];
            if (word != 0) {
                uint8 bit = leastSignificantBit(word);
                next = (int24(wp) << 8) | int24(uint24(bit));
                return (next, next <= maxTick);
            }
        }

        return (0, false);
    }

    /// @notice Find the previous active tick <= tick
    /// @param self The mapping storing the bitmap
    /// @param tick The starting tick
    /// @param minTick The minimum tick to search
    /// @return prev The previous active tick
    /// @return found True if an active tick was found
    function prevActiveTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 minTick
    ) internal view returns (int24 prev, bool found) {
        if (tick < minTick) return (0, false);

        (int16 wordPos, uint8 bitPos) = position(tick);


        uint256 word = self[wordPos];
        uint256 mask = (ONE << (bitPos + 1)) - ONE;
        uint256 masked = word & mask;

        if (masked != 0) {

            uint8 bit = mostSignificantBit(masked);
            prev = (int24(wordPos) << 8) | int24(uint24(bit));
            return (prev, prev >= minTick);
        }


        int16 minWordPos = int16(minTick >> 8);
        for (int16 wp = wordPos - 1; wp >= minWordPos; wp--) {
            word = self[wp];
            if (word != 0) {
                uint8 bit = mostSignificantBit(word);
                prev = (int24(wp) << 8) | int24(uint24(bit));
                return (prev, prev >= minTick);
            }
        }

        return (0, false);
    }

    /// @notice Get least significant bit position
    /// @param x The word
    /// @return r The bit position
    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x != 0, "TickBitmap: zero word");

        if (x & type(uint128).max == 0) {
            r += 128;
            x >>= 128;
        }
        if (x & type(uint64).max == 0) {
            r += 64;
            x >>= 64;
        }
        if (x & type(uint32).max == 0) {
            r += 32;
            x >>= 32;
        }
        if (x & type(uint16).max == 0) {
            r += 16;
            x >>= 16;
        }
        if (x & type(uint8).max == 0) {
            r += 8;
            x >>= 8;
        }
        if (x & 0xf == 0) {
            r += 4;
            x >>= 4;
        }
        if (x & 0x3 == 0) {
            r += 2;
            x >>= 2;
        }
        if (x & 0x1 == 0) {
            r += 1;
        }
    }

    /// @notice Get most significant bit position
    /// @param x The word
    /// @return r The bit position
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x != 0, "TickBitmap: zero word");

        if (x >= 0x100000000000000000000000000000000) {
            r += 128;
            x >>= 128;
        }
        if (x >= 0x10000000000000000) {
            r += 64;
            x >>= 64;
        }
        if (x >= 0x100000000) {
            r += 32;
            x >>= 32;
        }
        if (x >= 0x10000) {
            r += 16;
            x >>= 16;
        }
        if (x >= 0x100) {
            r += 8;
            x >>= 8;
        }
        if (x >= 0x10) {
            r += 4;
            x >>= 4;
        }
        if (x >= 0x4) {
            r += 2;
            x >>= 2;
        }
        if (x >= 0x2) {
            r += 1;
        }
    }
}
