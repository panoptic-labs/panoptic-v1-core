// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *
 * WARNING: TEST CONTRACT - NOT TO BE DEPLOYED INTO PRODUCTION
 *
 */
pragma solidity =0.8.18;

// Internal
import {Utils} from "./Utils.sol";

/*
 * @title Test The TickLimits used in `contracts/SemiFungiblePositionManager.sol`.
 * @author Axicon Labs Limited
 * @notice
 * @notice ***** NOT TO BE DEPLOYED INTO PRODUCTION *****
 * @notice
 * @notice you can run the tests by calling `runAll()` which will print "PASS" to the console or fail in a `require()` statement if any issue.
 */
contract TestTickLimits is Utils {
    /****************************************************
     * PASSING TESTS - CALLED INSIDE runAll()
     ****************************************************/

    /// @notice Call this function to run all tests
    /// @dev for this test file, implemented inside runAll()
    function runAll() external pure {
        int24 tickLow = -24;
        int24 tickHigh = 0;

        // reproduce the _getTickLimits:
        int48 BIT_MASK_INT24 = 0xFFFFFF;
        int48 tickLimits = (int48(tickLow) & BIT_MASK_INT24) + (int48(tickHigh) << 24);

        // we have 48 bits now with -24 on the right side and 0 on the left side:
        // -24 = 111111111111111111101000
        require(bit(tickLimits, 0) == 0); // 1st bit
        require(bit(tickLimits, 1) == 0);
        require(bit(tickLimits, 2) == 0);
        require(bit(tickLimits, 3) == 1);
        require(bit(tickLimits, 4) == 0);
        require(bit(tickLimits, 5) == 1);
        require(bit(tickLimits, 6) == 1);
        require(bit(tickLimits, 7) == 1);
        require(bit(tickLimits, 8) == 1);
        require(bit(tickLimits, 9) == 1);
        require(bit(tickLimits, 10) == 1);
        require(bit(tickLimits, 11) == 1);
        require(bit(tickLimits, 12) == 1);
        require(bit(tickLimits, 13) == 1);
        require(bit(tickLimits, 14) == 1);
        require(bit(tickLimits, 15) == 1);
        require(bit(tickLimits, 16) == 1);
        require(bit(tickLimits, 17) == 1);
        require(bit(tickLimits, 18) == 1);
        require(bit(tickLimits, 19) == 1);
        require(bit(tickLimits, 20) == 1);
        require(bit(tickLimits, 21) == 1);
        require(bit(tickLimits, 22) == 1);
        require(bit(tickLimits, 23) == 1); // 24th bit
        require(bit(tickLimits, 24) == 0);
        require(bit(tickLimits, 25) == 0);
        require(bit(tickLimits, 26) == 0);
        require(bit(tickLimits, 27) == 0);
        require(bit(tickLimits, 28) == 0);
        require(bit(tickLimits, 29) == 0);
        require(bit(tickLimits, 30) == 0);
        require(bit(tickLimits, 31) == 0);
        require(bit(tickLimits, 32) == 0);
        require(bit(tickLimits, 33) == 0);
        require(bit(tickLimits, 34) == 0);
        require(bit(tickLimits, 35) == 0);
        require(bit(tickLimits, 36) == 0);
        require(bit(tickLimits, 37) == 0);
        require(bit(tickLimits, 38) == 0);
        require(bit(tickLimits, 39) == 0);
        require(bit(tickLimits, 40) == 0);
        require(bit(tickLimits, 41) == 0);
        require(bit(tickLimits, 42) == 0);
        require(bit(tickLimits, 43) == 0);
        require(bit(tickLimits, 44) == 0);
        require(bit(tickLimits, 45) == 0);
        require(bit(tickLimits, 46) == 0);
        require(bit(tickLimits, 47) == 0); // 48th bit

        tickLow = -204;
        tickHigh = -8001;

        tickLimits = (int48(tickLow) & BIT_MASK_INT24) + (int48(tickHigh) << 24);

        // we have 48 bits now with -24 on the right side and 0 on the left side:
        // -204  = 111111111111111100110100
        // -8001 = 111111111110000010111111
        require(bit(tickLimits, 0) == 0); // 1st bit
        require(bit(tickLimits, 1) == 0);
        require(bit(tickLimits, 2) == 1);
        require(bit(tickLimits, 3) == 0);
        require(bit(tickLimits, 4) == 1);
        require(bit(tickLimits, 5) == 1);
        require(bit(tickLimits, 6) == 0);
        require(bit(tickLimits, 7) == 0);
        require(bit(tickLimits, 8) == 1);
        require(bit(tickLimits, 9) == 1);
        require(bit(tickLimits, 10) == 1);
        require(bit(tickLimits, 11) == 1);
        require(bit(tickLimits, 12) == 1);
        require(bit(tickLimits, 13) == 1);
        require(bit(tickLimits, 14) == 1);
        require(bit(tickLimits, 15) == 1);
        require(bit(tickLimits, 16) == 1);
        require(bit(tickLimits, 17) == 1);
        require(bit(tickLimits, 18) == 1);
        require(bit(tickLimits, 19) == 1);
        require(bit(tickLimits, 20) == 1);
        require(bit(tickLimits, 21) == 1);
        require(bit(tickLimits, 22) == 1);
        require(bit(tickLimits, 23) == 1); // 24th bit
        require(bit(tickLimits, 24) == 1);
        require(bit(tickLimits, 25) == 1);
        require(bit(tickLimits, 26) == 1);
        require(bit(tickLimits, 27) == 1);
        require(bit(tickLimits, 28) == 1);
        require(bit(tickLimits, 29) == 1);
        require(bit(tickLimits, 30) == 0);
        require(bit(tickLimits, 31) == 1);
        require(bit(tickLimits, 32) == 0);
        require(bit(tickLimits, 33) == 0);
        require(bit(tickLimits, 34) == 0);
        require(bit(tickLimits, 35) == 0);
        require(bit(tickLimits, 36) == 0);
        require(bit(tickLimits, 37) == 1);
        require(bit(tickLimits, 38) == 1);
        require(bit(tickLimits, 39) == 1);
        require(bit(tickLimits, 40) == 1);
        require(bit(tickLimits, 41) == 1);
        require(bit(tickLimits, 42) == 1);
        require(bit(tickLimits, 43) == 1);
        require(bit(tickLimits, 44) == 1);
        require(bit(tickLimits, 45) == 1);
        require(bit(tickLimits, 46) == 1);
        require(bit(tickLimits, 47) == 1); // 48th bit
    }
}
