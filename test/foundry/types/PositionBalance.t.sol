// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// foundry
import "forge-std/Test.sol";
// internal
import {Errors} from "../../../contracts/libraries/Errors.sol";
import {PositionBalanceHarness} from "./harnesses/PositionBalanceHarness.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

/**
 * Test Position Balance using Foundry and Fuzzing.
 *
 * @author Axicon Labs Limited
 */
contract PositionBalanceTest is Test {
    // harness
    PositionBalanceHarness harness;

    function setUp() public {
        harness = new PositionBalanceHarness();
    }

    function test_Success_storeBalanceData(uint128 y, uint16 z, uint16 u, uint96 w) public view {
        uint32 utilizations = uint32(z) + (uint32(u) << 16);
        PositionBalance x = harness.storeBalanceData(y, utilizations, w);
        assertEq(harness.positionSize(x), y);
        assertEq(harness.utilizations(x), utilizations);
        assertEq(harness.utilization0(x), int256(uint256(z)));
        assertEq(harness.utilization1(x), int256(uint256(u)));
        assertEq(harness.tickData(x), w);
    }

    function test_Success_storeBalanceData_utilizations(uint128 y, uint32 z, uint96 u) public view {
        PositionBalance x = harness.storeBalanceData(y, z, u);
        assertEq(harness.positionSize(x), y);
        assertEq(harness.utilizations(x), z);
        assertEq(harness.tickData(x), u);
    }

    function test_Success_packTickData(int24 y, int24 z, int24 u, int24 w) public view {
        uint96 x = harness.packTickData(y, z, u, w);

        console2.log("x", x);
        PositionBalance p = harness.storeBalanceData(uint128(0), uint32(0), x);

        assertEq(harness.currentTick(p), y);
        assertEq(harness.fastOracleTick(p), z);
        assertEq(harness.slowOracleTick(p), u);
        assertEq(harness.lastObservedTick(p), w);
    }
}
