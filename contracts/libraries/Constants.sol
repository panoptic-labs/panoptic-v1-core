// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Library of Constants used in Panoptic.
/// @author Axicon Labs Limited
/// @notice This library provides constants used in Panoptic.
library Constants {
    /// @notice Fixed point multiplier: 2**96
    uint256 internal constant FP96 = 0x1000000000000000000000000;

    /// @notice Minimum possible price tick in a Uniswap V3 pool
    int24 internal constant MIN_V3POOL_TICK = -887272;

    /// @notice Maximum possible price tick in a Uniswap V3 pool
    int24 internal constant MAX_V3POOL_TICK = 887272;

    /// @notice Minimum possible sqrtPriceX96 in a Uniswap V3 pool
    uint160 internal constant MIN_V3POOL_SQRT_RATIO = 4295128739;

    /// @notice Maximum possible sqrtPriceX96 in a Uniswap V3 pool
    uint160 internal constant MAX_V3POOL_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    /// @notice Parameter that determines which oracle type to use for the "slow" oracle price on non-liquidation solvency checks.
    /// @dev If false, an 8-slot internal median array is used to compute the "slow" oracle price.
    /// @dev This oracle is updated with the last Uniswap observation during `mintOptions` if MEDIAN_PERIOD has elapsed past the last observation.
    /// @dev If true, the "slow" oracle price is instead computed on-the-fly from 9 Uniswap observations (spaced 5 observations apart) irrespective of the frequency of `mintOptions` calls.
    bool internal constant SLOW_ORACLE_UNISWAP_MODE = false;

    /// @notice The minimum amount of time, in seconds, permitted between internal TWAP updates.
    uint256 internal constant MEDIAN_PERIOD = 60;

    /// @notice Amount of Uniswap observations to include in the "fast" oracle price.
    uint256 internal constant FAST_ORACLE_CARDINALITY = 3;

    /// @dev Amount of observation indices to skip in between each observation for the "fast" oracle price.
    /// @dev Note that the *minimum* total observation time is determined by the blocktime and may need to be adjusted by chain.
    /// @dev Uniswap observations snapshot the last block's closing price at the first interaction with the pool in a block.
    /// @dev In this case, if there is an interaction every block, the "fast" oracle can consider 3 consecutive block end prices (min=36 seconds on Ethereum).
    uint256 internal constant FAST_ORACLE_PERIOD = 1;

    /// @notice Amount of Uniswap observations to include in the "slow" oracle price (in Uniswap mode).
    uint256 internal constant SLOW_ORACLE_CARDINALITY = 9;

    /// @notice Amount of observation indices to skip in between each observation for the "slow" oracle price.
    /// @dev Structured such that the minimum total observation time is 9 minutes on Ethereum.
    uint256 internal constant SLOW_ORACLE_PERIOD = 5;
}
