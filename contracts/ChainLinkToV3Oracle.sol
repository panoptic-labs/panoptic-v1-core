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
        external
        view
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
        sqrtPriceX96 = chainlinkPriceToSqrtRatioX96(getChainlinkPrice());
        tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        // TODO: what to return for these? need to look at how they're consumed in panoptic
        // Maybe always return cardinality >= 100? Isn't that a constraint for pool readiness somewhere?
        observationIndex = uint16(block.timestamp % 65536); // Cycling index based on time
        observationCardinality = 8; // Match the 8-slot median queue
        observationCardinalityNext = 8;

        // not used in v4, so always 0
        feeProtocol = 0;
        // always true in v4
        unlocked = true;
    }

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
    {
        int24 tick = TickMath.getTickAtSqrtRatio(chainlinkPriceToSqrtRatioX96(getChainlinkPrice()));

        // Use a blockTimestamp close to now, but unique per-observation
        blockTimestamp = uint32(block.timestamp - index);
        tickCumulative = int56(tick) * int56(int32(blockTimestamp));

        // Always 0 in v4
        secondsPerLiquidityCumulativeX128 = 0;
        // These values are always safe to use - they're just stubbed based on the chainlink price
        initialized = true;
    }

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
    {
        tickCumulatives = new int56[](secondsAgos.length);

        int24 currentTick = TickMath.getTickAtSqrtRatio(chainlinkPriceToSqrtRatioX96(getChainlinkPrice()));

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            // Use the same current tick for all observations
            // The cumulative = tick * timestamp at that point in time
            // This ensures TWAP calculations will always result in the current tick
            uint256 timestamp = block.timestamp - secondsAgos[i];
            tickCumulatives[i] = int56(currentTick) * int56(int256(timestamp));
        }

        // DEV: *If we wanted* we could actually get historical price at each secondsAgo -
        // but requires searching through recent `round`s on Chainlink and
        // finding the one with a timestamp closest to the target: https://docs.chain.link/data-feeds/historical-data
        // Instead, I just return the current price in each slot

        return (tickCumulatives, new uint160[](secondsAgos.length));
    }

    /// @notice Get the current price from ChainLink with adjustable variation.
    /// @return The current price from the aggregator
    function getChainlinkPrice() internal view returns (int256) {
        (, int256 currentPrice, , , ) = aggregator.latestRoundData();

        return currentPrice;
    }

    /// @notice Take the square root of a ChainLink price and put it into X96 format.
    /// @param price raw ChainLink answer (has DECIMALS decimals)
    /// @return sqrtPriceX96 = sqrt(price/10^DECIMALS) * 2^96
    function chainlinkPriceToSqrtRatioX96(int256 price) internal pure returns (uint160) {
        uint256 p = uint256(price);
        // sqrt(p) has price’s decimals baked in; since price has 8 decimals,
        // we divide out √(10^8) = 10^4 after shifting.
        uint256 root = sqrt(p);
        uint256 scaled = (root << 96) / (10 ** (DECIMALS / 2));
        return uint160(scaled);
    }

    // TODO: Replace with standard lib
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /// @notice This method is typically used to increase the maximum number of price observations, but we just no-op.
    /// @dev PanopticFactory relies on this method, so we wanted to expose it, even if it does nothing.
    /// @param observationCardinalityNext The desired minimum number of observations for the oracle to store
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external {}
}
