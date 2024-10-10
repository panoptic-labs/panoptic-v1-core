// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
// Custom types
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract PanopticHelper {
    SemiFungiblePositionManager internal immutable SFPM;

    struct Leg {
        uint64 poolId;
        address UniswapV3Pool;
        uint256 asset;
        uint256 optionRatio;
        uint256 tokenType;
        uint256 isLong;
        uint256 riskPartner;
        int24 strike;
        int24 width;
    }

    /// @notice Construct the PanopticHelper contract
    /// @param _SFPM address of the SemiFungiblePositionManager
    /// @dev the SFPM is used to get the pool ID for a given address
    constructor(SemiFungiblePositionManager _SFPM) payable {
        SFPM = _SFPM;
    }

    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return collateralBalance the total combined balance of token0 and token1 for a user in terms of tokenType
    /// @return requiredCollateral The combined collateral requirement for a user in terms of tokenType
    function checkCollateral(
        PanopticPool pool,
        address account,
        int24 atTick,
        TokenId[] calldata positionIdList
    ) public view returns (uint256, uint256) {
        // Compute premia for all options (includes short+long premium)
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            uint256[2][] memory positionBalanceArray
        ) = pool.getAccumulatedFeesAndPositionsData(account, false, positionIdList);

        // Query the current and required collateral amounts for the two tokens
        LeftRightUnsigned tokenData0 = pool.collateralToken0().getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            shortPremium.rightSlot(),
            longPremium.rightSlot()
        );
        LeftRightUnsigned tokenData1 = pool.collateralToken1().getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            shortPremium.leftSlot(),
            longPremium.leftSlot()
        );

        // convert (using atTick) and return the total collateral balance and required balance in terms of tokenType
        return
            PanopticMath.getCrossBalances(tokenData0, tokenData1, Math.getSqrtRatioAtTick(atTick));
    }

    /// @notice Calculate NAV of user's option portfolio at a given tick.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick The tick to calculate the value at
    /// @param positionIdList A list of all positions the user holds on that pool
    /// @return value0 The amount of token0 owned by portfolio
    /// @return value1 The amount of token1 owned by portfolio
    function getPortfolioValue(
        PanopticPool pool,
        address account,
        int24 atTick,
        TokenId[] calldata positionIdList
    ) external view returns (int256 value0, int256 value1) {
        // Compute premia for all options (includes short+long premium)
        (, , uint256[2][] memory positionBalanceArray) = pool.getAccumulatedFeesAndPositionsData(
            account,
            false,
            positionIdList
        );

        for (uint256 k = 0; k < positionIdList.length; ) {
            TokenId tokenId = positionIdList[k];
            uint128 positionSize = LeftRightUnsigned.wrap(positionBalanceArray[k][1]).rightSlot();
            uint256 numLegs = tokenId.countLegs();
            for (uint256 leg = 0; leg < numLegs; ) {
                LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize
                );

                (uint256 amount0, uint256 amount1) = Math.getAmountsForLiquidity(
                    atTick,
                    liquidityChunk
                );

                if (tokenId.isLong(leg) == 0) {
                    unchecked {
                        value0 += int256(amount0);
                        value1 += int256(amount1);
                    }
                } else {
                    unchecked {
                        value0 -= int256(amount0);
                        value1 -= int256(amount1);
                    }
                }

                unchecked {
                    ++leg;
                }
            }
            unchecked {
                ++k;
            }
        }
    }

    /// @notice Returns the total number of contracts owned by `account` and the pool utilization at mint for a specified `tokenId.
    /// @param pool The PanopticPool instance corresponding to the pool specified in `TokenId`
    /// @param account The address of the account on which to retrieve `balance` and `poolUtilization`
    /// @return balance Number of contracts of `tokenId` owned by the user
    /// @return poolUtilization0 The utilization of token0 in the Panoptic pool at mint
    /// @return poolUtilization1 The utilization of token1 in the Panoptic pool at mint
    function optionPositionInfo(
        PanopticPool pool,
        address account,
        TokenId tokenId
    ) external view returns (uint128, uint16, uint16) {
        TokenId[] memory tokenIdList = new TokenId[](1);
        tokenIdList[0] = tokenId;

        (, , uint256[2][] memory positionBalanceArray) = pool.getAccumulatedFeesAndPositionsData(
            account,
            false,
            tokenIdList
        );

        PositionBalance balanceAndUtilization = PositionBalance.wrap(positionBalanceArray[0][1]);

        return (
            balanceAndUtilization.positionSize(),
            uint16(balanceAndUtilization.utilizations()),
            uint16(balanceAndUtilization.utilizations() >> 16)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          ORACLE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the median of the last `cardinality` average prices over `period` observations from `univ3pool`.
    /// @dev Used when we need a manipulation-resistant TWAP price.
    /// @dev oracle observations snapshot the closing price of the last block before the first interaction of a given block.
    /// @dev The maximum frequency of observations is 1 per block, but there is no guarantee that the pool will be observed at every block.
    /// @dev Each period has a minimum length of blocktime * period, but may be longer if the Uniswap pool is relatively inactive.
    /// @dev The final price used in the array (of length `cardinality`) is the average of all observations comprising `period` (which is itself a number of observations).
    /// @dev Thus, the minimum total time window is `cardinality` * `period` * `blocktime`.
    /// @param univ3pool The Uniswap pool to get the median observation from
    /// @param cardinality The number of `periods` to in the median price array, should be odd.
    /// @param period The number of observations to average to compute one entry in the median price array
    /// @return The median of `cardinality` observations spaced by `period` in the Uniswap pool
    function computeMedianObservedPrice(
        IV3CompatibleOracle univ3pool,
        uint256 cardinality,
        uint256 period
    ) external view returns (int24) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = univ3pool.slot0();

        (int24 medianTick, ) = PanopticMath.computeMedianObservedPrice(
            univ3pool,
            observationIndex,
            observationCardinality,
            cardinality,
            period
        );
        return medianTick;
    }

    /// @notice Takes a packed structure representing a sorted 8-slot queue of ticks and returns the median of those values.
    /// @dev Also inserts the latest oracle observation into the buffer, resorts, and returns if the last entry is at least `period` seconds old.
    /// @param period The minimum time in seconds that must have passed since the last observation was inserted into the buffer
    /// @param medianData The packed structure representing the sorted 8-slot queue of ticks
    /// @param univ3pool The Uniswap pool to retrieve observations from
    /// @return The median of the provided 8-slot queue of ticks in `medianData`
    /// @return The updated 8-slot queue of ticks with the latest observation inserted if the last entry is at least `period` seconds old (returns 0 otherwise)
    function computeInternalMedian(
        uint256 period,
        uint256 medianData,
        IV3CompatibleOracle univ3pool
    ) external view returns (int24, uint256) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = univ3pool.slot0();

        (int24 _medianTick, uint256 _medianData) = PanopticMath.computeInternalMedian(
            observationIndex,
            observationCardinality,
            period,
            medianData,
            univ3pool
        );
        return (_medianTick, _medianData);
    }

    /// @notice Computes the twap of a Uniswap V3 pool using data from its oracle.
    /// @dev Note that our definition of TWAP differs from a typical mean of prices over a time window.
    /// @dev We instead observe the average price over a series of time intervals, and define the TWAP as the median of those averages.
    /// @param univ3pool The Uniswap pool from which to compute the TWAP.
    /// @param twapWindow The time window to compute the TWAP over.
    /// @return The final calculated TWAP tick.
    function twapFilter(
        IV3CompatibleOracle univ3pool,
        uint32 twapWindow
    ) external view returns (int24) {
        return PanopticMath.twapFilter(univ3pool, twapWindow);
    }

    /// @notice Returns the net assets (balance - maintenance margin) of a given account on a given pool.
    /// @dev does not work for very large tick gradients.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param tick tick to consider
    /// @param positionIdList list of position IDs to consider
    /// @return netEquity the net assets of `account` on `pool`
    function netEquity(
        address pool,
        address account,
        int24 tick,
        TokenId[] calldata positionIdList
    ) internal view returns (int256) {
        (uint256 balanceCross, uint256 requiredCross) = checkCollateral(
            PanopticPool(pool),
            account,
            tick,
            positionIdList
        );

        // convert to token0 to ensure consistent units
        if (tick > 0) {
            balanceCross = PanopticMath.convert1to0(balanceCross, Math.getSqrtRatioAtTick(tick));
            requiredCross = PanopticMath.convert1to0(requiredCross, Math.getSqrtRatioAtTick(tick));
        }

        return int256(balanceCross) - int256(requiredCross);
    }

    // /// @notice Unwraps the contents of the tokenId into its legs.
    // /// @param tokenId the input tokenId
    // /// @return legs an array of leg structs
    // function unwrapTokenId(TokenId tokenId) public view returns (Leg[] memory) {
    //     uint256 numLegs = tokenId.countLegs();
    //     Leg[] memory legs = new Leg[](numLegs);

    //     uint64 poolId = tokenId.poolId();
    //     address UniswapV3Pool = address(SFPM.getUniswapV3PoolFromId(tokenId.poolId()));
    //     for (uint256 i = 0; i < numLegs; ++i) {
    //         legs[i].poolId = poolId;
    //         legs[i].UniswapV3Pool = UniswapV3Pool;
    //         legs[i].asset = tokenId.asset(i);
    //         legs[i].optionRatio = tokenId.optionRatio(i);
    //         legs[i].tokenType = tokenId.tokenType(i);
    //         legs[i].isLong = tokenId.isLong(i);
    //         legs[i].riskPartner = tokenId.riskPartner(i);
    //         legs[i].strike = tokenId.strike(i);
    //         legs[i].width = tokenId.width(i);
    //     }
    //     return legs;
    // }

    /// @notice Returns an estimate of the downside liquidation price for a given account on a given pool.
    /// @dev returns MIN_TICK if the LP is more than 100000 ticks below the current tick.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param positionIdList list of position IDs to consider
    /// @return liquidationTick the downward liquidation price of `account` on `pool`, if any
    function findLiquidationPriceDown(
        address pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (int24 liquidationTick) {
        // initialize right and left bounds from current tick
        (, int24 currentTick, , , , , ) = PanopticPool(pool).oracleContract().slot0();
        int24 x0 = currentTick - 10000;
        int24 x1 = currentTick;
        int24 tol = 100000;
        // use the secant method to find the root of the function netEquity(tick)
        // stopping criterion are netEquity(tick+1) > 0 and netEquity(tick-1) < 0
        // and tick is below currentTick - tol
        // (we have limited ability to calculate collateral for very large tick gradients)
        // in that case, we return the min tick
        while (true) {
            // perform an iteration of the secant method
            (x0, x1) = (
                x1,
                int24(
                    x1 -
                        (int256(netEquity(pool, account, x1, positionIdList)) * (x1 - x0)) /
                        int256(
                            netEquity(pool, account, x1, positionIdList) -
                                netEquity(pool, account, x0, positionIdList)
                        )
                )
            );
            // if price is not within a 100000 tick range of current price, return MIN_TICK
            if (x1 > currentTick + tol || x1 < currentTick - tol) {
                return Constants.MIN_V4POOL_TICK;
            }
            // stop if price is within 0.01% (1 tick) of LP
            if (
                netEquity(pool, account, x1 + 1, positionIdList) >= 0 ==
                netEquity(pool, account, x1 - 1, positionIdList) <= 0
            ) {
                return x1;
            }
        }
    }

    /// @notice Returns an estimate of the upside liquidation price for a given account on a given pool.
    /// @dev returns MAX_TICK if the LP is more than 100000 ticks above current tick.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param positionIdList list of position IDs to consider
    /// @return liquidationTick the upward liquidation price of `account` on `pool`, if any
    function findLiquidationPriceUp(
        address pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (int24 liquidationTick) {
        // initialize right and left bounds from current tick
        (, int24 currentTick, , , , , ) = PanopticPool(pool).oracleContract().slot0();
        int24 x0 = currentTick;
        int24 x1 = currentTick + 10000;
        int24 tol = 100000;
        // use the secant method to find the root of the function netEquity(tick)
        // stopping criterion are netEquity(tick+1) > 0 and netEquity(tick-1) < 0
        // and tick is within the range of currentTick +- tol
        // (we have limited ability to calculate collateral for very large tick gradients)
        // in that case, we return the corresponding max/min tick
        while (true) {
            // perform an iteration of the secant method
            (x0, x1) = (
                x1,
                int24(
                    x1 -
                        (int256(netEquity(pool, account, x1, positionIdList)) * (x1 - x0)) /
                        int256(
                            netEquity(pool, account, x1, positionIdList) -
                                netEquity(pool, account, x0, positionIdList)
                        )
                )
            );
            // if price is not within a 100000 tick range of current price, stop + return MAX_TICK
            if (x1 > currentTick + tol || x1 < currentTick - tol) {
                return Constants.MAX_V4POOL_TICK;
            }
            // stop if price is within 0.01% (1 tick) of LP
            if (
                netEquity(pool, account, x1 + 1, positionIdList) >= 0 ==
                netEquity(pool, account, x1 - 1, positionIdList) <= 0
            ) {
                return x1;
            }
        }
    }

    /// @notice initializes a given leg in a tokenId as a call.
    /// @param tokenId tokenId to edit
    /// @param legIndex index of the leg to edit
    /// @param optionRatio relative size of the leg
    /// @param asset asset of the leg
    /// @param isLong whether the leg is long or short
    /// @param riskPartner defined risk partner of the leg
    /// @param strike strike of the leg
    /// @param width width of the leg
    /// @return tokenId with the leg initialized
    function addCallLeg(
        TokenId tokenId,
        uint256 legIndex,
        uint256 optionRatio,
        uint256 asset,
        uint256 isLong,
        uint256 riskPartner,
        int24 strike,
        int24 width
    ) internal pure returns (TokenId) {
        return
            TokenIdLibrary.addLeg(
                tokenId,
                legIndex,
                optionRatio,
                asset,
                isLong,
                0,
                riskPartner,
                strike,
                width
            );
    }

    /// @notice initializes a given leg in a tokenId as a put.
    /// @param tokenId tokenId to edit
    /// @param legIndex index of the leg to edit
    /// @param optionRatio relative size of the leg
    /// @param asset asset of the leg
    /// @param isLong whether the leg is long or short
    /// @param riskPartner defined risk partner of the leg
    /// @param strike strike of the leg
    /// @param width width of the leg
    /// @return tokenId with the leg initialized
    function addPutLeg(
        TokenId tokenId,
        uint256 legIndex,
        uint256 optionRatio,
        uint256 asset,
        uint256 isLong,
        uint256 riskPartner,
        int24 strike,
        int24 width
    ) internal pure returns (TokenId) {
        return
            TokenIdLibrary.addLeg(
                tokenId,
                legIndex,
                optionRatio,
                asset,
                isLong,
                1,
                riskPartner,
                strike,
                width
            );
    }

    /// @notice creates "Classic" strangle using a call and a put, with asymmetric upward risk.
    /// @dev example: createStrangle(uniPoolAddress, 4, 50, -50, 0, 1, 1, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the strangle
    /// @param callStrike strike of the call
    /// @param putStrike strike of the put
    /// @param asset asset of the strangle
    /// @param isLong is the strangle long or short
    /// @param optionRatio relative size of the strangle
    /// @param start leg index where the (2 legs) of the strangle begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createStrangle(
        PoolId idV4,
        int24 width,
        int24 callStrike,
        int24 putStrike,
        uint256 asset,
        uint256 isLong,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // A strangle is composed of
        // 1. a call with a higher strike price
        // 2. a put with a lower strike price

        // Call w/ higher strike
        tokenId = addCallLeg(
            tokenId,
            start,
            optionRatio,
            asset,
            isLong,
            start + 1,
            callStrike,
            width
        );

        // Put w/ lower strike
        tokenId = addPutLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            isLong,
            start,
            putStrike,
            width
        );
    }

    /// @notice creates "Classic" straddle using a call and a put, with asymmetric upward risk.
    /// @dev createStraddle(uniPoolAddress, 4, 0, 0, 1, 1, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the strangle
    /// @param strike strike of the call and put
    /// @param asset asset of the strangle
    /// @param isLong is the strangle long or short
    /// @param optionRatio relative size of the strangle
    /// @param start leg index where the (2 legs) of the straddle begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createStraddle(
        PoolId idV4,
        int24 width,
        int24 strike,
        uint256 asset,
        uint256 isLong,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // A straddle is composed of
        // 1. a call with an identical strike price
        // 2. a put with an identical strike price

        // call
        tokenId = addCallLeg(tokenId, start, optionRatio, asset, isLong, start + 1, strike, width);

        // put
        tokenId = addPutLeg(tokenId, start + 1, optionRatio, asset, isLong, start, strike, width);
    }

    /// @notice creates a call spread with 1 long leg and 1 short leg.
    /// @dev example: createCallSpread(uniPoolAddress, 4, -50, 50, 0, 1, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallSpread(
        PoolId idV4,
        int24 width,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // A call spread is composed of
        // 1. a long call with a lower strike price
        // 2. a short call with a higher strike price

        // Long call
        tokenId = addCallLeg(tokenId, start, optionRatio, asset, 1, start + 1, strikeLong, width);

        // Short call
        tokenId = addCallLeg(tokenId, start + 1, optionRatio, asset, 0, start, strikeShort, width);
    }

    /// @notice creates a put spread with 1 long leg and 1 short leg.
    /// @dev example: createPutSpread(uniPoolAddress, 4, -50, 50, 0, 1, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutSpread(
        PoolId idV4,
        int24 width,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // A put spread is composed of
        // 1. a long put with a higher strike price
        // 2. a short put with a lower strike price

        // Long put
        tokenId = addPutLeg(tokenId, start, optionRatio, asset, 1, start + 1, strikeLong, width);

        // Short put
        tokenId = addPutLeg(tokenId, start + 1, optionRatio, asset, 0, start, strikeShort, width);
    }

    /// @notice creates a diagonal spread with 1 long leg and 1 short leg.abi.
    /// @dev example: createCallDiagonalSpread(uniPoolAddress, 4, 8, -50, 50, 0, 1, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallDiagonalSpread(
        PoolId idV4,
        int24 widthLong,
        int24 widthShort,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // A call diagonal spread is composed of
        // 1. a long call with a (lower/higher) strike price and (lower/higher) width(expiry)
        // 2. a short call with a (higher/lower) strike price and (higher/lower) width(expiry)

        // Long call
        tokenId = addCallLeg(
            tokenId,
            start,
            optionRatio,
            asset,
            1,
            start + 1,
            strikeLong,
            widthLong
        );

        // Short call
        tokenId = addCallLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            0,
            start,
            strikeShort,
            widthShort
        );
    }

    /// @notice creates a diagonal spread with 1 long leg and 1 short leg.
    /// @dev example: createPutDiagonalSpread(uniPoolAddress, 4, 8, -50, 50, 0, 1, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutDiagonalSpread(
        PoolId idV4,
        int24 widthLong,
        int24 widthShort,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // A bearish diagonal spread is composed of
        // 1. a long put with a (higher/lower) strike price and (lower/higher) width(expiry)
        // 2. a short put with a (lower/higher) strike price and (higher/lower) width(expiry)

        // Long put
        tokenId = addPutLeg(
            tokenId,
            start,
            optionRatio,
            asset,
            1,
            start + 1,
            strikeLong,
            widthLong
        );

        // Short put
        tokenId = addPutLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            0,
            start,
            strikeShort,
            widthShort
        );
    }

    /// @notice creates a calendar spread with 1 long leg and 1 short leg.
    /// @dev example: createCallCalendarSpread(uniPoolAddress, 4, 8, 0, 0, 1, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strike strike of the long and short legs
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallCalendarSpread(
        PoolId idV4,
        int24 widthLong,
        int24 widthShort,
        int24 strike,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // calendar spread is a diagonal spread where the legs have identical strike prices
        // so we can create one using the diagonal spread function
        tokenId = createCallDiagonalSpread(
            idV4,
            widthLong,
            widthShort,
            strike,
            strike,
            asset,
            optionRatio,
            start
        );
    }

    /// @notice creates a calendar spread with 1 long leg and 1 short leg.
    /// @dev example: createPutCalendarSpread(uniPoolAddress, 4, 8, 0, 0, 1, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strike strike of the long and short legs
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutCalendarSpread(
        PoolId idV4,
        int24 widthLong,
        int24 widthShort,
        int24 strike,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // calendar spread is a diagonal spread where the legs have identical strike prices
        // so we can create one using the diagonal spread function
        tokenId = createPutDiagonalSpread(
            idV4,
            widthLong,
            widthShort,
            strike,
            strike,
            asset,
            optionRatio,
            start
        );
    }

    /// @notice creates iron condor w/ call and put spread.
    /// @dev example: createIronCondor(uniPoolAddress, 4, 50, -50, 50, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param callStrike strike of the call spread
    /// @param putStrike strike of the put spread
    /// @param wingWidth width of the wings
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createIronCondor(
        PoolId idV4,
        int24 width,
        int24 callStrike,
        int24 putStrike,
        int24 wingWidth,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // an iron condor is composed of
        // 1. a call spread
        // 2. a put spread
        // the "wings" represent how much more OTM the long sides of the spreads are

        // call spread
        tokenId = createCallSpread(idV4, width, callStrike + wingWidth, callStrike, asset, 1, 0);

        // put spread
        tokenId = TokenId.wrap(
            TokenId.unwrap(tokenId) +
                TokenId.unwrap(
                    createPutSpread(
                        PoolId.wrap(0),
                        width,
                        putStrike - wingWidth,
                        putStrike,
                        asset,
                        1,
                        2
                    )
                )
        );
    }

    /// @notice creates a jade lizard w/ long call and short asymmetric (traditional) strangle.
    /// @dev example: createJadeLizard(uniPoolAddress, 4, 100, 50, -50, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longCallStrike strike of the long call
    /// @param shortCallStrike strike of the short call
    /// @param shortPutStrike strike of the short put
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createJadeLizard(
        PoolId idV4,
        int24 width,
        int24 longCallStrike,
        int24 shortCallStrike,
        int24 shortPutStrike,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // a jade lizard is composed of
        // 1. a short strangle
        // 2. a long call

        // short strangle
        tokenId = createStrangle(idV4, width, shortCallStrike, shortPutStrike, asset, 0, 1, 1);

        // long call
        tokenId = addCallLeg(tokenId, 0, 1, asset, 1, 0, longCallStrike, width);
    }

    /// @notice creates a big lizard w/ long call and short asymmetric (traditional) straddle.
    /// @dev example: createBigLizard(uniPoolAddress, 4, 100, 50, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longCallStrike strike of the long call
    /// @param straddleStrike strike of the short straddle
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createBigLizard(
        PoolId idV4,
        int24 width,
        int24 longCallStrike,
        int24 straddleStrike,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // a big lizard is composed of
        // 1. a short straddle
        // 2. a long call

        // short straddle
        tokenId = createStraddle(idV4, width, straddleStrike, asset, 0, 1, 1);

        // long call
        tokenId = addCallLeg(tokenId, 0, 1, asset, 1, 0, longCallStrike, width);
    }

    /// @notice creates a super bull w/ long call spread and short put.
    /// @dev example: createSuperBull(uniPoolAddress, 4, -50, 50, 50, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longCallStrike strike of the long call
    /// @param shortCallStrike strike of the short call
    /// @param shortPutStrike strike of the short put
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createSuperBull(
        PoolId idV4,
        int24 width,
        int24 longCallStrike,
        int24 shortCallStrike,
        int24 shortPutStrike,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // a super bull is composed of
        // 1. a long call spread
        // 2. a short put

        // long call spread
        tokenId = createCallSpread(idV4, width, longCallStrike, shortCallStrike, asset, 1, 1);

        // short put
        tokenId = addPutLeg(tokenId, 0, 1, asset, 0, 0, shortPutStrike, width);
    }

    /// @notice creates a super bear w/ long put spread and short call.
    /// @dev example: createSuperBear(uniPoolAddress, 4, 50, -50, -50, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longPutStrike strike of the long put
    /// @param shortPutStrike strike of the short put
    /// @param shortCallStrike strike of the short call
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createSuperBear(
        PoolId idV4,
        int24 width,
        int24 longPutStrike,
        int24 shortPutStrike,
        int24 shortCallStrike,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // a super bear is composed of
        // 1. a long put spread
        // 2. a short call

        // long put spread
        tokenId = createPutSpread(idV4, width, longPutStrike, shortPutStrike, asset, 1, 1);

        // short call
        tokenId = addCallLeg(tokenId, 0, 1, asset, 0, 0, shortCallStrike, width);
    }

    /// @notice creates a butterfly w/ long call spread and short put spread.
    /// @dev example: createIronButterfly(uniPoolAddress, 4, 0, 50, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param strike strike of the long and short legs
    /// @param wingWidth width of the wings
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createIronButterfly(
        PoolId idV4,
        int24 width,
        int24 strike,
        int24 wingWidth,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // an iron butterfly is composed of
        // 1. a long call spread
        // 2. a short put spread

        // long call spread
        tokenId = createCallSpread(idV4, width, strike, strike + wingWidth, asset, 1, 0);

        // short put spread
        tokenId = TokenId.wrap(
            TokenId.unwrap(tokenId) +
                TokenId.unwrap(
                    createPutSpread(PoolId.wrap(0), width, strike, strike - wingWidth, asset, 1, 2)
                )
        );
    }

    /// @notice creates a ratio spread w/ long call and multiple short calls.
    /// @dev example: createCallRatioSpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longStrike strike of the long call
    /// @param shortStrike strike of the short calls
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short calls to the long call
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured

    function createCallRatioSpread(
        PoolId idV4,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // a call ratio spread is composed of
        // 1. a long call
        // 2. multiple short calls

        // long call
        tokenId = addCallLeg(tokenId, start, 1, asset, 1, start + 1, longStrike, width);

        // short calls
        tokenId = addCallLeg(tokenId, start + 1, ratio, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ratio spread w/ long put and multiple short puts.
    /// @dev example: createPutRatioSpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longStrike strike of the long put
    /// @param shortStrike strike of the short puts
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short puts to the long put
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutRatioSpread(
        PoolId idV4,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // a put ratio spread is composed of
        // 1. a long put
        // 2. multiple short puts

        // long put
        tokenId = addPutLeg(tokenId, start, 1, asset, 1, start + 1, longStrike, width);

        // short puts
        tokenId = addPutLeg(tokenId, start + 1, ratio, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ZEBRA spread w/ short call and multiple long calls.
    /// @dev example: createCallZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longStrike strike of the long calls
    /// @param shortStrike strike of the short call
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short call to the long calls
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallZEBRASpread(
        PoolId idV4,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // a call ZEBRA(zero extrinsic value back ratio spread) spread is composed of
        // 1. a short call
        // 2. multiple long calls

        // long put
        tokenId = addCallLeg(tokenId, start, ratio, asset, 1, start + 1, longStrike, width);

        // short puts
        tokenId = addCallLeg(tokenId, start + 1, 1, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ZEBRA spread w/ short put and multiple long puts.
    /// @dev example: createPutZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longStrike strike of the long puts
    /// @param shortStrike strike of the short put
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short put to the long puts
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutZEBRASpread(
        PoolId idV4,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(idV4));

        // a put ZEBRA(zero extrinsic value back ratio spread) spread is composed of
        // 1. a short put
        // 2. multiple long puts

        // long puts
        tokenId = addPutLeg(tokenId, start, ratio, asset, 1, start + 1, longStrike, width);

        // short put
        tokenId = addPutLeg(tokenId, start + 1, 1, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ZEEHBS w/ call and put ZEBRA spreads.
    /// @dev example: createPutZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longStrike strike of the long legs
    /// @param shortStrike strike of the short legs
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short legs to the long legs
    /// @return tokenId the position id with the strategy configured
    function createZEEHBS(
        PoolId idV4,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio
    ) public view returns (TokenId tokenId) {
        // a ZEEHBS(Zero extrinsic hedged back spread) is composed of
        // 1. a call ZEBRA spread
        // 2. a put ZEBRA spread

        // call ZEBRA
        tokenId = createCallZEBRASpread(idV4, width, longStrike, shortStrike, asset, ratio, 0);

        // put ZEBRA
        tokenId = TokenId.wrap(
            TokenId.unwrap(tokenId) +
                TokenId.unwrap(
                    createPutZEBRASpread(
                        PoolId.wrap(0),
                        width,
                        longStrike,
                        shortStrike,
                        asset,
                        ratio,
                        2
                    )
                )
        );
    }

    /// @notice creates a BATS (AKA double ratio spread) w/ call and put ratio spreads.
    /// @dev example: createBATS(uniPoolAddress, 4, -50, 50, 0, 2).
    /// @param idV4 Uniswap V4 pool identifier
    /// @param width width of the spread
    /// @param longStrike strike of the long legs
    /// @param shortStrike strike of the short legs
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short legs to the long legs
    /// @return tokenId the position id with the strategy configured
    function createBATS(
        PoolId idV4,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio
    ) public view returns (TokenId tokenId) {
        // a BATS(double ratio spread) is composed of
        // 1. a call ratio spread
        // 2. a put ratio spread

        // call ratio spread
        tokenId = createCallRatioSpread(idV4, width, longStrike, shortStrike, asset, ratio, 0);

        // put ratio spread
        tokenId = TokenId.wrap(
            TokenId.unwrap(tokenId) +
                TokenId.unwrap(
                    createPutRatioSpread(
                        PoolId.wrap(0),
                        width,
                        longStrike,
                        shortStrike,
                        asset,
                        ratio,
                        2
                    )
                )
        );
    }
}
