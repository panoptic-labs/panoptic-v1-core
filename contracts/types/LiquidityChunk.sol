// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Custom types
import {TokenId} from "@types/TokenId.sol";

/// @title A Panoptic Liquidity Chunk. Tracks Tick Range and Liquidity Information for a "chunk." Used to track movement of chunks.
/// @author Axicon Labs Limited
///
/// @notice
///   A liquidity chunk is an amount of `liquidity` (an amount of WETH, e.g.) deployed between two ticks: `tickLower` and `tickUpper`
///   into a concentrated liquidity AMM (Shown as "Other AMM liquidity" in the diagram below):
///
///                liquidity
///                    ▲      liquidity chunk
///                    │        │
///                    │    ┌───▼────┐   ▲
///                    │    │        │   │ liquidity/size
///      Other AMM     │  ┌─┴────────┴─┐ ▼ of chunk
///      liquidity  ───┼──┼─►          │
///                    │  │            │
///                    └──┴─▲────────▲─┴──► price ticks
///                         │        │
///                         │        │
///                    tickLower     │
///                              tickUpper
///
/// @notice Track Tick Range Information. Lower and Upper ticks including the liquidity deployed within that range.
/// @notice This is used to track information about a leg in the Option Position identified by `TokenId.sol`.
/// @notice We pack this tick range info into a uint256.
///
/// @dev PACKING RULES FOR A LIQUIDITYCHUNK:
/// =================================================================================================
/// @dev From the LSB to the MSB:
/// (1) Liquidity        128bits  : The liquidity within the chunk (uint128).
/// ( ) (Zero-bits)       80bits  : Zero-bits to match a total uint256.
/// (2) tick Upper        24bits  : The upper tick of the chunk (int24).
/// (3) tick Lower        24bits  : The lower tick of the chunk (int24).
/// Total                256bits  : Total bits used by a chunk.
/// ===============================================================================================
///
/// The bit pattern is therefore:
///
///           (3)             (2)             ( )                (1)
///    <-- 24 bits -->  <-- 24 bits -->  <-- 80 bits -->   <-- 128 bits -->
///        tickLower       tickUpper         Zeros             Liquidity
///
///        <--- most significant bit        least significant bit --->
///
library LiquidityChunk {
    using LiquidityChunk for uint256;
    uint256 internal constant CLEAR_TL_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint256 internal constant CLEAR_TU_MASK = 0xFFFFFF000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new liquidity chunk given by its bounding ticks and its liquidity.
    /// @param self the uint256 to turn into a liquidity chunk - assumed to be 0
    /// @param _tickLower the lower tick of this chunk
    /// @param _tickUpper the upper tick of this chunk
    /// @param amount the amount of liquidity to add to this chunk.
    /// @return the new liquidity chunk
    function createChunk(
        uint256 self,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 amount
    ) internal pure returns (uint256) {
        unchecked {
            return self.addLiquidity(amount).addTickLower(_tickLower).addTickUpper(_tickUpper);
        }
    }

    /// @notice Add liquidity to the chunk.
    /// @param self the LiquidityChunk
    /// @param amount the amount of liquidity to add to this chunk
    /// @return the chunk with added liquidity
    function addLiquidity(uint256 self, uint128 amount) internal pure returns (uint256) {
        unchecked {
            return self + uint256(amount);
        }
    }

    /// @notice Add the lower tick to this chunk.
    /// @param self the LiquidityChunk
    /// @param _tickLower the lower tick to add
    /// @return the chunk with added lower tick
    function addTickLower(uint256 self, int24 _tickLower) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(uint24(_tickLower)) << 232);
        }
    }

    /// @notice Add the upper tick to this chunk.
    /// @param self the LiquidityChunk
    /// @param _tickUpper the upper tick to add
    /// @return the chunk with added upper tick
    function addTickUpper(uint256 self, int24 _tickUpper) internal pure returns (uint256) {
        unchecked {
            // convert tick upper to uint24 as explicit conversion from int24 to uint256 is not allowed
            return self + ((uint256(uint24(_tickUpper))) << 208);
        }
    }

    /// @notice Overwrites the lower tick to this chunk.
    /// @param self the LiquidityChunk
    /// @param _tickLower the lower tick to add
    /// @return the chunk with added lower tick
    function updateTickLower(uint256 self, int24 _tickLower) internal pure returns (uint256) {
        unchecked {
            return (self & CLEAR_TL_MASK).addTickLower(_tickLower);
        }
    }

    /// @notice Overwrites the upper tick to this chunk.
    /// @param self the LiquidityChunk
    /// @param _tickUpper the upper tick to add
    /// @return the chunk with added upper tick
    function updateTickUpper(uint256 self, int24 _tickUpper) internal pure returns (uint256) {
        unchecked {
            // convert tick upper to uint24 as explicit conversion from int24 to uint256 is not allowed
            return (self & CLEAR_TU_MASK).addTickUpper(_tickUpper);
        }
    }

    /// @notice Copy the tick range (upper and lower ticks) of a chunk `from` to `self`.
    /// @notice This is helpful if you have a pre-existing liquidity amount, say "100" as a uint128. Simply cast to a uint256 and then we want
    ///  to pack in the tick range as well so we add that to the front (towards the MSB) of the bit pattern keeping the liquidity amount the same.
    /// @dev note that the liquidity itself is not transferred over from `other` - only the chunk bounds/ticks are.
    /// @dev assumes that the incoming chunk does *not* already have ticks since the operation is additive.
    /// @param self the chunk to copy the ticks *to* (recipient of the tick range)
    /// @param from pre-existing chunk with lower and upper ticks that we want to copy *from*
    /// @return a liquidity chunk with the lower and upper tick values added to it
    function copyTickRange(uint256 self, uint256 from) internal pure returns (uint256) {
        unchecked {
            return self.addTickLower(from.tickLower()).addTickUpper(from.tickUpper());
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the lower tick of a chunk.
    /// @param self the LiquidityChunk uint256
    /// @return the lower tick of this chunk
    function tickLower(uint256 self) internal pure returns (int24) {
        unchecked {
            return int24(int256(self >> 232));
        }
    }

    /// @notice Get the upper tick of a chunk.
    /// @param self the LiquidityChunk uint256
    /// @return the upper tick of this chunk
    function tickUpper(uint256 self) internal pure returns (int24) {
        unchecked {
            return int24(int256(self >> 208));
        }
    }

    /// @notice Get the amount of liquidity/size of a chunk.
    /// @param self the LiquidityChunk uint256
    /// @return the size of this chunk
    function liquidity(uint256 self) internal pure returns (uint128) {
        unchecked {
            return uint128(self);
        }
    }
}
