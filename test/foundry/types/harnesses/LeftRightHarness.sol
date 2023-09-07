// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {LeftRight} from "@types/LeftRight.sol";

/// @title LeftRightHarness: A harness to expose the LeftRight library for code coverage analysis.
/// @notice Replicates the interface of the LeftRight library, passing through any function calls
/// @author Axicon Labs Limited
contract LeftRightHarness {
    /*//////////////////////////////////////////////////////////////
                              RIGHT SLOT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the "right" slot from a uint256 bit pattern.
     * @param self The uint256 (full 256 bits) to be cut in its right half.
     * @return the right half of self (128 bits).
     */
    function rightSlot(uint256 self) public view returns (uint128) {
        uint128 r = LeftRight.rightSlot(self);
        return r;
    }

    /**
     * @notice Get the "right" slot from an int256 bit pattern.
     * @param self The int256 (full 256 bits) to be cut in its right half.
     * @return the right half self (128 bits).
     */
    function rightSlot(int256 self) public view returns (int128) {
        int128 r = LeftRight.rightSlot(self);
        return r;
    }

    /// @dev All toRightSlot functions add bits to the right slot without clearing it first
    /// @dev Typically, the slot is already clear when writing to it, but if it is not, the bits will be added to the existing bits
    /// @dev Therefore, the assumption must not be made that the bits will be cleared while using these helpers

    /**
     * @notice Write the "right" slot to a uint256.
     * @param self the original full uint256 bit pattern to be written to.
     * @param right the bit pattern to write into the full pattern in the right half.
     * @return self with incoming right added (not overwritten, but added) to its right 128 bits.
     */
    function toRightSlot(uint256 self, uint128 right) public view returns (uint256) {
        uint256 r = LeftRight.toRightSlot(self, right);
        return r;
    }

    /**
     * @notice Write the "right" slot to a uint256.
     * @param self the original full uint256 bit pattern to be written to.
     * @param right the bit pattern to write into the full pattern in the right half.
     * @return self with right added to its right 128 bits.
     */
    function toRightSlot(uint256 self, int128 right) public view returns (uint256) {
        uint256 r = LeftRight.toRightSlot(self, right);
        return r;
    }

    /**
     * @notice Write the "right" slot to an int256.
     * @param self the original full int256 bit pattern to be written to.
     * @param right the bit pattern to write into the full pattern in the right half.
     * @return self with right added to its right 128 bits.
     */
    function toRightSlot(int256 self, uint128 right) public view returns (int256) {
        int256 r = LeftRight.toRightSlot(self, right);
        return r;
    }

    /**
     * @notice Write the "right" slot to an int256.
     * @param self the original full int256 bit pattern to be written to.
     * @param right the bit pattern to write into the full pattern in the right half.
     * @return self with right added to its right 128 bits.
     */
    function toRightSlot(int256 self, int128 right) public view returns (int256) {
        int256 r = LeftRight.toRightSlot(self, right);
        return r;
    }

    /*//////////////////////////////////////////////////////////////
                              LEFT SLOT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the "left" half from a uint256 bit pattern.
     * @param self The uint256 (full 256 bits) to be cut in its left half.
     * @return the left half (128 bits).
     */
    function leftSlot(uint256 self) public view returns (uint128) {
        uint128 r = LeftRight.leftSlot(self);
        return r;
    }

    /**
     * @notice Get the "left" half from an int256 bit pattern.
     * @param self The int256 (full 256 bits) to be cut in its left half.
     * @return the left half (128 bits).
     */
    function leftSlot(int256 self) public view returns (int128) {
        int128 r = LeftRight.leftSlot(self);
        return r;
    }

    /// @dev All toLeftSlot functions add bits to the left slot without clearing it first
    /// @dev Typically, the slot is already clear when writing to it, but if it is not, the bits will be added to the existing bits
    /// @dev Therefore, the assumption must not be made that the bits will be cleared while using these helpers

    /**
     * @notice Write the "left" slot to a uint256 bit pattern.
     * @param self the original full uint256 bit pattern to be written to.
     * @param left the bit pattern to write into the full pattern in the right half.
     * @return self with left added to its left 128 bits.
     */
    function toLeftSlot(uint256 self, uint128 left) public view returns (uint256) {
        uint256 r = LeftRight.toLeftSlot(self, left);
        return r;
    }

    /**
     * @notice Write the "left" slot to an int256 bit pattern.
     * @param self the original full int256 bit pattern to be written to.
     * @param left the bit pattern to write into the full pattern in the right half.
     * @return self with left added to its left 128 bits.
     */
    function toLeftSlot(int256 self, uint128 left) public view returns (int256) {
        int256 r = LeftRight.toLeftSlot(self, left);
        return r;
    }

    /**
     * @notice Write the "left" slot to an int256 bit pattern.
     * @param self the original full int256 bit pattern to be written to.
     * @param left the bit pattern to write into the full pattern in the right half.
     * @return self with left added to its left 128 bits.
     */
    function toLeftSlot(int256 self, int128 left) public view returns (int256) {
        int256 r = LeftRight.toLeftSlot(self, left);
        return r;
    }

    /*//////////////////////////////////////////////////////////////
                            MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add two uint256 bit LeftRight-encoded words; revert on overflow or underflow.
     * @param x the augend
     * @param y the addend
     * @return z the sum x + y
     */
    function add(uint256 x, uint256 y) public view returns (uint256) {
        uint256 r = LeftRight.add(x, y);
        return r;
    }

    /**
     * @notice Subtract two uint256 bit LeftRight-encoded words; revert on overflow or underflow.
     * @param x the minuend
     * @param y the subtrahend
     * @return z the difference x - y
     */
    function sub(uint256 x, uint256 y) public view returns (uint256) {
        uint256 r = LeftRight.sub(x, y);
        return r;
    }

    /**
     * @notice Multiply two uint256 bit LeftRight-encoded words; revert on overflow.
     * @param x the multiplicand
     * @param y the multiplier
     * @return z the product x * y
     */
    function mul(uint256 x, uint256 y) public view returns (uint256) {
        uint256 r = LeftRight.mul(x, y);
        return r;
    }

    /**
     * @notice Divide two uint256 bit LeftRight-encoded words; revert on division by zero.
     * @param x the numerator
     * @param y the denominator
     * @return z the ratio x / y
     */
    function div(uint256 x, uint256 y) public view returns (uint256) {
        uint256 r = LeftRight.div(x, y);
        return r;
    }

    /**
     * @notice Add uint256 to an int256 LeftRight-encoded word; revert on overflow or underflow.
     * @param x the augend
     * @param y the addend
     * @return z (int256) the sum x + y
     */
    function add(uint256 x, int256 y) public view returns (int256) {
        int256 r = LeftRight.add(x, y);
        return r;
    }

    /**
     * @notice Add two int256 bit LeftRight-encoded words; revert on overflow.
     * @param x the augend
     * @param y the addend
     * @return z the sum x + y
     */
    function add(int256 x, int256 y) public view returns (int256) {
        int256 r = LeftRight.add(x, y);
        return r;
    }

    /**
     * @notice Subtract two int256 bit LeftRight-encoded words; revert on overflow.
     * @param x the minuend
     * @param y the subtrahend
     * @return z the difference x - y
     */
    function sub(int256 x, int256 y) public view returns (int256) {
        int256 r = LeftRight.sub(x, y);
        return r;
    }

    /**
     * @notice Multiply two int256 bit LeftRight-encoded words; revert on overflow.
     * @param x the multiplicand
     * @param y the multiplier
     * @return z the product x * y
     */
    function mul(int256 x, int256 y) public view returns (int256) {
        int256 r = LeftRight.mul(x, y);
        return r;
    }

    /**
     * @notice Divide two int256 bit LeftRight-encoded words; revert on division by zero.
     * @param x the numerator
     * @param y the denominator
     * @return z the ratio x / y
     */
    function div(int256 x, int256 y) public view returns (int256) {
        int256 r = LeftRight.div(x, y);
        return r;
    }

    /*//////////////////////////////////////////////////////////////
                            SAFE CASTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Cast an int256 to an int128, revert on overflow or underflow.
     * @param self the int256 to be downcasted to int128.
     * @return selfAsInt128 the downcasted integer, now of type int128
     */
    function toInt128(int256 self) public view returns (int128) {
        int128 r = LeftRight.toInt128(self);
        return r;
    }

    /**
     * @notice Downcast uint256 to a uint128, revert on overflow
     * @param self the uint256 to be downcasted to uint128.
     * @return selfAsUint128 the downcasted uint256 now as uint128
     */
    function toUint128(uint256 self) public view returns (uint128) {
        uint128 r = LeftRight.toUint128(self);
        return r;
    }

    /**
     * @notice Cast a uint256 to an int256, revert on overflow
     * @param self the uint256 to be downcasted to uint128.
     * @return the incoming uint256 but now of type int256.
     */
    function toInt256(uint256 self) public view returns (int256) {
        int256 r = LeftRight.toInt256(self);
        return r;
    }
}
