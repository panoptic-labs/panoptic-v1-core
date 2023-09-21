// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.18;

// Interfaces
import {CollateralTracker} from "./CollateralTracker.sol";
import {PanopticFactory} from "./PanopticFactory.sol";
import {PanopticPool} from "./PanopticPool.sol";
import {SemiFungiblePositionManager} from "./SemiFungiblePositionManager.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";

// Libraries
import {Errors} from "./libraries/Errors.sol";

// OpenZeppelin libraries
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract GatedFactory {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the owner of the factory is changed.
    /// @param oldOwner The previous owner of the factory
    /// @param newOwner The new owner of the factory
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when a Panoptic Pool is created.
    /// @param poolAddress Address of the deployed Panoptic pool.
    /// @param uniswapPool Address of the underlying Uniswap v3 pool.
    /// @param collateralTracker0 Address of the collateral tracker contract for token0.
    /// @param collateralTracker1 Address of the collateral tracker contract for token1.
    /// @param rareNftId The id of the Factory-issued rare NFT minted as part of deploying the Panoptic pool (NOT the option position in the SFPM). (*NOT USED*)
    /// @param rarity The rarity of the deployed Panoptic Pool (associated with a rare NFT). (*NOT USED*)
    /// @param amount0 of token0 deployed at full range. (*NOT USED*)
    /// @param amount1 of token1 deployed at full range. (*NOT USED*)
    event PoolDeployed(
        PanopticPool indexed poolAddress,
        IUniswapV3Pool indexed uniswapPool,
        CollateralTracker collateralTracker0,
        CollateralTracker collateralTracker1,
        uint256 rareNftId,
        uint256 indexed rarity,
        uint256 amount0,
        uint256 amount1
    );

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev Using clones for deterministic create2 contract deployment
    using Clones for address;

    /*//////////////////////////////////////////////////////////////
                         CONSTANTS & IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @dev the increase in observation cardinality when a new PanopticPool is deployed
    uint16 internal constant CARDINALITY_INCREASE = 100;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev the owner of the Panoptic Factory
    address public factoryOwner;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address owner) {
        factoryOwner = owner;
        emit OwnerChanged(address(0), owner);
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensure that only the Panoptic Factory owner can call a function.
    modifier onlyOwner() {
        if (msg.sender != factoryOwner) revert Errors.NotOwner();
        _;
    }

    /// @notice Set the owner of the Panoptic Factory.
    /// @notice emits an OwnerChanged event.
    /// @param newOwner the new owner of the Panoptic Factory
    function setOwner(address newOwner) external onlyOwner {
        address currentOwner = factoryOwner;

        // change the owner
        factoryOwner = newOwner;

        emit OwnerChanged(currentOwner, newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                            POOL DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function deployNewPool(
        IUniswapV3Pool univ3pool,
        SemiFungiblePositionManager sfpm,
        address poolReference,
        address collateralReference,
        bytes32 salt
    ) external onlyOwner returns (PanopticPool newPoolContract) {
        address token0 = univ3pool.token0();
        address token1 = univ3pool.token1();
        int24 tickSpacing = univ3pool.tickSpacing();
        (, int24 currentTick, , , , , ) = univ3pool.slot0();
        uint24 fee = univ3pool.fee();

        newPoolContract = PanopticPool(poolReference.cloneDeterministic(salt));

        CollateralTracker collateralTracker0 = CollateralTracker(collateralReference.clone());
        collateralTracker0.startToken(univ3pool.token0(), univ3pool, newPoolContract);

        CollateralTracker collateralTracker1 = CollateralTracker(collateralReference.clone());
        collateralTracker1.startToken(univ3pool.token0(), univ3pool, newPoolContract);

        newPoolContract.startPool(
            univ3pool,
            tickSpacing,
            currentTick,
            token0,
            token1,
            collateralTracker0,
            collateralTracker1
        );

        sfpm.initializeAMMPool(token0, token1, fee);

        // Increase the observation cardinality by CARDINALITY_INCREASE in the UniswapV3Pool
        univ3pool.increaseObservationCardinalityNext(CARDINALITY_INCREASE);

        emit PoolDeployed(
            newPoolContract,
            univ3pool,
            collateralTracker0,
            collateralTracker1,
            0,
            0,
            0,
            0
        );
    }
}
