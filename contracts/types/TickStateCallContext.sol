// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title Panoptic TickStateCallContext packing and unpacking methods.
/// @author Axicon Labs Limited
/// @dev This needs to be recorded and passed through several functions to ultimately be used in:
/// @dev collateralTracker.takeCommissionAddData() and collateralTracker.exercise().
/// @dev Used to identify the user who originally called PanopticPool and avoid redundant Uniswap price queries.
/// @dev PACKING RULES FOR A TickStateCallContext:
/// =================================================================================================
/// @dev From the LSB to the MSB:
/// (1) currentTick       24bits  : The current tick
/// (2) medianTick        24bits  : The median tick
/// (3) caller           160bits  : The caller (of PanopticPool)
/// ( )                   46bits  : Zero-bits.
/// Total                256bits  : Total bits used by this information.
/// ===============================================================================================
///
/// The bit pattern is therefore:
///
///         (  )              (3)               (2)              (1)
///    <-- 46 bits -->  <-- 160 bits -->  <-- 24 bits -->  <-- 24 bits -->
///         Zeros            caller          medianTick      currentTick
///
///        <--- most significant bit     least significant bit --->
///
library TickStateCallContext {
    using TickStateCallContext for uint256;

    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /**
    /// @notice Overwrite the `currentTick` to the `tickStateCallContext` packed data.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @param _currentTick The current tick of the uniswap pool.
    /// @return the tickStateCallContext with added currentTick data.
     */
    function updateCurrentTick(uint256 self, int24 _currentTick) internal pure returns (uint256) {
        // typecast currentTick to uint24 as explicit type conversion is not allowed from int24 to uint256
        // the tick is cast to uint256 when added with the tickStateCallContext
        unchecked {
            return ((self >> 24) << 24) + uint24(_currentTick);
        }
    }

    /**
    /// @notice Add the `currentTick` to the `tickStateCallContext` packed data.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @param _currentTick The current tick of the uniswap pool.
    /// @return the tickStateCallContext with added currentTick data.
     */
    function addCurrentTick(uint256 self, int24 _currentTick) internal pure returns (uint256) {
        // typecast currentTick to uint24 as explicit type conversion is not allowed from int24 to uint256
        // the tick is cast to uint256 when added with the tickStateCallContext
        unchecked {
            return self + uint24(_currentTick);
        }
    }

    /**
    /// @notice Add the `MedianTick` to the `tickStateCallContext` packed data.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @param _medianTick The miniTWAP tick of the Panoptic pool.
    /// @return the tickStateCallContext with added median tick data.
     */
    function addMedianTick(uint256 self, int24 _medianTick) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(uint24(_medianTick)) << 24);
        }
    }

    /**
    /// @notice Add the `msg.sender` to the `tickStateCallContext` packed data.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @param _caller The user who called the Panoptic Pool.
    /// @return the tickStateCallContext with added msg.sender data.
     */
    function addCaller(uint256 self, address _caller) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(uint160(_caller)) << 48);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /**
    /// @notice Return the currentTick for data packed into tickStateCallContext.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @return the current tick of tickStateCallContext.
     */
    function currentTick(uint256 self) internal pure returns (int24) {
        return int24(int256(self));
    }

    /**
    /// @notice Return the median tick for data packed into tickStateCallContext.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @return the median tick of tickStateCallContext.
     */
    function medianTick(uint256 self) internal pure returns (int24) {
        return int24(int256(self >> 24));
    }

    /**
    /// @notice Return the caller for data packed into tickStateCallContext.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @return the caller stored in tickStateCallContext.
     */
    function caller(uint256 self) internal pure returns (address) {
        return address(uint160(self >> 48));
    }
}
