// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

type PositionBalance is uint256;
using PositionBalanceLibrary for PositionBalance global;

/// @title A Panoptic Position Balance. Tracks the Position Size, the Pool Utilizations at mint, and the current/fastOracle/slowOracle/latestObserved ticks at mint.
/// @author Axicon Labs Limited
//
//
// PACKING RULES FOR A POSITIONBALANCE:
// =================================================================================================
//  From the LSB to the MSB:
// (1) positionSize     128bits : The size of this position (uint128).
// (2) poolUtilization0 16bits  : The pool utilization of token0, stored as (10000 * inAMM0)/totalAssets0 (uint16).
// (3) poolUtilization1 16bits  : The pool utilization of token1, stored as (10000 * inAMM1)/totalAssets1 (uint16).
// (4) currentTick      24bits  : The currentTick at mint (int24).
// (5) fastOracleTick   24bits  : The fastOracleTick at mint (int24).
// (6) slowOracleTick   24bits  : The slowOracleTick at mint (int24).
// (7) lastObservedTick 24bits  : The lastObservedTick at mint (int24).
// Total                256bits : Total bits used by a PositionBalance.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//           (7)             (6)            (5)             (4)             (3)             (2)             (1)
//    <-- 24 bits --> <-- 24 bits --> <-- 24 bits --> <-- 24 bits --> <-- 16 bits --> <-- 16 bits --> <-- 128 bits -->
//   lastObservedTick  slowOracleTick  fastOracleTick   currentTick     utilization1    utilization0    positionSize
//
//    <--- most significant bit                                                             least significant bit --->
//
library PositionBalanceLibrary {
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `PositionBalance` given by positionSize, utilizations, and its tickData.
    /// @param _positionSize The amount of option minted
    /// @param _utilizations Packing of two uint16 utilizations into a 32 bit word
    /// @param _tickData Packing of 4 int25s into a single uint96
    /// @return The new PositionBalance with the given positionSize, utilization, and tickData
    function storeBalanceData(
        uint128 _positionSize,
        uint32 _utilizations,
        uint96 _tickData
    ) internal pure returns (PositionBalance) {
        unchecked {
            return
                PositionBalance.wrap(
                    (uint256(_tickData) << 160) +
                        (uint256(_utilizations) << 128) +
                        uint256(_positionSize)
                );
        }
    }

    /// @notice Concatenate all oracle ticks into a single uint96.
    /// @param _currentTick The current tick
    /// @param _fastOracleTick The fast Oracle tick
    /// @param _slowOracleTick The slow Oracle tick
    /// @param _lastObservedTick The last observed tick
    /// @return A 96bit word concatenating all 4 input ticks
    function packTickData(
        int24 _currentTick,
        int24 _fastOracleTick,
        int24 _slowOracleTick,
        int24 _lastObservedTick
    ) internal pure returns (uint96) {
        unchecked {
            return
                uint96(uint24(_currentTick)) +
                (uint96(uint24(_fastOracleTick)) << 24) +
                (uint96(uint24(_slowOracleTick)) << 48) +
                (uint96(uint24(_lastObservedTick)) << 72);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the last observed tick of `self`.
    /// @param self The PositionBalance to retrieve the last observed tick from
    /// @return The last observed tick of `self`
    function lastObservedTick(PositionBalance self) internal pure returns (int24) {
        unchecked {
            return int24(int256(PositionBalance.unwrap(self) >> 232));
        }
    }

    /// @notice Get the slow oracle tick of `self`.
    /// @param self The PositionBalance to retrieve the slow oracle tick from
    /// @return The slow oracle tick of `self`
    function slowOracleTick(PositionBalance self) internal pure returns (int24) {
        unchecked {
            return int24(int256(PositionBalance.unwrap(self) >> 208));
        }
    }

    /// @notice Get the fast oracle tick of `self`.
    /// @param self The PositionBalance to retrieve the fast oracle tick from
    /// @return The fast oracle tick of `self`
    function fastOracleTick(PositionBalance self) internal pure returns (int24) {
        unchecked {
            return int24(int256(PositionBalance.unwrap(self) >> 184));
        }
    }

    /// @notice Get the current tick of `self`.
    /// @param self The PositionBalance to retrieve the current tick from
    /// @return The current tick of `self`
    function currentTick(PositionBalance self) internal pure returns (int24) {
        unchecked {
            return int24(int256(PositionBalance.unwrap(self) >> 160));
        }
    }

    /// @notice Get the tickData of `self`.
    /// @param self The PositionBalance to retrieve the tickData from
    /// @return The packed tickData (currentTick, fastOracleTick, slowOracleTick, lastObservedTick)
    function tickData(PositionBalance self) internal pure returns (uint96) {
        unchecked {
            return uint96(PositionBalance.unwrap(self) >> 160);
        }
    }

    /// @notice Unpack the current, last observed, and fast/slow oracle ticks from a 96-bit tickData encoding.
    /// @param _tickData The packed tickData to unpack ticks from
    /// @return The current tick contained in `_tickData`
    /// @return The fast oracle tick contained in `_tickData`
    /// @return The slow oracle tick contained in `_tickData`
    /// @return The last observed tick contained in `_tickData`
    function unpackTickData(uint96 _tickData) internal pure returns (int24, int24, int24, int24) {
        PositionBalance self = PositionBalance.wrap(uint256(_tickData) << 160);
        return (
            self.currentTick(),
            self.fastOracleTick(),
            self.slowOracleTick(),
            self.lastObservedTick()
        );
    }

    /// @notice Get token0 utilization of `self`.
    /// @param self The PositionBalance to retrieve the token0 utilization from
    /// @return The token0 utilization, stored in bips
    function utilization0(PositionBalance self) internal pure returns (int256) {
        unchecked {
            return int256((PositionBalance.unwrap(self) >> 128) % 2 ** 16);
        }
    }

    /// @notice Get token1 utilization of `self`.
    /// @param self The PositionBalance to retrieve the token1 utilization from
    /// @return The token1 utilization, stored in bips
    function utilization1(PositionBalance self) internal pure returns (int256) {
        unchecked {
            return int256((PositionBalance.unwrap(self) >> 144) % 2 ** 16);
        }
    }

    /// @notice Get both token0 and token1 utilizations of `self`.
    /// @param self The PositionBalance to retrieve the utilizations from
    /// @return The token utilizations, stored in bips
    function utilizations(PositionBalance self) internal pure returns (uint32) {
        unchecked {
            return uint32(PositionBalance.unwrap(self) >> 128);
        }
    }

    /// @notice Get the positionSize of `self`.
    /// @param self The PositionBalance to retrieve the positionSize from
    /// @return The positionSize of `self`
    function positionSize(PositionBalance self) internal pure returns (uint128) {
        unchecked {
            return uint128(PositionBalance.unwrap(self));
        }
    }

    /// @notice Unpack all data from `self`.
    /// @param self The PositionBalance to get all data from
    /// @return currentTickAtMint `currentTick` at mint
    /// @return fastOracleTickAtMint Fast oracle tick at mint
    /// @return slowOracleTickAtMint Slow oracle tick at mint
    /// @return lastObservedTickAtMint Last observed tick at mint
    /// @return utilization0AtMint Utilization of token0 at mint
    /// @return utilization1AtMint Utilization of token1 at mint
    /// @return _positionSize Size of the position
    function unpackAll(
        PositionBalance self
    )
        external
        pure
        returns (
            int24 currentTickAtMint,
            int24 fastOracleTickAtMint,
            int24 slowOracleTickAtMint,
            int24 lastObservedTickAtMint,
            int256 utilization0AtMint,
            int256 utilization1AtMint,
            uint128 _positionSize
        )
    {
        (
            currentTickAtMint,
            fastOracleTickAtMint,
            slowOracleTickAtMint,
            lastObservedTickAtMint
        ) = unpackTickData(self.tickData());

        utilization0AtMint = self.utilization0();
        utilization1AtMint = self.utilization1();

        _positionSize = self.positionSize();
    }
}
