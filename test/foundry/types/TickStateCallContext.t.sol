// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@libraries/Errors.sol";
import "./harnesses/TickStateCallContextHarness.sol";
import "forge-std/Test.sol";

/// @title TickStateCallContextTest: A test suite for the TickStateCallContext library.
/// @author Axicon Labs Limited
contract TickStateCallContextTest is Test {
    TickStateCallContextHarness harness;

    function setUp() public {
        harness = new TickStateCallContextHarness();
    }

    function test_Success_updateCurrentTick(uint256 start, int24 tick) public {
        unchecked {
            assertEq(harness.updateCurrentTick(start, tick), ((start >> 24) << 24) + uint24(tick));
        }
    }

    function test_Success_addCurrentTick(uint256 start, int24 tick) public {
        unchecked {
            assertEq(harness.addCurrentTick(start, tick), start + uint24(tick));
        }
    }

    function test_Success_addMedianTick(uint256 start, int24 tick) public {
        unchecked {
            assertEq(harness.addMedianTick(start, tick), start + (uint256(uint24(tick)) << 24));
        }
    }

    function test_Success_addCaller(uint256 start, address _msgSender) public {
        unchecked {
            assertEq(
                harness.addCaller(start, _msgSender),
                start + (uint256(uint160(_msgSender)) << 48)
            );
        }
    }

    function test_Success_currentTick(uint256 start) public {
        unchecked {
            assertEq(harness.currentTick(start), int24(int256(start)));
        }
    }

    function test_Success_medianTick(uint256 start) public {
        unchecked {
            assertEq(harness.medianTick(start), int24(int256(start >> 24)));
        }
    }

    function test_Success_caller(uint256 start) public {
        unchecked {
            assertEq(harness.caller(start), address(uint160(start >> 48)));
        }
    }
}
