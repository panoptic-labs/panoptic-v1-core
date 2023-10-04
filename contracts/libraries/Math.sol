// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Libraries
import {Errors} from "@libraries/Errors.sol";

// Custom types
import {LiquidityChunk} from "@types/LiquidityChunk.sol";

/// @title Core math library.
/// @author Axicon Labs Limited
library Math {
    using LiquidityChunk for uint256; // a leg within an option position `tokenId`

    // equivalent to type(uint256).max - used in assembly blocks as a replacement
    uint256 internal constant MAX_UINT256 = 2 ** 256 - 1;

    /// @dev Last value for which 1.0001^MIN_TICK is greater than 2**-128
    int24 internal constant MIN_TICK = -887272;

    /// @dev Last value for which 1.0001^MAX_TICK is less than 2**128
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @dev Value of getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;

    /// @dev Value of getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

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

    /// @notice Returns the index of the most significant bit of the number,
    ///     where the least significant bit is at index 0 and the most significant bit is at index 255
    /// @dev The function satisfies the property:
    ///     x >= 2**mostSignificantBit(x) and x < 2**(mostSignificantBit(x)+1)
    /// @param x the value for which to compute the most significant bit, must be greater than 0
    /// @return r the index of the most significant bit
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);

        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            r += 128;
        }
        if (x >= 0x10000000000000000) {
            x >>= 64;
            r += 64;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            r += 32;
        }
        if (x >= 0x10000) {
            x >>= 16;
            r += 16;
        }
        if (x >= 0x100) {
            x >>= 8;
            r += 8;
        }
        if (x >= 0x10) {
            x >>= 4;
            r += 4;
        }
        if (x >= 0x4) {
            x >>= 2;
            r += 2;
        }
        if (x >= 0x2) r += 1;
    }

    /*//////////////////////////////////////////////////////////////
                                TICK MATHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates 1.0001^(tick/2) as an X96 number
    /// @dev Implemented using Uniswap's "incorrect" constants. Supplying commented-out real values for an accurate calculation
    /// @dev Will revert if |tick| > max tick
    /// @param tick Value of the tick for which sqrt(1.0001^tick) is calculated
    /// @return sqrtPriceX96 A Q64.96 number representing the sqrt price at the provided tick
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK))) revert Errors.InvalidTick();

            uint256 sqrtR = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            // RealV: 0xfffcb933bd6fad37aa2d162d1a594001
            if (absTick & 0x2 != 0) sqrtR = (sqrtR * 0xfff97272373d413259a46990580e213a) >> 128;
            // RealV: 0xfff97272373d413259a46990580e2139
            if (absTick & 0x4 != 0) sqrtR = (sqrtR * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            // RealV: 0xfff2e50f5f656932ef12357cf3c7fdca
            if (absTick & 0x8 != 0) sqrtR = (sqrtR * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            // RealV: 0xffe5caca7e10e4e61c3624eaa0941ccd
            if (absTick & 0x10 != 0) sqrtR = (sqrtR * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            // RealV: 0xffcb9843d60f6159c9db58835c92663e
            if (absTick & 0x20 != 0) sqrtR = (sqrtR * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            // RealV: 0xff973b41fa98c081472e6896dfb254b6
            if (absTick & 0x40 != 0) sqrtR = (sqrtR * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            // RealV: 0xff2ea16466c96a3843ec78b326b5284f
            if (absTick & 0x80 != 0) sqrtR = (sqrtR * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            // RealV: 0xfe5dee046a99a2a811c461f1969c3032
            if (absTick & 0x100 != 0) sqrtR = (sqrtR * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            // RealV: 0xfcbe86c7900a88aedcffc83b479aa363
            if (absTick & 0x200 != 0) sqrtR = (sqrtR * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            // RealV: 0xf987a7253ac413176f2b074cf7815dd0
            if (absTick & 0x400 != 0) sqrtR = (sqrtR * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            // RealV: 0xf3392b0822b70005940c7a398e4b6ff1
            if (absTick & 0x800 != 0) sqrtR = (sqrtR * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            // RealV: 0xe7159475a2c29b7443b29c7fa6e887f2
            if (absTick & 0x1000 != 0) sqrtR = (sqrtR * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            // RealV: 0xd097f3bdfd2022b8845ad8f792aa548c
            if (absTick & 0x2000 != 0) sqrtR = (sqrtR * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            // RealV: 0xa9f746462d870fdf8a65dc1f90e05b52
            if (absTick & 0x4000 != 0) sqrtR = (sqrtR * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            // RealV: 0x70d869a156d2a1b890bb3df62baf27ff
            if (absTick & 0x8000 != 0) sqrtR = (sqrtR * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            // RealV: 0x31be135f97d08fd981231505542fbfe8
            if (absTick & 0x10000 != 0) sqrtR = (sqrtR * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            // RealV: 0x9aa508b5b7a84e1c677de54f3e988fe
            if (absTick & 0x20000 != 0) sqrtR = (sqrtR * 0x5d6af8dedb81196699c329225ee604) >> 128;
            // RealV: 0x5d6af8dedb81196699c329225ed28d
            if (absTick & 0x40000 != 0) sqrtR = (sqrtR * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            // RealV: 0x2216e584f5fa1ea926041bedeaf4
            if (absTick & 0x80000 != 0) sqrtR = (sqrtR * 0x48a170391f7dc42444e8fa2) >> 128;
            // RealV: 0x48a170391f7dc42444e7be7

            if (tick > 0) sqrtR = type(uint256).max / sqrtR;

            // Downcast + rounding up to keep is consistent with Uniswap's
            sqrtPriceX96 = uint160((sqrtR >> 32) + (sqrtR % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @notice Calculates the greatest tick value such that getRatioAtTick(tick) <= ratio
    /// @dev Revets if sqrtPriceX96 < MIN_SQRT_RATIO or sqrtPrice > MAX_SQRT_RATIO
    /// @param sqrtPriceX96 The sqrt ratio for which to compute the tick as a Q64.96
    /// @return tick The greatest tick for which the ratio is less than or equal to the input ratio
    function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24) {
        unchecked {
            // second inequality must be < because the price can never reach the price at the max tick
            if (sqrtPriceX96 < MIN_SQRT_RATIO || sqrtPriceX96 > MAX_SQRT_RATIO)
                revert Errors.InvalidSqrtRatio();

            // Find the expression for sqrtPriceX96 = m * 2**msb, where m is a X32 number
            uint256 msb = mostSignificantBit(sqrtPriceX96);

            // find the mantissa
            uint256 m = msb > 128
                ? uint256(sqrtPriceX96) >> (msb - 128)
                : uint256(sqrtPriceX96) << (128 - msb);

            /// @dev Do a Taylor expansion of Ln[x] around x=1.5, x is always betweeen (1, 2):
            /// @dev Log[x] = Log[3/2] + 2/3*(x-3/2) - 2/9*(x-3/2)**2 + 8/81*(x-3/2)**3 - 4/81*(x-3/2)**4 + 32/1215*(x-3/2)**5 - 32/2187*(x-3/2)**6 +
            ///                  128/15309*(x-3/2)**7 - 32/6561*(x-3/2)**8 + 512/177147*(x-3/2)**9

            // compute the value of (x-3/2) as a X128
            int256 x3_2 = int256((m - (3 << 128) / 2));

            int256 log_mX128 = 0;
            //log_mX128 = (log_mX128 * x3_2) / 2**128 + 51805909208579726993690688479265032; //int256(32768 << 128) /int256(215233605);
            //log_mX128 = (log_mX128 * x3_2) / 2**128 - 83259496942360275525574320770247374; //int256(8192 << 128) / int256(33480783);
            //log_mX128 = (log_mX128 * x3_2) / 2**128 + 134496110445351214310543133551938065; //int256(8192 << 128) /int256(20726199);
            //log_mX128 = (log_mX128 * x3_2) / 2**128 - 218556179473695723254632592021899356; //int256(1024 << 128) / int256(1594323);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 + 357637384593320274416671514217653493; //int256(2048 << 128) / int256(1948617);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 - 590101684578978452787507998459128263; //int256(512 << 128) / int256(295245);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 + 983502807631630754645846664098547106; //int256(512 << 128) / int256(177147);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 - 1659660987878376898464866245666298242; //int256(32 << 128) / int256(6561);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 + 2845133122077217540225484992570796986; //int256(128 << 128) / int256(15309);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 - 4978982963635130695394598736998894726; //int256(32 << 128) / int256(2187);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 + 8962169334543235251710277726598010507; //int256(32 << 128) / int256(1215);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 - 16804067502268566096956770737371269701; //int256(4 << 128) / int256(81);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 + 33608135004537132193913541474742539403; //int256(8 << 128) / int256(81);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 - 75618303760208547436305468318170713656; //int256(2 << 128) / int256(9);
            log_mX128 = (log_mX128 * x3_2) / 2 ** 128 + 226854911280625642308916404954512140970; //int256(2 << 128) / int256(3);
            log_mX128 =
                (log_mX128 * x3_2) /
                2 ** 128 +
                int256(137972626690900373465550041896316339718); // Log[3/2]*2**128

            // compute expression for  log[m] + (msg-96)*Log[2] * 2**128
            int256 numerator = log_mX128 +
                int256(msb - 96) *
                int256(235865763225513294137944142764154484399);

            int256 tick;
            int256 tickDown;
            // round up if tick is negative
            if (msb < 96) {
                tick =
                    (numerator +
                        8506633848419547728916991634454851 +
                        1701326769683909545783398326890970) /
                    17013267696839095457833983268909703 -
                    1;
                tickDown =
                    (numerator +
                        8506633848419547728916991634454851 -
                        1701326769683909545783398326890970) /
                    17013267696839095457833983268909703;
            } else {
                tick =
                    (numerator + 1701326769683909545783398326890970) /
                    17013267696839095457833983268909703;
                tickDown =
                    (numerator - 1701326769683909545783398326890970) /
                    17013267696839095457833983268909703;
            }

            if (tick == tickDown) {
                return int24(tick);
            } else {
                if (sqrtPriceX96 < getSqrtRatioAtTick(int24(tick))) {
                    tick -= 1;
                }
                return int24(tick);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY AMOUNTS (STRIKE+WIDTH)
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the amount of token0 received for a given liquidityChunk
    /// @dev Had to use a less optimal calculation to match Uniswap's implementation
    /// @param liquidityChunk variable that efficiently packs the liquidity, tickLower, and tickUpper.
    /// @return amount0 The amount of token0
    function getAmount0ForLiquidity(
        uint256 liquidityChunk
    ) internal pure returns (uint256 amount0) {
        uint160 lowPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickLower());
        uint160 highPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickUpper());

        return
            mulDiv(
                uint256(liquidityChunk.liquidity()) << 96,
                highPriceX96 - lowPriceX96,
                highPriceX96
            ) / lowPriceX96;

        //return (uint256(liquidityChunk.liquidity()) << 96) / lowPriceX96 -  (uint256(liquidityChunk.liquidity()) << 96) / highPriceX96;
    }

    /// @notice Calculates the amount of token1 received for a given liquidityChunk
    /// @param liquidityChunk variable that efficiently packs the liquidity, tickLower, and tickUpper.
    /// @return amount1 The amount of token1
    function getAmount1ForLiquidity(
        uint256 liquidityChunk
    ) internal pure returns (uint256 amount1) {
        uint160 lowPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickLower());
        uint160 highPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickUpper());

        return mulDiv96(liquidityChunk.liquidity(), highPriceX96 - lowPriceX96);
    }

    /// @notice Calculates the amount of token0 and token1 received for a given liquidityChunk at the provided currentTick
    /// @param currentTick the current tick to be evaluated
    /// @param liquidityChunk variable that efficiently packs the liquidity, tickLower, and tickUpper.
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function getAmountsForLiquidity(
        int24 currentTick,
        uint256 liquidityChunk
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint160 lowPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickLower());
        uint160 highPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickUpper());

        uint160 currentPriceX96 = getSqrtRatioAtTick(currentTick);

        if (currentPriceX96 <= lowPriceX96) {
            amount0 = getAmount0ForLiquidity(liquidityChunk);
        } else if (currentPriceX96 > highPriceX96) {
            amount1 = getAmount1ForLiquidity(liquidityChunk);
        } else {
            amount0 = getAmount0ForLiquidity(liquidityChunk.updateTickLower(currentTick));
            amount1 = getAmount1ForLiquidity(liquidityChunk.updateTickUpper(currentTick));
        }
    }

    /// @notice Calculates the amount of liquidity for a given amount of token0 and liquidityChunk
    /// @dev Had to use a less optimal calculation to match Uniswap's implementation
    /// @param liquidityChunk variable that efficiently packs the liquidity, tickLower, and tickUpper.
    /// @param amount0 The amoint of token0
    /// @return liquidity The calculated amount of liquidity
    function getLiquidityForAmount0(
        uint256 liquidityChunk,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        uint160 lowPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickLower());
        uint160 highPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickUpper());

        return
            toUint128(
                mulDiv(amount0, mulDiv96(highPriceX96, lowPriceX96), highPriceX96 - lowPriceX96)
            );
    }

    /// @notice Calculates the amount of liquidity for a given amount of token0 and liquidityChunk
    /// @param liquidityChunk variable that efficiently packs the liquidity, tickLower, and tickUpper.
    /// @param amount1 The amoint of token1
    /// @return liquidity The calculated amount of liquidity
    function getLiquidityForAmount1(
        uint256 liquidityChunk,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        uint160 lowPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickLower());
        uint160 highPriceX96 = getSqrtRatioAtTick(liquidityChunk.tickUpper());

        return toUint128(mulDiv(amount1, 2 ** 96, highPriceX96 - lowPriceX96));
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
