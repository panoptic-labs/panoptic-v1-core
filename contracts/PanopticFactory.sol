// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.18;

/// @title Panoptic Factory which creates and registers Panoptic Pools.
/// @author Axicon Labs Limited
/// @notice Mimics the Uniswap v3 factory pool creation pattern.
/// @notice Allows anyone to create a Panoptic Pool.
interface PanopticFactory {
    /// @notice Get the address of the owner of this Panoptic Factory.
    /// @return the address which owns this Panoptic Factory.
    function factoryOwner() external view returns (address);
}
