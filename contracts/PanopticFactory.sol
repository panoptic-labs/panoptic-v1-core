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
// OpenZeppelin libraries
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
// Libraries
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
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
    /// @param amount0 The amount of token0 deployed at full range
    /// @param amount1 The amount of token1 deployed at full range
    event PoolDeployed(
        PanopticPool indexed poolAddress,
        IUniswapV3Pool indexed uniswapPool,
        CollateralTracker collateralTracker0,
        CollateralTracker collateralTracker1,
        uint256 amount0,
        uint256 amount1
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

    /// @notice Mapping from address(UniswapV3Pool) to address(PanopticPool) that stores the address of all deployed Panoptic Pools.
    mapping(IUniswapV3Pool univ3pool => PanopticPool panopticPool) internal s_getPanopticPool;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set immutable variables and store metadata pointers.
    /// @param _WETH9 Address of the Wrapped Ether (or other numeraire token) contract
    /// @param _SFPM The canonical `SemiFungiblePositionManager` deployment
    /// @param _univ3Factory The canonical Uniswap V3 Factory deployment
    /// @param _poolReference The reference implementation of the `PanopticPool` to clone
    /// @param _collateralReference The reference implementation of the `CollateralTracker` to clone
    /// @param properties An array of identifiers for different categories of metadata
    /// @param indices A nested array of keys for K-V metadata pairs for each property in `properties`
    /// @param pointers Contains pointers to the metadata values stored in contract data slices for each index in `indices`
    constructor(
        address _WETH9,
        SemiFungiblePositionManager _SFPM,
        IUniswapV3Factory _univ3Factory,
        address _poolReference,
        address _collateralReference,
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    ) FactoryNFT(properties, indices, pointers) {
        WETH = _WETH9;
        SFPM = _SFPM;
        UNIV3_FACTORY = _univ3Factory;
        POOL_REFERENCE = _poolReference;
        COLLATERAL_REFERENCE = _collateralReference;
    }

    /*//////////////////////////////////////////////////////////////
                           CALLBACK HANDLERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called after minting liquidity to a position.
    /// @dev Pays the pool tokens owed for the minted liquidity from the payer (always the caller).
    /// @param amount0Owed The amount of token0 due to the pool for the minted liquidity
    /// @param amount1Owed The amount of token1 due to the pool for the minted liquidity
    /// @param data Contains the payer address and the pool features required to validate the callback
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

        CallbackLib.validateCallback(msg.sender, UNIV3_FACTORY, decoded.poolFeatures);

        if (amount0Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token0,
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token1,
                decoded.payer,
                msg.sender,
                amount1Owed
            );
    }

    /*//////////////////////////////////////////////////////////////
                            POOL DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new Panoptic Pool linked to the given Uniswap pool identified uniquely by the incoming parameters.
    /// @dev There is a 1:1 mapping between a Panoptic Pool and a Uniswap Pool.
    /// @dev A Uniswap pool is uniquely identified by its tokens and the fee.
    /// @dev Salt used in PanopticPool CREATE2 is [leading 20 msg.sender chars][leading 20 pool address chars][salt].
    /// @param token0 Address of token0 for the underlying Uniswap v3 pool
    /// @param token1 Address of token1 for the underlying Uniswap v3 pool
    /// @param fee The fee tier of the underlying Uniswap v3 pool, denominated in hundredths of bips
    /// @param salt User-defined component of salt used in CREATE2 for the PanopticPool (must be a uint96 number)
    /// @param amount0Max The maximum amount of token0 to spend on the full-range deployment, which serves as a slippage check
    /// @param amount1Max The maximum amount of token1 to spend on the full-range deployment, which serves as a slippage check
    /// @return newPoolContract The address of the newly deployed Panoptic pool
    function deployNewPool(
        address token0,
        address token1,
        uint24 fee,
        uint96 salt,
        uint256 amount0Max,
        uint256 amount1Max
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
            Clones.clone(COLLATERAL_REFERENCE)
        );
        CollateralTracker collateralTracker1 = CollateralTracker(
            Clones.clone(COLLATERAL_REFERENCE)
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

        // Mints the full-range initial deposit
        // which is why the deployer becomes also a "donor" of full-range liquidity
        (uint256 amount0, uint256 amount1) = _mintFullRange(v3Pool, token0, token1, fee);

        if (amount0 > amount0Max || amount1 > amount1Max) revert Errors.PriceBoundFail();

        // Issue reward NFT to donor
        uint256 tokenId = uint256(uint160(address(newPoolContract)));
        _mint(msg.sender, tokenId);

        emit PoolDeployed(
            newPoolContract,
            v3Pool,
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
    /// @param v3Pool Address of the underlying UniswapV3Pool
    /// @param salt Salt value ([96-bit nonce]) to start from, useful as a checkpoint across multiple calls
    /// @param loops The number of mining operations starting from 'salt' in trying to find the highest rarity
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
        // Start at the given 'salt' value (a checkpoint used to continue mining across multiple calls)

        // Runs until 'bestSalt' reaches 'minTargetRarity' or for 'loops', whichever comes first
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

    /// @notice Seeds Uniswap V3 pool with a full-tick-range liquidity deployment using funds from caller.
    /// @param v3Pool The address of the Uniswap V3 pool to deploy liquidity in
    /// @param token0 The address of the first token in the Uniswap V3 pool
    /// @param token1 The address of the second token in the Uniswap V3 pool
    /// @param fee The fee level of the of the underlying Uniswap v3 pool, denominated in hundredths of bips
    /// @return The amount of token0 deployed at full range
    /// @return The amount of token1 deployed at full range
    function _mintFullRange(
        IUniswapV3Pool v3Pool,
        address token0,
        address token1,
        uint24 fee
    ) internal returns (uint256, uint256) {
        (uint160 currentSqrtPriceX96, , , , , , ) = v3Pool.slot0();

        // For full range: L = Δx * sqrt(P) = Δy / sqrt(P)
        // We start with fixed token amounts and apply this equation to calculate the liquidity
        // Note that for pools with a tickSpacing that is not a power of 2 or greater than 8 (887272 % ts != 0),
        // a position at the maximum and minimum allowable ticks will be wide, but not necessarily full-range.
        // In this case, the `fullRangeLiquidity` will always be an underestimate in respect to the token amounts required to mint.
        uint128 fullRangeLiquidity;
        unchecked {
            // Since we know one of the tokens is WETH, we simply add 0.1 ETH + worth in tokens
            if (token0 == WETH) {
                fullRangeLiquidity = uint128(
                    Math.mulDiv96RoundingUp(FULL_RANGE_LIQUIDITY_AMOUNT_WETH, currentSqrtPriceX96)
                );
            } else if (token1 == WETH) {
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
        int24 tickLower;
        int24 tickUpper;
        unchecked {
            int24 tickSpacing = v3Pool.tickSpacing();
            tickLower = (Constants.MIN_V3POOL_TICK / tickSpacing) * tickSpacing;
            tickUpper = -tickLower;
        }

        bytes memory mintCallback = abi.encode(
            CallbackLib.CallbackData({
                poolFeatures: CallbackLib.PoolFeatures({token0: token0, token1: token1, fee: fee}),
                payer: msg.sender
            })
        );

        return
            IUniswapV3Pool(v3Pool).mint(
                address(this),
                tickLower,
                tickUpper,
                fullRangeLiquidity,
                mintCallback
            );
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the address of the Panoptic Pool associated with 'univ3pool'.
    /// @param univ3pool The Uniswap V3 pool address to query
    /// @return Address of the Panoptic Pool associated with 'univ3pool'
    function getPanopticPool(IUniswapV3Pool univ3pool) external view returns (PanopticPool) {
        return s_getPanopticPool[univ3pool];
    }
}
