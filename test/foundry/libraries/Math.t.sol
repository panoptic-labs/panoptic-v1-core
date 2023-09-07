// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MathHarness} from "./harnesses/MathHarness.sol";
import {Errors} from "@libraries/Errors.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
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

    function test_Success_min24_A_LT_B(int24 a, int24 b) public {
        vm.assume(a < b);
        assertEq(harness.min24(a, b), a);
    }

    function test_Success_min24_A_GE_B(int24 a, int24 b) public {
        vm.assume(a >= b);
        assertEq(harness.min24(a, b), b);
    }

    function test_Success_max24_A_GT_B(int24 a, int24 b) public {
        vm.assume(a > b);
        assertEq(harness.max24(a, b), a);
    }

    function test_Success_max24_A_LE_B(int24 a, int24 b) public {
        vm.assume(a <= b);
        assertEq(harness.max24(a, b), b);
    }

    function test_Success_abs_X_GT_0(int256 x) public {
        vm.assume(x > 0);
        assertEq(harness.abs(x), x);
    }

    function test_Success_abs_X_LE_0(int256 x) public {
        vm.assume(x <= 0 && x != type(int256).min);
        assertEq(harness.abs(x), -x);
    }

    function test_Fail_abs_Overflow() public {
        // Should be Panic(0x11), but Foundry decodes panics incorrectly at the top level
        vm.expectRevert();
        harness.abs(type(int256).min);
    }

    function test_Success_toUint128(uint256 toDowncast) public {
        vm.assume(toDowncast <= type(uint128).max);
        assertEq(harness.toUint128(toDowncast), toDowncast);
    }

    function test_Fail_toUint128_Overflow(uint256 toDowncast) public {
        vm.assume(toDowncast > type(uint128).max);
        vm.expectRevert(Errors.CastingError.selector);
        harness.toUint128(toDowncast);
    }

    function test_Success_toInt128(uint128 toCast) public {
        vm.assume(toCast <= uint128(type(int128).max));
        assertEq(uint128(harness.toInt128(toCast)), toCast);
    }

    function test_Fail_toInt128_Overflow(uint128 toCast) public {
        vm.assume(toCast > uint128(type(int128).max));
        vm.expectRevert(Errors.CastingError.selector);
        harness.toInt128(toCast);
    }

    function test_Success_sort(int24[] memory data) public {
        vm.assume(data.length != 0);
        // Compare against an alternative sorting implementation
        // Bubble sort
        uint256 l = data.length;
        for (uint256 i = 0; i < l; i++) {
            for (uint256 j = i + 1; j < l; j++) {
                if (data[i] > data[j]) {
                    int24 temp = data[i];
                    data[i] = data[j];
                    data[j] = temp;
                }
            }
        }

        assertEq(abi.encodePacked(data), abi.encodePacked(harness.sort(data)));
    }

    function test_Success_mulDiv64(uint96 a, uint96 b) public {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 64);
        uint256 returnedResult = harness.mulDiv64(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv64() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv64(input, input);
    }

    function test_Success_mulDiv96(uint96 a, uint96 b) public {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 96);
        uint256 returnedResult = harness.mulDiv96(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv96() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv96(input, input);
    }

    function test_Success_mulDivUp(uint128 a, uint128 b, uint128 denominator) public {
        vm.assume(denominator != 0);

        uint256 expectedResult = FullMath.mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            require(expectedResult < type(uint256).max);
            expectedResult++;
        }
        uint256 returnedResult = harness.mulDivUp(a, b, denominator);

        assertEq(expectedResult, returnedResult);
    }

    function test_Success_mulDivDown(uint128 a, uint128 b, uint128 denominator) public {
        vm.assume(denominator != 0);

        uint256 expectedResult = FullMath.mulDiv(a, b, denominator);
        uint256 returnedResult = harness.mulDivDown(a, b, denominator);

        assertEq(expectedResult, returnedResult);
    }

    function test_Success_mulDiv192(uint128 a, uint128 b) public {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 192);
        uint256 returnedResult = harness.mulDiv192(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv192() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv192(input, input);
    }
}
