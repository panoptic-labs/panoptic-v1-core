// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {TickMath} from "v3-core/libraries/TickMath.sol";

/// @title ChainLinkToV3Oracle
/// @notice Contract that provides a Uniswap V3-compatible oracle interface on ChainLink-sourced data.
/// @dev We still use the v4 pool's slot0.
contract ChainLinkToV3Oracle {
    /// @notice The ChainLink price aggregator contract this adapter interacts with.
    AggregatorV3Interface public immutable aggregator;

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
      // 1) Chainlink gives price as answer/10**decimals, e.g. ETH/USD = 3000e8
      (, int256 answer,,,) = aggregator.latestRoundData();
      require(answer > 0, "bad price");

      // 2) normalize into Q64.96 sqrtPrice
      //    price is token1/token0, so sqrtPriceX96 = sqrt(price) * 2**96
      uint256 uAnswer = uint256(answer);
      // shift to Q128 (i.e. price * 2**128) so we can sqrt safely:
      uint256 priceQ128 = uAnswer << 128 / (10 ** aggregator.decimals());
      sqrtPriceX96 = uint160(sqrt(priceQ128)); // internal sqrt of uint256 → uint128

      // 3) derive tick via Uniswap’s library
      tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

      // TODO: Decide what to return here - they don't mean much in this context
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
}
