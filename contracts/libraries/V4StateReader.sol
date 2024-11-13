// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Uniswap V4 interfaces
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// Uniswap V4 libraries
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
// Uniswap V4 types
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice A library to retrieve state information from Uniswap V4 pools via `extsload`.
/// @author Axicon Labs Limited, credit to Uniswap Labs under MIT License
library V4StateReader {
    /// @notice Retrieves the current `sqrtPriceX96` from a Uniswap V4 pool.
    /// @param manager The Uniswap V4 pool manager contract
    /// @param poolId The pool ID of the Uniswap V4 pool
    /// @return sqrtPriceX96 The current `sqrtPriceX96` of the Uniswap V4 pool
    function getSqrtPriceX96(
        IPoolManager manager,
        PoolId poolId
    ) internal view returns (uint160 sqrtPriceX96) {
        bytes32 stateSlot = StateLibrary._getPoolStateSlot(poolId);
        bytes32 data = manager.extsload(stateSlot);

        assembly ("memory-safe") {
            sqrtPriceX96 := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    /// @notice Retrieves the current tick from a Uniswap V4 pool.
    /// @param manager The Uniswap V4 pool manager contract
    /// @param poolId The pool ID of the Uniswap V4 pool
    /// @return tick The current tick of the Uniswap V4 pool
    function getTick(IPoolManager manager, PoolId poolId) internal view returns (int24 tick) {
        bytes32 stateSlot = StateLibrary._getPoolStateSlot(poolId);
        bytes32 data = manager.extsload(stateSlot);

        assembly ("memory-safe") {
            tick := signextend(2, shr(160, data))
        }
    }

    /// @notice Calculates the fee growth that has occurred (per unit of liquidity) in the AMM/Uniswap for an
    /// option position's tick range.
    /// @param manager The Uniswap V4 pool manager contract
    /// @param idV4 The pool ID of the Uniswap V4 pool
    /// @param currentTick The current price tick in the AMM
    /// @param tickLower The lower tick of the option position leg (a liquidity chunk)
    /// @param tickUpper The upper tick of the option position leg (a liquidity chunk)
    /// @return feeGrowthInside0X128 The fee growth in the AMM for currency0
    /// @return feeGrowthInside1X128 The fee growth in the AMM for currency1
    function getFeeGrowthInside(
        IPoolManager manager,
        PoolId idV4,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        // Get feesGrowths from the option position's lower+upper ticks
        // lowerOut0: For currency0: fee growth per unit of liquidity on the _other_ side of tickLower (relative to currentTick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // (...)
        // upperOut1: For currency1: fee growth on the _other_ side of tickUpper (again: relative to currentTick)
        // the point is: the range covered by lowerOut0 changes depending on where currentTick is.
        (uint256 lowerOut0, uint256 lowerOut1) = StateLibrary.getTickFeeGrowthOutside(
            manager,
            idV4,
            tickLower
        );
        (uint256 upperOut0, uint256 upperOut1) = StateLibrary.getTickFeeGrowthOutside(
            manager,
            idV4,
            tickUpper
        );

        // compute the effective feeGrowth, depending on whether price is above/below/within range
        unchecked {
            if (currentTick < tickLower) {
                /**
                  Diagrams shown for currency0, and applies for currency1 the same
                  L = lowerTick, U = upperTick

                    liquidity         lowerOut0 (all fees collected in this price tick range for currency0)
                        ▲            ◄──────────────^v───► (to MAX_TICK)
                        │
                        │                      upperOut0
                        │                     ◄─────^v───►
                        │           ┌────────┐
                        │           │ chunk  │
                        │           │        │
                        └─────▲─────┴────────┴────────► price tick
                              │     L        U
                              │
                           current
                            tick
                */
                feeGrowthInside0X128 = lowerOut0 - upperOut0; // fee growth inside the chunk
                feeGrowthInside1X128 = lowerOut1 - upperOut1;
            } else if (currentTick >= tickUpper) {
                /**
                    liquidity
                        ▲           upperOut0
                        │◄─^v─────────────────────►
                        │
                        │     lowerOut0  ┌────────┐
                        │◄─^v───────────►│ chunk  │
                        │                │        │
                        └────────────────┴────────┴─▲─────► price tick
                                         L        U │
                                                    │
                                                 current
                                                  tick
                 */
                feeGrowthInside0X128 = upperOut0 - lowerOut0;
                feeGrowthInside1X128 = upperOut1 - lowerOut1;
            } else {
                /**
                  current AMM tick is within the option position range (within the chunk)

                     liquidity
                        ▲        feeGrowthGlobal0X128 = global fee growth
                        │                             = (all fees collected for the entire price range for currency0)
                        │
                        │
                        │     lowerOut0  ┌──────────────┐ upperOut0
                        │◄─^v───────────►│              │◄─────^v───►
                        │                │     chunk    │
                        │                │              │
                        └────────────────┴───────▲──────┴─────► price tick
                                         L       │      U
                                                 │
                                              current
                                               tick
                */

                (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = StateLibrary
                    .getFeeGrowthGlobals(manager, idV4);
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerOut0 - upperOut0;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerOut1 - upperOut1;
            }
        }
    }

    /// @notice Retrieves the last stored `feeGrowthInsideLast` values for a unique Uniswap V4 position.
    /// @dev Corresponds to pools[poolId].positions[positionId] in `manager`.
    /// @param manager The Uniswap V4 pool manager contract
    /// @param poolId The ID of the Uniswap V4 pool
    /// @param positionId The ID of the position, which is a hash of the owner, tickLower, tickUpper, and salt
    /// @return feeGrowthInside0LastX128 The fee growth inside the position for currency0
    /// @return feeGrowthInside1LastX128 The fee growth inside the position for currency1
    function getFeeGrowthInsideLast(
        IPoolManager manager,
        PoolId poolId,
        bytes32 positionId
    ) internal view returns (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) {
        bytes32 slot = StateLibrary._getPositionInfoSlot(poolId, positionId);

        // read all 3 words of the Position.State struct
        bytes32[] memory data = manager.extsload(slot, 3);

        assembly ("memory-safe") {
            feeGrowthInside0LastX128 := mload(add(data, 64))
            feeGrowthInside1LastX128 := mload(add(data, 96))
        }
    }
}
