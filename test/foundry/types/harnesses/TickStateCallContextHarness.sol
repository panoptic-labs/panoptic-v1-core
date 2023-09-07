// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@types/TickStateCallContext.sol";

/// @title TickStateCallContextHarness: A harness to expose the TickStateCallContext library for code coverage analysis.
/// @notice Replicates the interface of the TickStateCallContext library, passing through any function calls
/// @author Axicon Labs Limited
contract TickStateCallContextHarness {
    /*****************************************************************/
    /*
    /* WRITE TO A TickStateCallContext
    /*
    /*****************************************************************/

    /**
     * @notice Overwrite the `currentTick` to the `tickStateCallContext` packed data.
     * @param self the packed uint256 that holds current tick, median tick, and caller.
     * @param currentTick The current tick of the uniswap pool.
     * @return the tickStateCallContext with added currentTick data.
     */
    function updateCurrentTick(uint256 self, int24 currentTick) public pure returns (uint256) {
        uint256 r = TickStateCallContext.updateCurrentTick(self, currentTick);
        return r;
    }

    /**
     * @notice Add the `currentTick` to the `tickStateCallContext` packed data.
     * @param self the packed uint256 bit containing the current tick, sqrtPriceX96 and the swapFee.
     * @param currentTick The current tick of the uniswap pool.
     * @return the tickStateCallContext with added currentTick data .
     */
    function addCurrentTick(uint256 self, int24 currentTick) public pure returns (uint256) {
        uint256 r = TickStateCallContext.addCurrentTick(self, currentTick);
        return r;
    }

    /**
     * @notice Add the `sqrtPriceX96` to the `tickStateCallContext` packed data.
     * @param self the packed uint256 bit containing the current tick, sqrtPriceX96 and the swapFee.
     * @param medianTick The median tick of the mini TWAP.
     * @return the tickStateCallContext with added sqrtPriceX96 data.
     */
    function addMedianTick(uint256 self, int24 medianTick) public pure returns (uint256) {
        uint256 r = TickStateCallContext.addMedianTick(self, medianTick);
        return r;
    }

    /**
     * @notice Add the `msg.sender` to the `tickStateCallContext` packed data.
     * @param self the packed uint256 bit containing msg.sender, the medianTick, and the swapFee.
     * @param _msgSender The miniTWAP tick of the Panoptic pool.
     * @return the tickStateCallContext with added msg.sender data .
     */
    function addCaller(uint256 self, address _msgSender) public pure returns (uint256) {
        uint256 r = TickStateCallContext.addCaller(self, _msgSender);
        return r;
    }

    /*****************************************************************/
    /*
    /* READ FROM A TickStateCallContext
    /*
    /*****************************************************************/

    /**
     * @notice Return the currentTick for data packed into tickStateCallContext.
     * @param self the packed uint256 bit containing the current tick, sqrtPriceX96 and the swapFee.
     * @return the current tick of tickStateCallContext.
     */
    function currentTick(uint256 self) public pure returns (int24) {
        int24 r = TickStateCallContext.currentTick(self);
        return r;
    }

    /**
     * @notice Return the sqrtPrice for data packed into tickStateCallContext.
     * @param self the packed uint256 bit containing the current tick, median tick and the swapFee.
     * @return the sqrtPriceX96 of tickStateCallContext.
     */
    function medianTick(uint256 self) public pure returns (int24) {
        int24 r = TickStateCallContext.medianTick(self);
        return r;
    }

    /**
     * @notice Return the msgSender for data packed into tickStateCallContext.
     * @param self the packed uint256 bit containing msg.sender, the medianTick, and the swapFee.
     * @return the msgSender of tickStateCallContext.
     */
    function caller(uint256 self) public pure returns (address) {
        address r = TickStateCallContext.caller(self);
        return r;
    }
}
