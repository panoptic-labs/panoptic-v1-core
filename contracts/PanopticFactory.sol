// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Inherited implementations
import {Multicall} from "@base/Multicall.sol";
import {FactoryNFT} from "@base/FactoryNFT.sol";
// External libraries
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
// Custom types
import {Pointer} from "@types/Pointer.sol";

/// @title Panoptic Factory which creates and registers Panoptic Pools.
/// @author Axicon Labs Limited
/// @notice Facilitates deployment of Panoptic pools.
contract PanopticFactory is FactoryNFT, Multicall {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a Panoptic Pool is created.
    /// @param poolAddress Address of the deployed Panoptic pool
    /// @param uniswapPool Address of the underlying Uniswap V3 pool
    /// @param collateralTracker0 Address of the collateral tracker contract for token0
    /// @param collateralTracker1 Address of the collateral tracker contract for token1
    event PoolDeployed(
        PanopticPool indexed poolAddress,
        IUniswapV3Pool indexed uniswapPool,
        CollateralTracker collateralTracker0,
        CollateralTracker collateralTracker1
    );

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    using Clones for address;

    /*//////////////////////////////////////////////////////////////
                         CONSTANTS & IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Uniswap V3 factory contract to use.
    IUniswapV3Factory internal immutable UNIV3_FACTORY;

    /// @notice The Semi Fungible Position Manager (SFPM) which tracks option positions across Panoptic Pools.
    SemiFungiblePositionManager internal immutable SFPM;

    /// @notice Reference implementation of the `PanopticPool` to clone.
    address internal immutable POOL_REFERENCE;

    /// @notice Reference implementation of the `CollateralTracker` to clone.
    address internal immutable COLLATERAL_REFERENCE;

    /// @notice The `observationCardinalityNext` to set on the Uniswap pool when a new PanopticPool is deployed.
    uint16 internal constant CARDINALITY_INCREASE = 51;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping from address(UniswapV3Pool) to address(PanopticPool) that stores the address of all deployed Panoptic Pools.
    mapping(IUniswapV3Pool univ3pool => PanopticPool panopticPool) internal s_getPanopticPool;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set immutable variables and store metadata pointers.
    /// @param _SFPM The canonical `SemiFungiblePositionManager` deployment
    /// @param _univ3Factory The canonical Uniswap V3 Factory deployment
    /// @param _poolReference The reference implementation of the `PanopticPool` to clone
    /// @param _collateralReference The reference implementation of the `CollateralTracker` to clone
    /// @param properties An array of identifiers for different categories of metadata
    /// @param indices A nested array of keys for K-V metadata pairs for each property in `properties`
    /// @param pointers Contains pointers to the metadata values stored in contract data slices for each index in `indices`
    constructor(
        SemiFungiblePositionManager _SFPM,
        IUniswapV3Factory _univ3Factory,
        address _poolReference,
        address _collateralReference,
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    ) FactoryNFT(properties, indices, pointers) {
        SFPM = _SFPM;
        UNIV3_FACTORY = _univ3Factory;
        POOL_REFERENCE = _poolReference;
        COLLATERAL_REFERENCE = _collateralReference;
    }

    /*//////////////////////////////////////////////////////////////
                            POOL DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new Panoptic Pool linked to the given Uniswap pool identified uniquely by the incoming parameters.
    /// @dev There is a 1:1 mapping between a Panoptic Pool and a Uniswap Pool.
    /// @dev A Uniswap pool is uniquely identified by its tokens and the fee.
    /// @dev Salt used in PanopticPool CREATE2 is `[leading 20 msg.sender chars][leading 20 pool address chars][salt]`.
    /// @param token0 Address of token0 for the underlying Uniswap V3 pool
    /// @param token1 Address of token1 for the underlying Uniswap V3 pool
    /// @param fee The fee tier of the underlying Uniswap V3 pool, denominated in hundredths of bips
    /// @param salt User-defined component of salt used in CREATE2 for the PanopticPool (must be a uint96 number)
    /// @return newPoolContract The address of the newly deployed Panoptic pool
    function deployNewPool(
        address token0,
        address token1,
        uint24 fee,
        uint96 salt
    ) external returns (PanopticPool newPoolContract) {
        // sort the tokens, if necessary:
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        IUniswapV3Pool v3Pool = IUniswapV3Pool(UNIV3_FACTORY.getPool(token0, token1, fee));
        if (address(v3Pool) == address(0)) revert Errors.UniswapPoolNotInitialized();

        if (address(s_getPanopticPool[v3Pool]) != address(0))
            revert Errors.PoolAlreadyInitialized();

        // initialize pool in SFPM if it has not already been initialized
        SFPM.initializeAMMPool(token0, token1, fee);

        // Users can specify a salt, the aim is to incentivize the mining of addresses with leading zeros
        // salt format: (first 20 characters of deployer address) + (first 20 characters of UniswapV3Pool) + (uint96 user supplied salt)
        bytes32 salt32 = bytes32(
            abi.encodePacked(
                uint80(uint160(msg.sender) >> 80),
                uint80(uint160(address(v3Pool)) >> 80),
                salt
            )
        );

        // This creates a new Panoptic Pool (proxy to the PanopticPool implementation)
        newPoolContract = PanopticPool(POOL_REFERENCE.cloneDeterministic(salt32));

        // Deploy collateral token proxies
        CollateralTracker collateralTracker0 = CollateralTracker(
            COLLATERAL_REFERENCE.cloneDeterministic(bytes32(uint256(salt32) + 1))
        );
        CollateralTracker collateralTracker1 = CollateralTracker(
            COLLATERAL_REFERENCE.cloneDeterministic(bytes32(uint256(salt32) + 2))
        );

        // Run state initialization sequence for pool and collateral tokens
        collateralTracker0.startToken(true, token0, token1, fee, newPoolContract);
        collateralTracker1.startToken(false, token0, token1, fee, newPoolContract);

        newPoolContract.startPool(v3Pool, token0, token1, collateralTracker0, collateralTracker1);

        s_getPanopticPool[v3Pool] = newPoolContract;

        // The Panoptic pool won't be safe to use until the observation cardinality is at least CARDINALITY_INCREASE
        // If this is not the case, we increase the next cardinality during deployment so the cardinality can catch up over time
        // When that happens, there will be a period of time where the PanopticPool is deployed, but not (safely) usable
        v3Pool.increaseObservationCardinalityNext(CARDINALITY_INCREASE);

        // Issue reward NFT to donor
        uint256 tokenId = uint256(uint160(address(newPoolContract)));
        _mint(msg.sender, tokenId);

        emit PoolDeployed(newPoolContract, v3Pool, collateralTracker0, collateralTracker1);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Find the salt which would give a Panoptic Pool the highest rarity within the search parameters.
    /// @dev The rarity is defined in terms of how many leading zeros the Panoptic pool address has.
    /// @dev Note that the final salt may overflow if too many loops are given relative to the amount in `salt`.
    /// @param deployerAddress Address of the account that deploys the new PanopticPool
    /// @param v3Pool Address of the underlying UniswapV3Pool
    /// @param salt Salt value to start from, useful as a checkpoint across multiple calls
    /// @param loops The number of mining operations starting from `salt` in trying to find the highest rarity
    /// @param minTargetRarity The minimum target rarity to mine for. The internal loop stops when this is reached *or* when no more iterations
    /// @return bestSalt The salt of the rarest pool (potentially at the specified minimum target)
    /// @return highestRarity The rarity of `bestSalt`
    function minePoolAddress(
        address deployerAddress,
        address v3Pool,
        uint96 salt,
        uint256 loops,
        uint256 minTargetRarity
    ) external view returns (uint96 bestSalt, uint256 highestRarity) {
        // Start at the given `salt` value (a checkpoint used to continue mining across multiple calls)

        // Runs until `bestSalt` reaches `minTargetRarity` or for `loops`, whichever comes first
        uint256 maxSalt;
        unchecked {
            maxSalt = uint256(salt) + loops;
        }

        for (; uint256(salt) < maxSalt; ) {
            bytes32 newSalt = bytes32(
                abi.encodePacked(
                    uint80(uint160(deployerAddress) >> 80),
                    uint80(uint160(v3Pool) >> 80),
                    salt
                )
            );

            uint256 rarity = PanopticMath.numberOfLeadingHexZeros(
                POOL_REFERENCE.predictDeterministicAddress(newSalt)
            );

            if (rarity > highestRarity) {
                // found a more rare address at this nonce
                highestRarity = rarity;
                bestSalt = salt;
            }

            if (rarity >= minTargetRarity) {
                // desired target met
                highestRarity = rarity;
                bestSalt = salt;
                break;
            }

            unchecked {
                // increment the nonce of `currentSalt` (lower 96 bits)
                salt += 1;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the address of the Panoptic Pool associated with `univ3pool`.
    /// @param univ3pool The Uniswap V3 pool address to query
    /// @return Address of the Panoptic Pool associated with `univ3pool`
    function getPanopticPool(IUniswapV3Pool univ3pool) external view returns (PanopticPool) {
        return s_getPanopticPool[univ3pool];
    }
}
