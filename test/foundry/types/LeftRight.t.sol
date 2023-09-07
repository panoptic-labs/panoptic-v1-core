// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
// Foundry

import "forge-std/Test.sol";
// Internal
import {LeftRightHarness} from "./harnesses/LeftRightHarness.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";

/**
 * Test the LeftRight word packing library using Foundry and Fuzzing.
 *
 * @author Axicon Labs Limited
 */
contract LeftRightTest is Test {
    // harness
    LeftRightHarness harness;

    function setUp() public {
        harness = new LeftRightHarness();
    }

    // RIGHT SLOT
    function test_Success_RightSlot_Uint128_In_Uint256(uint128 y) public {
        uint256 x = 0;
        x = harness.toRightSlot(x, y);
        assertEq(uint128(harness.leftSlot(x)), 0);
        assertEq(uint128(harness.rightSlot(x)), y);
    }

    function test_Success_RightSlot_Uint128_In_Int256(uint128 y) public {
        int256 x = 0;
        x = harness.toRightSlot(x, y);
        assertEq(int128(harness.leftSlot(x)), 0);
        assertEq(int128(harness.rightSlot(x)), int128(y));
    }

    function test_Success_RightSlot_Int128_In_Int256(int128 y) public {
        int256 x = 0;
        x = harness.toRightSlot(x, y);
        assertEq(int128(harness.leftSlot(x)), 0);
        assertEq(int128(harness.rightSlot(x)), y);
    }

    function test_Fail_toRightSlot(int128 right) public {
        right = int128(bound(right, -type(int128).max, -1));

        vm.expectRevert(Errors.LeftRightInputError.selector);
        harness.toRightSlot(uint256(0), right);
    }

    // LEFT SLOT
    function test_Success_LeftSlot_Uint128_In_Uint256(uint128 y) public {
        uint256 x = 0;
        x = harness.toLeftSlot(x, y);
        assertEq(uint128(harness.leftSlot(x)), y);
        assertEq(uint128(harness.rightSlot(x)), 0);
    }

    function test_Success_LeftSlot_Uint128_In_Int256(uint128 y) public {
        int256 x = 0;
        x = harness.toLeftSlot(x, y);
        assertEq(int128(harness.leftSlot(x)), int128(y));
        assertEq(int128(harness.rightSlot(x)), 0);
    }

    function test_Success_LeftSlot_Int128_In_Int256(int128 y) public {
        int256 x = 0;
        x = harness.toLeftSlot(x, y);
        assertEq(int128(harness.leftSlot(x)), y);
        assertEq(int128(harness.rightSlot(x)), 0);
    }

    // BOTH
    function test_Success_BothSlots_uint256(uint128 y, uint128 z) public {
        uint256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);

        assertEq(uint128(harness.leftSlot(x)), y);
        assertEq(uint128(harness.rightSlot(x)), z);
    }

    function test_Success_BothSlots_int256(uint128 y, uint128 z) public {
        int256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);

        assertEq(uint128(harness.leftSlot(x)), y);
        assertEq(uint128(harness.rightSlot(x)), z);
    }

    function test_Success_BothSlots_int256(int128 y, int128 z) public {
        int256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);

        assertEq(int128(harness.leftSlot(x)), y);
        assertEq(int128(harness.rightSlot(x)), z);
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

    function test_Success_ToUint128(uint256 x) public {
        if (x > type(uint128).max) {
            vm.expectRevert(Errors.CastingError.selector);
            harness.toUint128(x);
        } else {
            uint128 y = harness.toUint128(x);
            assertEq(uint128(x), y);
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

    // MATH
    function test_Success_AddUints(uint128 y, uint128 z, uint128 u, uint128 v) public {
        uint256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);
        assertEq(uint128(harness.leftSlot(x)), y);
        assertEq(uint128(harness.rightSlot(x)), z);

        // try swapping order
        x = 0;
        x = harness.toRightSlot(x, y);
        x = harness.toLeftSlot(x, z);
        assertEq(uint128(harness.leftSlot(x)), z);
        assertEq(uint128(harness.rightSlot(x)), y);

        x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);
        assertEq(uint128(harness.leftSlot(x)), y);
        assertEq(uint128(harness.rightSlot(x)), z);

        uint256 xx = 0;
        xx = harness.toLeftSlot(xx, u);
        xx = harness.toRightSlot(xx, v);

        // now test add
        if (uint128(uint256(y) + uint256(u)) < y) {
            // under/overflow
            vm.expectRevert(Errors.UnderOverFlow.selector);
            uint256 other = harness.add(x, xx);
        } else if (uint128(uint256(z) + uint256(v)) < z) {
            // under/overflow
            vm.expectRevert(Errors.UnderOverFlow.selector);
            uint256 other = harness.add(x, xx);
        } else {
            // normal case
            uint256 other = harness.add(x, xx);
            assertEq(uint128(harness.leftSlot(other)), y + u);
            assertEq(uint128(harness.rightSlot(other)), z + v);
        }
    }

    function test_Success_AddUintInt(uint128 y, uint128 z, int128 u, int128 v) public {
        uint256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);
        assertEq(uint128(harness.leftSlot(x)), y);
        assertEq(uint128(harness.rightSlot(x)), z);

        int256 xx = 0;
        xx = harness.toLeftSlot(xx, u);
        xx = harness.toRightSlot(xx, v);

        // now test add
        unchecked {
            if (
                (int256(uint256(y)) + u < int256(uint256(y)) && u > 0) ||
                (int256(uint256(y)) + u > int256(uint256(y)) && u < 0)
            ) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.add(x, xx);
            } else if (
                (int256(uint256(z)) + v < int256(uint256(z)) && (v > 0)) ||
                (int256(uint256(z)) + v > int256(uint256(z)) && (v < 0))
            ) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.add(x, xx);
            } else if (
                int256(uint256(y)) + u > type(int128).max ||
                int256(uint256(z)) + v > type(int128).max
            ) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.add(x, xx);
            } else {
                // normal case
                int256 other = harness.add(x, xx);
                assertEq(uint128(harness.leftSlot(other)), uint128(int128(y) + u));
                assertEq(uint128(harness.rightSlot(other)), uint128(int128(z) + v));
            }
        }
    }

    function test_Success_SubUints(uint128 y, uint128 z, uint128 u, uint128 v) public {
        uint256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);

        assertEq(uint128(harness.leftSlot(x)), y);
        assertEq(uint128(harness.rightSlot(x)), z);

        uint256 xx = 0;
        xx = harness.toRightSlot(xx, v);
        xx = harness.toLeftSlot(xx, u);

        assertEq(uint128(harness.leftSlot(xx)), u);
        assertEq(uint128(harness.rightSlot(xx)), v);

        // now test sub
        unchecked {
            // needed b/c we are checking for under/overflow cases to actually happen
            if (y - u > y) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                uint256 other = harness.sub(x, xx);
            } else if (z - v > z) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                uint256 other = harness.sub(x, xx);
            } else {
                // normal case
                uint256 other = harness.sub(x, xx);
                assertEq(uint128(harness.leftSlot(other)), y - u);
                assertEq(uint128(harness.rightSlot(other)), z - v);
            }
        }
    }

    function test_Success_MulUints(uint128 y, uint128 z, uint128 u, uint128 v) public {
        uint256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);

        assertEq(uint128(harness.leftSlot(x)), y);
        assertEq(uint128(harness.rightSlot(x)), z);

        uint256 xx = 0;
        xx = harness.toRightSlot(xx, v);
        xx = harness.toLeftSlot(xx, u);

        assertEq(uint128(harness.leftSlot(xx)), u);
        assertEq(uint128(harness.rightSlot(xx)), v);

        // now test mul
        unchecked {
            // needed b/c we are checking for under/overflow cases to actually happen
            if (y != 0 && (y * u) / y != u) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                uint256 other = harness.mul(x, xx);
            } else if (z != 0 && (z * v) / z != v) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                uint256 other = harness.mul(x, xx);
            } else {
                // normal case
                uint256 other = harness.mul(x, xx);
                assertEq(uint128(harness.leftSlot(other)), y * u);
                assertEq(uint128(harness.rightSlot(other)), z * v);
            }
        }
    }

    function test_Success_DivUints(uint128 y, uint128 z, uint128 u, uint128 v) public {
        uint256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);

        assertEq(uint128(harness.leftSlot(x)), y);
        assertEq(uint128(harness.rightSlot(x)), z);

        uint256 xx = 0;
        xx = harness.toRightSlot(xx, v);
        xx = harness.toLeftSlot(xx, u);

        assertEq(uint128(harness.leftSlot(xx)), u);
        assertEq(uint128(harness.rightSlot(xx)), v);

        // now test div
        if (u == 0 || v == 0) {
            vm.expectRevert(Errors.LeftRightInputError.selector);
            uint256 other = harness.div(x, xx);
        } else {
            uint256 other = harness.div(x, xx);
            assertEq(uint128(harness.leftSlot(other)), y / u);
            assertEq(uint128(harness.rightSlot(other)), z / v);
        }
    }

    // MATH for ints
    function test_Success_AddInts(int128 y, int128 z, int128 u, int128 v) public {
        int256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);
        assertEq(int128(harness.leftSlot(x)), y);
        assertEq(int128(harness.rightSlot(x)), z);

        // try swapping order
        x = 0;
        x = harness.toRightSlot(x, y);
        x = harness.toLeftSlot(x, z);
        assertEq(int128(harness.leftSlot(x)), z);
        assertEq(int128(harness.rightSlot(x)), y);

        x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);
        assertEq(int128(harness.leftSlot(x)), y);
        assertEq(int128(harness.rightSlot(x)), z);

        int256 xx = 0;
        xx = harness.toLeftSlot(xx, u);
        xx = harness.toRightSlot(xx, v);

        // now test add
        unchecked {
            if ((y + u < y && u > 0) || (y + u > y && u < 0)) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.add(x, xx);
            } else if ((z + v < z && v > 0) || (z + v > z && v < 0)) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.add(x, xx);
            } else {
                // normal case
                int256 other = harness.add(x, xx);
                assertEq(int128(harness.leftSlot(other)), y + u);
                assertEq(int128(harness.rightSlot(other)), z + v);
            }
        }
    }

    function test_Success_SubInts(int128 y, int128 z, int128 u, int128 v) public {
        int256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);
        assertEq(int128(harness.leftSlot(x)), y);
        assertEq(int128(harness.rightSlot(x)), z);

        // try swapping order
        x = 0;
        x = harness.toRightSlot(x, y);
        x = harness.toLeftSlot(x, z);
        assertEq(int128(harness.leftSlot(x)), z);
        assertEq(int128(harness.rightSlot(x)), y);

        x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);
        assertEq(int128(harness.leftSlot(x)), y);
        assertEq(int128(harness.rightSlot(x)), z);

        int256 xx = 0;
        xx = harness.toLeftSlot(xx, u);
        xx = harness.toRightSlot(xx, v);

        // now test add
        unchecked {
            if ((y - u > y && u > 0) || (y - u < y && u < 0)) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.sub(x, xx);
            } else if ((z - v > z && v > 0) || (z - v < z && v < 0)) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.sub(x, xx);
            } else {
                // normal case
                int256 other = harness.sub(x, xx);
                assertEq(int128(harness.leftSlot(other)), y - u);
                assertEq(int128(harness.rightSlot(other)), z - v);
            }
        }
    }

    function test_Success_MulInts(int128 y, int128 z, int128 u, int128 v) public {
        int256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);

        assertEq(int128(harness.leftSlot(x)), y);
        assertEq(int128(harness.rightSlot(x)), z);

        int256 xx = 0;
        xx = harness.toRightSlot(xx, v);
        xx = harness.toLeftSlot(xx, u);

        assertEq(int128(harness.leftSlot(xx)), u);
        assertEq(int128(harness.rightSlot(xx)), v);

        // now test mul
        unchecked {
            // needed b/c we are checking for under/overflow cases to actually happen
            if (
                (y != 0 && (int256(y) * u) > type(int128).max) || (int256(y) * u) < type(int128).min
            ) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.mul(x, xx);
            } else if (
                (z != 0 && (int256(z) * v) > type(int128).max) || (int256(z) * v) < type(int128).min
            ) {
                // under/overflow
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.mul(x, xx);
            } else {
                // normal case
                int256 other = harness.mul(x, xx);
                assertEq(int128(harness.leftSlot(other)), y * u);
                assertEq(int128(harness.rightSlot(other)), z * v);
            }
        }
    }

    function test_Success_DivInts(int128 y, int128 z, int128 u, int128 v) public {
        int256 x = 0;
        x = harness.toLeftSlot(x, y);
        x = harness.toRightSlot(x, z);

        assertEq(int128(harness.leftSlot(x)), y);
        assertEq(int128(harness.rightSlot(x)), z);

        int256 xx = 0;
        xx = harness.toRightSlot(xx, v);
        xx = harness.toLeftSlot(xx, u);

        assertEq(int128(harness.leftSlot(xx)), u);
        assertEq(int128(harness.rightSlot(xx)), v);

        // now test div
        if (u == 0 || v == 0) {
            // Foundry cannot handle compiler panics, this should panic with 0x12
            vm.expectRevert();
            int256 other = harness.div(x, xx);
        } else {
            if (
                (harness.leftSlot(x) == type(int128).min && harness.leftSlot(xx) == -1) ||
                (harness.rightSlot(x) == type(int128).min && harness.rightSlot(xx) == -1)
            ) {
                vm.expectRevert(Errors.UnderOverFlow.selector);
                int256 other = harness.div(x, xx);
            } else {
                int256 other = harness.div(x, xx);
                assertEq(int128(harness.leftSlot(other)), y / u);
                assertEq(int128(harness.rightSlot(other)), z / v);
            }
        }
    }

    function test_Fail_DivInts() public {
        int256 x = type(int128).min;
        int256 xx = -1;

        vm.expectRevert(Errors.UnderOverFlow.selector);
        int256 other = harness.div(x, xx);
    }
}
