// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *
 * WARNING: TEST CONTRACT - NOT TO BE DEPLOYED INTO PRODUCTION
 *
 */
pragma solidity =0.8.18;

// Internal
import {TickStateCallContext} from "../contracts/types/TickStateCallContext.sol";
import {Utils} from "./Utils.sol";

/*
 * @title Test That the TickStateCallContext packing works as expected
 * @author Axicon Labs Limited
 * @notice
 * @notice ***** NOT TO BE DEPLOYED INTO PRODUCTION *****
 * @notice
 * @notice This contract tests that a tick price fee info gets packed correctly.
 * @notice you can run the tests by calling `runAll()` which will print "PASS" to the console or fail in a `require()` statement if any issue.
 */
contract TestTickStateCallContext is Utils {
    using TickStateCallContext for uint256;

    /// @notice Call this function to run all tests
    function runAll() external {
        testCurrentTick();
        testSqrtPrice();
    }

    /****************************************************
     * PASSING TESTS - CALLED VIA runAll() ABOVE
     ****************************************************/
    /// @notice test the recipient
    function testCurrentTick() private printStatus {
        uint256 newInt;

        newInt = newInt.addCurrentTick(400);
        require(newInt.currentTick() == 400);

        newInt = 0;
        newInt = newInt.addCurrentTick(0);
        require(newInt.currentTick() == 0);

        newInt = 0;
        newInt = newInt.addCurrentTick(-20);
        require(newInt.currentTick() == -20);
    }

    function testSqrtPrice() private printStatus {
        uint256 newInt;

        require(newInt.currentTick() == 0);

        newInt = 0;
        require(newInt.currentTick() == 0);

        newInt = 0;
        require(newInt.currentTick() == 0);
    }
}
