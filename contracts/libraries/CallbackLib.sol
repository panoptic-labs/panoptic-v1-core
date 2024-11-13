// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

// Interfaces
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
// Libraries
import {Errors} from "@libraries/Errors.sol";

/// @title Library for verifying and decoding Uniswap callbacks.
/// @author Axicon Labs Limited
/// @notice This library provides functions to verify that a callback came from a canonical Uniswap V3 pool with a claimed set of features.
library CallbackLib {
    /// @notice Type defining characteristics of a Uniswap V3 pool.
    /// @param token0 The address of `token0` for the Uniswap pool
    /// @param token1 The address of `token1` for the Uniswap pool
    /// @param fee The fee tier of the Uniswap pool (in hundredths of basis points)
    struct PoolFeatures {
        address token0;
        address token1;
        uint24 fee;
    }

    /// @notice Type for data sent by pool in mint/swap callbacks used to validate the pool and send back requisite tokens.
    /// @param poolFeatures The features of the pool that sent the callback (used to validate that the pool is canonical)
    /// @param payer The address from which the requested tokens should be transferred
    struct CallbackData {
        PoolFeatures poolFeatures;
        address payer;
    }

    /// @notice Verifies that a callback came from the canonical Uniswap pool with a claimed set of features.
    /// @param sender The address initiating the callback and claiming to be a Uniswap pool
    /// @param factory The address of the canonical Uniswap V3 factory
    /// @param features The features `sender` claims to contain (tokens and fee)
    function validateCallback(
        address sender,
        IUniswapV3Factory factory,
        PoolFeatures memory features
    ) internal view {
        // Call getPool on the factory to verify that the sender corresponds to the canonical pool with the claimed features
        if (factory.getPool(features.token0, features.token1, features.fee) != sender)
            revert Errors.InvalidUniswapCallback();
    }
}
