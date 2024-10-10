// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PanopticMath} from "@libraries/PanopticMath.sol";
import {TokenId} from "@types/TokenId.sol";
import "../core/SemiFungiblePositionManager.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

contract ReenterBurn {
    // ensure storage conflicts don't occur with etched contract
    uint256[65535] private __gap;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    Slot0 public slot0;

    int24 public tickSpacing;

    address public token0;
    address public token1;
    uint24 public fee;

    bool activated;

    function construct(
        Slot0 memory _slot0,
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) public {
        slot0 = _slot0;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    fallback() external {
        bool reenter = !activated;
        activated = true;

        PoolKey memory key;
        if (reenter)
            SemiFungiblePositionManagerHarness(msg.sender).burnTokenizedPosition(
                key,
                TokenId.wrap(0),
                0,
                0,
                0
            );
    }
}

contract ReenterMint {
    // ensure storage conflicts don't occur with etched contract
    uint256[65535] private __gap;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    Slot0 public slot0;

    int24 public tickSpacing;

    address public token0;
    address public token1;
    uint24 public fee;

    bool activated;

    function construct(
        Slot0 memory _slot0,
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) public {
        slot0 = _slot0;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    fallback() external {
        bool reenter = !activated;
        activated = true;

        PoolKey memory key;
        if (reenter)
            SemiFungiblePositionManagerHarness(msg.sender).mintTokenizedPosition(
                key,
                TokenId.wrap(0),
                0,
                0,
                0
            );
    }
}

// through ERC1155 transfer
contract Reenter1155Initialize {
    // ensure storage conflicts don't occur with etched contract
    uint256[65535] private __gap;

    PoolKey key;

    bool activated;

    function construct(PoolKey memory _key) public {
        key = _key;
    }

    function extsload(bytes32 slot) public view returns (bytes32 ret) {
        assembly {
            ret := sload(slot)
        }
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public returns (bytes4) {
        bool reenter = !activated;
        activated = true;

        if (reenter) SemiFungiblePositionManagerHarness(msg.sender).initializeAMMPool(key);
        if (reenter)
            SemiFungiblePositionManagerHarness(msg.sender).mintTokenizedPosition(
                key,
                TokenId.wrap(0),
                0,
                0,
                0
            );
        return this.onERC1155Received.selector;
    }
}
