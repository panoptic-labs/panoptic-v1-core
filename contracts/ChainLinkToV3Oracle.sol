// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {TickMath} from "v3-core/libraries/TickMath.sol";

/// @title ChainLinkToV3Oracle
/// @notice Contract that provides a Uniswap V3-compatible oracle interface on ChainLink-sourced data.
contract ChainLinkToV3Oracle {
    /// @notice The ChainLink price aggregator contract this adapter interacts with.
    AggregatorV3Interface public immutable aggregator;

    // TODO: _Should_ be able to pull from aggregator, but .decimals() was reverting in test
    // Hard-coding the ETH/USD value for now, and could possibly kick this to constructor:
    uint8 public constant DECIMALS = 8;

    /// @notice Initializes the adapter with the BaseOracleHook contract and pool ID.
    /// @param _aggregator The ChainLink price aggregator contract to read from
    constructor(AggregatorV3Interface _aggregator) {
        aggregator = _aggregator;
    }

    /// @notice Emulates the behavior of the exposed zeroth slot of a Uniswap V3 pool.
    /// @return sqrtPriceX96 The current price of the oracle as a sqrt(currency1/currency0) Q64.96 value
    /// @return tick The current tick of the oracle
    /// @return observationIndex The index of the last oracle observation that was written
    /// @return observationCardinality The current maximum number of observations stored in the oracle
    /// @return observationCardinalityNext The next maximum number of observations that can be stored in the oracle
    /// @return feeProtocol The protocol fee for this pool (not used in V4, always 0)
    /// @return unlocked Whether the pool is currently unlocked (always true for V4)
    function slot0()
      external view
      returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
      )
    {
      (, int256 answer,,,) = aggregator.latestRoundData();
      require(answer > 0, "bad price");

      uint256 uAnswer = uint256(answer);
      uint256 priceQ128 = (uAnswer << 128) / (10 ** DECIMALS);
      uint128 rootQ64 = sqrt(priceQ128);
      sqrtPriceX96 = uint160(uint256(rootQ64) << 32);

      tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

      // TODO: Decide what to return here - they don't mean much in this context, unless we actually want to stamp oracles.
      /*(observationIndex, observationCardinality, observationCardinalityNext) =
        baseOracleHook.stateById(poolId);*/

      feeProtocol = 0;
      unlocked = true;
    }

    // TODO: Replace with a standard lib
    function sqrt(uint256 x) internal pure returns (uint128 y) {
        uint256 z = (x + 1) / 2;
        y = uint128(x);
        while (z < y) {
            y = uint128(z);
            z = (x / z + z) / 2;
        }
    }

    // TODO: Some of the below should be stubbed with dummy values since they don't mean anything in this context
    // The biggest remaining decision could be whether to do actual "observations" -
    // e.g., record the actual returned value from ChainLink on X interval
    // Or, we could just return an array with [ChainLinkValue - HardcodedDeviance/2, ChainLinkValue + HardcodedDeviance/2, ChainLinkValue]
    /*
    /// @notice Returns data about a specific observation index.
   /// @param index The element of the observations array to fetch
   /// @return blockTimestamp The timestamp of the observation
   /// @return tickCumulative The tick multiplied by seconds elapsed for the life of the pool as of the observation timestamp.
   /// @return secondsPerLiquidityCumulativeX128 The seconds per in range liquidity for the life of the pool (always 0 in V4)
   /// @return initialized Whether the observation has been initialized and the values are safe to use
   function observations(
       uint256 index
   )
       external
       view
       returns (
           uint32 blockTimestamp,
           int56 tickCumulative,
           uint160 secondsPerLiquidityCumulativeX128,
           bool initialized
       )
   { }

   /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from the current block timestamp.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos` from the current block timestamp
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity-in-range value (always empty in V4)
    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    { }

    /// @notice Increase the maximum number of price observations that this oracle will store.
    /// @param observationCardinalityNext The desired minimum number of observations for the oracle to store
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external { }
    */

}
