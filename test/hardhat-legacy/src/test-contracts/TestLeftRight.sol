// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *
 * WARNING: TEST CONTRACT - NOT TO BE DEPLOYED INTO PRODUCTION
 *
 */
pragma solidity =0.8.18;

// Internal
import {LeftRight} from "../contracts/types/LeftRight.sol";
import {Utils} from "./Utils.sol";

/*
 * @title Test The Library Contract `LeftRight.sol`
 * @author Axicon Labs Limited
 * @notice
 * @notice ***** NOT TO BE DEPLOYED INTO PRODUCTION *****
 * @notice
 * @notice you can run the tests by calling `runAll()` which will print "PASS" to the console or fail in a `require()` statement if any issue.
 */
contract TestLeftRight is Utils {
    using LeftRight for uint256; // the Panoptic LeftRight library
    using LeftRight for int256;

    /// @notice Call this function to run all tests
    function runAll() external {
        testRightSlot();
        testRightSlotInt();

        testLeftSlotInt();
        testSlotUint();

        testToInt256();

        testMathUint();
        testMathInt();

        testMathUintInt();
    }

    /****************************************************
     * FAILING TESTS - CALLED FROM EXTERNAL JAVASCRIPT
     ****************************************************/

    /// @notice external test called from JS test suite (because it reverts).
    function revertsWithNegativeValue() external printStatus {
        // test the signed additions
        uint256 newInt;
        newInt = 0x11111111_22222222_33333333_44444444_55555555_66666666_77777777_88888888; // all 32 bytes
        newInt = newInt.toRightSlot(int128(-0x11111111_11111111_11111111_11111111));
        // ^^^ should fail, outside test will catch
    }

    /// @notice should revert if right half is overflow
    function revertsOnOverflowRight() external printStatus returns (int256) {
        int256 newInt = 2;
        return newInt.toRightSlot(type(uint128).max + 1);
    }

    /// @notice should revert if right half is overflow
    function revertsOnOverflowLeft() external printStatus returns (int256) {
        int256 newInt = 2;
        return newInt.toLeftSlot(type(uint128).max + 1);
    }

    /// @notice should revert when downcasting an overflow int
    function revertsOnOverflowDowncast() external printStatus returns (int128) {
        int256 biggerThanInt128 = 2 ** 200;
        return biggerThanInt128.toInt128();
    }

    /// @notice should revert when casting from an already overflowing uint256 to int256
    function revertsOnOverflowCast() external printStatus returns (int256) {
        uint256 overflowing = type(uint256).max;
        return overflowing.toInt256();
    }

    function toUint128Fail() external printStatus returns (uint128) {
        uint256 overflowing = 2 ** 250;
        return overflowing.toUint128();
    }

    function toInt256Fail() external printStatus returns (int256) {
        uint256 overflowing = 2 ** 255;
        return overflowing.toInt256();
    }

    // MATH
    function addUint256FailX() external printStatus returns (uint256) {
        uint128 overflowing = type(uint128).max;
        uint256 x = uint256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        uint256 y = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        return x.add(y);
    }

    function addUint256FailY() external printStatus returns (uint256) {
        uint128 overflowing = type(uint128).max;
        uint256 x = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        uint256 y = uint256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        return x.add(y);
    }

    function addUint256Int256FailX() external printStatus returns (int256 z) {
        uint128 overflowing = type(uint128).max;

        uint256 x = uint256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        int256 y = int256(0).toRightSlot(int128(4)).toLeftSlot(int128(4));

        return x.add(y);
    }

    function addUint256Int256FailY() external printStatus returns (int256) {
        int128 overflowing = type(int128).max;
        uint256 x = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        int256 y = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        return x.add(y);
    }

    function addUint256Int256FailRight() external printStatus returns (int256) {
        int128 overflowing = type(int128).max;
        uint256 x = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        int256 y = int256(0).toRightSlot(overflowing).toLeftSlot(int128(2));
        return x.add(y);
    }

    function addUint256Int256FailLeft() external printStatus returns (int256) {
        int128 overflowing = type(int128).max;
        uint256 x = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        int256 y = int256(0).toRightSlot(int128(2)).toLeftSlot(overflowing);
        return x.add(y);
    }

    function subUint256Fail() external printStatus returns (uint256) {
        uint256 x = uint256(0).toRightSlot(uint128(1)).toLeftSlot(uint128(1));
        uint256 y = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        return x.sub(y);
    }

    function mulUint256FailX() external printStatus returns (uint256) {
        uint128 overflowing = 2 ** 128 - 1;
        uint256 x = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        uint256 y = uint256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        return x.mul(y);
    }

    function mulUint256FailY() external printStatus returns (uint256) {
        uint128 overflowing = 2 ** 128 - 1;
        uint256 x = uint256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        uint256 y = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        return x.mul(y);
    }

    function mulUint256FailRightSlot() external printStatus returns (uint256) {
        uint128 overflowing = 2 ** 128 - 1;
        uint256 x = uint256(0).toRightSlot(overflowing).toLeftSlot(uint128(2));
        uint256 y = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        return x.mul(y);
    }

    function mulUint256FailZeroX() external printStatus returns (uint256) {
        uint128 overflowing = 2 ** 128 - 1;
        uint256 x = uint256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        uint256 y = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        return x.mul(y);
    }

    function mulUint256FailZeroY() external printStatus returns (uint256) {
        uint128 overflowing = 2 ** 128 - 1;
        uint256 x = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        uint256 y = uint256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        return x.mul(y);
    }

    function divUint256Fail() external printStatus returns (uint256) {
        uint256 x = uint256(0).toRightSlot(uint128(2)).toLeftSlot(uint128(2));
        uint256 y = uint256(0).toRightSlot(uint128(0)).toLeftSlot(uint128(0));
        return x.div(y);
    }

    // int256
    function addInt256FailX() external printStatus returns (int256) {
        int128 overflowing = 2 ** 127 - 1;
        int256 x = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        int256 y = int256(0).toRightSlot(int128(2)).toLeftSlot(int128(2));
        return x.add(y);
    }

    function addInt256FailY() external printStatus returns (int256) {
        int128 overflowing = 2 ** 127 - 1;
        int256 x = int256(0).toRightSlot(int128(2)).toLeftSlot(int128(2));
        int256 y = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        return x.add(y);
    }

    function addInt256FailNegX() external printStatus returns (int256) {
        int128 overflowing = -2 ** 127 + 1;
        int256 x = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        int256 y = int256(0).toRightSlot(int128(-2)).toLeftSlot(int128(-2));
        return x.add(y);
    }

    function addInt256FailNegY() external printStatus returns (int256) {
        int128 overflowing = -2 ** 127 + 1;
        int256 x = int256(0).toRightSlot(int128(-2)).toLeftSlot(int128(-2));
        int256 y = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        return x.add(y);
    }

    function subInt256Fail() external printStatus returns (int256) {
        int128 overflowing = -2 ** 127 + 1;
        int256 x = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        int256 y = int256(0).toRightSlot(int128(2)).toLeftSlot(int128(2));
        return x.sub(y);
    }

    function subInt256FailNeg() external printStatus returns (int256) {
        int128 overflowing = 2 ** 127 - 1;
        int256 x = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        int256 y = int256(0).toRightSlot(int128(-2)).toLeftSlot(int128(-2));
        return x.sub(y);
    }

    function mulInt256FailX() external printStatus returns (int256) {
        int128 overflowing = 2 ** 127 - 1;
        int256 x = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        int256 y = int256(0).toRightSlot(int128(2)).toLeftSlot(int128(2));
        return x.mul(y);
    }

    function mulInt256FailY() external printStatus returns (int256) {
        int128 overflowing = 2 ** 127 - 1;
        int256 x = int256(0).toRightSlot(int128(2)).toLeftSlot(int128(2));
        int256 y = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        return x.mul(y);
    }

    function mulInt256FailXNeg() external printStatus returns (int256) {
        int128 overflowing = -2 ** 127 + 1;
        int256 x = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        int256 y = int256(0).toRightSlot(int128(2)).toLeftSlot(int128(2));
        return x.mul(y);
    }

    function mulInt256FailYNeg() external printStatus returns (int256) {
        int128 overflowing = 2 ** 127 - 1;
        int256 x = int256(0).toRightSlot(int128(-2)).toLeftSlot(int128(-2));
        int256 y = int256(0).toRightSlot(overflowing).toLeftSlot(overflowing);
        return x.mul(y);
    }

    function divInt256Fail() external printStatus returns (int256) {
        int256 x = 2;
        int256 y = 0;
        return x.div(y);
    }

    function divInt256Fail_part2() external printStatus returns (int256) {
        int256 x;
        int256 y;

        x = x.toLeftSlot(type(int128).min).toRightSlot(type(int128).min);
        y = y.toLeftSlot(-1).toRightSlot(-1);
        return x.div(y);
    }

    /****************************************************
     * PASSING TESTS - CALLED VIA runAll() ABOVE
     ****************************************************/

    /// @notice test that setting the right slot in a uint256 behaves as expected
    function testRightSlot() private printStatus {
        uint256 newInt;
        newInt = 0x11111111_22222222_33333333_44444444_55555555_66666666_77777777_88888888; // all 32 bytes

        // grab the right half of that pattern:
        uint128 rightSlot = newInt.rightSlot(); // will be 16 bytes
        require(rightSlot == 0x55555555_66666666_77777777_88888888, "RS: Failure1a!");

        uint128 leftSlot = newInt.leftSlot();
        require(leftSlot == 0x11111111_22222222_33333333_44444444, "RS: Failure1b!");

        // great, so we can grab the relevant halves of the 32 bytes, let's try some math on the halves:
        // add to the right slot:
        newInt = newInt.toRightSlot(uint128(0x11111111_11111111_11111111_11111111));
        rightSlot = newInt.rightSlot(); // read the updated value

        require(
            rightSlot ==
                0x55555555_66666666_77777777_88888888 + 0x11111111_11111111_11111111_11111111,
            "RS: Failure2a!"
        );

        leftSlot = newInt.leftSlot(); // this should not have changed
        require(leftSlot == 0x11111111_22222222_33333333_44444444, "RS: Failure2b!");

        // add to the left slot:
        newInt = newInt.toLeftSlot(uint128(0x11111111_11111111_11111111_11111111));
        leftSlot = newInt.leftSlot(); // read the updated value

        require(leftSlot == 0x22222222_33333333_44444444_55555555, "RS: Failure3a!");

        leftSlot = newInt.rightSlot(); // this should not have changed from previously
        require(leftSlot == 0x66666666_77777777_88888888_99999999, "RS: Failure3b!");
    }

    function testToInt256() private printStatus {
        uint256 newInt = 4;
        require(newInt.toInt256() == int256(4));
    }

    /// @notice test that the right slot signed int can be returned
    function testRightSlotInt() private printStatus {
        // test the signed additions
        uint256 newInt;
        newInt = 0x11111111_22222222_33333333_44444444_55555555_66666666_77777777_88888888; // all 32 bytes

        // grab the right half of that pattern:
        uint128 rightSlot = newInt.rightSlot(); // will be 16 bytes
        require(rightSlot == 0x55555555_66666666_77777777_88888888, "RSI: Failure1a");

        newInt = newInt.toRightSlot(int128(0x11111111_11111111_11111111_11111111));

        require(newInt.rightSlot() == 0x66666666_77777777_88888888_99999999, "RSI: Failure1b");
        require(newInt.leftSlot() == 0x11111111_22222222_33333333_44444444, "RSI: Failure1c!");

        int256 newInt2;
        newInt2 = newInt2.toRightSlot(-2);

        require(newInt2.rightSlot() == -2);
        require(newInt2.leftSlot() == 0);

        newInt2 = newInt2.toLeftSlot(-200);

        require(newInt2.rightSlot() == -2);
        require(newInt2.leftSlot() == -200);

        int256 newInt3;
        newInt3 = newInt3.toLeftSlot(-2);

        require(newInt3.leftSlot() == -2);
        require(newInt3.rightSlot() == 0);

        newInt3 = newInt3.toRightSlot(-8001);

        require(newInt3.leftSlot() == -2);
        require(newInt3.rightSlot() == -8001);

        int256 newInt4;
        newInt4 = newInt4.toRightSlot(-2);
        newInt4 = newInt4.toLeftSlot(int128(4000));

        require(newInt4.leftSlot() == 4000);
        require(newInt4.rightSlot() == -2);

        int256 newInt5;
        newInt5 = newInt5.toRightSlot(int128(200));
        newInt5 = newInt5.toLeftSlot(-4000);

        require(newInt5.rightSlot() == 200);
        require(newInt5.leftSlot() == -4000);
    }

    /// @notice test that the left slot signed integer works
    function testLeftSlotInt() private printStatus {
        // test the signed additions
        int256 newInt; // signed

        newInt = newInt.toLeftSlot(-1);

        require(newInt.rightSlot() == 0);
        require(newInt.leftSlot() == -1);

        newInt = newInt.toRightSlot(-200);

        require(newInt.rightSlot() == -200);
        require(newInt.leftSlot() == -1);

        int256 newInt2; // signed
        newInt2 = newInt2.toLeftSlot(int128(0));
        newInt2 = newInt2.toRightSlot(int128(-200));

        require(newInt2.leftSlot() == 0);
        require(newInt2.rightSlot() == -200);
    }

    function testSlotUint() private printStatus {
        uint256 newInt;

        newInt = newInt.toLeftSlot(uint128(24));
        newInt = newInt.toRightSlot(uint128(8000));

        require(newInt.leftSlot() == 24);
        require(newInt.rightSlot() == 8000);

        uint256 newInt2;

        newInt2 = newInt2.toLeftSlot(uint128(24));
        newInt2 = newInt2.toRightSlot(uint128(0));

        require(newInt2.leftSlot() == 24);
        require(newInt2.rightSlot() == 0);
    }

    function testMathUint() private printStatus {
        // add uint256
        uint256 x;
        uint256 y;

        x = x.toRightSlot(uint128(8000)).toLeftSlot(uint128(25));
        y = y.toRightSlot(uint128(2000)).toLeftSlot(uint128(5));

        require((x.add(y)).rightSlot() == 10000);
        require((x.add(y)).leftSlot() == 30);

        // sub uint256
        uint256 x2;
        uint256 y2;

        x2 = x2.toRightSlot(uint128(8000)).toLeftSlot(uint128(25));
        y2 = y2.toRightSlot(uint128(2000)).toLeftSlot(uint128(5));

        require((x2.sub(y2)).rightSlot() == 6000);
        require((x2.sub(y2)).leftSlot() == 20);

        // mul uint256
        uint256 x3;
        uint256 y3;

        x3 = x3.toRightSlot(uint128(8000)).toLeftSlot(uint128(25));
        y3 = y3.toRightSlot(uint128(2000)).toLeftSlot(uint128(5));

        require((x3.mul(y3)).rightSlot() == 16000000);
        require((x3.mul(y3)).leftSlot() == 125);

        // div uint256
        uint256 x4;
        uint256 y4;

        x4 = x4.toRightSlot(uint128(8000)).toLeftSlot(uint128(25));
        y4 = y4.toRightSlot(uint128(2000)).toLeftSlot(uint128(5));

        require((x4.div(y4)).rightSlot() == 4);
        require((x4.div(y4)).leftSlot() == 5);
    }

    function testMathInt() private printStatus {
        // add int256
        int256 x;
        int256 y;

        x = x.toRightSlot(int128(8000)).toLeftSlot(int128(25));
        y = y.toRightSlot(int128(2000)).toLeftSlot(int128(-5));

        require((x.add(y)).rightSlot() == 10000);
        require((x.add(y)).leftSlot() == 20);

        // sub int256
        int256 x2;
        int256 y2;

        x2 = x2.toRightSlot(int128(8000)).toLeftSlot(int128(25));
        y2 = y2.toRightSlot(int128(2000)).toLeftSlot(int128(-5));

        require((x2.sub(y2)).rightSlot() == 6000);
        require((x2.sub(y2)).leftSlot() == 30);

        // mul int256
        int256 x3;
        int256 y3;

        x3 = x3.toRightSlot(int128(8000)).toLeftSlot(int128(25));
        y3 = y3.toRightSlot(int128(2000)).toLeftSlot(int128(-5));

        require((x3.mul(y3)).rightSlot() == 16000000);
        require((x3.mul(y3)).leftSlot() == -125);

        // div int256
        int256 x4;
        int256 y4;

        x4 = x4.toRightSlot(int128(8000)).toLeftSlot(int128(25));
        y4 = y4.toRightSlot(int128(2000)).toLeftSlot(int128(-5));

        require((x4.div(y4)).rightSlot() == 4);
        require((x4.div(y4)).leftSlot() == -5);
    }

    function testMathUintInt() private printStatus {
        // add uint256 and int256
        uint256 x;
        int256 y;

        x = x.toRightSlot(uint128(8000)).toLeftSlot(uint128(25));
        y = y.toRightSlot(int128(2000)).toLeftSlot(int128(-5));

        require((x.add(y)).rightSlot() == 10000);
        require((x.add(y)).leftSlot() == 20);

        // fyi we dont have sub, mul, div on this uint256/int256 mix, only add
    }
}
