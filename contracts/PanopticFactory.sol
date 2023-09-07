// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.18;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Inherited implementations
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Multicall} from "@multicall/Multicall.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// OpenZeppelin libraries
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
// Libraries
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
// Custom types
import {TokenId} from "@types/TokenId.sol";

/// @title Panoptic Factory which creates and registers Panoptic Pools.
/// @author Axicon Labs Limited
/// @notice Mimics the Uniswap v3 factory pool creation pattern.
/// @notice Allows anyone to create a Panoptic Pool.
contract PanopticFactory is ReentrancyGuard, ERC1155, Multicall {
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
    /// @param rareNftId The id of the Factory-issued rare NFT minted as part of deploying the Panoptic pool (NOT the option position in the SFPM).
    /// @param rarity The rarity of the deployed Panoptic Pool (associated with a rare NFT).
    /// @param amount0 of token0 deployed at full range.
    /// @param amount1 of token1 deployed at full range.
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
    /// @dev needed to construct genesisId
    using TokenId for uint256; // an option position

    /*//////////////////////////////////////////////////////////////
                         CONSTANTS & IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @dev the Uniswap v3 factory contract to use
    IUniswapV3Factory internal immutable univ3Factory;

    /// @dev the Semi Fungible Position Manager (sfpm) which tracks option positions across Panoptic Pools
    SemiFungiblePositionManager internal immutable sfpm;

    /// @dev Reference implementation of the panoptic pool to clone
    address internal immutable POOL_REFERENCE;

    /// @dev Reference implementation of the collateral token to clone
    address internal immutable COLLATERAL_REFERENCE;

    /// @dev WETH smart contract address
    address internal immutable WETH;

    /// @dev An amount that's deployed when initializing the SFPM against a new AMM pool.
    /// If we know one of the tokens is WETH, we deploy 0.1 ETH worth in tokens.
    uint256 internal constant FULL_RANGE_LIQUIDITY_AMOUNT_WETH = 0.1 ether;

    /// @dev An amount that's deployed when initializing the SFPM against a new AMM pool.
    /// Deploy 1e6 worth of tokens if not WETH.
    uint256 internal constant FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN = 1e6;

    /// @dev the increase in observation cardinality when a new PanopticPool is deployed
    uint16 internal constant CARDINALITY_INCREASE = 100;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev the owner of the Panoptic Factory
    address internal s_factoryOwner;

    /// @dev Mapping from address(UniswapV3Pool) to address(PanopticPool) that stores the address of all deployed panoptic pools
    mapping(IUniswapV3Pool univ3pool => PanopticPool panopticPool) internal s_getPanopticPool;

    /// @dev The ID of the next token that will be minted (skips 0)
    uint256 internal s_nextId = 1;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Construct the Panoptic Factory.
    /// @dev This is meant to be a one-time operation. We have one factory spinning out Panoptic Pools.
    /// @notice This factory mimics the Uniswap v3 factory.
    /// @notice Anyone can spin up Panoptic Pools readily using the factory pattern,
    /// akin to how Uniswap pools can be spun up using the Uniswap factory pattern.
    /// @param _WETH9 The Wrapped Ether contract address.
    /// @param _SFPM The semi fungible position manager keeping track of all options positions of users.
    /// @param _univ3Factory The uniswap v3 factory used to get and confirm existing uniswap v3 pool details.
    /// @param _poolReference The reference implementation of the Panoptic Pool to clone.
    /// @param _collateralReference The reference implementation of the Collateral Token to clone.
    constructor(
        address _WETH9,
        SemiFungiblePositionManager _SFPM,
        IUniswapV3Factory _univ3Factory,
        address _poolReference,
        address _collateralReference
    ) ERC1155("") {
        // Set the WETH contract address
        WETH = _WETH9;

        // Set the contract owner to the account the deployed the factory contract
        s_factoryOwner = _msgSender();

        // deploy base pool contract to use as reference
        sfpm = _SFPM;

        // We store the Uniswap Factory contract - later we can use this to verify uniswap pools
        univ3Factory = _univ3Factory;

        // Import the Panoptic Pool reference (for cloning)
        POOL_REFERENCE = _poolReference;

        // Import the Collateral Tracker reference (for cloning)
        COLLATERAL_REFERENCE = _collateralReference;

        emit OwnerChanged(address(0), _msgSender());
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensure that only the Panoptic Factory owner can call a function.
    modifier onlyOwner() {
        if (_msgSender() != s_factoryOwner) revert Errors.NotOwner();
        _;
    }

    /// @notice Set the owner of the Panoptic Factory.
    /// @notice emits an OwnerChanged event.
    /// @param newOwner the new owner of the Panoptic Factory
    function setOwner(address newOwner) external nonReentrant onlyOwner {
        address currentOwner = s_factoryOwner;

        // change the owner
        s_factoryOwner = newOwner;

        emit OwnerChanged(currentOwner, newOwner);
    }

    /// @notice Get the address of the owner of this Panoptic Factory.
    /// @return the address which owns this Panoptic Factory.
    function factoryOwner() external view returns (address) {
        return s_factoryOwner;
    }

    /*//////////////////////////////////////////////////////////////
                           CALLBACK HANDLERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called after minting liquidity to a position.
    /// @dev Pays the pool tokens owed for the minted liquidity from the payer (always the caller)
    /// @param amount0Owed The amount of token0 due to the pool for the minted liquidity
    /// @param amount1Owed The amount of token1 due to the pool for the minted liquidity
    /// @param data Contains the payer address and the pool features required to validate the callback
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        // Decode the mint callback data
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));
        // Validate caller to ensure we got called from the AMM pool
        CallbackLib.validateCallback(msg.sender, address(univ3Factory), decoded.poolFeatures);

        // Sends the amount0Owed and amount1Owed quantities provided
        if (amount0Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token0,
                decoded.payer,
                _msgSender(),
                amount0Owed
            );
        if (amount1Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token1,
                decoded.payer,
                _msgSender(),
                amount1Owed
            );
    }

    /*//////////////////////////////////////////////////////////////
                            POOL DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new Panoptic Pool linked to the given Uniswap pool identified uniquely by the incoming parameters.
    /// @notice NOTE: If called by a contract, the caller must implement {IERC1155Receiver-onERC1155Received}
    /// and return the acceptance magic value!
    /// @notice There is a 1:1 mapping between a Panoptic Pool and a Uniswap Pool.
    /// @dev A Uniswap pool is uniquely given by its tokens and the fee.
    /// @param token0 Address of token0 for the underlying Uniswap v3 pool.
    /// @param token1 Address of token1 for the underlying Uniswap v3 pool.
    /// @param fee The fee level of the underlying Uniswap v3 pool, denominated in hundredths of bips.
    /// @param salt User-defined salt used in CREATE2.
    /// @return newPoolContract The interface of the newly deployed Panoptic pool.
    function deployNewPool(
        address token0,
        address token1,
        uint24 fee,
        uint96 salt
    ) external nonReentrant returns (PanopticPool newPoolContract) {
        // order the tokens, if necessary:
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        // get the uniswap pool corresponding to the incoming tokens and fee
        IUniswapV3Pool v3Pool = _getUniswapPool(token0, token1, fee);
        if (address(v3Pool) == address(0)) revert Errors.UniswapPoolNotInitialized(); // the uniswap pool needs to exist

        if (address(s_getPanopticPool[v3Pool]) != address(0))
            revert Errors.PoolAlreadyInitialized();

        int24 tickSpacing = v3Pool.tickSpacing();
        // The tickSpacing is assumed to be 2x the fee, which is not true for all pools (such as 1bps)
        if (uint24(tickSpacing) != fee / 50) revert Errors.UniswapPoolNotSupported();

        // This creates a new Panoptic Pool
        // Create the new proxy clone for pool management
        // Set the pool address (can only be done once)
        // Address is computed deterministically using the v3Pool, the deployer address and a user-defined salt
        // Users can specify a salt, the aim is to incentivize the mining of addresses with leading zeros
        newPoolContract = PanopticPool(
            POOL_REFERENCE.cloneDeterministic(_getSalt(address(v3Pool), _msgSender(), salt))
        );

        CollateralTracker collateralTracker0 = CollateralTracker(
            Clones.clone(COLLATERAL_REFERENCE)
        );
        collateralTracker0.startToken(token0, v3Pool, newPoolContract);

        CollateralTracker collateralTracker1 = CollateralTracker(
            Clones.clone(COLLATERAL_REFERENCE)
        );
        collateralTracker1.startToken(token1, v3Pool, newPoolContract);

        // pass in current tick of uniswap pool to initalize Panoptic's median TWAP
        (, int24 currentTick, , , , , ) = v3Pool.slot0();

        // connect the panoptic pool with the underlying univ3 pool
        s_getPanopticPool[v3Pool] = newPoolContract;
        newPoolContract.startPool(
            v3Pool,
            tickSpacing,
            currentTick,
            token0,
            token1,
            collateralTracker0,
            collateralTracker1
        );

        /*//////////////////////////////////////////////////////////////
         FULL-RANGE LIQUIDITY DEPLOYMENT, INITIAL COLLATERAL DEPOSITS, AND NFT LOGIC
        //////////////////////////////////////////////////////////////*/

        // Mints the full-range initial deposit
        // which is why the deployer becomes also a "donor" of full-range liquidity
        // NOTE: make sure the donor has the funds necessary to deploy this liquidity
        // Behind the scenes the SFPM will move the required full-range liquidity from the donor to the Uniswap pool
        // (identified uniquely by token0, token1, and fee).
        sfpm.initializeAMMPool(token0, token1, fee);

        // Full-Range Liquidity Deployment on Genesis
        (uint256 amount0, uint256 amount1) = _mintFullRange(
            v3Pool,
            token0,
            token1,
            fee,
            tickSpacing
        );

        // Increase the observation cardinality by CARDINALITY_INCREASE in the UniswapV3Pool
        v3Pool.increaseObservationCardinalityNext(CARDINALITY_INCREASE);

        /*
        NFT type = ending character:
        0  : naked option
        1  : spread
        2  : jade lizard
        3  : straddle
        4  : iron butterfly
        5  : iron condor
        6  : super-bull
        7  : calendar
        8  : covered position
        9  : super-bear
        a  : ZEBRA
        b  : bat
        v  : strangle
        d  : big lizard
        e  : ratio spread 
        f  : ZEEHBS 
        
        Mint NFT according to its rarity.
        0x0000babababab...
             ▲
             │
        Leading zeros (= rarity):
        0  : COMMUN
        1  : RARE
        2  : EPIQUE
        3  : MYTHIQUE
        4  : LEGENDAIRE
        5  : FANTASMAGORIQUE
        6  : AGATHIQUE
        7  : QUIXOTIQUE
        8  : UTOPIQUE
        9  : VITALIQUE
        10 : ETHERONIQUE
        11 : PROMETHEIQUE
        12 : ATOMIQUE
        13 : QUANTIQUE
        14 : LEPTONIQUE
        15 : QUARKTIQUE
        16 : BRANIQUE
        17 : CONIQUE
        18 : COMIQUE
        19 : STEREOTYPIQUE
        20+: BASIQUE
        */
        uint256 rarity = PanopticMath.numberOfLeadingHexZeros(address(newPoolContract));
        uint256 tokenId = _issueNFTToDonor();

        emit PoolDeployed(
            newPoolContract,
            v3Pool,
            collateralTracker0,
            collateralTracker1,
            tokenId,
            rarity,
            amount0,
            amount1
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Find the salt which would give a Panoptic Pool the highest rarity within the search parameters.
    /// The rarity is defined in terms of how many leading hex characters that are zero the Panoptic pool address has.
    /// The salt parameter returned is then needed as a next step as input to 'deployNewPool(...)' to ensure the found rarity.
    /// @dev Anyone can create a new Panoptic Pool. Rare addresses of said pools will get a rare NFT.
    /// @param token0  Address of token0 for the underlying Uniswap v3 pool.
    /// @param token1  Address of token1 for the underlying Uniswap v3 pool.
    /// @param fee The fee level of the of the underlying Uniswap v3 pool, denominated in hundredths of bips.
    /// @param salt Optional salt value to start from (can be zero).
    /// @param deployer Address of the deployer.
    /// @param loops The number of mining operations starting from 'salt' in trying to find the highest rarity.
    /// @param minTargetRarity The minimum target rarity to mine for. The internal loop stops when this is reached *or* when no more iterations.
    /// @return bestSalt The salt of the rarest pool (potentially at the specified minimum target).
    /// @return highestRarity The highest rarity found.
    function minePoolAddress(
        address token0,
        address token1,
        uint24 fee,
        uint96 salt,
        address deployer,
        uint256 loops,
        uint256 minTargetRarity
    ) external view returns (uint96 bestSalt, uint256 highestRarity) {
        IUniswapV3Pool v3Pool = _getUniswapPool(token0, token1, fee);
        if (deployer == address(0)) deployer = _msgSender();

        // Create the new proxy clone for pool management
        // Set the pool address (can only be done once)
        address newPoolAddress;
        uint256 rarity;
        // Start at the given 'salt' value (a checkpoint used to continue mining across multiple calls)
        // Stores the first salt which generated the address of highest rarity
        bestSalt = salt;

        // Runs until 'bestSalt' reaches 'minTargetRarity' or for 'loops', whichever comes first
        uint256 maxLoops = salt + loops;
        for (uint96 nonce = salt; nonce < maxLoops; ) {
            // get the address we will obtain when using clonedeterministic with this salt value
            newPoolAddress = POOL_REFERENCE.predictDeterministicAddress(
                _getSalt(address(v3Pool), deployer, nonce)
            );
            rarity = PanopticMath.numberOfLeadingHexZeros(newPoolAddress);

            if (rarity > highestRarity) {
                // found a more rare address at this nonce
                highestRarity = rarity;
                bestSalt = nonce;
            }

            if (rarity >= minTargetRarity) {
                // desired target met
                highestRarity = rarity;
                bestSalt = nonce;
                break;
            }
            unchecked {
                ++nonce;
            }
        }
        return (bestSalt, highestRarity);
    }

    /// @notice Seeds Uniswap V3 pool with a full-tick-range liquidity deployment using funds from caller.
    /// @param v3Pool The address of the Uniswap V3 pool to deploy liquidity in.
    /// @param token0 The address of the first token in the Uniswap V3 pool.
    /// @param token1 The address of the second token in the Uniswap V3 pool.
    /// @param fee The fee level of the of the underlying Uniswap v3 pool, denominated in hundredths of bips
    /// @param tickSpacing The tick spacing of the underlying Uniswap v3 pool
    /// @return the amount of token0 deployed at full range
    /// @return the amount of token1 deployed at full range
    function _mintFullRange(
        IUniswapV3Pool v3Pool,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (uint256, uint256) {
        // get current tick
        (uint160 currentSqrtPriceX96, , , , , , ) = v3Pool.slot0();

        // build callback data
        bytes memory mintdata = abi.encode(
            CallbackLib.CallbackData({ // compute by reading values from univ3pool every time
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: token0,
                        token1: token1,
                        fee: fee
                    }),
                    payer: _msgSender()
                })
        );

        // For full range: L = Δx * sqrt(P) = Δy / sqrt(P)
        // We start with fixed delta amounts and apply this equation to calculate the liquidity
        uint128 fullRangeLiquidity;
        unchecked {
            // Since we know one of the tokens is WETH, we simply add 0.1 ETH + worth in tokens
            if (token0 == WETH) {
                fullRangeLiquidity = uint128(
                    (FULL_RANGE_LIQUIDITY_AMOUNT_WETH * currentSqrtPriceX96) / Constants.FP96
                );
            } else if (token1 == WETH) {
                fullRangeLiquidity = uint128(
                    (FULL_RANGE_LIQUIDITY_AMOUNT_WETH * Constants.FP96) / currentSqrtPriceX96
                );
            } else {
                // Find the resulting liquidity for providing 1e6 of both tokens
                uint128 liquidity0 = uint128(
                    (FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN * currentSqrtPriceX96) / Constants.FP96
                );
                uint128 liquidity1 = uint128(
                    (FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN * Constants.FP96) / currentSqrtPriceX96
                );

                // Pick the greater of the liquidities - i.e the more "expensive" option
                // This ensures that the liquidity added is sufficiently large
                fullRangeLiquidity = liquidity0 > liquidity1 ? liquidity0 : liquidity1;
            }
        }

        /// mint the required amount in the Uniswap pool
        /// this triggers the uniswap mint callback function
        return
            IUniswapV3Pool(v3Pool).mint(
                address(this),
                (Constants.MIN_V3POOL_TICK / tickSpacing) * tickSpacing,
                (Constants.MAX_V3POOL_TICK / tickSpacing) * tickSpacing,
                fullRangeLiquidity,
                mintdata
            );
    }

    /// @notice Issue an NFT to the creator of the new Panoptic pool - the donor of genesis full-range liquidity.
    /// @return tokenId the ID of the NFT issued to the creator of the new Panoptic pool.
    function _issueNFTToDonor() internal returns (uint256 tokenId) {
        // It costs 0.1 ETH to deploy a new Panoptic Pool - that liquidity becomes background liquidity ("v2-esque")
        // in return, and only when using this factory (as opposed to the sfpm directly)
        // does the initializor get a rare NFT.
        // Mint (rare) NFT to deployer ('msg.sender'):
        tokenId = s_nextId++;

        // give the creator an NFT;
        // note: if contract is a creator, they must implement onERC1155Received
        _mint(_msgSender(), tokenId, 1, "");
    }

    /// @notice Return the Uniswap v3 pool from the Uniswap factory corresponding to the incoming pool parameters.
    /// @param _token0 The token0 of the pool requested from the Uniswap factory.
    /// @param _token1 The token1 of the pool requested from the Uniswap factory.
    /// @param _fee The fee level of the of the underlying Uniswap v3 pool, denominated in hundredths of bips.
    /// @return The address of the Uniswap v3 pool from the Uniswap factory corresponding to the incoming pool parameters.
    function _getUniswapPool(
        address _token0,
        address _token1,
        uint24 _fee
    ) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(univ3Factory.getPool(address(_token0), address(_token1), _fee));
    }

    /// @notice Get a salt value to use with the clone deterministic pattern.
    /// @param _v3Pool The Uniswap v3 pool address / implementation.
    /// @param _deployer The deployer of the contract.
    /// @param _nonce A nonce used in the context of mining rarity.
    /// @return A value to use with clone deterministic (in the context of 'minePoolAddress').
    function _getSalt(
        address _v3Pool,
        address _deployer,
        uint96 _nonce
    ) internal pure returns (bytes32) {
        return
            bytes32(
                abi.encodePacked(
                    PanopticMath.getPoolId(_v3Pool),
                    uint64(uint160(_deployer)),
                    _nonce
                )
            );
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the address of the Panoptic Pool associated with 'univ3pool'.
    /// @param univ3pool the Uniswap V3 pool address that 'panopticPool' is associated with.
    /// @return address of the Panoptic Pool associated with 'univ3pool'.
    function getPanopticPool(IUniswapV3Pool univ3pool) external view returns (PanopticPool) {
        return s_getPanopticPool[univ3pool];
    }
}
