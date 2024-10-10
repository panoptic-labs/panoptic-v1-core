// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";
// Inherited implementations
import {Multicall} from "@base/Multicall.sol";
import {FactoryNFT} from "@base/FactoryNFT.sol";
// External libraries
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
// Internal libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
// Custom types
import {Pointer} from "@types/Pointer.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

/// @title Panoptic Factory which creates and registers Panoptic Pools.
/// @author Axicon Labs Limited
/// @notice Facilitates deployment of Panoptic pools.
contract PanopticFactory is FactoryNFT, Multicall {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a Panoptic Pool is created.
    /// @param poolAddress Address of the deployed Panoptic pool
    /// @param oracleContract The external oracle contract used by the newly deployed Panoptic Pool
    /// @param poolKey The Uniswap V4 pool key associated with the Panoptic Pool
    /// @param collateralTracker0 Address of the collateral tracker contract for token0
    /// @param collateralTracker1 Address of the collateral tracker contract for token1
    /// @param amount0 The amount of token0 deployed at full range
    /// @param amount1 The amount of token1 deployed at full range
    event PoolDeployed(
        PanopticPool indexed poolAddress,
        IV3CompatibleOracle indexed oracleContract,
        PoolKey poolKey,
        CollateralTracker collateralTracker0,
        CollateralTracker collateralTracker1,
        uint256 amount0,
        uint256 amount1
    );

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    using ClonesWithImmutableArgs for address;

    /*//////////////////////////////////////////////////////////////
                         CONSTANTS & IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice The canonical Uniswap V4 Pool Manager address.
    IPoolManager internal immutable POOL_MANAGER_V4;

    /// @notice The Semi Fungible Position Manager (SFPM) which tracks option positions across Panoptic Pools.
    SemiFungiblePositionManager internal immutable SFPM;

    /// @notice Reference implementation of the `PanopticPool` to clone.
    address internal immutable POOL_REFERENCE;

    /// @notice Reference implementation of the `CollateralTracker` to clone.
    address internal immutable COLLATERAL_REFERENCE;

    /// @notice Address of the Wrapped Ether (or other numeraire token) contract.
    address internal immutable WETH;

    /// @notice An amount of `WETH` deployed when initializing the SFPM against a new AMM pool.
    /// @dev If we know one of the tokens is WETH, we deploy 0.1 ETH worth in tokens.
    uint256 internal constant FULL_RANGE_LIQUIDITY_AMOUNT_WETH = 0.1 ether;

    /// @notice An amount of another token that's deployed when initializing the SFPM against a new AMM pool.
    /// @dev Deploy 1e6 worth of tokens if not WETH.
    uint256 internal constant FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN = 1e6;

    /// @notice The `observationCardinalityNext` to set on the Uniswap pool when a new PanopticPool is deployed.
    uint16 internal constant CARDINALITY_INCREASE = 51;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping from keccak256(Uniswap V4 pool id, oracle contract address) to address(PanopticPool) that stores the address of all deployed Panoptic Pools.
    mapping(bytes32 panopticPoolKey => PanopticPool panopticPool) internal s_getPanopticPool;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set immutable variables and store metadata pointers.
    /// @param _WETH9 Address of the Wrapped Ether (or other numeraire token) contract
    /// @param _SFPM The canonical `SemiFungiblePositionManager` deployment
    /// @param manager The canonical Uniswap V4 pool manager
    /// @param _poolReference The reference implementation of the `PanopticPool` to clone
    /// @param _collateralReference The reference implementation of the `CollateralTracker` to clone
    /// @param properties An array of identifiers for different categories of metadata
    /// @param indices A nested array of keys for K-V metadata pairs for each property in `properties`
    /// @param pointers Contains pointers to the metadata values stored in contract data slices for each index in `indices`
    constructor(
        address _WETH9,
        SemiFungiblePositionManager _SFPM,
        IPoolManager manager,
        address _poolReference,
        address _collateralReference,
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    ) FactoryNFT(properties, indices, pointers) {
        WETH = _WETH9;
        SFPM = _SFPM;
        POOL_MANAGER_V4 = manager;
        POOL_REFERENCE = _poolReference;
        COLLATERAL_REFERENCE = _collateralReference;
    }

    /*//////////////////////////////////////////////////////////////
                        UNISWAP V4 LOCK CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V4 unlock callback implementation.
    /// @dev Parameters are `(PoolKey key, int24 tickLower, int24 tickUpper, uint128 liquidity, address payer)`.
    /// @dev Adds `liquidity` to the Uniswap V4 pool `key` at `tickLower-tickUpper` and transfers the tokens from `payer`.
    /// @param data The encoded data containing the input parameters
    /// @return `(uint256 token0Delta, uint256 token1Delta)` The amount of token0 and token1 used to create `liquidity` in the Uniswap pool
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER_V4)) revert Errors.UnauthorizedUniswapCallback();

        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            address payer
        ) = abi.decode(data, (PoolKey, int24, int24, uint128, address));
        (BalanceDelta delta, BalanceDelta feesAccrued) = POOL_MANAGER_V4.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                tickLower,
                tickUpper,
                int256(uint256(liquidity)),
                bytes32(0)
            ),
            ""
        );

        if (delta.amount0() < 0) {
            POOL_MANAGER_V4.sync(key.currency0);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency0),
                payer,
                address(POOL_MANAGER_V4),
                uint128(-delta.amount0())
            );
            POOL_MANAGER_V4.settle();
        } else if (delta.amount0() > 0) {
            POOL_MANAGER_V4.clear(key.currency0, uint128(delta.amount0()));
        }

        if (delta.amount1() < 0) {
            POOL_MANAGER_V4.sync(key.currency1);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency1),
                payer,
                address(POOL_MANAGER_V4),
                uint128(-delta.amount1())
            );
            POOL_MANAGER_V4.settle();
        } else if (delta.amount1() > 0) {
            POOL_MANAGER_V4.clear(key.currency1, uint128(delta.amount1()));
        }

        return
            abi.encode(
                feesAccrued.amount0() - delta.amount0(),
                feesAccrued.amount1() - delta.amount1()
            );
    }

    /*//////////////////////////////////////////////////////////////
                            POOL DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new Panoptic Pool linked to the given Uniswap pool identified uniquely by the incoming parameters.
    /// @dev There is a 1:1 mapping between a Panoptic Pool and a Uniswap Pool.
    /// @dev A Uniswap pool is uniquely identified by its tokens and the fee.
    /// @dev Salt used in PanopticPool creation is `[leading 20 msg.sender chars][uint80(uint256(keccak256(abi.encode(V4PoolKey, oracleContractAddress))))][salt]`.
    /// @param oracleContract The external oracle contract to be used by the newly deployed Panoptic Pool
    /// @param key The Uniswap V4 pool key
    /// @param salt User-defined component of salt used in deployment process for the PanopticPool
    /// @param amount0Max The maximum amount of token0 to spend on the full-range deployment
    /// @param amount1Max The maximum amount of token1 to spend on the full-range deployment
    /// @return newPoolContract The address of the newly deployed Panoptic pool
    function deployNewPool(
        IV3CompatibleOracle oracleContract,
        PoolKey calldata key,
        uint96 salt,
        uint256 amount0Max,
        uint256 amount1Max
    ) external returns (PanopticPool newPoolContract) {
        bytes32 panopticPoolKey = keccak256(abi.encode(key, oracleContract));

        if (V4StateReader.getSqrtPriceX96(POOL_MANAGER_V4, key.toId()) == 0)
            revert Errors.UniswapPoolNotInitialized();

        if (address(s_getPanopticPool[panopticPoolKey]) != address(0))
            revert Errors.PoolAlreadyInitialized();

        // initialize pool in SFPM if it has not already been initialized
        SFPM.initializeAMMPool(key);

        // Users can specify a salt, the aim is to incentivize the mining of addresses with leading zeros
        // salt format: (first 20 characters of deployer address) + (hash of pool key and oracle contract address) + (uint96 user supplied salt)
        bytes32 salt32 = bytes32(
            abi.encodePacked(
                uint80(uint160(msg.sender) >> 80),
                uint80(uint256(panopticPoolKey)),
                salt
            )
        );

        // using CREATE3 for the PanopticPool given we don't know some of the immutable args (`CollateralTracker` addresses)
        // this allows us to link the PanopticPool into the CollateralTrackers as an immutable arg without advance knowledge of their addresses
        newPoolContract = PanopticPool(ClonesWithImmutableArgs.addressOfClone3(salt32));

        // Deploy collateral token proxies
        CollateralTracker collateralTracker0 = CollateralTracker(
            COLLATERAL_REFERENCE.clone2(
                abi.encodePacked(
                    newPoolContract,
                    true,
                    key.currency0,
                    key.currency0,
                    key.currency1,
                    key.fee
                )
            )
        );

        CollateralTracker collateralTracker1 = CollateralTracker(
            COLLATERAL_REFERENCE.clone2(
                abi.encodePacked(
                    newPoolContract,
                    false,
                    key.currency1,
                    key.currency0,
                    key.currency1,
                    key.fee
                )
            )
        );

        // This creates a new Panoptic Pool (proxy to the PanopticPool implementation)
        newPoolContract = PanopticPool(
            POOL_REFERENCE.clone3(
                abi.encodePacked(
                    collateralTracker0,
                    collateralTracker1,
                    oracleContract,
                    key.toId(),
                    abi.encode(key)
                ),
                salt32
            )
        );

        newPoolContract.initialize();
        collateralTracker0.initialize();
        collateralTracker1.initialize();

        s_getPanopticPool[panopticPoolKey] = newPoolContract;

        // The Panoptic pool won't be safe to use until the observation cardinality is at least CARDINALITY_INCREASE
        // If this is not the case, we increase the next cardinality during deployment so the cardinality can catch up over time
        // When that happens, there will be a period of time where the PanopticPool is deployed, but not (safely) usable
        oracleContract.increaseObservationCardinalityNext(CARDINALITY_INCREASE);

        // Mints the full-range initial deposit
        // which is why the deployer becomes also a "donor" of full-range liquidity
        (uint256 amount0, uint256 amount1) = _mintFullRange(key, key.toId());

        if (amount0 > amount0Max || amount1 > amount1Max) revert Errors.PriceBoundFail();

        // Issue reward NFT to donor
        uint256 tokenId = uint256(uint160(address(newPoolContract)));
        _mint(msg.sender, tokenId);

        emit PoolDeployed(
            newPoolContract,
            oracleContract,
            key,
            collateralTracker0,
            collateralTracker1,
            amount0,
            amount1
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Find the salt which would give a Panoptic Pool the highest rarity within the search parameters.
    /// @dev The rarity is defined in terms of how many leading zeros the Panoptic pool address has.
    /// @dev Note that the final salt may overflow if too many loops are given relative to the amount in `salt`.
    /// @param deployerAddress Address of the account that deploys the new PanopticPool
    /// @param salt Salt value to start from, useful as a checkpoint across multiple calls
    /// @param loops The number of mining operations starting from `salt` in trying to find the highest rarity
    /// @param minTargetRarity The minimum target rarity to mine for. The internal loop stops when this is reached *or* when no more iterations
    /// @return bestSalt The salt of the rarest pool (potentially at the specified minimum target)
    /// @return highestRarity The rarity of `bestSalt`
    function minePoolAddress(
        address deployerAddress,
        address oracleContract,
        PoolKey calldata key,
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
                    uint80(uint256(keccak256(abi.encode(key, oracleContract)))),
                    salt
                )
            );

            uint256 rarity = PanopticMath.numberOfLeadingHexZeros(
                ClonesWithImmutableArgs.addressOfClone3(newSalt)
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

    /// @notice Seeds Uniswap V4 pool with a full-tick-range liquidity deployment using funds from caller.
    /// @param key The Uniswap V4 pool key
    /// @param idV4 The Uniswap V4 pool id (hash of `key`)
    /// @return The amount of token0 deployed at full range
    /// @return The amount of token1 deployed at full range
    function _mintFullRange(PoolKey memory key, PoolId idV4) internal returns (uint256, uint256) {
        uint160 currentSqrtPriceX96 = V4StateReader.getSqrtPriceX96(POOL_MANAGER_V4, idV4);

        // For full range: L = Δx * sqrt(P) = Δy / sqrt(P)
        // We start with fixed token amounts and apply this equation to calculate the liquidity
        // Note that for pools with a tickSpacing that is not a power of 2 or greater than 8 (887272 % ts != 0),
        // a position at the maximum and minimum allowable ticks will be wide, but not necessarily full-range.
        // In this case, the `fullRangeLiquidity` will always be an underestimate in respect to the token amounts required to mint.
        uint128 fullRangeLiquidity;
        unchecked {
            // Since we know one of the tokens is WETH, we simply add 0.1 ETH + worth in tokens
            if (Currency.unwrap(key.currency0) == WETH) {
                fullRangeLiquidity = uint128(
                    Math.mulDiv96RoundingUp(FULL_RANGE_LIQUIDITY_AMOUNT_WETH, currentSqrtPriceX96)
                );
            } else if (Currency.unwrap(key.currency1) == WETH) {
                fullRangeLiquidity = uint128(
                    Math.mulDivRoundingUp(
                        FULL_RANGE_LIQUIDITY_AMOUNT_WETH,
                        Constants.FP96,
                        currentSqrtPriceX96
                    )
                );
            } else {
                // Find the resulting liquidity for providing 1e6 of both tokens
                uint128 liquidity0 = uint128(
                    Math.mulDiv96RoundingUp(FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN, currentSqrtPriceX96)
                );
                uint128 liquidity1 = uint128(
                    Math.mulDivRoundingUp(
                        FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN,
                        Constants.FP96,
                        currentSqrtPriceX96
                    )
                );

                // Pick the greater of the liquidities - i.e the more "expensive" option
                // This ensures that the liquidity added is sufficiently large
                fullRangeLiquidity = liquidity0 > liquidity1 ? liquidity0 : liquidity1;
            }
        }

        // The maximum range we can mint is determined by the tickSpacing of the pool
        // The upper and lower ticks must be divisible by `tickSpacing`, so
        // tickSpacing = 1: tU/L = +/-887272
        // tickSpacing = 10: tU/L = +/-887270
        // tickSpacing = 60: tU/L = +/-887220
        // tickSpacing = 200: tU/L = +/-887200
        // etc...
        int24 tickLower;
        int24 tickUpper;
        unchecked {
            int24 tickSpacing = key.tickSpacing;
            tickLower = (Constants.MIN_V4POOL_TICK / tickSpacing) * tickSpacing;
            tickUpper = -tickLower;
        }

        return
            abi.decode(
                POOL_MANAGER_V4.unlock(
                    abi.encode(key, tickLower, tickUpper, fullRangeLiquidity, msg.sender)
                ),
                (uint256, uint256)
            );
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the address of the Panoptic Pool associated with the given Uniswap V4 pool key and oracle contract.
    /// @param keyV4 The Uniswap V4 pool key
    /// @param oracleContract The external oracle contract used by the Panoptic Pool
    /// @return Address of the Panoptic Pool on `keyV4` using `oracleContract`
    function getPanopticPool(
        PoolKey calldata keyV4,
        IV3CompatibleOracle oracleContract
    ) external view returns (PanopticPool) {
        return s_getPanopticPool[keccak256(abi.encode(keyV4, oracleContract))];
    }
}
