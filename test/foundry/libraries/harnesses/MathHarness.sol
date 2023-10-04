// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Math} from "@libraries/Math.sol";

/// @title MathHarness: A harness to expose the Math library for code coverage analysis.
/// @notice Replicates the interface of the Math library, passing through any function calls
/// @author Axicon Labs Limited
contract MathHarness {
    /*****************************************************************
     *
     * GENERAL MATH HELPERS
     *
     *****************************************************************/
    /**
     * @notice Compute the min of the incoming int24s `a` and `b`.
     * @param a first number
     * @param b second number
     * @return the min of `a` and `b`: min(a, b), e.g.: min(4, 1) = 1.
     */
    function min24(int24 a, int24 b) public pure returns (int24) {
        int24 r = Math.min24(a, b);
        return r;
    }

    /**
     * @notice Compute the max of the incoming int24s `a` and `b`.
     * @param a first number
     * @param b second number
     * @return the max of `a` and `b`: max(a, b), e.g.: max(4, 1) = 4.
     */
    function max24(int24 a, int24 b) public pure returns (int24) {
        int24 r = Math.max24(a, b);
        return r;
    }

    /**
     * @notice Compute the absolute value of an integer (int256).
     * @param x the incoming *signed* integer to take the absolute value of.
     * @return the absolute value of `x`, e.g. abs(-4) = 4.
     */
    function abs(int256 x) public pure returns (int256) {
        int256 r = Math.abs(x);
        return r;
    }

    /**
     * @notice Downcast uint256 to uint128. Revert on overflow or underflow.
     * @param toDowncast The uint256 to be downcasted
     * @return the downcasted int (uint128 now).
     */
    function toUint128(uint256 toDowncast) public pure returns (uint128) {
        uint128 r = Math.toUint128(toDowncast);
        return r;
    }

    /**
     * @notice Recast uint128 to int128.
     * @param toCast The uint256 to be downcasted
     * @return the recasted uint128 now as an int128
     */
    function toInt128(uint128 toCast) public pure returns (int128) {
        int128 r = Math.toInt128(toCast);
        return r;
    }

    function sort(int24[] memory data) public returns (int24[] memory) {
        int24[] memory sortedData = Math.sort(data);
        return sortedData;
    }

    function mulDivUp(uint256 a, uint256 b, uint256 denominator) public pure returns (uint256) {
        uint256 result = Math.mulDivUp(a, b, denominator);
        return result;
    }

    function mulDivDown(uint256 a, uint256 b, uint256 denominator) public pure returns (uint256) {
        uint256 result = Math.mulDivDown(a, b, denominator);
        return result;
    }

    function mulDiv96(uint256 a, uint256 b) public pure returns (uint256) {
        uint256 result = Math.mulDiv96(a, b);
        return result;
    }

    function mulDiv128(uint256 a, uint256 b) public pure returns (uint256) {
        uint256 result = Math.mulDiv128(a, b);
        return result;
    }

    function mulDiv64(uint256 a, uint256 b) public pure returns (uint256) {
        uint256 result = Math.mulDiv64(a, b);
        return result;
    }

    function mulDiv192(uint256 a, uint256 b) public pure returns (uint256) {
        uint256 result = Math.mulDiv192(a, b);
        return result;
    }
    
    function getSqrtRatioAtTick(int24 a) public pure returns (uint160) {
        uint160 result = Math.getSqrtRatioAtTick(a);
        return result;
    }

    function getTickAtSqrtRatio(uint160 a) public pure returns (int24) {
        int24 result = Math.getTickAtSqrtRatio(a);
        return result;
    }

    function getAmount0ForLiquidity(uint256 a) public pure returns (uint256) {
        uint256 result = Math.getAmount0ForLiquidity(a);
        return result;
    }

    function getAmount1ForLiquidity(uint256 a) public pure returns (uint256) {
        uint256 result = Math.getAmount1ForLiquidity(a);
        return result;
    }

    function getAmountsForLiquidity(int24 t, uint256 a) public pure returns (uint256, uint256) {
        (uint256 result0, uint256 result1) = Math.getAmountsForLiquidity(t, a);
        return (result0, result1);
    }
}
