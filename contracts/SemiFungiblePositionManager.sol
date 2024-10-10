// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// Inherited implementations
import {ERC1155} from "@tokens/ERC1155Minimal.sol";
import {Multicall} from "@base/Multicall.sol";
import {TransientReentrancyGuard} from "solmate/src/utils/TransientReentrancyGuard.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
// Custom types
import {LeftRightUnsigned, LeftRightSigned, LeftRightLibrary} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";
// V4 types
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

//                                                                        ..........
//                       ,.                                   .,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,.                                    ,,
//                    ,,,,,,,                           ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,                            ,,,,,,
//                  .,,,,,,,,,,.                   ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,                     ,,,,,,,,,,,
//                .,,,,,,,,,,,,,,,             ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,.              ,,,,,,,,,,,,,,,
//               ,,,,,,,,,,,,,,.            ,,,,,,,,,,,,,,,,,,,,,,,,,,,                ,,,,,,,,,,,,,,,,,,,,,,,,,,.             ,,,,,,,,,,,,,,,
//             ,,,,,,,,,,,,,,,           ,,,,,,,,,,,,,,,,,,,,,,                                ,,,,,,,,,,,,,,,,,,,,,,            ,,,,,,,,,,,,,,,
//            ,,,,,,,,,,,,,.           ,,,,,,,,,,,,,,,,,,                                           .,,,,,,,,,,,,,,,,,,            ,,,,,,,,,,,,,,
//          ,,,,,,,,,,,,,,          ,,,,,,,,,,,,,,,,,.                                                  ,,,,,,,,,,,,,,,,,           .,,,,,,,,,,,,,
//         ,,,,,,,,,,,,,.         .,,,,,,,,,,,,,,,.                                                        ,,,,,,,,,,,,,,,,           ,,,,,,,,,,,,,.
//        ,,,,,,,,,,,,,          ,,,,,,,,,,,,,,,                                                              ,,,,,,,,,,,,,,,           ,,,,,,,,,,,,,
//       ,,,,,,,,,,,,,         ,,,,,,,,,,,,,,.                                                                  ,,,,,,,,,,,,,,           ,,,,,,,,,,,,,
//      ,,,,,,,,,,,,,         ,,,,,,,,,,,,,,                                                                      ,,,,,,,,,,,,,,          ,,,,,,,,,,,,,
//     ,,,,,,,,,,,,,         ,,,,,,,,,,,,,                                                                         ,,,,,,,,,,,,,,          ,,,,,,,,,,,,.
//    .,,,,,,,,,,,,        .,,,,,,,,,,,,,                                                                            ,,,,,,,,,,,,,          ,,,,,,,,,,,,
//    ,,,,,,,,,,,,         ,,,,,,,,,,,,                                                                               ,,,,,,,,,,,,,         .,,,,,,,,,,,,
//   ,,,,,,,,,,,,         ,,,,,,,,,,,,                                                                                 ,,,,,,,,,,,,.         ,,,,,,,,,,,,
//   ,,,,,,,,,,,,        ,,,,,,,,,,,,.                █████████  ███████████ ███████████  ██████   ██████               ,,,,,,,,,,,,          ,,,,,,,,,,,,
//  .,,,,,,,,,,,,        ,,,,,,,,,,,,                ███░░░░░███░░███░░░░░░█░░███░░░░░███░░██████ ██████                .,,,,,,,,,,,,         ,,,,,,,,,,,,
//  ,,,,,,,,,,,,        ,,,,,,,,,,,,                ░███    ░░░  ░███   █ ░  ░███    ░███ ░███░█████░███                 ,,,,,,,,,,,,         ,,,,,,,,,,,,.
//  ,,,,,,,,,,,,        ,,,,,,,,,,,,                ░░█████████  ░███████    ░██████████  ░███░░███ ░███                 .,,,,,,,,,,,          ,,,,,,,,,,,.
//  ,,,,,,,,,,,,        ,,,,,,,,,,,,                 ░░░░░░░░███ ░███░░░█    ░███░░░░░░   ░███ ░░░  ░███                  ,,,,,,,,,,,.         ,,,,,,,,,,,,
//  ,,,,,,,,,,,,        ,,,,,,,,,,,,                 ███    ░███ ░███  ░     ░███         ░███      ░███                  ,,,,,,,,,,,,         ,,,,,,,,,,,,
//  ,,,,,,,,,,,,        ,,,,,,,,,,,,                ░░█████████  █████       █████        █████     █████                 ,,,,,,,,,,,          ,,,,,,,,,,,,
//  ,,,,,,,,,,,,        ,,,,,,,,,,,,                 ░░░░░░░░░  ░░░░░       ░░░░░        ░░░░░     ░░░░░                 ,,,,,,,,,,,,          ,,,,,,,,,,,.
//  ,,,,,,,,,,,,        .,,,,,,,,,,,.                                                                                    ,,,,,,,,,,,,         ,,,,,,,,,,,,
//  .,,,,,,,,,,,,        ,,,,,,,,,,,,                                                                                   .,,,,,,,,,,,,         ,,,,,,,,,,,,
//   ,,,,,,,,,,,,        ,,,,,,,,,,,,,                                                                                  ,,,,,,,,,,,,          ,,,,,,,,,,,,
//   ,,,,,,,,,,,,.        ,,,,,,,,,,,,.                                                                                ,,,,,,,,,,,,.         ,,,,,,,,,,,,
//    ,,,,,,,,,,,,         ,,,,,,,,,,,,,                                                                              ,,,,,,,,,,,,,         .,,,,,,,,,,,,
//     ,,,,,,,,,,,,         ,,,,,,,,,,,,,                                                                            ,,,,,,,,,,,,,         .,,,,,,,,,,,,
//     .,,,,,,,,,,,,         ,,,,,,,,,,,,,                                                                         ,,,,,,,,,,,,,.          ,,,,,,,,,,,,
//      ,,,,,,,,,,,,,         ,,,,,,,,,,,,,,                                                                     .,,,,,,,,,,,,,.          ,,,,,,,,,,,,
//       ,,,,,,,,,,,,,         .,,,,,,,,,,,,,,                                                                 .,,,,,,,,,,,,,,          .,,,,,,,,,,,,
//        ,,,,,,,,,,,,,          ,,,,,,,,,,,,,,,                                                             ,,,,,,,,,,,,,,,.          ,,,,,,,,,,,,,.
//         ,,,,,,,,,,,,,,          ,,,,,,,,,,,,,,,,                                                       .,,,,,,,,,,,,,,,,           ,,,,,,,,,,,,,
//          .,,,,,,,,,,,,,           ,,,,,,,,,,,,,,,,,                                                 .,,,,,,,,,,,,,,,,,           ,,,,,,,,,,,,,,
//            ,,,,,,,,,,,,,,           ,,,,,,,,,,,,,,,,,,,.                                        ,,,,,,,,,,,,,,,,,,,.            ,,,,,,,,,,,,,,
//             ,,,,,,,,,,,,,,,            ,,,,,,,,,,,,,,,,,,,,,,                             .,,,,,,,,,,,,,,,,,,,,,,             ,,,,,,,,,,,,,,
//               ,,,,,,,,,,,,,,,            .,,,,,,,,,,,,,,,,,,,,,,,,,,,,,.        ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,             .,,,,,,,,,,,,,,.
//                 ,,,,,,,,,,,,,,.              ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,               ,,,,,,,,,,,,,,,
//                   ,,,,,,,,,,                     ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,                     .,,,,,,,,,,
//                     ,,,,,.                            ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,                             ,,,,,,
//                       ,                                     ..,,,,,,,,,,,,,,,,,,,,,,,,,,,,.

/// @author Axicon Labs Limited
/// @title Semi-Fungible Position Manager (ERC1155) - a gas-efficient Uniswap V4 position manager.
/// @notice Wraps Uniswap V4 positions with up to 4 legs behind an ERC1155 token.
/// @dev Replaces the NonfungiblePositionManager.sol (ERC721) from Uniswap Labs.
contract SemiFungiblePositionManager is ERC1155, Multicall, TransientReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a Uniswap V4 pool is initialized in the SFPM.
    /// @param poolKeyV4 The Uniswap V4 pool key
    /// @param poolId The SFPM's pool identifier for the pool, including the 16-bit tick spacing and 48-bit pool pattern
    event PoolInitialized(PoolKey indexed poolKeyV4, uint64 poolId);

    /// @notice Emitted when a position is destroyed/burned.
    /// @param recipient The address of the user who burned the position
    /// @param tokenId The tokenId of the burned position
    /// @param positionSize The number of contracts burnt, expressed in terms of the asset
    event TokenizedPositionBurnt(
        address indexed recipient,
        TokenId indexed tokenId,
        uint128 positionSize
    );

    /// @notice Emitted when a position is created/minted.
    /// @param caller The address of the user who minted the position
    /// @param tokenId The tokenId of the minted position
    /// @param positionSize The number of contracts minted, expressed in terms of the asset
    event TokenizedPositionMinted(
        address indexed caller,
        TokenId indexed tokenId,
        uint128 positionSize
    );

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    using Math for uint256;
    using Math for int256;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES 
    //////////////////////////////////////////////////////////////*/

    /// @notice Flag used to indicate a regular position mint.
    bool internal constant MINT = false;

    /// @notice Flag used to indicate that a position burn (with a burnTokenId) is occuring.
    bool internal constant BURN = true;

    /// @notice Parameter used to modify the [equation](https://www.desmos.com/calculator/mdeqob2m04) of the utilization-based multiplier for long premium.
    // ν = 1/2**VEGOID = multiplicative factor for long premium (Eqns 1-5)
    // Similar to vega in options because the liquidity utilization is somewhat reflective of the implied volatility (IV),
    // and vegoid modifies the sensitivity of the streamia to changes in that utilization,
    // much like vega measures the sensitivity of traditional option prices to IV.
    // The effect of vegoid on the long premium multiplier can be explored here: https://www.desmos.com/calculator/mdeqob2m04
    uint128 private constant VEGOID = 2;

    /// @notice The canonical Uniswap V4 Pool Manager address.
    IPoolManager internal immutable POOL_MANAGER_V4;

    /*//////////////////////////////////////////////////////////////
                            STORAGE 
    //////////////////////////////////////////////////////////////*/

    /// @notice Retrieve the corresponding SFPM poolId for a given Uniswap V4 poolId.
    /// @dev pool address => pool id + 2 ** 255 (initialization bit for `poolId == 0`, set if the pool exists)
    mapping(PoolId idV4 => uint256 poolIdData) internal s_V4toSFPMIdData;

    /// @notice Retrieve the Uniswap V4 pool key corresponding to a given poolId.
    mapping(uint64 poolId => PoolKey key) internal s_poolIdToKey;

    /*
        We're tracking the amount of net and removed liquidity for the specific region:

             net amount    
           received minted  
          ▲ for isLong=0     amount           
          │                 moved out      actual amount 
          │  ┌────┐-T      due isLong=1   in the Uniswap V4 
          │  │    │          mints          pool 
          │  │    │      
          │  │    │                        ┌────┐-(T-R)  
          │  │    │         ┌────┐-R       │    │          
          │  │    │         │    │         │    │     
          └──┴────┴─────────┴────┴─────────┴────┴──────►                     
             total=T       removed=R      net=(T-R)


     *       removed liquidity r          net liquidity N=(T-R)
     * |<------- 128 bits ------->|<------- 128 bits ------->|
     * |<---------------------- 256 bits ------------------->|
     */

    /// @notice Retrieve the current liquidity state in a chunk for a given user.
    /// @dev `removedAndNetLiquidity` is a LeftRight. The right slot represents the liquidity currently sold (added) in the AMM owned by the user and
    // the left slot represents the amount of liquidity currently bought (removed) that has been removed from the AMM - the user owes it to a seller.
    // The reason why it is called "removedLiquidity" is because long options are created by removed liquidity - ie. short selling LP positions.
    mapping(bytes32 positionKey => LeftRightUnsigned removedAndNetLiquidity)
        internal s_accountLiquidity;

    /*
        Any liquidity that has been deposited in the AMM using the SFPM will collect fees over 
        time, we call this the gross premia. If that liquidity has been removed, we also need to
        keep track of the amount of fees that *would have been collected*, we call this the owed
        premia. The gross and owed premia are tracked per unit of liquidity by the 
        s_accountPremiumGross and s_accountPremiumOwed accumulators.
        
        Here is how we can use the accumulators to compute the Gross, Net, and Owed fees collected
        by any position.

        Let`s say Charlie the smart contract deposited T into the AMM and later removed R from that
        same tick using a tokenId with a isLong=1 parameter. Because the netLiquidity is only (T-R),
        the AMM will collect fees equal to:

              net_feesCollectedX128 = feeGrowthX128 * (T - R)
                                    = feeGrowthX128 * N                                     
        
        where N = netLiquidity = T-R. Had that liquidity never been removed, we want the gross
        premia to be given by:

              gross_feesCollectedX128 = feeGrowthX128 * T

        So we must keep track of fees for the removed liquidity R so that the long premia exactly
        compensates for the fees that would have been collected from the initial liquidity.

        In addition to tracking, we also want to track those fees plus a small spread. Specifically,
        we want:

              gross_feesCollectedX128 = net_feesCollectedX128 + owed_feesCollectedX128

       where 

              owed_feesCollectedX128 = feeGrowthX128 * R * (1 + spread)                      (Eqn 1)

        A very opinionated definition for the spread is: 
              
              spread = ν*(liquidity removed from that strike)/(netLiquidity remaining at that strike)
                     = ν*R/N

        For an arbitrary parameter 0 <= ν <= 1 (ν = 1/2^VEGOID). This way, the gross_feesCollectedX128 will be given by: 

              gross_feesCollectedX128 = feeGrowthX128 * N + feeGrowthX128*R*(1 + ν*R/N) 
                                      = feeGrowthX128 * T + feesGrowthX128*ν*R^2/N         
                                      = feeGrowthX128 * T * (1 + ν*R^2/(N*T))                (Eqn 2)
        
        The s_accountPremiumOwed accumulator tracks the feeGrowthX128 * R * (1 + spread) term
        per unit of removed liquidity R every time the position touched:

              s_accountPremiumOwed += feeGrowthX128 * R * (1 + ν*R/N) / R
                                   += feeGrowthX128 * (T - R + ν*R)/N
                                   += feeGrowthX128 * T/N * (1 - R/T + ν*R/T)
         
        Note that the value of feeGrowthX128 can be extracted from the amount of fees collected by
        the smart contract since the amount of feesCollected is related to feeGrowthX128 according
        to:

             feesCollected = feesGrowthX128 * (T-R)

        So that we get:
             
             feesGrowthX128 = feesCollected/N

        And the accumulator is computed from the amount of collected fees according to:
             
             s_accountPremiumOwed += feesCollected * T/N^2 * (1 - R/T + ν*R/T)          (Eqn 3)     

        So, the amount of owed premia for a position of size r minted at time t1 and burnt at 
        time t2 is:

             owedPremia(t1, t2) = (s_accountPremiumOwed_t2-s_accountPremiumOwed_t1) * r
                                = ∆feesGrowthX128 * r * T/N * (1 - R/T + ν*R/T)
                                = ∆feesGrowthX128 * r * (T - R + ν*R)/N
                                = ∆feesGrowthX128 * r * (N + ν*R)/N
                                = ∆feesGrowthX128 * r * (1 + ν*R/N)             (same as Eqn 1)

        This way, the amount of premia owed for a position will match Eqn 1 exactly.

        Similarly, the amount of gross fees for the total liquidity is tracked in a similar manner
        by the s_accountPremiumGross accumulator. 

        However, since we require that Eqn 2 holds up-- ie. the gross fees collected should be equal
        to the net fees collected plus the ower fees plus the small spread, the expression for the
        s_accountPremiumGross accumulator has to be given by (you`ll see why in a minute): 

            s_accountPremiumGross += feesCollected * T/N^2 * (1 - R/T + ν*R^2/T^2)       (Eqn 4) 

        This expression can be used to calculate the fees collected by a position of size t between times
        t1 and t2 according to:
             
            grossPremia(t1, t2) = ∆(s_accountPremiumGross) * t
                                = ∆feeGrowthX128 * t * T/N * (1 - R/T + ν*R^2/T^2) 
                                = ∆feeGrowthX128 * t * (T - R + ν*R^2/T) / N 
                                = ∆feeGrowthX128 * t * (N + ν*R^2/T) / N
                                = ∆feeGrowthX128 * t * (1  + ν*R^2/(N*T))   (same as Eqn 2)
            
        where the last expression matches Eqn 2 exactly.

        In summary, the s_accountPremium accumulators allow smart contracts that need to handle 
        long+short liquidity to guarantee that liquidity deposited always receives the correct
        premia, whether that liquidity has been removed from the AMM or not.

        Note that the expression for the spread is extremely opinionated, and may not fit the
        specific risk management profile of every smart contract. And simply setting the ν parameter
        to zero would get rid of the "spread logic".
    */

    /// @notice Per-liquidity accumulator for the premium owed by buyers on a given chunk, tokenType and account.
    mapping(bytes32 positionKey => LeftRightUnsigned accountPremium) private s_accountPremiumOwed;

    /// @notice Per-liquidity accumulator for the premium earned by sellers on a given chunk, tokenType and account.
    mapping(bytes32 positionKey => LeftRightUnsigned accountPremium) private s_accountPremiumGross;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the canonical Uniswap V4 pool manager address.
    /// @param poolManager The canonical Uniswap V4 pool manager address
    constructor(IPoolManager poolManager) {
        POOL_MANAGER_V4 = poolManager;
    }

    /// @notice Initialize a Uniswap V4 pool in the SFPM.
    /// @dev Revert if already initialized.
    /// @param key An identifying key for a Uniswap V4 pool
    function initializeAMMPool(PoolKey calldata key) external {
        PoolId idV4 = key.toId();

        if (V4StateReader.getSqrtPriceX96(POOL_MANAGER_V4, idV4) == 0)
            revert Errors.UniswapPoolNotInitialized();

        // return if the pool has already been initialized in SFPM
        // pools can be initialized from the Panoptic Factory or by calling initializeAMMPool directly, so reverting
        // could prevent a PanopticPool from being deployed on a previously initialized but otherwise valid pool
        // if poolId == 0, we have a bit on the left set if it was initialized, so this will still return properly
        if (s_V4toSFPMIdData[idV4] != 0) return;

        // The base poolId is composed as follows:
        // [tickSpacing][pool pattern]
        // [16 bit tickSpacing][most significant 48 bits of the V4 poolId]
        uint64 poolId = PanopticMath.getPoolId(idV4, key.tickSpacing);

        // There are 281,474,976,710,655 possible pool patterns.
        // A modern GPU can generate a collision in such a space relatively quickly,
        // so if a collision is detected increment the pool pattern until a unique poolId is found
        while (s_poolIdToKey[poolId].tickSpacing != 0) {
            poolId = PanopticMath.incrementPoolPattern(poolId);
        }

        s_poolIdToKey[poolId] = key;

        // add a bit on the end to indicate that the pool is initialized
        // (this is for the case that poolId == 0, so we can make a distinction between zero and uninitialized)
        unchecked {
            s_V4toSFPMIdData[idV4] = uint256(poolId) + 2 ** 255;
        }

        emit PoolInitialized(key, poolId);
    }

    /*//////////////////////////////////////////////////////////////
                        UNISWAP V4 LOCK CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes the corresponding operations and state updates required to mint `tokenId` of `positionSize` in `key`
    /// @param key The Uniswap V4 pool key in which to mint `tokenId`
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @param positionSize The number of contracts minted, expressed in terms of the asset
    /// @param tokenId The tokenId of the minted position, which encodes information about up to 4 legs
    /// @param isBurn Flag indicating if the position is being burnt
    /// @return An array of LeftRight encoded words containing the amount of token0 and token1 collected as fees for each leg
    /// @return The net amount of token0 and token1 moved to/from the Uniswap V4 pool
    function _unlockAndCreatePositionInAMM(
        PoolKey calldata key,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        uint128 positionSize,
        TokenId tokenId,
        bool isBurn
    ) internal returns (LeftRightUnsigned[4] memory, LeftRightSigned) {
        return
            abi.decode(
                POOL_MANAGER_V4.unlock(
                    abi.encode(
                        msg.sender,
                        key,
                        tickLimitLow,
                        tickLimitHigh,
                        positionSize,
                        tokenId,
                        isBurn
                    )
                ),
                (LeftRightUnsigned[4], LeftRightSigned)
            );
    }

    /// @notice Uniswap V4 unlock callback implementation.
    /// @dev Parameters are `(PoolKey key, int24 tickLimitLow, int24 tickLimitHigh, uint128 positionSize, TokenId tokenId, bool isBurn)`.
    /// @dev Executes the corresponding operations and state updates required to mint `tokenId` of `positionSize` in `key`
    /// @dev (shorts/longs are reversed before calling this function at burn)
    /// @param data The encoded data containing the input parameters
    /// @return `(LeftRightUnsigned[4] collectedByLeg, LeftRightSigned totalMoved)` An array of LeftRight encoded words containing the amount of token0 and token1 collected as fees for each leg and the net amount of token0 and token1 moved to/from the Uniswap V4 pool
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER_V4)) revert Errors.UnauthorizedUniswapCallback();

        (
            address account,
            PoolKey memory key,
            int24 tickLimitLow,
            int24 tickLimitHigh,
            uint128 positionSize,
            TokenId tokenId,
            bool isBurn
        ) = abi.decode(data, (address, PoolKey, int24, int24, uint128, TokenId, bool));

        (
            LeftRightUnsigned[4] memory collectedByLeg,
            LeftRightSigned totalMoved
        ) = _createPositionInAMM(
                account,
                key,
                tickLimitLow,
                tickLimitHigh,
                positionSize,
                tokenId,
                isBurn
            );
        return abi.encode(collectedByLeg, totalMoved);
    }

    /*//////////////////////////////////////////////////////////////
                       PUBLIC MINT/BURN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn a new position containing up to 4 legs wrapped in a ERC1155 token.
    /// @dev Auto-collect all accumulated fees.
    /// @param key The Uniswap V4 pool key in which to burn `tokenId`
    /// @param tokenId The tokenId of the minted position, which encodes information about up to 4 legs
    /// @param positionSize The number of contracts minted, expressed in terms of the asset
    /// @param slippageTickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param slippageTickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @return An array of LeftRight encoded words containing the amount of token0 and token1 collected as fees for each leg
    /// @return The net amount of token0 and token1 moved to/from the Uniswap V4 pool
    function burnTokenizedPosition(
        PoolKey calldata key,
        TokenId tokenId,
        uint128 positionSize,
        int24 slippageTickLimitLow,
        int24 slippageTickLimitHigh
    ) external nonReentrant returns (LeftRightUnsigned[4] memory, LeftRightSigned) {
        _burn(msg.sender, TokenId.unwrap(tokenId), positionSize);

        uint256 sfpmId = s_V4toSFPMIdData[key.toId()];
        if (uint64(sfpmId) != tokenId.poolId() || sfpmId == 0)
            revert Errors.InvalidTokenIdParameter(0);

        emit TokenizedPositionBurnt(msg.sender, tokenId, positionSize);

        return
            _unlockAndCreatePositionInAMM(
                key,
                slippageTickLimitLow,
                slippageTickLimitHigh,
                positionSize,
                tokenId.flipToBurnToken(),
                BURN
            );
    }

    /// @notice Create a new position `tokenId` containing up to 4 legs.
    /// @param key The Uniswap V4 pool key in which to `tokenId`
    /// @param tokenId The tokenId of the minted position, which encodes information for up to 4 legs
    /// @param positionSize The number of contracts minted, expressed in terms of the asset
    /// @param slippageTickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param slippageTickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @return An array of LeftRight encoded words containing the amount of token0 and token1 collected as fees for each leg
    /// @return The net amount of token0 and token1 moved to/from the Uniswap V4 pool
    function mintTokenizedPosition(
        PoolKey calldata key,
        TokenId tokenId,
        uint128 positionSize,
        int24 slippageTickLimitLow,
        int24 slippageTickLimitHigh
    ) external nonReentrant returns (LeftRightUnsigned[4] memory, LeftRightSigned) {
        _mint(msg.sender, TokenId.unwrap(tokenId), positionSize);

        emit TokenizedPositionMinted(msg.sender, tokenId, positionSize);

        // verify that the tokenId is correctly formatted and conforms to all enforced constraints
        tokenId.validate();

        uint256 sfpmId = s_V4toSFPMIdData[key.toId()];
        if (uint64(sfpmId) != tokenId.poolId() || sfpmId == 0)
            revert Errors.InvalidTokenIdParameter(0);

        return
            _unlockAndCreatePositionInAMM(
                key,
                slippageTickLimitLow,
                slippageTickLimitHigh,
                positionSize,
                tokenId,
                MINT
            );
    }

    /*//////////////////////////////////////////////////////////////
                     TRANSFER HOOK IMPLEMENTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice All ERC1155 transfers are disabled.
    function safeTransferFrom(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) public pure override {
        revert();
    }

    /// @notice All ERC1155 transfers are disabled.
    function safeBatchTransferFrom(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) public pure override {
        revert();
    }

    /*//////////////////////////////////////////////////////////////
              AMM INTERACTION AND POSITION UPDATE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called to perform an ITM swap in the Uniswap pool to resolve any non-tokenType token deltas.
    /// @dev When a position is minted or burnt in-the-money (ITM) we are *not* 100% token0 or 100% token1: we have a mix of both tokens.
    /// @dev The swapping for ITM options is needed because only one of the tokens are "borrowed" by a user to create the position.
    // This is an ITM situation below (price within the range of the chunk):
    //
    //        AMM       strike
    //     liquidity   price tick
    //        ▲           │
    //        │       ┌───▼───┐
    //        │       │       │liquidity chunk
    //        │ ┌─────┴─▲─────┴─────┐
    //        │ │       │           │
    //        │ │       :           │
    //        │ │       :           │
    //        │ │       :           │
    //        └─┴───────▲───────────┴─► price
    //                  │
    //            current price
    //             in-the-money: mix of tokens 0 and 1 within the chunk
    //
    //   If we take token0 as an example, we deploy it to the AMM pool and *then* swap to get the right mix of token0 and token1
    //   to be correctly in the money at that strike.
    //   It that position is burnt, then we remove a mix of the two tokens and swap one of them so that the user receives only one.
    /// @param key The Uniswap V4 pool key in which to perform the swap
    /// @param itmAmounts How much to swap (i.e. how many tokens are ITM)
    /// @return The token deltas swapped in the AMM
    function swapInAMM(
        PoolKey memory key,
        LeftRightSigned itmAmounts
    ) internal returns (LeftRightSigned) {
        unchecked {
            bool zeroForOne; // The direction of the swap, true for token0 to token1, false for token1 to token0
            int256 swapAmount; // The amount of token0 or token1 to swap

            // unpack the in-the-money amounts
            int128 itm0 = itmAmounts.rightSlot();
            int128 itm1 = itmAmounts.leftSlot();

            // NOTE: upstream users of this function such as the Panoptic Pool should ensure users always compensate for the ITM amount delta
            // the netting swap is not perfectly accurate, and it is possible for swaps to run out of liquidity, so we do not want to rely on it
            // this is simply a convenience feature, and should be treated as such
            if ((itm0 != 0) && (itm1 != 0)) {
                // implement a single "netting" swap. Thank you @danrobinson for this puzzle/idea
                // NOTE: negative ITM amounts denote a surplus of tokens (burning liquidity), while positive amounts denote a shortage of tokens (minting liquidity)
                // compute the approximate delta of token0 that should be resolved in the swap at the current tick
                // we do this by flipping the signs on the token1 ITM amount converting+deducting it against the token0 ITM amount
                // couple examples (price = 2 1/0):
                //  - 100 surplus 0, 100 surplus 1 (itm0 = -100, itm1 = -100)
                //    normal swap 0: 100 0 => 200 1
                //    normal swap 1: 100 1 => 50 0
                //    final swap amounts: 50 0 => 100 1
                //    netting swap: net0 = -100 - (-100/2) = -50, ZF1 = true, 50 0 => 100 1
                // - 100 surplus 0, 100 shortage 1 (itm0 = -100, itm1 = 100)
                //    normal swap 0: 100 0 => 200 1
                //    normal swap 1: 50 0 => 100 1
                //    final swap amounts: 150 0 => 300 1
                //    netting swap: net0 = -100 - (100/2) = -150, ZF1 = true, 150 0 => 300 1
                // - 100 shortage 0, 100 surplus 1 (itm0 = 100, itm1 = -100)
                //    normal swap 0: 200 1 => 100 0
                //    normal swap 1: 100 1 => 50 0
                //    final swap amounts: 300 1 => 150 0
                //    netting swap: net0 = 100 - (-100/2) = 150, ZF1 = false, 300 1 => 150 0
                // - 100 shortage 0, 100 shortage 1 (itm0 = 100, itm1 = 100)
                //    normal swap 0: 200 1 => 100 0
                //    normal swap 1: 50 0 => 100 1
                //    final swap amounts: 100 1 => 50 0
                //    netting swap: net0 = 100 - (100/2) = 50, ZF1 = false, 100 1 => 50 0
                // - = Net surplus of token0
                // + = Net shortage of token0
                int256 net0 = itm0 -
                    PanopticMath.convert1to0(
                        itm1,
                        V4StateReader.getSqrtPriceX96(POOL_MANAGER_V4, key.toId())
                    );

                zeroForOne = net0 < 0;

                swapAmount = net0;
            } else if (itm0 != 0) {
                zeroForOne = itm0 < 0;
                swapAmount = itm0;
            } else {
                zeroForOne = itm1 > 0;
                swapAmount = itm1;
            }

            // NOTE: can occur if itm0 and itm1 have the same value
            // in that case, swapping would be pointless so skip
            if (swapAmount == 0) return LeftRightSigned.wrap(0);

            BalanceDelta swapDelta = POOL_MANAGER_V4.swap(
                key,
                IPoolManager.SwapParams(
                    zeroForOne,
                    swapAmount,
                    zeroForOne
                        ? Constants.MIN_V4POOL_SQRT_RATIO + 1
                        : Constants.MAX_V4POOL_SQRT_RATIO - 1
                ),
                ""
            );

            return
                LeftRightSigned.wrap(0).toRightSlot(-swapDelta.amount0()).toLeftSlot(
                    -swapDelta.amount1()
                );
        }
    }

    /// @notice Create the position in the AMM defined by `tokenId`.
    /// @dev Loops over each leg in the tokenId and calls _createLegInAMM for each, which does the mint/burn in the AMM.
    /// @param account The address of the user creating the position
    /// @param key The Uniswap V4 pool key in which to create the position
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @param positionSize The size of the option position
    /// @param tokenId The option position
    /// @param isBurn Whether a position is being minted (true) or burned (false)
    /// @return collectedByLeg An array of LeftRight encoded words containing the amount of token0 and token1 collected as fees for each leg
    /// @return totalMoved The net amount of funds moved to/from Uniswap
    function _createPositionInAMM(
        address account,
        PoolKey memory key,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        uint128 positionSize,
        TokenId tokenId,
        bool isBurn
    ) internal returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalMoved) {
        uint256 amount0;
        uint256 amount1;

        LeftRightSigned itmAmounts;

        LeftRightUnsigned totalCollected;
        for (uint256 leg = 0; leg < tokenId.countLegs(); ) {
            address _account = account;

            LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                tokenId,
                leg,
                positionSize
            );

            unchecked {
                // increment accumulators of the upper bound on tokens contained across all legs of the position at any given tick
                amount0 += Math.getAmount0ForLiquidity(liquidityChunk);

                amount1 += Math.getAmount1ForLiquidity(liquidityChunk);
            }

            PoolKey memory _key = key;
            LeftRightSigned movedLeg;
            TokenId _tokenId = tokenId;
            bool _isBurn = isBurn;

            (movedLeg, collectedByLeg[leg]) = _createLegInAMM(
                _account,
                _key,
                _tokenId,
                leg,
                liquidityChunk,
                _isBurn
            );

            totalMoved = totalMoved.add(movedLeg);
            totalCollected = totalCollected.add(collectedByLeg[leg]);

            // if tokenType is 1, and we transacted some token0: then this leg is ITM
            // if tokenType is 0, and we transacted some token1: then this leg is ITM
            itmAmounts = itmAmounts.add(
                _tokenId.tokenType(leg) == 0
                    ? LeftRightSigned.wrap(0).toLeftSlot(movedLeg.leftSlot())
                    : LeftRightSigned.wrap(0).toRightSlot(movedLeg.rightSlot())
            );

            unchecked {
                ++leg;
            }
        }

        // Ensure upper bound on amount of tokens contained across all legs of the position on any given tick does not exceed a maximum of (2**127-1).
        // This is the maximum value of the `int128` type we frequently use to hold token amounts, so a given position's size should be guaranteed to
        // fit within that limit at all times.
        if (amount0 > uint128(type(int128).max - 4) || amount1 > uint128(type(int128).max - 4))
            revert Errors.PositionTooLarge();

        if (tickLimitLow > tickLimitHigh) {
            // if the in-the-money amount is not zero (i.e. positions were minted ITM) and the user did provide tick limits LOW > HIGH, then swap necessary amounts
            if ((LeftRightSigned.unwrap(itmAmounts) != 0)) {
                totalMoved = totalMoved.add(swapInAMM(key, itmAmounts));
            }

            (tickLimitLow, tickLimitHigh) = (tickLimitHigh, tickLimitLow);
        }

        LeftRightSigned cumulativeDelta = totalMoved.sub(totalCollected);

        if (cumulativeDelta.rightSlot() > 0) {
            POOL_MANAGER_V4.burn(
                account,
                uint160(Currency.unwrap(key.currency0)),
                uint128(cumulativeDelta.rightSlot())
            );
        } else if (cumulativeDelta.rightSlot() < 0) {
            POOL_MANAGER_V4.mint(
                account,
                uint160(Currency.unwrap(key.currency0)),
                uint128(-cumulativeDelta.rightSlot())
            );
        }

        if (cumulativeDelta.leftSlot() > 0) {
            POOL_MANAGER_V4.burn(
                account,
                uint160(Currency.unwrap(key.currency1)),
                uint128(cumulativeDelta.leftSlot())
            );
        } else if (cumulativeDelta.leftSlot() < 0) {
            POOL_MANAGER_V4.mint(
                account,
                uint160(Currency.unwrap(key.currency1)),
                uint128(-cumulativeDelta.leftSlot())
            );
        }

        PoolKey memory __key = key;

        // Get the current tick of the Uniswap pool, check slippage
        int24 currentTick = V4StateReader.getTick(POOL_MANAGER_V4, __key.toId());

        if ((currentTick >= tickLimitHigh) || (currentTick <= tickLimitLow))
            revert Errors.PriceBoundFail();
    }

    /// @notice Create the position in the AMM for a specific leg in the tokenId.
    /// @dev For the leg specified by the _leg input:
    /// @dev  - mints any new liquidity in the AMM needed (via _mintLiquidity)
    /// @dev  - burns any new liquidity in the AMM needed (via _burnLiquidity)
    /// @dev  - tracks all amounts minted and burned
    /// @dev To burn a position, the opposing position is "created" through this function,
    /// but we need to pass in a flag to indicate that so the removedLiquidity is updated.
    /// @param account The address of the user creating the position
    /// @param key The Uniswap V4 pool key in which to create the position
    /// @param tokenId The option position
    /// @param leg The leg index that needs to be modified
    /// @param liquidityChunk The liquidity chunk in Uniswap represented by the leg
    /// @param isBurn Whether a position is being minted (true) or burned (false)
    /// @return moved The net amount of funds moved to/from Uniswap
    /// @return collectedSingleLeg LeftRight encoded words containing the amount of token0 and token1 collected as fees
    function _createLegInAMM(
        address account,
        PoolKey memory key,
        TokenId tokenId,
        uint256 leg,
        LiquidityChunk liquidityChunk,
        bool isBurn
    ) internal returns (LeftRightSigned moved, LeftRightUnsigned collectedSingleLeg) {
        // unique key to identify the liquidity chunk in this Uniswap pool
        bytes32 positionKey = keccak256(
            abi.encodePacked(
                key.toId(),
                account,
                tokenId.tokenType(leg),
                liquidityChunk.tickLower(),
                liquidityChunk.tickUpper()
            )
        );

        // update our internal bookkeeping of how much liquidity we have deployed in the AMM
        // for example: if this leg is short, we add liquidity to the amm, make sure to add that to our tracking
        uint128 updatedLiquidity;
        uint256 isLong = tokenId.isLong(leg);
        LeftRightUnsigned currentLiquidity = s_accountLiquidity[positionKey];
        {
            // did we have liquidity already deployed in Uniswap for this chunk range from some past mint?

            // s_accountLiquidity is a LeftRight. The right slot represents the liquidity currently sold (added) in the AMM owned by the user
            // the left slot represents the amount of liquidity currently bought (removed) that has been removed from the AMM - the user owes it to a seller
            // the reason why it is called "removedLiquidity" is because long options are created by removing - ie. short selling LP positions
            uint128 startingLiquidity = currentLiquidity.rightSlot();
            uint128 removedLiquidity = currentLiquidity.leftSlot();
            uint128 chunkLiquidity = liquidityChunk.liquidity();

            // 0-liquidity interactions are asymmetrical in Uniswap (burning 0 liquidity is permitted and functions as a poke, but minting is prohibited)
            // thus, we prohibit all 0-liquidity chunks to prevent users from creating positions that cannot be closed
            if (chunkLiquidity == 0) revert Errors.ZeroLiquidity();

            if (isLong == 0) {
                // selling/short: so move from account *to* uniswap
                // we're minting more liquidity in uniswap: so add the incoming liquidity chunk to the existing liquidity chunk
                updatedLiquidity = startingLiquidity + chunkLiquidity;

                /// @dev If the isLong flag is 0=short but the position was burnt, then this is closing a long position
                /// @dev so the amount of removed liquidity should decrease.
                if (isBurn) {
                    removedLiquidity -= chunkLiquidity;
                }
            } else {
                // the _leg is long (buying: moving *from* uniswap to account)
                // so we seek to move the incoming liquidity chunk *out* of uniswap - but was there sufficient liquidity sitting in uniswap
                // in the first place?
                if (startingLiquidity < chunkLiquidity) {
                    // the amount we want to move (liquidityChunk.legLiquidity()) out of uniswap is greater than
                    // what the account that owns the liquidity in uniswap has (startingLiquidity)
                    // we must ensure that an account can only move its own liquidity out of uniswap
                    // so we revert in this case
                    revert Errors.NotEnoughLiquidity();
                } else {
                    // startingLiquidity is >= chunkLiquidity, so no possible underflow
                    unchecked {
                        // we want to move less than what already sits in uniswap, no problem:
                        updatedLiquidity = startingLiquidity - chunkLiquidity;
                    }
                }

                /// @dev If the isLong flag is 1=long and the position is minted, then this is opening a long position
                /// @dev so the amount of removed liquidity should increase.
                if (!isBurn) {
                    removedLiquidity += chunkLiquidity;
                }
            }

            // update the starting liquidity for this position for next time around
            s_accountLiquidity[positionKey] = LeftRightUnsigned.wrap(updatedLiquidity).toLeftSlot(
                removedLiquidity
            );
        }

        // track how much liquidity we need to collect from uniswap
        // add the fees that accumulated in uniswap within the liquidityChunk:

        /* if the position is NOT long (selling a put or a call), then _mintLiquidity to move liquidity
            from the msg.sender to the Uniswap V4 pool:
            Selling(isLong=0): Mint chunk of liquidity in Uniswap (defined by upper tick, lower tick, and amount)
                   ┌─────────────────────────────────┐
            ▲     ┌▼┐ liquidityChunk                 │
            │  ┌──┴─┴──┐                         ┌───┴──┐
            │  │       │                         │      │
            └──┴───────┴──►                      └──────┘
              Uniswap V4                        msg.sender
        
            else: the position is long (buying a put or a call), then _burnLiquidity to remove liquidity from Uniswap V4
            Buying(isLong=1): Burn in Uniswap
                   ┌─────────────────┐
            ▲     ┌┼┐                │
            │  ┌──┴─┴──┐         ┌───▼──┐
            │  │       │         │      │
            └──┴───────┴──►      └──────┘
              Uniswap V4        msg.sender 
        */

        LiquidityChunk _liquidityChunk = liquidityChunk;

        PoolKey memory _key = key;

        (BalanceDelta delta, BalanceDelta feesAccrued) = POOL_MANAGER_V4.modifyLiquidity(
            _key,
            IPoolManager.ModifyLiquidityParams(
                _liquidityChunk.tickLower(),
                _liquidityChunk.tickUpper(),
                isLong == 0
                    ? int256(uint256(_liquidityChunk.liquidity()))
                    : -int256(uint256(_liquidityChunk.liquidity())),
                positionKey
            ),
            ""
        );

        unchecked {
            moved = LeftRightSigned
                .wrap(0)
                .toRightSlot(feesAccrued.amount0() - delta.amount0())
                .toLeftSlot(feesAccrued.amount1() - delta.amount1());
        }

        // (premium can only be collected if liquidity existed in the chunk prior to this mint)
        if (currentLiquidity.rightSlot() > 0) {
            collectedSingleLeg = LeftRightUnsigned
                .wrap(0)
                .toRightSlot(uint128(feesAccrued.amount0()))
                .toLeftSlot(uint128(feesAccrued.amount1()));

            _updateStoredPremia(positionKey, currentLiquidity, collectedSingleLeg);
        }
    }

    /// @notice Updates the premium accumulators for a chunk with the latest collected tokens.
    /// @param positionKey A key representing a liquidity chunk/range in Uniswap
    /// @param currentLiquidity The total amount of liquidity in the AMM for the specified chunk
    /// @param collectedAmounts The amount of tokens (token0 and token1) collected from Uniswap
    function _updateStoredPremia(
        bytes32 positionKey,
        LeftRightUnsigned currentLiquidity,
        LeftRightUnsigned collectedAmounts
    ) private {
        (
            LeftRightUnsigned deltaPremiumOwed,
            LeftRightUnsigned deltaPremiumGross
        ) = _getPremiaDeltas(currentLiquidity, collectedAmounts);

        // add deltas to accumulators and freeze both accumulators (for a token) if one of them overflows
        // (i.e if only token0 (right slot) of the owed premium overflows, then stop accumulating  both token0 owed premium and token0 gross premium for the chunk)
        // this prevents situations where the owed premium gets out of sync with the gross premium due to one of them overflowing
        (s_accountPremiumOwed[positionKey], s_accountPremiumGross[positionKey]) = LeftRightLibrary
            .addCapped(
                s_accountPremiumOwed[positionKey],
                deltaPremiumOwed,
                s_accountPremiumGross[positionKey],
                deltaPremiumGross
            );
    }

    /// @notice Compute deltas for Owed/Gross premium given quantities of tokens collected from Uniswap.
    /// @dev Returned accumulators are capped at the max value (`2^128 - 1`) for each token if they overflow.
    /// @param currentLiquidity NetLiquidity (right) and removedLiquidity (left) at the start of the transaction
    /// @param collectedAmounts Total amount of tokens (token0 and token1) collected from Uniswap
    /// @return deltaPremiumOwed The extra premium (per liquidity X64) to be added to the owed accumulator for token0 (right) and token1 (left)
    /// @return deltaPremiumGross The extra premium (per liquidity X64) to be added to the gross accumulator for token0 (right) and token1 (left)
    function _getPremiaDeltas(
        LeftRightUnsigned currentLiquidity,
        LeftRightUnsigned collectedAmounts
    )
        private
        pure
        returns (LeftRightUnsigned deltaPremiumOwed, LeftRightUnsigned deltaPremiumGross)
    {
        // extract liquidity values
        uint256 removedLiquidity = currentLiquidity.leftSlot();
        uint256 netLiquidity = currentLiquidity.rightSlot();

        // premia spread equations are graphed and documented here: https://www.desmos.com/calculator/mdeqob2m04
        // explains how we get from the premium per liquidity (calculated here) to the total premia collected and the multiplier
        // as well as how the value of VEGOID affects the premia
        // note that the "base" premium is just a common factor shared between the owed (long) and gross (short)
        // premia, and is only seperated to simplify the calculation
        // (the graphed equations include this factor without separating it)
        unchecked {
            uint256 totalLiquidity = netLiquidity + removedLiquidity;

            uint256 premium0X64_base;
            uint256 premium1X64_base;

            {
                uint128 collected0 = collectedAmounts.rightSlot();
                uint128 collected1 = collectedAmounts.leftSlot();

                // compute the base premium as collected * total / net^2 (from Eqn 3)
                premium0X64_base = Math.mulDiv(
                    collected0,
                    totalLiquidity * 2 ** 64,
                    netLiquidity ** 2
                );
                premium1X64_base = Math.mulDiv(
                    collected1,
                    totalLiquidity * 2 ** 64,
                    netLiquidity ** 2
                );
            }

            {
                uint128 premium0X64_owed;
                uint128 premium1X64_owed;
                {
                    // compute the owed premium (from Eqn 3)
                    uint256 numerator = netLiquidity + (removedLiquidity / 2 ** VEGOID);

                    premium0X64_owed = Math
                        .mulDiv(premium0X64_base, numerator, totalLiquidity)
                        .toUint128Capped();
                    premium1X64_owed = Math
                        .mulDiv(premium1X64_base, numerator, totalLiquidity)
                        .toUint128Capped();

                    deltaPremiumOwed = LeftRightUnsigned.wrap(premium0X64_owed).toLeftSlot(
                        premium1X64_owed
                    );
                }
            }

            {
                uint128 premium0X64_gross;
                uint128 premium1X64_gross;
                {
                    // compute the gross premium (from Eqn 4)
                    uint256 numerator = totalLiquidity ** 2 -
                        totalLiquidity *
                        removedLiquidity +
                        ((removedLiquidity ** 2) / 2 ** (VEGOID));

                    premium0X64_gross = Math
                        .mulDiv(premium0X64_base, numerator, totalLiquidity ** 2)
                        .toUint128Capped();
                    premium1X64_gross = Math
                        .mulDiv(premium1X64_base, numerator, totalLiquidity ** 2)
                        .toUint128Capped();

                    deltaPremiumGross = LeftRightUnsigned.wrap(premium0X64_gross).toLeftSlot(
                        premium1X64_gross
                    );
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            SFPM PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the liquidity associated with a given liquidity chunk/tokenType for a user on a Uniswap pool.
    /// @param idV4 The Uniswap V4 pool id to query
    /// @param owner The address of the account that is queried
    /// @param tokenType The tokenType of the position
    /// @param tickLower The lower end of the tick range for the position
    /// @param tickUpper The upper end of the tick range for the position
    /// @return accountLiquidities The amount of liquidity that held in and removed from Uniswap for that chunk (netLiquidity:removedLiquidity -> rightSlot:leftSlot)
    function getAccountLiquidity(
        PoolId idV4,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (LeftRightUnsigned accountLiquidities) {
        // Extract the account liquidity for a given Uniswap pool, owner, token type, and ticks
        // tokenType input here is the asset of the positions minted, this avoids put liquidity to be used for call, and vice-versa
        accountLiquidities = s_accountLiquidity[
            keccak256(abi.encodePacked(idV4, owner, tokenType, tickLower, tickUpper))
        ];
    }

    /// @notice Return the premium associated with a given position, where premium is an accumulator of feeGrowth for the touched position.
    /// @dev If an atTick parameter is provided that is different from `type(int24).max`, then it will update the premium up to the current
    /// block at the provided atTick value. We do this because this may be called immediately after the Uniswap V4 pool has been touched,
    /// so no need to read the feeGrowths from the Uniswap V4 pool.
    /// @param idV4 The Uniswap V4 pool id to query
    /// @param owner The address of the account that is queried
    /// @param tokenType The tokenType of the position
    /// @param tickLower The lower end of the tick range for the position
    /// @param tickUpper The upper end of the tick range for the position
    /// @param atTick The current tick. Set `atTick < (type(int24).max = 8388608)` to get latest premium up to the current block
    /// @param isLong Whether the position is long (=1) or short (=0)
    /// @return The amount of premium (per liquidity X64) for token0 = `sum(feeGrowthLast0X128)` over every block where the position has been touched
    /// @return The amount of premium (per liquidity X64) for token1 = `sum(feeGrowthLast0X128)` over every block where the position has been touched
    function getAccountPremium(
        PoolId idV4,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper,
        int24 atTick,
        uint256 isLong
    ) external view returns (uint128, uint128) {
        bytes32 positionKey = keccak256(
            abi.encodePacked(idV4, owner, tokenType, tickLower, tickUpper)
        );

        LeftRightUnsigned acctPremia;

        LeftRightUnsigned accountLiquidities = s_accountLiquidity[positionKey];
        uint128 netLiquidity = accountLiquidities.rightSlot();

        // Compute the premium up to the current block (ie. after last touch until now). Do not proceed if `atTick == (type(int24).max = 8388608)`
        if (atTick < type(int24).max && netLiquidity != 0) {
            // unique key to identify the liquidity chunk in this Uniswap pool
            LeftRightUnsigned amountToCollect;
            {
                PoolId _idV4 = idV4;
                int24 _tickLower = tickLower;
                int24 _tickUpper = tickUpper;
                int24 _atTick = atTick;
                bytes32 _positionKey = positionKey;

                (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = V4StateReader
                    .getFeeGrowthInside(POOL_MANAGER_V4, _idV4, _atTick, _tickLower, _tickUpper);

                (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = V4StateReader
                    .getFeeGrowthInsideLast(
                        POOL_MANAGER_V4,
                        _idV4,
                        keccak256(
                            abi.encodePacked(address(this), _tickLower, _tickUpper, _positionKey)
                        )
                    );

                unchecked {
                    amountToCollect = LeftRightUnsigned
                        .wrap(
                            uint128(
                                Math.mulDiv128(
                                    feeGrowthInside0X128 - feeGrowthInside0LastX128,
                                    netLiquidity
                                )
                            )
                        )
                        .toLeftSlot(
                            uint128(
                                Math.mulDiv128(
                                    feeGrowthInside1X128 - feeGrowthInside1LastX128,
                                    netLiquidity
                                )
                            )
                        );
                }
            }

            (LeftRightUnsigned premiumOwed, LeftRightUnsigned premiumGross) = _getPremiaDeltas(
                accountLiquidities,
                amountToCollect
            );

            // add deltas to accumulators and freeze both accumulators (for a token) if one of them overflows
            // (i.e if only token0 (right slot) of the owed premium overflows, then stop accumulating  both token0 owed premium and token0 gross premium for the chunk)
            // this prevents situations where the owed premium gets out of sync with the gross premium due to one of them overflowing
            (premiumOwed, premiumGross) = LeftRightLibrary.addCapped(
                s_accountPremiumOwed[positionKey],
                premiumOwed,
                s_accountPremiumGross[positionKey],
                premiumGross
            );

            acctPremia = isLong == 1 ? premiumOwed : premiumGross;
        } else {
            // Extract the account liquidity for a given Uniswap pool, owner, token type, and ticks
            acctPremia = isLong == 1
                ? s_accountPremiumOwed[positionKey]
                : s_accountPremiumGross[positionKey];
        }
        return (acctPremia.rightSlot(), acctPremia.leftSlot());
    }

    /// @notice Returns the Uniswap V4 poolkey  for a given `poolId`.
    /// @param poolId The unique pool identifier for a Uni V4 pool in the SFPM
    /// @return The Uniswap V4 pool key corresponding to `poolId`
    function getUniswapV4PoolKeyFromId(uint64 poolId) external view returns (PoolKey memory) {
        return s_poolIdToKey[poolId];
    }

    /// @notice Returns the SFPM `poolId` for a given Uniswap V4 `PoolId`.
    /// @param idV4 The Uniswap V4 pool identifier
    /// @return The unique pool identifier in the SFPM corresponding to `idV4`
    function getPoolId(PoolId idV4) external view returns (uint64) {
        return uint64(s_V4toSFPMIdData[idV4]);
    }

    /// @notice Returns the SFPM `poolId` for a given Uniswap V4 `PoolKey`.
    /// @param key The Uniswap V4 pool key
    /// @return The unique pool identifier in the SFPM corresponding to `key`
    function getPoolId(PoolKey calldata key) external view returns (uint64) {
        return uint64(s_V4toSFPMIdData[key.toId()]);
    }
}
