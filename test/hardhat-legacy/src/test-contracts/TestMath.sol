// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *
 * WARNING: TEST CONTRACT - NOT TO BE DEPLOYED INTO PRODUCTION
 *
 */
pragma solidity =0.8.18;

// Internal
import {Math} from "../contracts/libraries/Math.sol";
import {Utils} from "./Utils.sol";

/*
 * @title Test That the Core Math library is working.
 * @author Axicon Labs Limited
 * @notice
 * @notice ***** NOT TO BE DEPLOYED INTO PRODUCTION *****
 * @notice
 * @notice you can run the tests by calling `runAll()` which will print "PASS" to the console or fail in a `require()` statement if any issue.
 */
contract TestMath is Utils {
    using Math for uint256;
    using Math for uint128;
    using Math for int256;

    /// @notice Call this function to run all tests
    function runAll() external {
        testCastToUint128();
    }

    /****************************************************
     * FAILING TESTS - CALLED FROM EXTERNAL JAVASCRIPT
     ****************************************************/
    function testCastToUint128Fail() external printStatus {
        uint256 x;

        x = 2 ** 250; // should not work (too large for 128)
        require(x.toUint128() == uint128(x));
    }

    function testToInt128fail() external printStatus {
        uint128 x;

        x = type(uint128).max; // too large for int128
        require(x.toInt128() == int128(x));
    }

    function testAbsInt256Fail() external printStatus {
        int256 x = type(int256).min;

        // will fail
        int256 y = x.abs();
    }

    /****************************************************
     * PASSING TESTS - CALLED VIA runAll() ABOVE
     ****************************************************/
    /// @dev test that it works for positive numbers
    function testCastToUint128() private printStatus {
        uint256 x;

        x = 2 ** 120; // should work
        require(x.toUint128() == uint128(x));
    }
}
