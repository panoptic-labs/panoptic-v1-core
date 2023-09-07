// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Libraries
import {Errors} from "@libraries/Errors.sol";

/// @title Core math library.
/// @author Axicon Labs Limited
library Math {
    // equivalent to type(uint256).max - used in assembly blocks as a replacement
    uint256 internal constant MAX_UINT256 = 2 ** 256 - 1;

    /*//////////////////////////////////////////////////////////////
                          GENERAL MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute the min of the incoming int24s `a` and `b`.
    /// @param a the first number
    /// @param b the second number
    /// @return the min of `a` and `b`: min(a, b), e.g.: min(4, 1) = 1
    function min24(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }

    /// @notice Compute the max of the incoming int24s `a` and `b`.
    /// @param a the first number
    /// @param b the second number
    /// @return the max of `a` and `b`: max(a, b), e.g.: max(4, 1) = 4
    function max24(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }

    /// @notice Compute the absolute value of an integer (int256).
    /// @param x the incoming *signed* integer to take the absolute value of
    /// @dev Does not support `type(int256).min` and will revert (type(int256).max is one less).
    /// @return the absolute value of `x`, e.g. abs(-4) = 4
    function abs(int256 x) internal pure returns (int256) {
        return x > 0 ? x : -x;
    }

    /// @notice Compute the absolute value of an integer (int256).
    /// @param x the incoming *signed* integer to take the absolute value of
    /// @dev Supports `type(int256).min` because the corresponding value can fit in a uint (unlike `type(int256).max`).
    /// @return the absolute value of `x`, e.g. abs(-4) = 4
    function absUint(int256 x) internal pure returns (uint256) {
        unchecked {
            return x > 0 ? uint256(x) : uint256(-x);
        }
    }

    /// @notice Returns the index of the most significant nibble of the 160-bit number,
    /// where the least significant nibble is at index 0 and the most significant nibble is at index 40.
    /// @param x the value for which to compute the most significant nibble
    /// @return r the index of the most significant nibble (default: 0)
    function mostSignificantNibble(uint160 x) internal pure returns (uint256 r) {
        unchecked {
            if (x >= 0x100000000000000000000000000000000) {
                x >>= 128;
                r += 32;
            }
            if (x >= 0x10000000000000000) {
                x >>= 64;
                r += 16;
            }
            if (x >= 0x100000000) {
                x >>= 32;
                r += 8;
            }
            if (x >= 0x10000) {
                x >>= 16;
                r += 4;
            }
            if (x >= 0x100) {
                x >>= 8;
                r += 2;
            }
            if (x >= 0x10) {
                r += 1;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                CASTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Downcast uint256 to uint128. Revert on overflow or underflow.
    /// @param toDowncast the uint256 to be downcasted
    /// @return downcastedInt the downcasted uint (uint128 now)
    function toUint128(uint256 toDowncast) internal pure returns (uint128 downcastedInt) {
        if ((downcastedInt = uint128(toDowncast)) != toDowncast) revert Errors.CastingError();
    }

    /// @notice Recast uint128 to int128.
    /// @param toCast the uint256 to be downcasted.
    /// @return downcastedInt the downcasted int (int128 now)
    function toInt128(uint128 toCast) internal pure returns (int128 downcastedInt) {
        if ((downcastedInt = int128(toCast)) < 0) revert Errors.CastingError();
    }

    /*//////////////////////////////////////////////////////////////
                           MULDIV ALGORITHMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates floor(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0.
    /// @param a the multiplicand
    /// @param b the multiplier
    /// @param denominator the divisor
    /// @return result The 256-bit result
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                require(denominator > 0);
                assembly ("memory-safe") {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // Make sure the result is less than 2**256.
            // Also prevents denominator == 0
            require(denominator > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            // Compute largest power of two divisor of denominator.
            // Always >= 1.
            uint256 twos = (0 - denominator) & denominator;
            // Divide denominator by power of two
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
            }

            // Divide [prod1 prod0] by the factors of two
            assembly ("memory-safe") {
                prod0 := div(prod0, twos)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            assembly ("memory-safe") {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4
            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the precoditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
            return result;
        }
    }

    /// @notice Calculates floor(a×b÷2^64) with full precision. Throws if result overflows a uint256 or denominator == 0.
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @return result The 256-bit result
    function mulDiv64(uint256 a, uint256 b) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                    result := shr(64, prod0)
                }
                return result;
            }

            // Make sure the result is less than 2**256.
            require(2 ** 64 > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, 0x10000000000000000)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Divide [prod1 prod0] by the factors of two (note that this is just 2**96 since the denominator is a power of 2 itself)
            assembly ("memory-safe") {
                // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                prod0 := shr(64, prod0)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            // Note that this is just 2**192 since 2**256 over the fixed denominator (2**64) equals 2**192
            prod0 |= prod1 * 2 ** 192;

            return prod0;
        }
    }

    /// @notice Calculates floor(a×b÷2^96) with full precision. Throws if result overflows a uint256 or denominator == 0.
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @return result The 256-bit result
    function mulDiv96(uint256 a, uint256 b) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                    result := shr(96, prod0)
                }
                return result;
            }

            // Make sure the result is less than 2**256.
            require(2 ** 96 > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, 0x1000000000000000000000000)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Divide [prod1 prod0] by the factors of two (note that this is just 2**96 since the denominator is a power of 2 itself)
            assembly ("memory-safe") {
                // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                prod0 := shr(96, prod0)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            // Note that this is just 2**160 since 2**256 over the fixed denominator (2**96) equals 2**160
            prod0 |= prod1 * 2 ** 160;

            return prod0;
        }
    }

    /// @notice Calculates floor(a×b÷2^128) with full precision. Throws if result overflows a uint256 or denominator == 0.
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @return result The 256-bit result
    function mulDiv128(uint256 a, uint256 b) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                    result := shr(128, prod0)
                }
                return result;
            }

            // Make sure the result is less than 2**256.
            require(2 ** 128 > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, 0x100000000000000000000000000000000)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Divide [prod1 prod0] by the factors of two (note that this is just 2**128 since the denominator is a power of 2 itself)
            assembly ("memory-safe") {
                // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                prod0 := shr(128, prod0)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            // Note that this is just 2**160 since 2**256 over the fixed denominator (2**128) equals 2**128
            prod0 |= prod1 * 2 ** 128;

            return prod0;
        }
    }

    /// @notice Calculates floor(a×b÷2^192) with full precision. Throws if result overflows a uint256 or denominator == 0.
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @return result The 256-bit result
    function mulDiv192(uint256 a, uint256 b) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                    result := shr(192, prod0)
                }
                return result;
            }

            // Make sure the result is less than 2**256.
            require(2 ** 192 > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, 0x1000000000000000000000000000000000000000000000000)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Divide [prod1 prod0] by the factors of two (note that this is just 2**96 since the denominator is a power of 2 itself)
            assembly ("memory-safe") {
                // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                prod0 := shr(192, prod0)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            // Note that this is just 2**64 since 2**256 over the fixed denominator (2**192) equals 2**64
            prod0 |= prod1 * 2 ** 64;

            return prod0;
        }
    }

    /// @notice From the Solmate/FixedPointMathLib.sol library, calculates (a×b÷denominator) rounded down.
    /// @param x The multiplicand
    /// @param y The multiplier
    /// @param denominator The divisor
    /// @return z The 256-bit result
    function mulDivDown(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
                revert(0, 0)
            }

            // Divide x * y by the denominator.
            z := div(mul(x, y), denominator)
        }
    }

    /// @notice From the Solmate/FixedPointMathLib.sol library, calculates (a×b÷denominator) rounded up.
    /// @param x The multiplicand
    /// @param y The multiplier
    /// @param denominator The divisor
    /// @return z The 256-bit result
    function mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
                revert(0, 0)
            }

            // If x * y modulo the denominator is strictly greater than 0,
            // 1 is added to round up the division of x * y by the denominator.
            z := add(gt(mod(mul(x, y), denominator), 0), div(mul(x, y), denominator))
        }
    }

    /*//////////////////////////////////////////////////////////////
                                SORTING
    //////////////////////////////////////////////////////////////*/

    /// @notice QuickSort is a sorting algorithm that employs the Divide and Conquer strategy. It selects a pivot element and arranges the given array around
    /// this pivot by correctly positioning it within the sorted array.
    /// @param arr the elements that must be sorted
    /// @param left the starting index
    /// @param right the ending index
    function quickSort(int24[] memory arr, int256 left, int256 right) internal pure {
        unchecked {
            int256 i = left;
            int256 j = right;
            if (i == j) return;
            int24 pivot = arr[uint256(left + (right - left) / 2)];
            while (i < j) {
                while (arr[uint256(i)] < pivot) i++;
                while (pivot < arr[uint256(j)]) j--;
                if (i <= j) {
                    (arr[uint256(i)], arr[uint256(j)]) = (arr[uint256(j)], arr[uint256(i)]);
                    i++;
                    j--;
                }
            }
            if (left < j) quickSort(arr, left, j);
            if (i < right) quickSort(arr, i, right);
        }
    }

    /// @notice calls `quickSort` with default starting index of 0 and ending index of the last element in the array.
    /// @param data the elements that must be sorted
    function sort(int24[] memory data) internal pure returns (int24[] memory) {
        unchecked {
            quickSort(data, int256(0), int256(data.length - 1));
        }
        return data;
    }
}
