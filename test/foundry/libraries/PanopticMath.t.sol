// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry
import "forge-std/Test.sol";
// Internal
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {BitMath} from "v3-core/libraries/BitMath.sol";
import {Errors} from "@libraries/Errors.sol";
import {PanopticMathHarness} from "./harnesses/PanopticMathHarness.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRight} from "@types/LeftRight.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
// Uniswap
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {FixedPoint96} from "v3-core/libraries/FixedPoint96.sol";
import {FixedPoint128} from "v3-core/libraries/FixedPoint128.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
// Test util
import {PositionUtils} from "../testUtils/PositionUtils.sol";

/**
 * Test the PanopticMath functionality with Foundry and Fuzzing.
 *
 * @author Axicon Labs Limited
 */
contract PanopticMathTest is Test, PositionUtils {
    // harness
    PanopticMathHarness harness;

    // libraries
    using LeftRight for int256;
    using LeftRight for uint256;
    using TokenId for uint256;
    using LiquidityChunk for uint256;

    // store a few different mainnet pairs - the pool used is part of the fuzz
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IUniswapV3Pool constant WBTC_ETH_30 =
        IUniswapV3Pool(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);
    IUniswapV3Pool constant USDC_WETH_30 =
        IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8);
    IUniswapV3Pool[3] public pools = [USDC_WETH_5, WBTC_ETH_30, USDC_WETH_30];

    function setUp() public {
        harness = new PanopticMathHarness();
    }

    // use storage as temp to avoid stack to deeps
    IUniswapV3Pool selectedPool;
    int24 tickSpacing;
    int24 currentTick;

    int24 minTick;
    int24 maxTick;
    int24 lowerBound;
    int24 upperBound;
    int24 strikeOffset;

    function test_Success_getLiquidityChunk_asset0(
        uint16 optionRatio,
        uint16 isLong,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 127);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(positionSize, 0, 2)]; // resue position size as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, 0, isLong, tokenType, 0, strike, width);
        }

        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(0, tickSpacing);

        uint160 sqrtPriceBottom = (tokenId.width(0) == 4095)
            ? TickMath.getSqrtRatioAtTick(tokenId.strike(0))
            : TickMath.getSqrtRatioAtTick(tickLower);

        uint256 amount = uint256(positionSize) * tokenId.optionRatio(0);
        uint128 legLiquidity = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceBottom,
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount
        );

        uint256 expectedLiquidityChunk = uint256(0).createChunk(tickLower, tickUpper, legLiquidity);
        uint256 returnedLiquidityChunk = harness.getLiquidityChunk(
            tokenId,
            0,
            positionSize,
            tickSpacing
        );

        assertEq(expectedLiquidityChunk, returnedLiquidityChunk);
    }

    function test_Success_getLiquidityChunk_asset1(
        uint16 optionRatio,
        uint16 isLong,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 127);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(positionSize, 0, 2)]; // resue position size as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, 1, isLong, tokenType, 0, strike, width);
        }

        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(0, tickSpacing);

        uint160 sqrtPriceTop = (tokenId.width(0) == 4095)
            ? TickMath.getSqrtRatioAtTick(tokenId.strike(0))
            : TickMath.getSqrtRatioAtTick(tickUpper);

        uint256 amount = uint256(positionSize) * tokenId.optionRatio(0);
        uint128 legLiquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtRatioAtTick(tickLower),
            sqrtPriceTop,
            amount
        );

        uint256 expectedLiquidityChunk = uint256(0).createChunk(tickLower, tickUpper, legLiquidity);
        uint256 returnedLiquidityChunk = harness.getLiquidityChunk(
            tokenId,
            0,
            positionSize,
            tickSpacing
        );

        assertEq(expectedLiquidityChunk, returnedLiquidityChunk);
    }

    function test_Success_getPoolId(address univ3pool) public {
        uint64 poolId = uint64(uint160(univ3pool) >> 96);
        assertEq(poolId, harness.getPoolId(univ3pool));
    }

    function test_Success_getFinalPoolId(
        uint64 basePoolId,
        address token0,
        address token1,
        uint8 feeSeed
    ) public {
        uint64 finalPoolId;
        uint24 fee = [30, 60, 100][bound(feeSeed, 0, 2)];
        unchecked {
            finalPoolId =
                basePoolId +
                (uint64(uint256(keccak256(abi.encodePacked(token0, token1, fee)))) >> 32);
        }

        assertEq(finalPoolId, harness.getFinalPoolId(basePoolId, token0, token1, fee));
    }

    function test_Success_computeExercisedAmounts_emptyOldTokenId(
        uint16 optionRatio,
        uint16 isLong,
        uint16 asset,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 127);

            vm.assume(positionSize * uint128(optionRatio) < type(uint56).max);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            asset = asset & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(positionSize, 0, 2)]; // resue position size as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, asset, isLong, tokenType, 0, strike, width);
        }

        (int256 expectedLongs, int256 expectedShorts) = harness.calculateIOAmounts(
            tokenId,
            positionSize,
            0,
            tickSpacing
        );

        (int256 returnedLongs, int256 returnedShorts) = harness.computeExercisedAmounts(
            tokenId,
            0,
            positionSize,
            tickSpacing
        );

        assertEq(expectedLongs, returnedLongs);
        assertEq(expectedShorts, returnedShorts);
    }

    function test_Success_computeExercisedAmounts_fullOldTokenId(
        uint16 optionRatio,
        uint16 isLong,
        uint16 asset,
        uint16 tokenType,
        int24 strike,
        int24 strike2,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);

        uint256 tokenId;
        uint256 tokenId2;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 127);

            vm.assume(positionSize * uint128(optionRatio) < type(uint56).max);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            asset = asset & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(positionSize, 0, 2)]; // resue position size as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, asset, isLong, tokenType, 0, strike, width);
        }

        {
            strike2 = int24(bound(strike2, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike2 = int24(strike2 * tickSpacing + strikeOffset);

            // create identical token with differing strike and width
            tokenId2 = tokenId2.addLeg(0, optionRatio, asset, isLong, tokenType, 0, strike, width);
        }

        (int256 expectedLongs, int256 expectedShorts) = harness.calculateIOAmounts(
            tokenId,
            positionSize,
            0,
            tickSpacing
        );

        (int256 expectedLongsOld, int256 expectedShortsOld) = harness.calculateIOAmounts(
            tokenId2,
            positionSize,
            0,
            tickSpacing
        );

        expectedLongs = expectedLongs.sub(expectedLongsOld);
        expectedShorts = expectedShorts.sub(expectedShortsOld);

        (int256 returnedLongs, int256 returnedShorts) = harness.computeExercisedAmounts(
            tokenId,
            tokenId2,
            positionSize,
            tickSpacing
        );

        assertEq(expectedLongs, returnedLongs);
        assertEq(expectedShorts, returnedShorts);
    }

    function test_Success_numberOfLeadingHexZeros(address addr) public {
        uint256 expectedData = addr == address(0)
            ? 40
            : 39 - Math.mostSignificantNibble(uint160(addr));
        assertEq(expectedData, harness.numberOfLeadingHexZeros(addr));
    }

    function test_Success_updatePositionsHash_add(
        uint16 optionRatio,
        uint16 isLong,
        uint16 asset,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint256 existingHash
    ) public {
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 127);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            asset = asset & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // resue optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, asset, isLong, tokenType, 0, strike, width);
        }

        uint248 updatedHash = uint248(existingHash) ^
            (uint248(uint256(keccak256(abi.encode(tokenId)))));
        uint256 expectedHash = uint256(updatedHash) + (((existingHash >> 248) + 1) << 248);

        uint256 returnedHash = harness.updatePositionsHash(existingHash, tokenId, true);

        assertEq(expectedHash, returnedHash);
    }

    function test_Success_updatePositionsHash_update(
        uint16 optionRatio,
        uint16 isLong,
        uint16 asset,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint256 existingHash
    ) public {
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 127);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            asset = asset & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // resue optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, asset, isLong, tokenType, 0, strike, width);
        }

        uint256 expectedHash;
        uint256 returnedHash;
        unchecked {
            uint248 updatedHash = uint248(existingHash) ^
                (uint248(uint256(keccak256(abi.encode(tokenId)))));
            expectedHash = uint256(updatedHash) + (((existingHash >> 248) - 1) << 248);

            returnedHash = harness.updatePositionsHash(existingHash, tokenId, false);
        }

        assertEq(expectedHash, returnedHash);
    }

    function test_Success_twapFilter(uint32 twapWindow) public {
        twapWindow = uint32(bound(twapWindow, 100, 10000));

        selectedPool = pools[bound(twapWindow, 0, 2)]; // resue twapWindow as seed

        uint32[] memory secondsAgos = new uint32[](20);
        int24[] memory twapMeasurement = new int24[](19);

        for (uint32 i = 0; i < 20; ++i) {
            secondsAgos[i] = ((i + 1) * twapWindow) / uint32(20);
        }

        (int56[] memory tickCumulatives, ) = selectedPool.observe(secondsAgos);

        // compute the average tick per 30s window
        for (uint32 i = 0; i < 19; ++i) {
            twapMeasurement[i] = int24(
                (tickCumulatives[i] - tickCumulatives[i + 1]) / int56(uint56(twapWindow / 20))
            );
        }

        // sort the tick measurements
        int24[] memory sortedTicks = Math.sort(twapMeasurement);

        // Get the median value
        int24 twapTick = sortedTicks[10];

        assertEq(twapTick, harness.twapFilter(selectedPool, twapWindow));
    }

    function test_Success_convertCollateralData_Tick_tokenType0(
        int256 atTickSeed,
        uint128 balance0,
        uint128 required0,
        uint128 balance1,
        uint128 required1
    ) public {
        int24 atTick = int24(bound(atTickSeed, TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(atTick);

        (uint256 collateralBalance, uint256 requiredCollateral, ) = harness.convertCollateralData(
            uint256(0).toRightSlot(balance0).toLeftSlot(required0),
            uint256(0).toRightSlot(balance1).toLeftSlot(required1),
            0,
            sqrtPriceX96
        );
        assertEq(collateralBalance, balance0 + PanopticMath.convert1to0(balance1, sqrtPriceX96));
        assertEq(requiredCollateral, required0 + PanopticMath.convert1to0(required1, sqrtPriceX96));
    }

    function test_Success_convertCollateralData_Tick_tokenType1(
        int256 atTickSeed,
        uint128 balance0,
        uint128 required0,
        uint128 balance1,
        uint128 required1
    ) public {
        int24 atTick = int24(bound(atTickSeed, TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(atTick);

        (uint256 collateralBalance, uint256 requiredCollateral, ) = harness.convertCollateralData(
            uint256(0).toRightSlot(balance0).toLeftSlot(required0),
            uint256(0).toRightSlot(balance1).toLeftSlot(required1),
            1,
            sqrtPriceX96
        );
        assertEq(collateralBalance, balance1 + PanopticMath.convert0to1(balance0, sqrtPriceX96));
        assertEq(requiredCollateral, required1 + PanopticMath.convert0to1(required0, sqrtPriceX96));
    }

    function test_Success_convertCollateralData_sqrtPrice_tokenType0(
        uint256 sqrtPriceSeed,
        uint128 balance0,
        uint128 required0,
        uint128 balance1,
        uint128 required1
    ) public {
        uint160 sqrtPriceX96 = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO)
        );

        (uint256 collateralBalance, uint256 requiredCollateral, ) = harness.convertCollateralData(
            uint256(0).toRightSlot(balance0).toLeftSlot(required0),
            uint256(0).toRightSlot(balance1).toLeftSlot(required1),
            0,
            sqrtPriceX96
        );
        assertEq(collateralBalance, balance0 + PanopticMath.convert1to0(balance1, sqrtPriceX96));
        assertEq(requiredCollateral, required0 + PanopticMath.convert1to0(required1, sqrtPriceX96));
    }

    function test_Success_convertCollateralData_sqrtPrice_tokenType1(
        uint256 sqrtPriceSeed,
        uint128 balance0,
        uint128 required0,
        uint128 balance1,
        uint128 required1
    ) public {
        uint160 sqrtPriceX96 = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO)
        );

        (uint256 collateralBalance, uint256 requiredCollateral, ) = harness.convertCollateralData(
            uint256(0).toRightSlot(balance0).toLeftSlot(required0),
            uint256(0).toRightSlot(balance1).toLeftSlot(required1),
            1,
            sqrtPriceX96
        );
        assertEq(collateralBalance, balance1 + PanopticMath.convert0to1(balance0, sqrtPriceX96));
        assertEq(requiredCollateral, required1 + PanopticMath.convert0to1(required0, sqrtPriceX96));
    }

    function test_Success_convertNotional_asset0(
        int256 tickLower,
        int256 tickUpper,
        uint128 amount
    ) public {
        tickLower = bound(tickLower, TickMath.MIN_TICK, TickMath.MAX_TICK);
        tickUpper = bound(tickUpper, TickMath.MIN_TICK, TickMath.MAX_TICK);

        uint256 sqrtRatio = uint256(
            TickMath.getSqrtRatioAtTick(int24((tickLower + tickUpper) / 2))
        );

        // make sure nothing overflows
        if (sqrtRatio < 340275971719517849884101479065584693834) {
            uint256 priceX192 = uint256(sqrtRatio) ** 2;

            unchecked {
                uint256 mm = mulmod(priceX192, amount, type(uint256).max);
                uint256 prod0 = priceX192 * amount;
                vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 192);
            }
        } else {
            uint256 priceX128 = FullMath.mulDiv(sqrtRatio, sqrtRatio, 2 ** 64);

            // make sure the final result does not overflow
            unchecked {
                uint256 mm = mulmod(priceX128, amount, type(uint256).max);
                uint256 prod0 = priceX128 * amount;
                vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 128);
            }
        }

        uint256 res = harness.convert0to1(amount, uint160(sqrtRatio));

        // make sure result fits in uint128 and is nonzero
        vm.assume(res <= type(uint128).max && res > 0);

        assertEq(harness._convertNotional(amount, int24(tickLower), int24(tickUpper), 0), res);
    }

    function test_Success_convertNotional_asset0_InvalidNotionalValue(
        int256 tickLower,
        int256 tickUpper,
        uint128 amount
    ) public {
        tickLower = bound(tickLower, TickMath.MIN_TICK, TickMath.MAX_TICK);
        tickUpper = bound(tickUpper, TickMath.MIN_TICK, TickMath.MAX_TICK);

        uint256 sqrtRatio = uint256(
            TickMath.getSqrtRatioAtTick(int24((tickLower + tickUpper) / 2))
        );

        // make sure nothing overflows
        if (sqrtRatio < 340275971719517849884101479065584693834) {
            uint256 priceX192 = uint256(sqrtRatio) ** 2;

            unchecked {
                uint256 mm = mulmod(priceX192, amount, type(uint256).max);
                uint256 prod0 = priceX192 * amount;
                vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 192);
            }
        } else {
            uint256 priceX128 = FullMath.mulDiv(sqrtRatio, sqrtRatio, 2 ** 64);

            // make sure the final result does not overflow
            unchecked {
                uint256 mm = mulmod(priceX128, amount, type(uint256).max);
                uint256 prod0 = priceX128 * amount;
                vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 128);
            }
        }

        uint256 res = harness.convert0to1(amount, uint160(sqrtRatio));

        // make sure result does not fit in uint128 or is zero
        vm.assume(res > type(uint128).max || res == 0);

        vm.expectRevert(Errors.InvalidNotionalValue.selector);
        harness._convertNotional(amount, int24(tickLower), int24(tickUpper), 0);
    }

    function test_Success_convertNotional_asset1(
        int256 tickLower,
        int256 tickUpper,
        uint128 amount
    ) public {
        tickLower = bound(tickLower, TickMath.MIN_TICK, TickMath.MAX_TICK);
        tickUpper = bound(tickUpper, TickMath.MIN_TICK, TickMath.MAX_TICK);

        uint256 sqrtRatio = uint256(
            TickMath.getSqrtRatioAtTick(int24((tickLower + tickUpper) / 2))
        );

        // make sure nothing overflows
        if (sqrtRatio < 340275971719517849884101479065584693834) {
            uint256 priceX192 = uint256(sqrtRatio) ** 2;

            unchecked {
                uint256 mm = mulmod(2 ** 192, amount, type(uint256).max);
                uint256 prod0 = 2 ** 192 * amount;
                vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX192);
            }
        } else {
            uint256 priceX128 = FullMath.mulDiv(sqrtRatio, sqrtRatio, 2 ** 64);

            // make sure the final result does not overflow
            unchecked {
                uint256 mm = mulmod(2 * 128, amount, type(uint256).max);
                uint256 prod0 = 2 ** 128 * amount;
                vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX128);
            }
        }

        uint256 res = harness.convert1to0(amount, uint160(sqrtRatio));

        // make sure result fits in uint128 and is nonzero
        vm.assume(res <= type(uint128).max && res > 0);

        assertEq(harness._convertNotional(amount, int24(tickLower), int24(tickUpper), 1), res);
    }

    function test_Success_convertNotional_asset1_InvalidNotionalValue(
        int256 tickLower,
        int256 tickUpper,
        uint128 amount
    ) public {
        tickLower = bound(tickLower, TickMath.MIN_TICK, TickMath.MAX_TICK);
        tickUpper = bound(tickUpper, TickMath.MIN_TICK, TickMath.MAX_TICK);

        uint256 sqrtRatio = uint256(
            TickMath.getSqrtRatioAtTick(int24((tickLower + tickUpper) / 2))
        );

        // make sure nothing overflows
        if (sqrtRatio < 340275971719517849884101479065584693834) {
            uint256 priceX192 = uint256(sqrtRatio) ** 2;

            unchecked {
                uint256 mm = mulmod(2 ** 192, amount, type(uint256).max);
                uint256 prod0 = 2 ** 192 * amount;
                vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX192);
            }
        } else {
            uint256 priceX128 = FullMath.mulDiv(sqrtRatio, sqrtRatio, 2 ** 64);

            // make sure the final result does not overflow
            unchecked {
                uint256 mm = mulmod(2 * 128, amount, type(uint256).max);
                uint256 prod0 = 2 ** 128 * amount;
                vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX128);
            }
        }

        uint256 res = harness.convert1to0(amount, uint160(sqrtRatio));

        // make sure result does not fit in uint128 or is zero
        vm.assume(res > type(uint128).max || res == 0);

        vm.expectRevert(Errors.InvalidNotionalValue.selector);
        harness._convertNotional(amount, int24(tickLower), int24(tickUpper), 1);
    }

    function test_Success_convert0to1_PriceX192_Uint(uint256 amount, uint256 sqrtPriceSeed) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(priceX192, amount, type(uint256).max);
            uint256 prod0 = priceX192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 192);
        }

        assertEq(
            harness.convert0to1(amount, sqrtPrice),
            FullMath.mulDiv(amount, priceX192, 2 ** 192)
        );
    }

    function test_Fail_convert0to1_PriceX192_Uint_overflow(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX192, amount, type(uint256).max);
            uint256 prod0 = priceX192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= 2 ** 192);
        }

        vm.expectRevert();
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Success_convert0to1_PriceX192_Int(int256 amount, uint256 sqrtPriceSeed) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(priceX192, absAmount, type(uint256).max);
            uint256 prod0 = priceX192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 192);
        }
        vm.assume(FullMath.mulDiv(absAmount, priceX192, 2 ** 192) <= uint256(type(int256).max));
        assertEq(
            harness.convert0to1(amount, sqrtPrice),
            (amount < 0 ? -1 : int(1)) * int(FullMath.mulDiv(absAmount, priceX192, 2 ** 192))
        );
    }

    function test_Fail_convert0to1_PriceX192_Int_overflow(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX192, absAmount, type(uint256).max);
            uint256 prod0 = priceX192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= 2 ** 192);
        }

        vm.expectRevert();
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Fail_convert0to1_PriceX192_Int_CastingError(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX192, absAmount, type(uint256).max);
            uint256 prod0 = priceX192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 192);
        }

        vm.assume(FullMath.mulDiv(absAmount, priceX192, 2 ** 192) > uint256(type(int256).max));
        vm.expectRevert(Errors.CastingError.selector);
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Success_convert1to0_PriceX192_Uint(uint256 amount, uint256 sqrtPriceSeed) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(amount, 2 ** 192, type(uint256).max);
            uint256 prod0 = 2 ** 192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX192);
        }

        assertEq(
            harness.convert1to0(amount, sqrtPrice),
            FullMath.mulDiv(amount, 2 ** 192, priceX192)
        );
    }

    function test_Fail_convert1to0_PriceX192_Uint_overflow(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(amount, 2 ** 192, type(uint256).max);
            uint256 prod0 = 2 ** 192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= priceX192);
        }

        vm.expectRevert();
        harness.convert1to0(amount, sqrtPrice);
    }

    function test_Success_convert1to0_PriceX192_Int(int256 amount, uint256 sqrtPriceSeed) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(absAmount, 2 ** 192, type(uint256).max);
            uint256 prod0 = 2 ** 192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX192);
        }

        vm.assume(FullMath.mulDiv(absAmount, 2 ** 192, priceX192) <= uint256(type(int256).max));
        assertEq(
            harness.convert1to0(amount, sqrtPrice),
            (amount < 0 ? -1 : int(1)) * int(FullMath.mulDiv(absAmount, 2 ** 192, priceX192))
        );
    }

    function test_Fail_convert1to0_PriceX192_Int_overflow(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(2 ** 192, absAmount, type(uint256).max);
            uint256 prod0 = 2 ** 192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= priceX192);
        }

        vm.expectRevert();
        harness.convert1to0(amount, sqrtPrice);
    }

    function test_Fail_convert1to0_PriceX192_Int_CastingError(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, 340275971719517849884101479065584693833)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(2 ** 192, absAmount, type(uint256).max);
            uint256 prod0 = 2 ** 192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX192);
        }

        vm.assume(FullMath.mulDiv(absAmount, 2 ** 192, priceX192) > uint256(type(int256).max));
        vm.expectRevert(Errors.CastingError.selector);
        harness.convert1to0(amount, sqrtPrice);
    }

    function test_Success_convert0to1_PriceX128_Uint(uint256 amount, uint256 sqrtPriceSeed) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, 340275971719517849884101479065584693834, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(priceX128, amount, type(uint256).max);
            uint256 prod0 = priceX128 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 128);
        }

        assertEq(
            harness.convert0to1(amount, sqrtPrice),
            FullMath.mulDiv(amount, priceX128, 2 ** 128)
        );
    }

    function test_Fail_convert0to1_PriceX128_Uint_overflow(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, 340275971719517849884101479065584693834, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX128, amount, type(uint256).max);
            uint256 prod0 = priceX128 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= 2 ** 128);
        }

        vm.expectRevert();
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Success_convert0to1_PriceX128_Int(int256 amount, uint256 sqrtPriceSeed) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, 340275971719517849884101479065584693834, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(priceX128, absAmount, type(uint256).max);
            uint256 prod0 = priceX128 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 128);
        }

        vm.assume(FullMath.mulDiv(absAmount, priceX128, 2 ** 128) <= uint256(type(int256).max));
        assertEq(
            harness.convert0to1(amount, sqrtPrice),
            (amount < 0 ? -1 : int(1)) * int(FullMath.mulDiv(absAmount, priceX128, 2 ** 128))
        );
    }

    function test_Fail_convert0to1_PriceX128_Int_overflow(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, 340275971719517849884101479065584693834, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX128, absAmount, type(uint256).max);
            uint256 prod0 = priceX128 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= 2 ** 128);
        }

        vm.expectRevert();
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Fail_convert0to1_PriceX128_Int_CastingError(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, 340275971719517849884101479065584693834, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX128, absAmount, type(uint256).max);
            uint256 prod0 = priceX128 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 128);
        }

        vm.assume(FullMath.mulDiv(absAmount, priceX128, 2 ** 128) > uint256(type(int256).max));
        vm.expectRevert(Errors.CastingError.selector);
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Success_convert1to0_PriceX128_Uint(uint256 amount, uint256 sqrtPriceSeed) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, 340275971719517849884101479065584693834, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(2 ** 128, amount, type(uint256).max);
            uint256 prod0 = 2 ** 128 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX128);
        }

        assertEq(
            harness.convert1to0(amount, sqrtPrice),
            FullMath.mulDiv(amount, 2 ** 128, priceX128)
        );
    }

    function test_Success_convert1to0_PriceX128_Int(int256 amount, uint256 sqrtPriceSeed) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, 340275971719517849884101479065584693834, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(2 ** 128, absAmount, type(uint256).max);
            uint256 prod0 = 2 ** 128 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX128);
        }

        vm.assume(FullMath.mulDiv(absAmount, 2 ** 128, priceX128) <= uint256(type(int256).max));
        assertEq(
            harness.convert1to0(amount, sqrtPrice),
            (amount < 0 ? -1 : int(1)) * int(FullMath.mulDiv(absAmount, 2 ** 128, priceX128))
        );
    }

    function test_Success_getAmountsMoved_asset0(
        uint16 optionRatio,
        uint16 isLong,
        uint16 asset,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 1);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // resue optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, 0, isLong, tokenType, 0, strike, width);
        }

        // get the tick range for this leg in order to get the strike price (the underlying price)
        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(0, tickSpacing);

        uint128 amount0 = positionSize * uint128(tokenId.optionRatio(0));
        uint128 amount1 = harness.convertNotional(amount0, tickLower, tickUpper, tokenId.asset(0));
        uint256 expectedContractsNotional = uint256(0).toRightSlot(amount0).toLeftSlot(amount1);

        uint256 returnedContractsNotional = harness.getAmountsMoved(
            tokenId,
            positionSize,
            0,
            tickSpacing
        );
        assertEq(expectedContractsNotional, returnedContractsNotional);
    }

    function test_Success_getAmountsMoved_asset1(
        uint16 optionRatio,
        uint16 isLong,
        uint16 asset,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 127);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // resue optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, 1, isLong, tokenType, 0, strike, width);
        }

        // get the tick range for this leg in order to get the strike price (the underlying price)
        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(0, tickSpacing);

        uint128 amount1 = positionSize * uint128(tokenId.optionRatio(0));
        uint128 amount0 = harness.convertNotional(amount1, tickLower, tickUpper, tokenId.asset(0));
        uint256 expectedContractsNotional = uint256(0).toRightSlot(amount0).toLeftSlot(amount1);

        uint256 returnedContractsNotional = harness.getAmountsMoved(
            tokenId,
            positionSize,
            0,
            tickSpacing
        );
        assertEq(expectedContractsNotional, returnedContractsNotional);
    }

    // // _calculateIOAmounts
    function test_Success_calculateIOAmounts_shortTokenType0(
        uint16 optionRatio,
        uint16 asset,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 1);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            asset = asset & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // resue optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, asset, 0, 0, 0, strike, width);
        }

        uint256 contractsNotional = harness.getAmountsMoved(tokenId, positionSize, 0, tickSpacing);

        int256 expectedShorts = int256(0).toRightSlot(Math.toInt128(contractsNotional.rightSlot()));
        (int256 returnedLongs, int256 returnedShorts) = harness.calculateIOAmounts(
            tokenId,
            positionSize,
            0,
            tickSpacing
        );

        assertEq(expectedShorts, returnedShorts);
        assertEq(0, returnedLongs);
    }

    function test_Success_calculateIOAmounts_longTokenType0(
        uint16 optionRatio,
        uint16 asset,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 1);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            asset = asset & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // resue optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, asset, 1, 0, 0, strike, width);
        }

        // contractSize = positionSize * uint128(tokenId.optionRatio(legIndex));
        (int24 legLowerTick, int24 legUpperTick) = tokenId.asTicks(0, tickSpacing);

        positionSize = uint64(
            PositionUtils.getContractsForAmountAtTick(
                currentTick,
                legLowerTick,
                legUpperTick,
                1,
                uint128(positionSize)
            )
        );

        uint256 contractsNotional = harness.getAmountsMoved(tokenId, positionSize, 0, tickSpacing);

        int256 expectedLongs = int256(0).toRightSlot(Math.toInt128(contractsNotional.rightSlot()));
        (int256 returnedLongs, int256 returnedShorts) = harness.calculateIOAmounts(
            tokenId,
            positionSize,
            0,
            tickSpacing
        );

        assertEq(0, returnedShorts);
        assertEq(expectedLongs, returnedLongs);
    }

    function test_Success_calculateIOAmounts_shortTokenType1(
        uint16 optionRatio,
        uint16 asset,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 127);

            vm.assume(positionSize * uint128(optionRatio) < type(uint56).max);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            asset = asset & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // resue optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, asset, 0, 1, 0, strike, width);
        }

        uint256 contractsNotional = harness.getAmountsMoved(tokenId, positionSize, 0, tickSpacing);

        int256 expectedShorts = int256(0).toLeftSlot(Math.toInt128(contractsNotional.leftSlot()));
        (int256 returnedLongs, int256 returnedShorts) = harness.calculateIOAmounts(
            tokenId,
            positionSize,
            0,
            tickSpacing
        );

        assertEq(expectedShorts, returnedShorts);
        assertEq(0, returnedLongs);
    }

    function test_Success_calculateIOAmounts_longTokenType1(
        uint16 optionRatio,
        uint16 asset,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        uint256 tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatio, 1, 127);

            // max bound position size * optionRatio can be to avoid overflows
            vm.assume(positionSize * uint128(optionRatio) < type(uint56).max);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            asset = asset & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // resue optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContext(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = tokenId.addLeg(0, optionRatio, asset, 1, 1, 0, strike, width);
        }

        uint256 contractsNotional = harness.getAmountsMoved(tokenId, positionSize, 0, tickSpacing);

        int256 expectedLongs = int256(0).toLeftSlot(Math.toInt128(contractsNotional.leftSlot()));
        (int256 returnedLongs, int256 returnedShorts) = harness.calculateIOAmounts(
            tokenId,
            positionSize,
            0,
            tickSpacing
        );

        assertEq(0, returnedShorts);
        assertEq(expectedLongs, returnedLongs);
    }
}
