// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Libraries
import {Errors} from "@libraries/Errors.sol";

/// @title Pack two separate data (each of 128bit) into a single 256-bit slot; 256bit-to-128bit packing methods.
/// @author Axicon Labs Limited
/// @notice we want a compact representation of 256 bits of data. So we split it into two separate
/// @notice 128-bit chunks "left" and "right".
/// @notice The background here is that if an integer is explicitly converted to a smaller type,
/// @notice higher-order bits are cut off. For example: uint32 a = 0x12345678; uint16 b = uint16(a); // b will be 0x5678 now
library LeftRight {
    using LeftRight for uint256;
    using LeftRight for int256;
    int256 internal constant RIGHT_HALF_BIT_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /*//////////////////////////////////////////////////////////////
                              RIGHT SLOT
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the "right" slot from a uint256 bit pattern.
    /// @param self The uint256 (full 256 bits) to be cut in its right half
    /// @return the right half of self (128 bits)
    function rightSlot(uint256 self) internal pure returns (uint128) {
        return uint128(self);
    }

    /// @notice Get the "right" slot from an int256 bit pattern.
    /// @param self The int256 (full 256 bits) to be cut in its right half
    /// @return the right half self (128 bits)
    function rightSlot(int256 self) internal pure returns (int128) {
        return int128(self);
    }

    /// @dev All toRightSlot functions add bits to the right slot without clearing it first
    /// @dev Typically, the slot is already clear when writing to it, but if it is not, the bits will be added to the existing bits
    /// @dev Therefore, the assumption must not be made that the bits will be cleared while using these helpers

    /// @notice Write the "right" slot to a uint256.
    /// @param self the original full uint256 bit pattern to be written to
    /// @param right the bit pattern to write into the full pattern in the right half
    /// @return self with incoming right added (not overwritten, but added) to its right 128 bits
    function toRightSlot(uint256 self, uint128 right) internal pure returns (uint256) {
        unchecked {
            return self + uint256(right);
        }
    }

    /// @notice Write the "right" slot to a uint256.
    /// @param self the original full uint256 bit pattern to be written to
    /// @param right the bit pattern to write into the full pattern in the right half
    /// @return self with right added to its right 128 bits
    function toRightSlot(uint256 self, int128 right) internal pure returns (uint256) {
        if (right < 0) revert Errors.LeftRightInputError();
        unchecked {
            return self + uint256(int256(right));
        }
    }

    /// @notice Write the "right" slot to an int256.
    /// @param self the original full int256 bit pattern to be written to
    /// @param right the bit pattern to write into the full pattern in the right half
    /// @return self with right added to its right 128 bits
    function toRightSlot(int256 self, uint128 right) internal pure returns (int256) {
        unchecked {
            return self + int256(uint256(right));
        }
    }

    /// @notice Write the "right" slot to an int256.
    /// @param self the original full int256 bit pattern to be written to
    /// @param right the bit pattern to write into the full pattern in the right half
    /// @return self with right added to its right 128 bits
    function toRightSlot(int256 self, int128 right) internal pure returns (int256) {
        // bit mask needed in case rightHalfBitPattern < 0 due to 2's complement
        unchecked {
            return self + (int256(right) & RIGHT_HALF_BIT_MASK);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              LEFT SLOT
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the "left" half from a uint256 bit pattern.
    /// @param self The uint256 (full 256 bits) to be cut in its left half
    /// @return the left half (128 bits)
    function leftSlot(uint256 self) internal pure returns (uint128) {
        return uint128(self >> 128);
    }

    /// @notice Get the "left" half from an int256 bit pattern.
    /// @param self The int256 (full 256 bits) to be cut in its left half
    /// @return the left half (128 bits)
    function leftSlot(int256 self) internal pure returns (int128) {
        return int128(self >> 128);
    }

    /// @dev All toLeftSlot functions add bits to the left slot without clearing it first
    /// @dev Typically, the slot is already clear when writing to it, but if it is not, the bits will be added to the existing bits
    /// @dev Therefore, the assumption must not be made that the bits will be cleared while using these helpers

    /// @notice Write the "left" slot to a uint256 bit pattern.
    /// @param self the original full uint256 bit pattern to be written to
    /// @param left the bit pattern to write into the full pattern in the right half
    /// @return self with left added to its left 128 bits
    function toLeftSlot(uint256 self, uint128 left) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(left) << 128);
        }
    }

    /// @notice Write the "left" slot to an int256 bit pattern.
    /// @param self the original full int256 bit pattern to be written to
    /// @param left the bit pattern to write into the full pattern in the right half
    /// @return self with left added to its left 128 bits
    function toLeftSlot(int256 self, uint128 left) internal pure returns (int256) {
        unchecked {
            return self + (int256(int128(left)) << 128);
        }
    }

    /// @notice Write the "left" slot to an int256 bit pattern.
    /// @param self the original full int256 bit pattern to be written to
    /// @param left the bit pattern to write into the full pattern in the right half
    /// @return self with left added to its left 128 bits
    function toLeftSlot(int256 self, int128 left) internal pure returns (int256) {
        unchecked {
            return self + (int256(left) << 128);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Add two uint256 bit LeftRight-encoded words; revert on overflow or underflow.
    /// @param x the augend
    /// @param y the addend
    /// @return z the sum x + y
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            // adding leftRight packed uint128's is same as just adding the values explictily
            // given that we check for overflows of the left and right values
            z = x + y;

            // on overflow z will be less than either x or y
            // type cast z to uint128 to isolate the right slot and if it's lower than a value it's comprised of (x)
            // then an overflow has occured
            if (z < x || (uint128(z) < uint128(x))) revert Errors.UnderOverFlow();
        }
    }

    /// @notice Subtract two uint256 bit LeftRight-encoded words; revert on overflow or underflow.
    /// @param x the minuend
    /// @param y the subtrahend
    /// @return z the difference x - y
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            // subtracting leftRight packed uint128's is same as just subtracting the values explictily
            // given that we check for underflows of the left and right values
            z = x - y;

            // on underflow z will be greater than either x or y
            // type cast z to uint128 to isolate the right slot and if it's higher than a value that was subtracted from (x)
            // then an underflow has occured
            if (z > x || (uint128(z) > uint128(x))) revert Errors.UnderOverFlow();
        }
    }

    /// @notice Multiply two uint256 bit LeftRight-encoded words; revert on overflow.
    /// @param x the multiplicand
    /// @param y the multiplier
    /// @return z the product x/// y
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            // left slot
            uint256 leftProd256 = uint256(x.leftSlot()) * uint256(y.leftSlot());
            uint128 leftProd128 = uint128(leftProd256);

            // right slot
            uint256 rightProd256 = uint256(x.rightSlot()) * uint256(y.rightSlot());
            uint128 rightProd128 = uint128(rightProd256);

            // under/overflow checks
            if (leftProd128 != leftProd256 || rightProd128 != rightProd256)
                revert Errors.UnderOverFlow();

            // if no error then return
            // shift leftProd128 from its original position right, to the left slot
            //          128 | 128
            //  leftProd128 | rightProd128
            return rightProd256.toLeftSlot(leftProd128);
        }
    }

    /// @notice Divide two uint256 bit LeftRight-encoded words; revert on division by zero.
    /// @param x the numerator
    /// @param y the denominator
    /// @return z the ratio x / y
    function div(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            // cache on stack reused values for efficiency
            uint128 yLeftSlot = y.leftSlot();
            uint128 yRightSlot = y.rightSlot();

            if ((yLeftSlot == 0) || (yRightSlot == 0)) revert Errors.LeftRightInputError();

            return z.toRightSlot(x.rightSlot() / yRightSlot).toLeftSlot(x.leftSlot() / yLeftSlot);
        }
    }

    /// @notice Add uint256 to an int256 LeftRight-encoded word; revert on overflow or underflow.
    /// @param x the augend
    /// @param y the addend
    /// @return z (int256) the sum x + y
    function add(uint256 x, int256 y) internal pure returns (int256 z) {
        unchecked {
            int256 left = int256(uint256(x.leftSlot())) + y.leftSlot();
            int128 left128 = int128(left);

            if (left128 != left) revert Errors.UnderOverFlow();

            int256 right = int256(uint256(x.rightSlot())) + y.rightSlot();
            int128 right128 = int128(right);

            if (right128 != right) revert Errors.UnderOverFlow();

            return z.toRightSlot(right128).toLeftSlot(left128);
        }
    }

    /// @notice Add two int256 bit LeftRight-encoded words; revert on overflow.
    /// @param x the augend
    /// @param y the addend
    /// @return z the sum x + y
    function add(int256 x, int256 y) internal pure returns (int256 z) {
        unchecked {
            int256 left256 = int256(x.leftSlot()) + y.leftSlot();
            int128 left128 = int128(left256);

            int256 right256 = int256(x.rightSlot()) + y.rightSlot();
            int128 right128 = int128(right256);

            if (left128 != left256 || right128 != right256) revert Errors.UnderOverFlow();

            return z.toRightSlot(right128).toLeftSlot(left128);
        }
    }

    /// @notice Subtract two int256 bit LeftRight-encoded words; revert on overflow.
    /// @param x the minuend
    /// @param y the subtrahend
    /// @return z the difference x - y
    function sub(int256 x, int256 y) internal pure returns (int256 z) {
        unchecked {
            int256 left256 = int256(x.leftSlot()) - y.leftSlot();
            int128 left128 = int128(left256);

            int256 right256 = int256(x.rightSlot()) - y.rightSlot();
            int128 right128 = int128(right256);

            if (left128 != left256 || right128 != right256) revert Errors.UnderOverFlow();

            return z.toRightSlot(right128).toLeftSlot(left128);
        }
    }

    /// @notice Multiply two int256 bit LeftRight-encoded words; revert on overflow.
    /// @param x the multiplicand
    /// @param y the multiplier
    /// @return z the product x * y
    function mul(int256 x, int256 y) internal pure returns (int256 z) {
        unchecked {
            int256 leftProd256 = int256(x.leftSlot()) * int256(y.leftSlot());
            int128 leftProd128 = int128(leftProd256);

            int256 rightProd256 = int256(x.rightSlot()) * int256(y.rightSlot());
            int128 rightProd128 = int128(rightProd256);

            // under/overflow checks
            if (leftProd128 != leftProd256 || rightProd128 != rightProd256)
                revert Errors.UnderOverFlow();

            // if no error then return
            // shift leftProd128 from its original position right, to the left slot
            //          128 | 128
            //  leftProd128 | rightProd128
            return z.toRightSlot(rightProd128).toLeftSlot(leftProd128);
        }
    }

    /// @notice Divide two int256 bit LeftRight-encoded words; revert on division by zero.
    /// @param x the numerator
    /// @param y the denominator
    /// @return z the ratio x / y
    function div(int256 x, int256 y) internal pure returns (int256 z) {
        unchecked {
            // cache on stack reused values for efficiency
            int128 xLeftSlot = x.leftSlot();
            int128 xRightSlot = x.rightSlot();

            // store as int256 so that the result of division is stored as an int256
            // this way we can check if the left/right values don't fit into int128 slots
            int256 yLeftSlot = y.leftSlot();
            int256 yRightSlot = y.rightSlot();

            // quotient values (result of division)
            int256 leftQuotient256 = xLeftSlot / yLeftSlot;
            int256 rightQuotient256 = xRightSlot / yRightSlot;
            int128 leftQuotient128 = int128(leftQuotient256);
            int128 rightQuotient128 = int128(rightQuotient256);

            // if downcasted value does not match original value then an overflow has occured
            if (leftQuotient128 != leftQuotient256 || rightQuotient128 != rightQuotient256)
                revert Errors.UnderOverFlow();

            return z.toRightSlot(rightQuotient128).toLeftSlot(leftQuotient128);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            SAFE CASTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Cast an int256 to an int128, revert on overflow or underflow.
    /// @param self the int256 to be downcasted to int128
    /// @return selfAsInt128 the downcasted integer, now of type int128
    function toInt128(int256 self) internal pure returns (int128 selfAsInt128) {
        if (!((selfAsInt128 = int128(self)) == self)) revert Errors.CastingError();
    }

    /// @notice Downcast uint256 to a uint128, revert on overflow
    /// @param self the uint256 to be downcasted to uint128
    /// @return selfAsUint128 the downcasted uint256 now as uint128
    function toUint128(uint256 self) internal pure returns (uint128 selfAsUint128) {
        if (!((selfAsUint128 = uint128(self)) == self)) revert Errors.CastingError();
    }

    /// @notice Cast a uint256 to an int256, revert on overflow
    /// @param self the uint256 to be downcasted to uint128
    /// @return the incoming uint256 but now of type int256
    function toInt256(uint256 self) internal pure returns (int256) {
        if (self > uint256(type(int256).max)) revert Errors.CastingError();
        return int256(self);
    }
}
