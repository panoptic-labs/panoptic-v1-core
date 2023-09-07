// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {LiquidityChunk} from "@types/LiquidityChunk.sol";

/// @title LeftRightHarness: A harness to expose the LeftRight library for code coverage analysis.
/// @notice Replicates the interface of the LeftRight library, passing through any function calls
/// @author Axicon Labs Limited
contract LiquidityChunkHarness {
    /**
     * @dev PACKING RULES FOR A LIQUIDITYCHUNK:
     * =================================================================================================
     * @dev From the LSB to the MSB:
     * (1) Liquidity        128bits  : The liquidity within the chunk (uint128).
     * ( ) (Zero-bits)       80bits  : Zero-bits to match a total uint256.
     * (2) tick Upper        24bits  : The upper tick of the chunk (int24).
     * (3) tick Lower        24bits  : The lower tick of the chunk (int24).
     * Total                256bits  : Total bits used by a chunk.
     * ===============================================================================================
     *
     * The bit pattern is therefore:
     *
     *           (3)             (2)             ( )                (1)
     *    <-- 24 bits -->  <-- 24 bits -->  <-- 80 bits -->   <-- 128 bits -->
     *        tickLower       tickUpper         Zeros             Liquidity
     *
     *        <--- most significant bit        least significant bit --->
     */

    /*****************************************************************/
    /*
    /* CONSTANTS AND "USING FOR"
    /*
    /*****************************************************************/
    using LiquidityChunk for uint256;

    int256 public constant BITMASK_INT24 = 0xFFFFFF;

    /*****************************************************************/
    /*
    /* WRITE TO A LIQUIDITYCHUNK
    /*
    /*****************************************************************/

    /**
     * @notice Create a new liquidity chunk given by its bounding ticks and its liquidity.
     * @param self the uint256 to turn into a liquidity chunk - assumed to be 0
     * @param tickLower the lower tick of this chunk
     * @param tickUpper the upper tick of this chunk
     * @param amount the amount of liquidity to add to this chunk.
     * @return the new liquidity chunk
     */
    function createChunk(
        uint256 self,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) public pure returns (uint256) {
        uint256 r = LiquidityChunk.createChunk(self, tickLower, tickUpper, amount);
        return r;
    }

    /**
     * @notice Add liquidity to the chunk.
     * @param self the LiquidityChunk.
     * @param amount the amount of liquidity to add to this chunk.
     * @return the chunk with added liquidity
     */
    function addLiquidity(uint256 self, uint128 amount) public pure returns (uint256) {
        uint256 r = LiquidityChunk.addLiquidity(self, amount);
        return r;
    }

    /**
     * @notice Add the lower tick to this chunk.
     * @param self the LiquidityChunk.
     * @param tickLower the lower tick to add.
     * @return the chunk with added lower tick
     */
    function addTickLower(uint256 self, int24 tickLower) public pure returns (uint256) {
        uint256 r = LiquidityChunk.addTickLower(self, tickLower);
        return r;
    }

    /**
     * @notice Add the upper tick to this chunk.
     * @param self the LiquidityChunk.
     * @param tickUpper the upper tick to add.
     * @return the chunk with added upper tick
     */
    function addTickUpper(uint256 self, int24 tickUpper) public pure returns (uint256) {
        uint256 r = LiquidityChunk.addTickUpper(self, tickUpper);
        return r;
    }

    /**
     * @notice Copy the tick range (upper and lower ticks) of a chunk `from` to `self`.
     * @notice This is helpful if you have a pre-existing liquidity amount, say "100" as a uint128. Simply cast to a uint256 and then we want
     *  to pack in the tick range as well so we add that to the front (towards the MSB) of the bit pattern keeping the liquidity amount the same.
     * @dev note that the liquidity itself is not transferred over from `other` - only the chunk bounds/ticks are.
     * @dev assumes that the incoming chunk does *not* already have ticks since the operation is additive.
     * @param self the chunk to copy the ticks *to* (recipient of the tick range).
     * @param from pre-existing chunk with lower and upper ticks that we want to copy *from*.
     * @return a liquidity chunk with the lower and upper tick values added to it.
     */
    function copyTickRange(uint256 self, uint256 from) public pure returns (uint256) {
        uint256 r = LiquidityChunk.copyTickRange(self, from);
        return r;
    }

    /*****************************************************************/
    /*
    /* READ FROM A LIQUIDITYCHUNK
    /*
    /*****************************************************************/

    /**
     * @notice Get the lower tick of a chunk.
     * @param self the LiquidityChunk uint256.
     * @return the lower tick of this chunk.
     */
    function tickLower(uint256 self) public pure returns (int24) {
        int24 r = LiquidityChunk.tickLower(self);
        return r;
    }

    /**
     * @notice Get the upper tick of a chunk.
     * @param self the LiquidityChunk uint256.
     * @return the upper tick of this chunk.
     */
    function tickUpper(uint256 self) public pure returns (int24) {
        int24 r = LiquidityChunk.tickUpper(self);
        return r;
    }

    /**
     * @notice Get the amount of liquidity/size of a chunk.
     * @param self the LiquidityChunk uint256.
     * @return the size of this chunk.
     */
    function liquidity(uint256 self) public pure returns (uint128) {
        uint128 r = LiquidityChunk.liquidity(self);
        return r;
    }
}
