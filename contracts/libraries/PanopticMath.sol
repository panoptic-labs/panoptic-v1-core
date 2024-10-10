// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
// OpenZeppelin libraries
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
// Custom types
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title Compute general math quantities relevant to Panoptic and AMM pool management.
/// @notice Contains Panoptic-specific helpers and math functions.
/// @author Axicon Labs Limited
library PanopticMath {
    using Math for uint256;

    /// @notice This is equivalent to `type(uint256).max` — used in assembly blocks as a replacement.
    uint256 internal constant MAX_UINT256 = 2 ** 256 - 1;

    /// @notice Masks 16-bit tickSpacing out of 64-bit `[16-bit tickspacing][48-bit poolPattern]` format poolId
    uint64 internal constant TICKSPACING_MASK = 0xFFFF000000000000;

    /*//////////////////////////////////////////////////////////////
                              MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Given a 256-bit Uniswap V4 pool ID (hash) and the corresponding `tickSpacing`, return its 64-bit ID as used in the `TokenId` of Panoptic.
    // Example:
    //      [16-bit tickSpacing][last 48 bits of Uniswap V4 pool ID] = poolId
    //      e.g.:
    //        idV4        = 0x9c33e1937fe23c3ff82d7725f2bb5af696db1c89a9b8cae141cb0e986847638a
    //        tickSpacing = 60
    //      the returned id is then:
    //        poolPattern = 0x0000e986847638a
    //        tickSpacing = 0x003c000000000000    +
    //        --------------------------------------------
    //        poolId      = 0x003ce986847638a
    /// @param idV4 The 256-bit Uniswap V4 pool ID
    /// @param tickSpacing The tick spacing of the Uniswap V4 pool identified by `idV4`
    /// @return A fingerprint representing the Uniswap V4 pool
    function getPoolId(PoolId idV4, int24 tickSpacing) internal pure returns (uint64) {
        unchecked {
            return uint48(uint256(PoolId.unwrap(idV4))) + (uint64(uint24(tickSpacing)) << 48);
        }
    }

    /// @notice Increments the pool pattern (first 48 bits) of a poolId by 1.
    /// @param poolId The 64-bit pool ID
    /// @return The provided `poolId` with its pool pattern slot incremented by 1
    function incrementPoolPattern(uint64 poolId) internal pure returns (uint64) {
        unchecked {
            return (poolId & TICKSPACING_MASK) + (uint48(poolId) + 1);
        }
    }

    /// @notice Get the number of leading hex characters in an address.
    //     0x0000bababaab...     0xababababab...
    //          ▲                 ▲
    //          │                 │
    //     4 leading hex      0 leading hex
    //    character zeros    character zeros
    //
    /// @param addr The address to get the number of leading zero hex characters for
    /// @return The number of leading zero hex characters in the address
    function numberOfLeadingHexZeros(address addr) external pure returns (uint256) {
        unchecked {
            return addr == address(0) ? 40 : 39 - Math.mostSignificantNibble(uint160(addr));
        }
    }

    /// @notice Returns ERC20 symbol of `token`.
    /// @param token The address of the token to get the symbol of
    /// @return The symbol of `token` or "???" if not supported
    function safeERC20Symbol(address token) external view returns (string memory) {
        // not guaranteed that token supports metadata extension
        // so we need to let call fail and return placeholder if not
        try IERC20Metadata(token).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return "???";
        }
    }

    /// @notice Converts `fee` to a string with "bps" appended, or DYNAMIC if "fee" is equivalent to `0x800000`.
    /// @dev The lowest supported value of `fee` is 1 (`="0.01bps"`).
    /// @param fee The fee to convert to a string (in hundredths of basis points)
    /// @return Stringified version of `fee` with "bps" appended
    function uniswapFeeToString(uint24 fee) internal pure returns (string memory) {
        return
            fee == 0x800000
                ? "DYNAMIC"
                : string.concat(
                    Strings.toString(fee / 100),
                    fee % 100 == 0
                        ? ""
                        : string.concat(
                            ".",
                            Strings.toString((fee / 10) % 10),
                            Strings.toString(fee % 10)
                        ),
                    "bps"
                );
    }

    /*//////////////////////////////////////////////////////////////
                              UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Update an existing account's "positions hash" with a new `tokenId`.
    /// @notice The positions hash contains a fingerprint of all open positions created by an account/user and a count of those positions.
    /// @dev The "fingerprint" portion of the hash is given by XORing the hashed `tokenId` of each position the user has open together.
    /// @param existingHash The existing position hash containing all historical N positions created and the count of the positions
    /// @param tokenId The new position to add to the existing hash: `existingHash = uint248(existingHash) ^ hashOf(tokenId)`
    /// @param addFlag Whether to mint (add) the tokenId to the count of positions or burn (subtract) it from the count `(existingHash >> 248) +/- 1`
    /// @return newHash The new positionHash with the updated hash
    function updatePositionsHash(
        uint256 existingHash,
        TokenId tokenId,
        bool addFlag
    ) internal pure returns (uint256) {
        // update hash by taking the XOR of the new tokenId
        uint256 updatedHash = uint248(existingHash) ^
            (uint248(uint256(keccak256(abi.encode(tokenId)))));

        // increment the upper 8 bits (position counter) if addflag=true, decrement otherwise
        uint256 newPositionCount = addFlag
            ? uint8(existingHash >> 248) + 1
            : uint8(existingHash >> 248) - 1;

        unchecked {
            return uint256(updatedHash) + (newPositionCount << 248);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ORACLE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes various oracle prices corresponding to a Uniswap pool.
    /// @param oracleContract The external oracle contract to retrieve observations from
    /// @param miniMedian The packed structure representing the sorted 8-slot queue of internal median observations
    /// @return fastOracleTick The fast oracle tick computed as the median of the past N observations in the Uniswap Pool
    /// @return slowOracleTick The slow oracle tick as tracked by `s_miniMedian`
    /// @return latestObservation The latest observation from the Uniswap pool (price at the end of the last block)
    /// @return medianData The updated value for `s_miniMedian` (returns 0 if not enough time has passed since last observation)
    function getOracleTicks(
        IV3CompatibleOracle oracleContract,
        uint256 miniMedian
    )
        external
        view
        returns (
            int24 fastOracleTick,
            int24 slowOracleTick,
            int24 latestObservation,
            uint256 medianData
        )
    {
        uint16 observationIndex;
        uint16 observationCardinality;

        (, , observationIndex, observationCardinality, , , ) = oracleContract.slot0();

        (fastOracleTick, latestObservation) = computeMedianObservedPrice(
            oracleContract,
            observationIndex,
            observationCardinality,
            Constants.FAST_ORACLE_CARDINALITY,
            Constants.FAST_ORACLE_PERIOD
        );

        if (Constants.SLOW_ORACLE_UNISWAP_MODE) {
            (slowOracleTick, ) = computeMedianObservedPrice(
                oracleContract,
                observationIndex,
                observationCardinality,
                Constants.SLOW_ORACLE_CARDINALITY,
                Constants.SLOW_ORACLE_PERIOD
            );
        } else {
            (slowOracleTick, medianData) = computeInternalMedian(
                observationIndex,
                observationCardinality,
                Constants.MEDIAN_PERIOD,
                miniMedian,
                oracleContract
            );
        }
    }

    /// @notice Returns the median of the last `cardinality` average prices over `period` observations from `oracleContract`.
    /// @dev Used when we need a manipulation-resistant TWAP price.
    /// @dev oracle observations snapshot the closing price of the last block before the first interaction of a given block.
    /// @dev The maximum frequency of observations is 1 per block, but there is no guarantee that the pool will be observed at every block.
    /// @dev Each period has a minimum length of blocktime * period, but may be longer if the Uniswap pool is relatively inactive.
    /// @dev The final price used in the array (of length `cardinality`) is the average of all observations comprising `period` (which is itself a number of observations).
    /// @dev Thus, the minimum total time window is `cardinality` * `period` * `blocktime`.
    /// @param oracleContract The external oracle contract to retrieve observations from
    /// @param observationIndex The index of the last observation in the pool
    /// @param observationCardinality The number of observations in the pool
    /// @param cardinality The number of `periods` to in the median price array, should be odd
    /// @param period The number of observations to average to compute one entry in the median price array
    /// @return The median of `cardinality` observations spaced by `period` in the Uniswap pool
    /// @return The latest observation in the Uniswap pool
    function computeMedianObservedPrice(
        IV3CompatibleOracle oracleContract,
        uint256 observationIndex,
        uint256 observationCardinality,
        uint256 cardinality,
        uint256 period
    ) internal view returns (int24, int24) {
        unchecked {
            int256[] memory tickCumulatives = new int256[](cardinality + 1);

            uint256[] memory timestamps = new uint256[](cardinality + 1);
            // get the last "cardinality" timestamps/tickCumulatives (if observationIndex < cardinality, the index will wrap back from observationCardinality)
            for (uint256 i = 0; i < cardinality + 1; ++i) {
                (timestamps[i], tickCumulatives[i], , ) = oracleContract.observations(
                    uint256(
                        (int256(observationIndex) - int256(i * period)) +
                            int256(observationCardinality)
                    ) % observationCardinality
                );
            }

            int256[] memory ticks = new int256[](cardinality);
            // use cardinality periods given by cardinality + 1 accumulator observations to compute the last cardinality observed ticks spaced by period
            for (uint256 i = 0; i < cardinality; ++i) {
                ticks[i] =
                    (tickCumulatives[i] - tickCumulatives[i + 1]) /
                    int256(timestamps[i] - timestamps[i + 1]);
            }

            // get the median of the `ticks` array (assuming `cardinality` is odd)
            return (int24(Math.sort(ticks)[cardinality / 2]), int24(ticks[0]));
        }
    }

    /// @notice Takes a packed structure representing a sorted 8-slot queue of ticks and returns the median of those values and an updated queue if another observation is warranted.
    /// @dev Also inserts the latest oracle observation into the buffer, resorts, and returns if the last entry is at least `period` seconds old.
    /// @param observationIndex The index of the last observation in the Uniswap pool
    /// @param observationCardinality The number of observations in the Uniswap pool
    /// @param period The minimum time in seconds that must have passed since the last observation was inserted into the buffer
    /// @param medianData The packed structure representing the sorted 8-slot queue of ticks
    /// @param oracleContract The external oracle contract to retrieve observations from
    /// @return medianTick The median of the provided 8-slot queue of ticks in `medianData`
    /// @return updatedMedianData The updated 8-slot queue of ticks with the latest observation inserted if the last entry is at least `period` seconds old (returns 0 otherwise)
    function computeInternalMedian(
        uint256 observationIndex,
        uint256 observationCardinality,
        uint256 period,
        uint256 medianData,
        IV3CompatibleOracle oracleContract
    ) public view returns (int24 medianTick, uint256 updatedMedianData) {
        unchecked {
            // return the average of the rank 3 and 4 values
            medianTick =
                (int24(uint24(medianData >> ((uint24(medianData >> (192 + 3 * 3)) % 8) * 24))) +
                    int24(uint24(medianData >> ((uint24(medianData >> (192 + 3 * 4)) % 8) * 24)))) /
                2;

            // only proceed if last entry is at least MEDIAN_PERIOD seconds old
            if (block.timestamp >= uint256(uint40(medianData >> 216)) + period) {
                int24 lastObservedTick;
                {
                    (uint256 timestamp_old, int56 tickCumulative_old, , ) = oracleContract
                        .observations(
                            uint256(
                                int256(observationIndex) -
                                    int256(1) +
                                    int256(observationCardinality)
                            ) % observationCardinality
                        );

                    (uint256 timestamp_last, int56 tickCumulative_last, , ) = oracleContract
                        .observations(observationIndex);
                    lastObservedTick = int24(
                        (tickCumulative_last - tickCumulative_old) /
                            int256(timestamp_last - timestamp_old)
                    );
                }

                uint24 orderMap = uint24(medianData >> 192);

                uint24 newOrderMap;
                uint24 shift = 1;
                bool below = true;
                uint24 rank;
                int24 entry;
                for (uint8 i; i < 8; ++i) {
                    // read the rank from the existing ordering
                    rank = (orderMap >> (3 * i)) % 8;

                    if (rank == 7) {
                        shift -= 1;
                        continue;
                    }

                    // read the corresponding entry
                    entry = int24(uint24(medianData >> (rank * 24)));
                    if ((below) && (lastObservedTick > entry)) {
                        shift += 1;
                        below = false;
                    }

                    newOrderMap = newOrderMap + ((rank + 1) << (3 * (i + shift - 1)));
                }

                updatedMedianData =
                    (block.timestamp << 216) +
                    (uint256(newOrderMap) << 192) +
                    uint256(uint192(medianData << 24)) +
                    uint256(uint24(lastObservedTick));
            }
        }
    }

    /// @notice Computes a TWAP price over `twapWindow` on a Uniswap V3-style observation oracle.
    /// @dev Note that our definition of TWAP differs from a typical mean of prices over a time window.
    /// @dev We instead observe the average price over a series of time intervals, and define the TWAP as the median of those averages.
    /// @param oracleContract The external oracle contract to retrieve observations from
    /// @param twapWindow The time window to compute the TWAP over
    /// @return The final calculated TWAP tick
    function twapFilter(
        IV3CompatibleOracle oracleContract,
        uint32 twapWindow
    ) external view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](20);

        int256[] memory twapMeasurement = new int256[](19);

        unchecked {
            // construct the time slots
            for (uint256 i = 0; i < 20; ++i) {
                secondsAgos[i] = uint32(((i + 1) * twapWindow) / 20);
            }

            // observe the tickCumulative at the 20 pre-defined time slots
            (int56[] memory tickCumulatives, ) = oracleContract.observe(secondsAgos);

            // compute the average tick per 30s window
            for (uint256 i = 0; i < 19; ++i) {
                twapMeasurement[i] = int24(
                    (tickCumulatives[i] - tickCumulatives[i + 1]) / int56(uint56(twapWindow / 20))
                );
            }

            // sort the tick measurements
            int256[] memory sortedTicks = Math.sort(twapMeasurement);

            // Get the median value
            return int24(sortedTicks[9]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDITY CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice For a given option position (`tokenId`), leg index within that position (`legIndex`), and `positionSize` get the tick range spanned and its
    /// liquidity (share ownership) in the Uniswap V4 pool; this is a liquidity chunk.
    //          Liquidity chunk  (defined by tick upper, tick lower, and its size/amount: the liquidity)
    //   liquidity    │
    //         ▲      │
    //         │     ┌▼┐
    //         │  ┌──┴─┴──┐
    //         │  │       │
    //         │  │       │
    //         └──┴───────┴────► price
    //         Uniswap V4 Pool
    /// @param tokenId The option position id
    /// @param legIndex The leg index of the option position, can be {0,1,2,3}
    /// @param positionSize The number of contracts held by this leg
    /// @return A LiquidityChunk with `tickLower`, `tickUpper`, and `liquidity`
    function getLiquidityChunk(
        TokenId tokenId,
        uint256 legIndex,
        uint128 positionSize
    ) internal pure returns (LiquidityChunk) {
        // get the tick range for this leg
        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(legIndex);

        // Get the amount of liquidity owned by this leg in the Uniswap V4 pool in the above tick range
        // Background:
        //
        //  In Uniswap V4, the amount of liquidity received for a given amount of token0 when the price is
        //  not in range is given by:
        //     Liquidity = amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))
        //  For token1, it is given by:
        //     Liquidity = amount1 / (sqrt(upper) - sqrt(lower))
        //
        //  However, in Panoptic, each position has a asset parameter. The asset is the "basis" of the position.
        //  In TradFi, the asset is always cash and selling a $1000 put requires the user to lock $1000, and selling
        //  a call requires the user to lock 1 unit of asset.
        //
        //  Because Uniswap V4 chooses token0 and token1 from the alphanumeric order, there is no consistency as to whether token0 is
        //  stablecoin, ETH, or an ERC20. Some pools may want ETH to be the asset (e.g. ETH-DAI) and some may wish the stablecoin to
        //  be the asset (e.g. DAI-ETH) so that K asset is moved for puts and 1 asset is moved for calls.
        //  But since the convention is to force the order always we have no say in this.
        //
        //  To solve this, we encode the asset value in tokenId. This parameter specifies which of token0 or token1 is the
        //  asset, such that:
        //     when asset=0, then amount0 moved at strike K =1.0001**currentTick is 1, amount1 moved to strike K is 1/K
        //     when asset=1, then amount1 moved at strike K =1.0001**currentTick is K, amount0 moved to strike K is 1
        //
        //  The following function takes this into account when computing the liquidity of the leg and switches between
        //  the definition for getLiquidityForAmount0 or getLiquidityForAmount1 when relevant.
        //
        //
        uint256 amount = uint256(positionSize) * tokenId.optionRatio(legIndex);
        if (tokenId.asset(legIndex) == 0) {
            return Math.getLiquidityForAmount0(tickLower, tickUpper, amount);
        } else {
            return Math.getLiquidityForAmount1(tickLower, tickUpper, amount);
        }
    }

    /// @notice Extract the tick range specified by `strike` and `width` for the given `tickSpacing`, if valid.
    /// @param strike The strike price of the option
    /// @param width The width of the option
    /// @param tickSpacing The tick spacing of the underlying Uniswap V4 pool
    /// @return tickLower The lower tick of the liquidity chunk
    /// @return tickUpper The upper tick of the liquidity chunk
    function getTicks(
        int24 strike,
        int24 width,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(width, tickSpacing);

        (tickLower, tickUpper) = (strike - rangeDown, strike + rangeUp);

        // Revert if the upper/lower ticks are not multiples of tickSpacing
        // Revert if the tick range extends from the strike outside of the valid tick range
        // These are invalid states, and would revert later on in the Uniswap pool
        if (
            tickLower % tickSpacing != 0 ||
            tickUpper % tickSpacing != 0 ||
            tickLower < Constants.MIN_V4POOL_TICK ||
            tickUpper > Constants.MAX_V4POOL_TICK
        ) revert Errors.TicksNotInitializable();
    }

    /// @notice Returns the distances of the upper and lower ticks from the strike for a position with the given width and tickSpacing.
    /// @dev Given `r = (width * tickSpacing) / 2`, `tickLower = strike - floor(r)` and `tickUpper = strike + ceil(r)`.
    /// @param width The width of the leg
    /// @param tickSpacing The tick spacing of the underlying pool
    /// @return The lower tick of the range
    /// @return The upper tick of the range
    function getRangesFromStrike(
        int24 width,
        int24 tickSpacing
    ) internal pure returns (int24, int24) {
        return (
            (width * tickSpacing) / 2,
            int24(int256(Math.unsafeDivRoundingUp(uint24(width) * uint24(tickSpacing), 2)))
        );
    }

    /*//////////////////////////////////////////////////////////////
                         TOKEN CONVERSION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute the amount of notional value underlying this option position.
    /// @param tokenId The option position id
    /// @param positionSize The number of contracts of this option
    /// @return longAmounts Left-right packed word where rightSlot = token0 and leftSlot = token1 held against borrowed Uniswap liquidity for long legs
    /// @return shortAmounts Left-right packed word where where rightSlot = token0 and leftSlot = token1 borrowed to create short legs
    function computeExercisedAmounts(
        TokenId tokenId,
        uint128 positionSize
    ) internal pure returns (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) {
        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            // Compute the amount of funds that have been removed from the Panoptic Pool
            (LeftRightSigned longs, LeftRightSigned shorts) = _calculateIOAmounts(
                tokenId,
                positionSize,
                leg
            );

            longAmounts = longAmounts.add(longs);
            shortAmounts = shortAmounts.add(shorts);

            unchecked {
                ++leg;
            }
        }
    }

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks
    /// @param amount The amount of token0 to convert into token1
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token0 into token1
    /// @return The converted `amount` of token0 represented in terms of token1
    function convert0to1(uint256 amount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                return Math.mulDiv192(amount, uint256(sqrtPriceX96) ** 2);
            } else {
                return Math.mulDiv128(amount, Math.mulDiv64(sqrtPriceX96, sqrtPriceX96));
            }
        }
    }

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks
    /// @param amount The amount of token0 to convert into token1
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token0 into token1
    /// @return The converted `amount` of token0 represented in terms of token1
    function convert0to1RoundingUp(
        uint256 amount,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                return Math.mulDiv192RoundingUp(amount, uint256(sqrtPriceX96) ** 2);
            } else {
                return Math.mulDiv128RoundingUp(amount, Math.mulDiv64(sqrtPriceX96, sqrtPriceX96));
            }
        }
    }

    /// @notice Convert an amount of token1 into an amount of token0 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token1 to convert into token0
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token1 into token0
    /// @return The converted `amount` of token1 represented in terms of token0
    function convert1to0(uint256 amount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                return Math.mulDiv(amount, 2 ** 192, uint256(sqrtPriceX96) ** 2);
            } else {
                return Math.mulDiv(amount, 2 ** 128, Math.mulDiv64(sqrtPriceX96, sqrtPriceX96));
            }
        }
    }

    /// @notice Convert an amount of token1 into an amount of token0 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token1 to convert into token0
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token1 into token0
    /// @return The converted `amount` of token1 represented in terms of token0
    function convert1to0RoundingUp(
        uint256 amount,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                return Math.mulDivRoundingUp(amount, 2 ** 192, uint256(sqrtPriceX96) ** 2);
            } else {
                return
                    Math.mulDivRoundingUp(
                        amount,
                        2 ** 128,
                        Math.mulDiv64(sqrtPriceX96, sqrtPriceX96)
                    );
            }
        }
    }

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token0 to convert into token1
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token0 into token1
    /// @return The converted `amount` of token0 represented in terms of token1
    function convert0to1(int256 amount, uint160 sqrtPriceX96) internal pure returns (int256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                int256 absResult = Math
                    .mulDiv192(Math.absUint(amount), uint256(sqrtPriceX96) ** 2)
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            } else {
                int256 absResult = Math
                    .mulDiv128(Math.absUint(amount), Math.mulDiv64(sqrtPriceX96, sqrtPriceX96))
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            }
        }
    }

    /// @notice Convert an amount of token1 into an amount of token0 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token1 to convert into token0
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token1 into token0
    /// @return The converted `amount` of token1 represented in terms of token0
    function convert1to0(int256 amount, uint160 sqrtPriceX96) internal pure returns (int256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                int256 absResult = Math
                    .mulDiv(Math.absUint(amount), 2 ** 192, uint256(sqrtPriceX96) ** 2)
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            } else {
                int256 absResult = Math
                    .mulDiv(
                        Math.absUint(amount),
                        2 ** 128,
                        Math.mulDiv64(sqrtPriceX96, sqrtPriceX96)
                    )
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            }
        }
    }

    /// @notice Get a single collateral balance and requirement in terms of the lowest-priced token for a given set of (token0/token1) collateral balances and requirements.
    /// @param tokenData0 LeftRight encoded word with balance of token0 in the right slot, and required balance in left slot
    /// @param tokenData1 LeftRight encoded word with balance of token1 in the right slot, and required balance in left slot
    /// @param sqrtPriceX96 The price at which to compute the collateral value and requirements
    /// @return The combined collateral balance of `tokenData0` and `tokenData1` in terms of (token0 if `price(token1/token0) < 1` and vice versa)
    /// @return The combined required collateral threshold of `tokenData0` and `tokenData1` in terms of (token0 if `price(token1/token0) < 1` and vice versa)
    function getCrossBalances(
        LeftRightUnsigned tokenData0,
        LeftRightUnsigned tokenData1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256, uint256) {
        // convert values to the highest precision (lowest price) of the two tokens (token0 if price token1/token0 < 1 and vice versa)
        if (sqrtPriceX96 < Constants.FP96) {
            return (
                tokenData0.rightSlot() +
                    PanopticMath.convert1to0(tokenData1.rightSlot(), sqrtPriceX96),
                tokenData0.leftSlot() +
                    PanopticMath.convert1to0RoundingUp(tokenData1.leftSlot(), sqrtPriceX96)
            );
        }

        return (
            PanopticMath.convert0to1(tokenData0.rightSlot(), sqrtPriceX96) + tokenData1.rightSlot(),
            PanopticMath.convert0to1RoundingUp(tokenData0.leftSlot(), sqrtPriceX96) +
                tokenData1.leftSlot()
        );
    }

    /// @notice Compute the notional value (for `tokenType = 0` and `tokenType = 1`) represented by a given leg in an option position.
    /// @param tokenId The option position identifier
    /// @param positionSize The number of option contracts held in this position (each contract can control multiple tokens)
    /// @param legIndex The leg index of the option contract, can be {0,1,2,3}
    /// @return A LeftRight encoded variable containing the amount0 and the amount1 value controlled by this option position's leg
    function getAmountsMoved(
        TokenId tokenId,
        uint128 positionSize,
        uint256 legIndex
    ) internal pure returns (LeftRightUnsigned) {
        uint128 amount0;
        uint128 amount1;

        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(legIndex);

        // effective strike price of the option (avg. price over LP range)
        // geometric mean of two numbers = √(x1 * x2) = √x1 * √x2
        uint256 geometricMeanPriceX96 = Math.mulDiv96(
            Math.getSqrtRatioAtTick(tickLower),
            Math.getSqrtRatioAtTick(tickUpper)
        );

        if (tokenId.asset(legIndex) == 0) {
            amount0 = positionSize * uint128(tokenId.optionRatio(legIndex));

            amount1 = Math.mulDiv96RoundingUp(amount0, geometricMeanPriceX96).toUint128();
        } else {
            amount1 = positionSize * uint128(tokenId.optionRatio(legIndex));

            amount0 = Math.mulDivRoundingUp(amount1, 2 ** 96, geometricMeanPriceX96).toUint128();
        }

        return LeftRightUnsigned.wrap(amount0).toLeftSlot(amount1);
    }

    /// @notice Compute the amount of funds that are moved to or removed from the Panoptic Pool when `tokenId` is created.
    /// @param tokenId The option position identifier
    /// @param positionSize The number of positions minted
    /// @param legIndex The leg index minted in this position, can be {0,1,2,3}
    /// @return longs A LeftRight-packed word containing the total amount of long positions
    /// @return shorts A LeftRight-packed word containing the amount of short positions
    function _calculateIOAmounts(
        TokenId tokenId,
        uint128 positionSize,
        uint256 legIndex
    ) internal pure returns (LeftRightSigned longs, LeftRightSigned shorts) {
        // compute amounts moved
        LeftRightUnsigned amountsMoved = getAmountsMoved(tokenId, positionSize, legIndex);

        bool isShort = tokenId.isLong(legIndex) == 0;

        // if token0
        if (tokenId.tokenType(legIndex) == 0) {
            if (isShort) {
                // if option is short, increment shorts by contracts
                shorts = shorts.toRightSlot(Math.toInt128(amountsMoved.rightSlot()));
            } else {
                // is option is long, increment longs by contracts
                longs = longs.toRightSlot(Math.toInt128(amountsMoved.rightSlot()));
            }
        } else {
            if (isShort) {
                // if option is short, increment shorts by notional
                shorts = shorts.toLeftSlot(Math.toInt128(amountsMoved.leftSlot()));
            } else {
                // if option is long, increment longs by notional
                longs = longs.toLeftSlot(Math.toInt128(amountsMoved.leftSlot()));
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                LIQUIDATION/FORCE EXERCISE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute the pre-haircut liquidation bonuses to be paid to the liquidator and the protocol loss caused by the liquidation (pre-haircut).
    /// @param tokenData0 LeftRight encoded word with balance of token0 in the right slot, and required balance in left slot
    /// @param tokenData1 LeftRight encoded word with balance of token1 in the right slot, and required balance in left slot
    /// @param atSqrtPriceX96 The oracle price used to swap tokens between the liquidator/liquidatee and determine solvency for the liquidatee
    /// @param netPaid The net amount of tokens paid/received by the liquidatee to close their portfolio of positions
    /// @param shortPremium Total owed premium (prorated by available settled tokens) across all short legs being liquidated
    /// @return The LeftRight-packed bonus amounts to be paid to the liquidator for both tokens (may be negative)
    /// @return The LeftRight-packed protocol loss (pre-haircut) for both tokens, i.e., the delta between the user's starting balance and expended tokens
    function getLiquidationBonus(
        LeftRightUnsigned tokenData0,
        LeftRightUnsigned tokenData1,
        uint160 atSqrtPriceX96,
        LeftRightSigned netPaid,
        LeftRightUnsigned shortPremium
    ) external pure returns (LeftRightSigned, LeftRightSigned) {
        int256 bonus0;
        int256 bonus1;
        unchecked {
            // compute bonus as min(collateralBalance/2, required-collateralBalance)
            {
                // compute the ratio of token0 to total collateral requirements
                // evaluate at TWAP price to maintain consistency with solvency calculations
                (uint256 balanceCross, uint256 thresholdCross) = PanopticMath.getCrossBalances(
                    tokenData0,
                    tokenData1,
                    atSqrtPriceX96
                );

                uint256 bonusCross = Math.min(balanceCross / 2, thresholdCross - balanceCross);

                // `bonusCross` and `thresholdCross` are returned in terms of the lowest-priced token
                if (atSqrtPriceX96 < Constants.FP96) {
                    // required0 / (required0 + token0(required1))
                    uint256 requiredRatioX128 = Math.mulDiv(
                        tokenData0.leftSlot(),
                        2 ** 128,
                        thresholdCross
                    );

                    bonus0 = int256(Math.mulDiv128(bonusCross, requiredRatioX128));

                    bonus1 = int256(
                        PanopticMath.convert0to1(
                            Math.mulDiv128(bonusCross, 2 ** 128 - requiredRatioX128),
                            atSqrtPriceX96
                        )
                    );
                } else {
                    // required1 / (token1(required0) + required1)
                    uint256 requiredRatioX128 = Math.mulDiv(
                        tokenData1.leftSlot(),
                        2 ** 128,
                        thresholdCross
                    );

                    bonus1 = int256(Math.mulDiv128(bonusCross, requiredRatioX128));

                    bonus0 = int256(
                        PanopticMath.convert1to0(
                            Math.mulDiv128(bonusCross, 2 ** 128 - requiredRatioX128),
                            atSqrtPriceX96
                        )
                    );
                }
            }

            // negative premium (owed to the liquidatee) is credited to the collateral balance
            // this is already present in the netPaid amount, so to avoid double-counting we remove it from the balance
            int256 balance0 = int256(uint256(tokenData0.rightSlot())) -
                int256(uint256(shortPremium.rightSlot()));
            int256 balance1 = int256(uint256(tokenData1.rightSlot())) -
                int256(uint256(shortPremium.leftSlot()));

            int256 paid0 = bonus0 + int256(netPaid.rightSlot());
            int256 paid1 = bonus1 + int256(netPaid.leftSlot());

            // note that "balance0" and "balance1" are the liquidatee's original balances before token delegation by a liquidator
            // their actual balances at the time of computation may be higher, but these are a buffer representing the amount of tokens we
            // have to work with before cutting into the liquidator's funds
            if (!(paid0 > balance0 && paid1 > balance1)) {
                // liquidatee cannot pay back the liquidator fully in either token, so no protocol loss can be avoided
                if ((paid0 > balance0)) {
                    // liquidatee has insufficient token0 but some token1 left over, so we use what they have left to mitigate token0 losses
                    // we do this by substituting an equivalent value of token1 in our refund to the liquidator, plus a bonus, for the token0 we convert
                    // we want to convert the minimum amount of tokens required to achieve the lowest possible protocol loss (to avoid overpaying on the conversion bonus)
                    // the maximum level of protocol loss mitigation that can be achieved is the liquidatee's excess token1 balance: balance1 - paid1
                    // and paid0 - balance0 is the amount of token0 that the liquidatee is missing, i.e the protocol loss
                    // if the protocol loss is lower than the excess token1 balance, then we can fully mitigate the loss and we should only convert the loss amount
                    // if the protocol loss is higher than the excess token1 balance, we can only mitigate part of the loss, so we should convert only the excess token1 balance
                    // thus, the value converted should be min(balance1 - paid1, paid0 - balance0)
                    bonus1 += Math.min(
                        balance1 - paid1,
                        PanopticMath.convert0to1(paid0 - balance0, atSqrtPriceX96)
                    );
                    bonus0 -= Math.min(
                        PanopticMath.convert1to0(balance1 - paid1, atSqrtPriceX96),
                        paid0 - balance0
                    );
                }
                if ((paid1 > balance1)) {
                    // liquidatee has insufficient token1 but some token0 left over, so we use what they have left to mitigate token1 losses
                    // we do this by substituting an equivalent value of token0 in our refund to the liquidator, plus a bonus, for the token1 we convert
                    // we want to convert the minimum amount of tokens required to achieve the lowest possible protocol loss (to avoid overpaying on the conversion bonus)
                    // the maximum level of protocol loss mitigation that can be achieved is the liquidatee's excess token0 balance: balance0 - paid0
                    // and paid1 - balance1 is the amount of token1 that the liquidatee is missing, i.e the protocol loss
                    // if the protocol loss is lower than the excess token0 balance, then we can fully mitigate the loss and we should only convert the loss amount
                    // if the protocol loss is higher than the excess token0 balance, we can only mitigate part of the loss, so we should convert only the excess token0 balance
                    // thus, the value converted should be min(balance0 - paid0, paid1 - balance1)
                    bonus0 += Math.min(
                        balance0 - paid0,
                        PanopticMath.convert1to0(paid1 - balance1, atSqrtPriceX96)
                    );
                    bonus1 -= Math.min(
                        PanopticMath.convert0to1(balance0 - paid0, atSqrtPriceX96),
                        paid1 - balance1
                    );
                }
            }

            paid0 = bonus0 + int256(netPaid.rightSlot());
            paid1 = bonus1 + int256(netPaid.leftSlot());
            return (
                LeftRightSigned.wrap(0).toRightSlot(int128(bonus0)).toLeftSlot(int128(bonus1)),
                LeftRightSigned.wrap(0).toRightSlot(int128(balance0 - paid0)).toLeftSlot(
                    int128(balance1 - paid1)
                )
            );
        }
    }

    /// @notice Haircut/clawback any premium paid by `liquidatee` on `positionIdList` over the protocol loss threshold during a liquidation.
    /// @dev Note that the storage mapping provided as the `settledTokens` parameter WILL be modified on the caller by this function.
    /// @param liquidatee The address of the user being liquidated
    /// @param positionIdList The list of position ids being liquidated
    /// @param premiasByLeg The premium paid (or received) by the liquidatee for each leg of each position
    /// @param collateralRemaining The remaining collateral after the liquidation (negative if protocol loss)
    /// @param atSqrtPriceX96 The oracle price used to swap tokens between the liquidator/liquidatee and determine solvency for the liquidatee
    /// @param collateral0 The collateral tracker for token0
    /// @param collateral1 The collateral tracker for token1
    /// @param settledTokens The per-chunk accumulator of settled tokens in storage from which to subtract the haircut premium
    /// @return The delta, if any, to apply to the existing liquidation bonus
    function haircutPremia(
        address liquidatee,
        TokenId[] memory positionIdList,
        LeftRightSigned[4][] memory premiasByLeg,
        LeftRightSigned collateralRemaining,
        CollateralTracker collateral0,
        CollateralTracker collateral1,
        uint160 atSqrtPriceX96,
        mapping(bytes32 chunkKey => LeftRightUnsigned settledTokens) storage settledTokens
    ) external returns (LeftRightSigned) {
        unchecked {
            // get the amount of premium paid by the liquidatee
            LeftRightSigned longPremium;
            for (uint256 i = 0; i < positionIdList.length; ++i) {
                TokenId tokenId = positionIdList[i];
                uint256 numLegs = tokenId.countLegs();
                for (uint256 leg = 0; leg < numLegs; ++leg) {
                    if (tokenId.isLong(leg) == 1) {
                        longPremium = longPremium.sub(premiasByLeg[i][leg]);
                    }
                }
            }
            // Ignore any surplus collateral - the liquidatee is either solvent or it converts to <1 unit of the other token
            int256 collateralDelta0 = -Math.min(collateralRemaining.rightSlot(), 0);
            int256 collateralDelta1 = -Math.min(collateralRemaining.leftSlot(), 0);
            int256 haircut0;
            int256 haircut1;

            // if the premium in the same token is not enough to cover the loss and there is a surplus of the other token,
            // the liquidator will provide the tokens (reflected in the bonus amount) & receive compensation in the other token
            if (
                longPremium.rightSlot() < collateralDelta0 &&
                longPremium.leftSlot() > collateralDelta1
            ) {
                int256 protocolLoss1 = collateralDelta1;
                (collateralDelta0, collateralDelta1) = (
                    -Math.min(
                        collateralDelta0 - longPremium.rightSlot(),
                        PanopticMath.convert1to0(
                            longPremium.leftSlot() - collateralDelta1,
                            atSqrtPriceX96
                        )
                    ),
                    Math.min(
                        longPremium.leftSlot() - collateralDelta1,
                        PanopticMath.convert0to1(
                            collateralDelta0 - longPremium.rightSlot(),
                            atSqrtPriceX96
                        )
                    )
                );

                haircut0 = longPremium.rightSlot();
                haircut1 = protocolLoss1 + collateralDelta1;
            } else if (
                longPremium.leftSlot() < collateralDelta1 &&
                longPremium.rightSlot() > collateralDelta0
            ) {
                int256 protocolLoss0 = collateralDelta0;
                (collateralDelta0, collateralDelta1) = (
                    Math.min(
                        longPremium.rightSlot() - collateralDelta0,
                        PanopticMath.convert1to0(
                            collateralDelta1 - longPremium.leftSlot(),
                            atSqrtPriceX96
                        )
                    ),
                    -Math.min(
                        collateralDelta1 - longPremium.leftSlot(),
                        PanopticMath.convert0to1(
                            longPremium.rightSlot() - collateralDelta0,
                            atSqrtPriceX96
                        )
                    )
                );

                haircut0 = collateralDelta0 + protocolLoss0;
                haircut1 = longPremium.leftSlot();
            } else {
                // for each token, haircut until the protocol loss is mitigated or the premium paid is exhausted
                haircut0 = Math.min(collateralDelta0, longPremium.rightSlot());
                haircut1 = Math.min(collateralDelta1, longPremium.leftSlot());

                collateralDelta0 = 0;
                collateralDelta1 = 0;
            }

            {
                address _liquidatee = liquidatee;
                if (haircut0 != 0) collateral0.exercise(_liquidatee, 0, 0, 0, int128(haircut0));
                if (haircut1 != 0) collateral1.exercise(_liquidatee, 0, 0, 0, int128(haircut1));
            }

            for (uint256 i = 0; i < positionIdList.length; i++) {
                TokenId tokenId = positionIdList[i];
                LeftRightSigned[4][] memory _premiasByLeg = premiasByLeg;
                for (uint256 leg = 0; leg < tokenId.countLegs(); ++leg) {
                    if (tokenId.isLong(leg) == 1) {
                        mapping(bytes32 chunkKey => LeftRightUnsigned settledTokens)
                            storage _settledTokens = settledTokens;

                        // calculate amounts to revoke from settled and subtract from haircut req
                        uint256 settled0 = Math.unsafeDivRoundingUp(
                            uint128(-_premiasByLeg[i][leg].rightSlot()) * uint256(haircut0),
                            uint128(longPremium.rightSlot())
                        );
                        uint256 settled1 = Math.unsafeDivRoundingUp(
                            uint128(-_premiasByLeg[i][leg].leftSlot()) * uint256(haircut1),
                            uint128(longPremium.leftSlot())
                        );

                        bytes32 chunkKey = keccak256(
                            abi.encodePacked(
                                tokenId.strike(leg),
                                tokenId.width(leg),
                                tokenId.tokenType(leg)
                            )
                        );

                        // The long premium is not commited to storage during the liquidation, so we add the entire adjusted amount
                        // for the haircut directly to the accumulator
                        settled0 = Math.max(
                            0,
                            uint128(-_premiasByLeg[i][leg].rightSlot()) - settled0
                        );
                        settled1 = Math.max(
                            0,
                            uint128(-_premiasByLeg[i][leg].leftSlot()) - settled1
                        );

                        _settledTokens[chunkKey] = _settledTokens[chunkKey].add(
                            LeftRightUnsigned.wrap(uint128(settled0)).toLeftSlot(uint128(settled1))
                        );
                    }
                }
            }

            return
                LeftRightSigned.wrap(0).toRightSlot(int128(collateralDelta0)).toLeftSlot(
                    int128(collateralDelta1)
                );
        }
    }

    /// @notice Redistribute the final exercise fee deltas between tokens if necessary according to the available collateral from the exercised user.
    /// @param exercisee The address of the user being exercised
    /// @param exerciseFees Pre-adjustment exercise fees to debit from exercisor (rightSlot = token0 left = token1)
    /// @param atTick The tick at which to convert between token0/token1 when redistributing the exercise fees
    /// @param ct0 The collateral tracker for token0
    /// @param ct1 The collateral tracker for token1
    /// @return The LeftRight-packed deltas for token0/token1 to move from the exercisor to the exercisee
    function getExerciseDeltas(
        address exercisee,
        LeftRightSigned exerciseFees,
        int24 atTick,
        CollateralTracker ct0,
        CollateralTracker ct1
    ) external view returns (LeftRightSigned) {
        uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(atTick);
        unchecked {
            // if the refunder lacks sufficient token0 to pay back the virtual shares, have the exercisor cover the difference in exchange for token1 (and vice versa)

            int256 balanceShortage = int256(uint256(type(uint248).max)) -
                int256(ct0.balanceOf(exercisee)) -
                int256(ct0.convertToShares(uint128(-exerciseFees.rightSlot())));

            if (balanceShortage > 0) {
                return
                    LeftRightSigned
                        .wrap(0)
                        .toRightSlot(
                            int128(
                                exerciseFees.rightSlot() -
                                    int256(
                                        Math.mulDivRoundingUp(
                                            uint256(balanceShortage),
                                            ct0.totalAssets(),
                                            ct0.totalSupply()
                                        )
                                    )
                            )
                        )
                        .toLeftSlot(
                            int128(
                                int256(
                                    PanopticMath.convert0to1(
                                        ct0.convertToAssets(uint256(balanceShortage)),
                                        sqrtPriceX96
                                    )
                                ) + exerciseFees.leftSlot()
                            )
                        );
            }

            balanceShortage =
                int256(uint256(type(uint248).max)) -
                int256(ct1.balanceOf(exercisee)) -
                int256(ct1.convertToShares(uint128(-exerciseFees.leftSlot())));
            if (balanceShortage > 0) {
                return
                    LeftRightSigned
                        .wrap(0)
                        .toRightSlot(
                            int128(
                                int256(
                                    PanopticMath.convert1to0(
                                        ct1.convertToAssets(uint256(balanceShortage)),
                                        sqrtPriceX96
                                    )
                                ) + exerciseFees.rightSlot()
                            )
                        )
                        .toLeftSlot(
                            int128(
                                exerciseFees.leftSlot() -
                                    int256(
                                        Math.mulDivRoundingUp(
                                            uint256(balanceShortage),
                                            ct1.totalAssets(),
                                            ct1.totalSupply()
                                        )
                                    )
                            )
                        );
            }
        }

        // otherwise, no need to deviate from the original exercise fee deltas
        return exerciseFees;
    }
}
