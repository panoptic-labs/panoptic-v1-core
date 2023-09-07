// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Internal
import {PanopticMath} from "@libraries/PanopticMath.sol";
// Uniswap
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import "forge-std/Test.sol";

/// @title PanopticMathHarness: A harness to expose the PanopticMath library for code coverage analysis.
/// @notice Replicates the interface of the PanopticMath library, passing through any function calls
/// @author Axicon Labs Limited
contract PanopticMathHarness is Test {
    function getLiquidityChunk(
        uint256 tokenId,
        uint256 legIndex,
        uint128 positionSize,
        int24 tickSpacing
    ) public view returns (uint256) {
        uint256 liquidityChunk = PanopticMath.getLiquidityChunk(
            tokenId,
            legIndex,
            positionSize,
            tickSpacing
        );
        return liquidityChunk;
    }

    function getPoolId(address univ3pool) public pure returns (uint64) {
        uint64 poolId = PanopticMath.getPoolId(univ3pool);
        return poolId;
    }

    function getFinalPoolId(
        uint64 basePoolId,
        address token0,
        address token1,
        uint24 fee
    ) public pure returns (uint64) {
        uint64 finalPoolId = PanopticMath.getFinalPoolId(basePoolId, token0, token1, fee);
        return finalPoolId;
    }

    function computeExercisedAmounts(
        uint256 tokenId,
        uint256 oldTokenId,
        uint128 positionSize,
        int24 tickSpacing
    ) public view returns (int256, int256) {
        (int256 longAmounts, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
            tokenId,
            oldTokenId,
            positionSize,
            tickSpacing
        );
        return (longAmounts, shortAmounts);
    }

    function numberOfLeadingHexZeros(address addr) public pure returns (uint256) {
        uint256 leadingZeroes = PanopticMath.numberOfLeadingHexZeros(addr);
        return leadingZeroes;
    }

    function updatePositionsHash(
        uint256 existingHash,
        uint256 tokenId,
        bool addFlag
    ) public pure returns (uint256 newHash) {
        uint256 newHash = PanopticMath.updatePositionsHash(existingHash, tokenId, addFlag);
        return newHash;
    }

    function twapFilter(
        IUniswapV3Pool univ3pool,
        uint32 twapWindow
    ) public returns (int24 twapTick) {
        int24 twapTick = PanopticMath.twapFilter(univ3pool, twapWindow);
        return twapTick;
    }

    function convertCollateralData(
        uint256 tokenData0,
        uint256 tokenData1,
        uint256 tokenType,
        int24 tick
    ) public pure returns (uint256, uint256) {
        (uint256 collateralBalance, uint256 requiredCollateral) = PanopticMath
            .convertCollateralData(tokenData0, tokenData1, tokenType, tick);
        return (collateralBalance, requiredCollateral);
    }

    function convertCollateralData(
        uint256 tokenData0,
        uint256 tokenData1,
        uint256 tokenType,
        uint160 sqrtPriceX96
    ) public pure returns (uint256, uint256) {
        (uint256 collateralBalance, uint256 requiredCollateral) = PanopticMath
            .convertCollateralData(tokenData0, tokenData1, tokenType, sqrtPriceX96);
        return (collateralBalance, requiredCollateral);
    }

    function _convertNotional(
        uint128 contractSize,
        int24 tickLower,
        int24 tickUpper,
        uint256 asset
    ) public view returns (uint128) {
        uint128 notional = PanopticMath.convertNotional(contractSize, tickLower, tickUpper, asset);
        return notional;
    }

    function convertNotional(
        uint128 contractSize,
        int24 tickLower,
        int24 tickUpper,
        uint256 asset
    ) public view returns (uint128) {
        try this._convertNotional(contractSize, tickLower, tickUpper, asset) returns (
            uint128 notional
        ) {
            return notional;
        } catch {
            vm.assume(2 + 2 == 5);
        }
    }

    function _getAmountsMoved(
        uint256 tokenId,
        uint128 positionSize,
        uint256 legIndex,
        int24 tickSpacing
    ) public view returns (uint256) {
        uint256 amountsMoved = PanopticMath.getAmountsMoved(
            tokenId,
            positionSize,
            legIndex,
            tickSpacing
        );
        return amountsMoved;
    }

    // skip if notional value is invalid (tested elsewhere)
    function getAmountsMoved(
        uint256 tokenId,
        uint128 positionSize,
        uint256 legIndex,
        int24 tickSpacing
    ) public view returns (uint256) {
        try this._getAmountsMoved(tokenId, positionSize, legIndex, tickSpacing) returns (
            uint256 contractsNotional
        ) {
            return contractsNotional;
        } catch {
            vm.assume(2 + 2 == 5);
        }
    }

    function _calculateIOAmounts(
        uint256 tokenId,
        uint128 positionSize,
        uint256 legIndex,
        int24 tickSpacing
    ) public view returns (int256, int256) {
        (int256 longs, int256 shorts) = PanopticMath._calculateIOAmounts(
            tokenId,
            positionSize,
            legIndex,
            tickSpacing
        );
        return (longs, shorts);
    }

    function calculateIOAmounts(
        uint256 tokenId,
        uint128 positionSize,
        uint256 legIndex,
        int24 tickSpacing
    ) public view returns (int256, int256) {
        try this._calculateIOAmounts(tokenId, positionSize, legIndex, tickSpacing) returns (
            int256 longs,
            int256 shorts
        ) {
            return (longs, shorts);
        } catch {
            vm.assume(2 + 2 == 5);
        }
    }

    function convert0to1(uint256 amount, uint160 sqrtPriceX96) public pure returns (uint256) {
        uint256 result = PanopticMath.convert0to1(amount, sqrtPriceX96);
        return result;
    }

    function convert0to1(int256 amount, uint160 sqrtPriceX96) public pure returns (int256) {
        int256 result = PanopticMath.convert0to1(amount, sqrtPriceX96);
        return result;
    }

    function convert1to0(uint256 amount, uint160 sqrtPriceX96) public pure returns (uint256) {
        uint256 result = PanopticMath.convert1to0(amount, sqrtPriceX96);
        return result;
    }

    function convert1to0(int256 amount, uint160 sqrtPriceX96) public pure returns (int256) {
        int256 result = PanopticMath.convert1to0(amount, sqrtPriceX96);
        return result;
    }
}
