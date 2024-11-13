// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MathHarness} from "./harnesses/MathHarness.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import {LiquidityChunk, LiquidityChunkLibrary} from "@types/LiquidityChunk.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {Tick} from "v3-core/libraries/Tick.sol";
import "forge-std/Test.sol";

/**
 * Test the Core Math library using Foundry and Fuzzing.
 *
 * @author Axicon Labs Limited
 */
contract MathTest is Test {
    MathHarness harness;

    function setUp() public {
        harness = new MathHarness();
    }

    function test_Success_min24_A_LT_B(int24 a, int24 b) public view {
        vm.assume(a < b);
        assertEq(harness.min24(a, b), a);
    }

    function test_Success_min24_A_GE_B(int24 a, int24 b) public view {
        vm.assume(a >= b);
        assertEq(harness.min24(a, b), b);
    }

    function test_Success_max24_A_GT_B(int24 a, int24 b) public view {
        vm.assume(a > b);
        assertEq(harness.max24(a, b), a);
    }

    function test_Success_max24_A_LE_B(int24 a, int24 b) public view {
        vm.assume(a <= b);
        assertEq(harness.max24(a, b), b);
    }

    function test_Success_abs_X_GT_0(int256 x) public view {
        vm.assume(x > 0);
        assertEq(harness.abs(x), x);
    }

    function test_Success_abs_X_LE_0(int256 x) public view {
        vm.assume(x <= 0 && x != type(int256).min);
        assertEq(harness.abs(x), -x);
    }

    function test_Fail_abs_Overflow() public {
        // Should be Panic(0x11), but Foundry decodes panics incorrectly at the top level
        vm.expectRevert();
        harness.abs(type(int256).min);
    }

    function test_Success_toUint128(uint256 toDowncast) public view {
        vm.assume(toDowncast <= type(uint128).max);
        assertEq(harness.toUint128(toDowncast), toDowncast);
    }

    function test_Success_toUint128Capped(uint256 toDowncast) public view {
        vm.assume(toDowncast <= type(uint128).max);
        assertEq(harness.toUint128Capped(toDowncast), toDowncast);
    }

    function test_Success_Cap_toUint128Capped(uint256 toDowncast) public view {
        vm.assume(toDowncast > type(uint128).max);
        assertEq(harness.toUint128Capped(toDowncast), type(uint128).max);
    }

    function test_Fail_toUint128_Overflow(uint256 toDowncast) public {
        vm.assume(toDowncast > type(uint128).max);
        vm.expectRevert(Errors.CastingError.selector);
        harness.toUint128(toDowncast);
    }

    function test_Success_toInt128(uint128 toCast) public view {
        vm.assume(toCast <= uint128(type(int128).max));
        assertEq(uint128(harness.toInt128(toCast)), toCast);
    }

    function test_Fail_toInt128_Overflow(uint128 toCast) public {
        vm.assume(toCast > uint128(type(int128).max));
        vm.expectRevert(Errors.CastingError.selector);
        harness.toInt128(toCast);
    }

    // CASTING
    function test_Success_ToInt256(uint256 x) public {
        if (x > uint256(type(int256).max)) {
            vm.expectRevert(Errors.CastingError.selector);
            harness.toInt256(x);
        } else {
            int256 y = harness.toInt256(x);
            assertEq(y, int256(x));
        }
    }

    function test_Success_ToInt128(int256 x) public {
        if (x > type(int128).max || x < type(int128).min) {
            vm.expectRevert(Errors.CastingError.selector);
            harness.toInt128(x);
        } else {
            int128 y = harness.toInt128(x);
            assertEq(int128(x), y);
        }
    }

    function test_Success_sort(int256[] memory data) public view {
        vm.assume(data.length != 0);
        // Compare against an alternative sorting implementation
        // Bubble sort
        uint256 l = data.length;
        for (uint256 i = 0; i < l; i++) {
            for (uint256 j = i + 1; j < l; j++) {
                if (data[i] > data[j]) {
                    int256 temp = data[i];
                    data[i] = data[j];
                    data[j] = temp;
                }
            }
        }

        assertEq(abi.encodePacked(data), abi.encodePacked(harness.sort(data)));
    }

    function test_Success_mulDiv64(uint96 a, uint96 b) public view {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 64);
        uint256 returnedResult = harness.mulDiv64(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv64() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv64(input, input);
    }

    function test_Success_mulDiv96(uint96 a, uint96 b) public view {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 96);
        uint256 returnedResult = harness.mulDiv96(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv96() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv96(input, input);
    }

    function test_Success_mulDiv128(uint128 a, uint128 b) public view {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 128);
        uint256 returnedResult = harness.mulDiv128(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv128() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv128(input, input);
    }

    function test_Success_mulDiv128RoundingUp(uint128 a, uint128 b) public view {
        uint256 expectedResult = FullMath.mulDivRoundingUp(a, b, 2 ** 128);
        uint256 returnedResult = harness.mulDiv128RoundingUp(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Success_mulDiv192(uint128 a, uint128 b) public view {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 192);
        uint256 returnedResult = harness.mulDiv192(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_success_mulDiv192RoundingUp(uint128 a, uint128 b) public view {
        uint256 expectedResult = FullMath.mulDivRoundingUp(a, b, 2 ** 192);
        uint256 returnedResult = harness.mulDiv192RoundingUp(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv192() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv192(input, input);
    }

    function test_Success_mulDivCapped(uint256 a, uint256 b, uint256 c, uint256 power) public view {
        power = bound(power, 0, 255);
        vm.assume(c != 0);

        try harness.mulDiv(a, b, c) returns (uint256 res) {
            assertEq(Math.min(2 ** power - 1, res), Math.mulDivCapped(a, b, c, power));
        } catch {
            console2.log("A");
            assertEq(Math.mulDivCapped(a, b, c, power), 2 ** power - 1);
        }
    }

    function test_Success_unsafeDivRoundingUp(uint256 a, uint256 b) public view {
        uint256 divRes;
        uint256 modRes;
        assembly ("memory-safe") {
            divRes := div(a, b)
            modRes := mod(a, b)
        }
        unchecked {
            assertEq(harness.unsafeDivRoundingUp(a, b), modRes > 0 ? divRes + 1 : divRes);
        }
    }

    function test_Fail_getSqrtRatioAtTick() public {
        int24 x = int24(887273);
        vm.expectRevert();
        harness.getSqrtRatioAtTick(x);
        vm.expectRevert();
        harness.getSqrtRatioAtTick(-x);
    }

    function test_Success_getSqrtRatioAtTick(int24 x) public view {
        x = int24(bound(x, int24(-887271), int24(887271)));
        uint160 uniV3Result = TickMath.getSqrtRatioAtTick(x);
        uint160 returnedResult = harness.getSqrtRatioAtTick(x);
        assertEq(uniV3Result, returnedResult);
    }

    function test_getApproxTickWithMaxAmount(uint256 amount, uint256 ts_seed) public pure {
        int24 ts = int24(int256(bound(ts_seed, 1, 32767)));

        amount = bound(amount, 2_100 * 10 ** 18, 10 ** 26);

        uint128 lMax = Math.getMaxLiquidityPerTick(ts);
        int24 res = Math.getApproxTickWithMaxAmount(amount, ts, lMax);

        assertGt(
            amount,
            Math.getAmount0ForLiquidity(
                LiquidityChunkLibrary.createChunk(res + 2 - ts, res + 2, lMax)
            )
        );
        assertLt(
            amount,
            Math.getAmount0ForLiquidity(
                LiquidityChunkLibrary.createChunk(res - 2 - ts, res - 2, lMax)
            )
        );
    }

    function test_Success_getMaxLiquidityPerTick(int256 x) public pure {
        x = bound(x, 1, 32767);
        console2.log("Math act", Math.getMaxLiquidityPerTick(int24(x)));
        assertEq(
            Tick.tickSpacingToMaxLiquidityPerTick(int24(x)),
            Math.getMaxLiquidityPerTick(int24(x))
        );
    }

    function test_Success_log_Sqrt1p0001MantissaRect(uint256 x) public pure {
        x = bound(x, TickMath.MIN_SQRT_RATIO, 2 ** 96 - 1);

        // abs(max_error) ≈ 1.70234
        assertApproxEqAbs(
            int256(Math.log_Sqrt1p0001MantissaRect(x << 32, 13)),
            -TickMath.getTickAtSqrtRatio(uint160(x)),
            2
        );
    }

    function test_Success_getAmount0ForLiquidity(uint128 a) public view {
        a = uint128(bound(a, uint128(1), uint128(2 ** 128 - 1)));
        uint256 uniV3Result = LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        uint256 returnedResult = harness.getAmount0ForLiquidity(
            LiquidityChunkLibrary.createChunk(int24(-14), int24(10), a)
        );

        assertEq(uniV3Result, returnedResult);
    }

    function test_Success_getAmount1ForLiquidity(uint128 a) public view {
        uint256 uniV3Result = LiquidityAmounts.getAmount1ForLiquidity(
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        uint256 returnedResult = harness.getAmount1ForLiquidity(
            LiquidityChunkLibrary.createChunk(int24(-14), int24(10), a)
        );

        assertEq(uniV3Result, returnedResult);
    }

    function test_Success_getAmountsForLiquidity(uint128 a) public view {
        (uint256 uniV3Result0, uint256 uniV3Result1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(int24(2)),
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        (uint256 returnedResult0, uint256 returnedResult1) = harness.getAmountsForLiquidity(
            int24(2),
            LiquidityChunkLibrary.createChunk(int24(-14), int24(10), a)
        );

        assertEq(uniV3Result0, returnedResult0);
        assertEq(uniV3Result1, returnedResult1);
    }

    function test_Success_getLiquidityForAmount0(uint112 a) public view {
        uint256 uniV3Result = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        uint256 returnedResult = harness
            .getLiquidityForAmount0(int24(-14), int24(10), a)
            .liquidity();

        assertEq(uniV3Result, returnedResult);
    }

    function test_Success_getLiquidityForAmount1(uint112 a) public view {
        uint256 uniV3Result = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        uint256 returnedResult = harness
            .getLiquidityForAmount1(int24(-14), int24(10), a)
            .liquidity();

        assertEq(uniV3Result, returnedResult);
    }
}
