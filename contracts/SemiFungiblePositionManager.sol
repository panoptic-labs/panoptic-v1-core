// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Inherited implementations
import {ERC1155} from "@tokens/ERC1155Minimal.sol";
import {Multicall} from "@base/Multicall.sol";
import {TransientReentrancyGuard} from "solmate/utils/TransientReentrancyGuard.sol";
// Libraries
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {FeesCalc} from "@libraries/FeesCalc.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
// Custom types
import {LeftRightUnsigned, LeftRightSigned, LeftRightLibrary} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";

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
/// @title Semi-Fungible Position Manager (ERC1155) - a gas-efficient Uniswap V3 position manager.
/// @notice Wraps Uniswap V3 positions with up to 4 legs behind an ERC1155 token.
/// @dev Replaces the NonfungiblePositionManager.sol (ERC721) from Uniswap Labs.
contract SemiFungiblePositionManager is ERC1155, Multicall, TransientReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a UniswapV3Pool is initialized in the SFPM.
    /// @param uniswapPool Address of the underlying Uniswap v3 pool
    /// @param poolId The SFPM's pool identifier for the pool, including the 16-bit tick spacing and 48-bit pool pattern
    event PoolInitialized(address indexed uniswapPool, uint64 poolId);

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
    /// @dev `recipient` is used to track whether it was minted directly by the user or through an option contract.
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

    /// @notice Canonical Uniswap V3 Factory address.
    /// @dev Used to verify callbacks and initialize pools.
    IUniswapV3Factory internal immutable FACTORY;

    /*//////////////////////////////////////////////////////////////
                            STORAGE 
    //////////////////////////////////////////////////////////////*/

    /// @notice Retrieve the corresponding poolId for a given Uniswap V3 pool address.
    /// @dev pool address => pool id + 2 ** 255 (initialization bit for `poolId == 0`, set if the pool exists)
    mapping(address univ3pool => uint256 poolIdData) internal s_AddrToPoolIdData;

    /// @notice Retrieve the Uniswap V3 pool address corresponding to a given poolId.
    mapping(uint64 poolId => IUniswapV3Pool pool) internal s_poolIdToAddr;

    /*
        We're tracking the amount of net and removed liquidity for the specific region:

             net amount    
           received minted  
          ▲ for isLong=0     amount           
          │                 moved out      actual amount 
          │  ┌────┐-T      due isLong=1   in the UniswapV3Pool 
          │  │    │          mints      
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

    /// @notice Per-liquidity accumulator for the fees collected on an account for a given chunk.
    /// @dev Base fees is stored as int128((feeGrowthInside0LastX128 * liquidity) / 2**128), which allows us to store the accumulated fees as int128 instead of uint256.
    /// @dev Right slot: int128 token0 base fees, Left slot: int128 token1 base fees.
    /// @dev feesBase represents the baseline fees collected by the position last time it was updated - this is recalculated every time the position is collected from with the new value.
    mapping(bytes32 positionKey => LeftRightSigned baseFees0And1) internal s_accountFeesBase;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the canonical Uniswap V3 Factory address.
    /// @param _factory The canonical Uniswap V3 Factory address
    constructor(IUniswapV3Factory _factory) {
        FACTORY = _factory;
    }

    /// @notice Initialize a Uniswap v3 pool in the SFPM.
    /// @dev Revert if already initialized.
    /// @param token0 The contract address of token0 of the pool
    /// @param token1 The contract address of token1 of the pool
    /// @param fee The fee level of the of the underlying Uniswap v3 pool, denominated in hundredths of bips
    function initializeAMMPool(address token0, address token1, uint24 fee) external {
        // compute the address of the Uniswap v3 pool for the given token0, token1, and fee tier
        address univ3pool = FACTORY.getPool(token0, token1, fee);

        // reverts if the Uni v3 pool has not been initialized
        if (univ3pool == address(0)) revert Errors.UniswapPoolNotInitialized();

        // return if the pool has already been initialized in SFPM
        // pools can be initialized from the Panoptic Factory or by calling initializeAMMPool directly, so reverting
        // could prevent a PanopticPool from being deployed on a previously initialized but otherwise valid pools
        // if poolId == 0, we have a bit on the left set if it was initialized, so this will still return properly
        if (s_AddrToPoolIdData[univ3pool] != 0) return;

        // The base poolId is composed as follows:
        // [tickSpacing][pool pattern]
        // [16 bit tickSpacing][most significant 48 bits of the pool address]
        uint64 poolId = PanopticMath.getPoolId(univ3pool);

        // There are 281,474,976,710,655 possible pool patterns.
        // A modern GPU can generate a collision in such a space relatively quickly,
        // so if a collision is detected increment the pool pattern until a unique poolId is found
        while (address(s_poolIdToAddr[poolId]) != address(0)) {
            poolId = PanopticMath.incrementPoolPattern(poolId);
        }

        s_poolIdToAddr[poolId] = IUniswapV3Pool(univ3pool);

        // add a bit on the end to indicate that the pool is initialized
        // (this is for the case that poolId == 0, so we can make a distinction between zero and uninitialized)
        unchecked {
            s_AddrToPoolIdData[univ3pool] = uint256(poolId) + 2 ** 255;
        }

        emit PoolInitialized(univ3pool, poolId);
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
        // Decode the mint callback data
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));
        // Validate caller to ensure we got called from the AMM pool
        CallbackLib.validateCallback(msg.sender, FACTORY, decoded.poolFeatures);
        // Sends the amount0Owed and amount1Owed quantities provided
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

    /// @notice Called by the pool after executing a swap during an ITM option mint/burn.
    /// @dev Pays the pool tokens owed for the swap from the payer (always the caller).
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool
    /// @param data Contains the payer address and the pool features required to validate the callback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode the swap callback data, checks that the UniswapV3Pool has the correct address.
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));
        // Validate caller to ensure we got called from the AMM pool
        CallbackLib.validateCallback(msg.sender, FACTORY, decoded.poolFeatures);

        // Extract the address of the token to be sent (amount0 -> token0, amount1 -> token1)
        address token = amount0Delta > 0
            ? address(decoded.poolFeatures.token0)
            : address(decoded.poolFeatures.token1);

        // Transform the amount to pay to uint256 (take positive one from amount0 and amount1)
        // the pool will always pass one delta with a positive sign and one with a negative sign or zero,
        // so this logic always picks the correct delta to pay
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        // Pay the required token from the payer to the caller of this contract
        SafeTransferLib.safeTransferFrom(token, decoded.payer, msg.sender, amountToPay);
    }

    /*//////////////////////////////////////////////////////////////
                       PUBLIC MINT/BURN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn a new position containing up to 4 legs wrapped in a ERC1155 token.
    /// @dev Auto-collect all accumulated fees.
    /// @param tokenId The tokenId of the minted position, which encodes information about up to 4 legs
    /// @param positionSize The number of contracts minted, expressed in terms of the asset
    /// @param slippageTickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param slippageTickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @return An array of LeftRight encoded words containing the amount of token0 and token1 collected as fees for each leg
    /// @return A LeftRight encoded word containing the total amount of token0 and token1 swapped if minting ITM
    function burnTokenizedPosition(
        TokenId tokenId,
        uint128 positionSize,
        int24 slippageTickLimitLow,
        int24 slippageTickLimitHigh
    ) external nonReentrant returns (LeftRightUnsigned[4] memory, LeftRightSigned) {
        // burn this ERC1155 token id
        _burn(msg.sender, TokenId.unwrap(tokenId), positionSize);

        // emit event
        emit TokenizedPositionBurnt(msg.sender, tokenId, positionSize);

        // Call a function that contains other functions to mint/burn position, collect amounts, swap if necessary
        return
            _createPositionInAMM(
                slippageTickLimitLow,
                slippageTickLimitHigh,
                positionSize,
                tokenId.flipToBurnToken(),
                BURN
            );
    }

    /// @notice Create a new position `tokenId` containing up to 4 legs.
    /// @param tokenId The tokenId of the minted position, which encodes information for up to 4 legs
    /// @param positionSize The number of contracts minted, expressed in terms of the asset
    /// @param slippageTickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param slippageTickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @return An array of LeftRight encoded words containing the amount of token0 and token1 collected as fees for each leg
    /// @return A LeftRight encoded word containing the total amount of token0 and token1 swapped if minting ITM
    function mintTokenizedPosition(
        TokenId tokenId,
        uint128 positionSize,
        int24 slippageTickLimitLow,
        int24 slippageTickLimitHigh
    ) external nonReentrant returns (LeftRightUnsigned[4] memory, LeftRightSigned) {
        // create the option position via its ID in this erc1155
        _mint(msg.sender, TokenId.unwrap(tokenId), positionSize);

        emit TokenizedPositionMinted(msg.sender, tokenId, positionSize);

        // verify that the tokenId is correctly formatted and conforms to all enforced constraints
        tokenId.validate();

        // validate the incoming option position, then forward to the AMM for minting/burning required liquidity chunks
        return
            _createPositionInAMM(
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

    /// @notice Transfer a single token from one user to another.
    /// @dev Supports token approvals.
    /// @param from The user to transfer tokens from
    /// @param to The user to transfer tokens to
    /// @param id The ERC1155 token id to transfer
    /// @param amount The amount of tokens to transfer
    /// @param data Optional data to include in the receive hook
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) public override nonReentrant {
        registerTokenTransfer(from, to, TokenId.wrap(id), amount);

        super.safeTransferFrom(from, to, id, amount, data);
    }

    /// @notice Transfer multiple tokens from one user to another.
    /// @dev Supports token approvals.
    /// @dev `ids` and `amounts` must be of equal length.
    /// @param from The user to transfer tokens from
    /// @param to The user to transfer tokens to
    /// @param ids The ERC1155 token ids to transfer
    /// @param amounts The amounts of tokens to transfer
    /// @param data Optional data to include in the receive hook
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) public override nonReentrant {
        for (uint256 i = 0; i < ids.length; ) {
            registerTokenTransfer(from, to, TokenId.wrap(ids[i]), amounts[i]);
            unchecked {
                ++i;
            }
        }

        super.safeBatchTransferFrom(from, to, ids, amounts, data);
    }

    /// @notice Update user position data following a token transfer.
    /// @dev All liquidity for `from` in the chunk for each leg of `id` must be transferred.
    /// @dev `from` must not have long liquidity in any of the chunks being transferred.
    /// @dev `to` must not have (long or short) liquidity in any of the chunks being transferred.
    /// @param from The address of the sender
    /// @param to The address of the recipient
    /// @param id The tokenId being transferred
    /// @param amount The amount of the token being transferred
    function registerTokenTransfer(address from, address to, TokenId id, uint256 amount) internal {
        IUniswapV3Pool univ3pool = s_poolIdToAddr[id.poolId()];

        uint256 numLegs = id.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                id,
                leg,
                uint128(amount)
            );

            bytes32 positionKey_from = keccak256(
                abi.encodePacked(
                    address(univ3pool),
                    from,
                    id.tokenType(leg),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                )
            );
            bytes32 positionKey_to = keccak256(
                abi.encodePacked(
                    address(univ3pool),
                    to,
                    id.tokenType(leg),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                )
            );

            // Revert if recipient already has liquidity in `liquidityChunk`
            // Revert if sender has long liquidity in `liquidityChunk` or they are attempting to transfer less than their `netLiquidity`
            LeftRightUnsigned fromLiq = s_accountLiquidity[positionKey_from];
            if (
                LeftRightUnsigned.unwrap(s_accountLiquidity[positionKey_to]) != 0 ||
                LeftRightUnsigned.unwrap(fromLiq) != liquidityChunk.liquidity()
            ) revert Errors.TransferFailed();

            s_accountLiquidity[positionKey_to] = fromLiq;
            s_accountLiquidity[positionKey_from] = LeftRightUnsigned.wrap(0);

            s_accountFeesBase[positionKey_to] = s_accountFeesBase[positionKey_from];
            s_accountFeesBase[positionKey_from] = LeftRightSigned.wrap(0);

            unchecked {
                ++leg;
            }
        }
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
    /// @param univ3pool The uniswap pool in which to swap.
    /// @param itmAmounts How much to swap - how much is ITM
    /// @return totalSwapped The token deltas swapped in the AMM
    function swapInAMM(
        IUniswapV3Pool univ3pool,
        LeftRightSigned itmAmounts
    ) internal returns (LeftRightSigned totalSwapped) {
        bool zeroForOne; // The direction of the swap, true for token0 to token1, false for token1 to token0
        int256 swapAmount; // The amount of token0 or token1 to swap
        bytes memory data;

        IUniswapV3Pool _univ3pool = univ3pool;

        unchecked {
            // unpack the in-the-money amounts
            int128 itm0 = itmAmounts.rightSlot();
            int128 itm1 = itmAmounts.leftSlot();

            // construct the swap callback struct
            data = abi.encode(
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: _univ3pool.token0(),
                        token1: _univ3pool.token1(),
                        fee: _univ3pool.fee()
                    }),
                    payer: msg.sender
                })
            );

            // NOTE: upstream users of this function such as the Panoptic Pool should ensure users always compensate for the ITM amount delta
            // the netting swap is not perfectly accurate, and it is possible for swaps to run out of liquidity, so we do not want to rely on it
            // this is simply a convenience feature, and should be treated as such
            if ((itm0 != 0) && (itm1 != 0)) {
                (uint160 sqrtPriceX96, , , , , , ) = _univ3pool.slot0();

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
                int256 net0 = itm0 - PanopticMath.convert1to0(itm1, sqrtPriceX96);

                zeroForOne = net0 < 0;

                //compute the swap amount, set as positive (exact input)
                swapAmount = -net0;
            } else if (itm0 != 0) {
                zeroForOne = itm0 < 0;
                swapAmount = -itm0;
            } else {
                zeroForOne = itm1 > 0;
                swapAmount = -itm1;
            }

            // NOTE: can occur if itm0 and itm1 have the same value
            // in that case, swapping would be pointless so skip
            if (swapAmount == 0) return LeftRightSigned.wrap(0);

            // swap tokens in the Uniswap pool
            // NOTE: this triggers our swap callback function
            (int256 swap0, int256 swap1) = _univ3pool.swap(
                msg.sender,
                zeroForOne,
                swapAmount,
                zeroForOne
                    ? Constants.MIN_V3POOL_SQRT_RATIO + 1
                    : Constants.MAX_V3POOL_SQRT_RATIO - 1,
                data
            );

            // Add amounts swapped to totalSwapped variable
            totalSwapped = LeftRightSigned.wrap(0).toRightSlot(swap0.toInt128()).toLeftSlot(
                swap1.toInt128()
            );
        }
    }

    /// @notice Create the position in the AMM given in the tokenId.
    /// @dev Loops over each leg in the tokenId and calls _createLegInAMM for each, which does the mint/burn in the AMM.
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @param positionSize The size of the option position
    /// @param tokenId The option position
    /// @param isBurn Whether a position is being minted (true) or burned (false)
    /// @return collectedByLeg An array of LeftRight encoded words containing the amount of token0 and token1 collected as fees for each leg
    /// @return totalMoved The net amount of funds moved to/from Uniswap
    function _createPositionInAMM(
        int24 tickLimitLow,
        int24 tickLimitHigh,
        uint128 positionSize,
        TokenId tokenId,
        bool isBurn
    ) internal returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalMoved) {
        // Extract univ3pool from the poolId map to Uniswap Pool
        IUniswapV3Pool univ3pool = s_poolIdToAddr[tokenId.poolId()];

        // Revert if the pool not been previously initialized
        if (univ3pool == IUniswapV3Pool(address(0))) revert Errors.UniswapPoolNotInitialized();

        // upper bound on amount of tokens contained across all legs of the position at any given tick
        uint256 amount0;
        uint256 amount1;

        LeftRightSigned itmAmounts;
        uint256 numLegs = tokenId.countLegs();

        for (uint256 leg = 0; leg < numLegs; ) {
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

            LeftRightSigned movedLeg;

            (movedLeg, collectedByLeg[leg]) = _createLegInAMM(
                univ3pool,
                tokenId,
                leg,
                liquidityChunk,
                isBurn
            );

            totalMoved = totalMoved.add(movedLeg);

            // if tokenType is 1, and we transacted some token0: then this leg is ITM
            // if tokenType is 0, and we transacted some token1: then this leg is ITM
            itmAmounts = itmAmounts.add(
                tokenId.tokenType(leg) == 0
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
                totalMoved = swapInAMM(univ3pool, itmAmounts).add(totalMoved);
            }

            (tickLimitLow, tickLimitHigh) = (tickLimitHigh, tickLimitLow);
        }

        // Get the current tick of the Uniswap pool, check slippage
        (, int24 currentTick, , , , , ) = univ3pool.slot0();

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
    /// @param univ3pool The Uniswap pool
    /// @param tokenId The option position
    /// @param leg The leg index that needs to be modified
    /// @param liquidityChunk The liquidity chunk in Uniswap represented by the leg
    /// @param isBurn Whether a position is being minted (true) or burned (false)
    /// @return moved The net amount of funds moved to/from Uniswap
    /// @return collectedSingleLeg LeftRight encoded words containing the amount of token0 and token1 collected as fees
    function _createLegInAMM(
        IUniswapV3Pool univ3pool,
        TokenId tokenId,
        uint256 leg,
        LiquidityChunk liquidityChunk,
        bool isBurn
    ) internal returns (LeftRightSigned moved, LeftRightUnsigned collectedSingleLeg) {
        // unique key to identify the liquidity chunk in this uniswap pool
        bytes32 positionKey = keccak256(
            abi.encodePacked(
                address(univ3pool),
                msg.sender,
                tokenId.tokenType(leg),
                liquidityChunk.tickLower(),
                liquidityChunk.tickUpper()
            )
        );

        // update our internal bookkeeping of how much liquidity we have deployed in the AMM
        // for example: if this _leg is short, we add liquidity to the amm, make sure to add that to our tracking
        uint128 updatedLiquidity;
        uint256 isLong = tokenId.isLong(leg);
        LeftRightUnsigned currentLiquidity = s_accountLiquidity[positionKey]; //cache
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
                // selling/short: so move from msg.sender *to* uniswap
                // we're minting more liquidity in uniswap: so add the incoming liquidity chunk to the existing liquidity chunk
                updatedLiquidity = startingLiquidity + chunkLiquidity;

                /// @dev If the isLong flag is 0=short but the position was burnt, then this is closing a long position
                /// @dev so the amount of removed liquidity should decrease.
                if (isBurn) {
                    removedLiquidity -= chunkLiquidity;
                }
            } else {
                // the _leg is long (buying: moving *from* uniswap to msg.sender)
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
            from the msg.sender to the uniswap v3 pool:
            Selling(isLong=0): Mint chunk of liquidity in Uniswap (defined by upper tick, lower tick, and amount)
                   ┌─────────────────────────────────┐
            ▲     ┌▼┐ liquidityChunk                 │
            │  ┌──┴─┴──┐                         ┌───┴──┐
            │  │       │                         │      │
            └──┴───────┴──►                      └──────┘
                Uniswap v3                      msg.sender
        
            else: the position is long (buying a put or a call), then _burnLiquidity to remove liquidity from univ3
            Buying(isLong=1): Burn in Uniswap
                   ┌─────────────────┐
            ▲     ┌┼┐                │
            │  ┌──┴─┴──┐         ┌───▼──┐
            │  │       │         │      │
            └──┴───────┴──►      └──────┘
                Uniswap v3      msg.sender 
        */
        moved = isLong == 0
            ? _mintLiquidity(liquidityChunk, univ3pool)
            : _burnLiquidity(liquidityChunk, univ3pool); // from msg.sender to Uniswap

        // if there was liquidity at that tick before the transaction, collect any accumulated fees
        if (currentLiquidity.rightSlot() > 0) {
            collectedSingleLeg = _collectAndWritePositionData(
                liquidityChunk,
                univ3pool,
                currentLiquidity,
                positionKey,
                moved,
                isLong
            );
        }

        // position has been touched, update s_accountFeesBase with the latest values from the pool.positions
        // round up the stored feesbase to minimize Δfeesbase when we next calculate it
        s_accountFeesBase[positionKey] = _getFeesBase(
            univ3pool,
            updatedLiquidity,
            liquidityChunk,
            true
        );
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

    /// @notice Compute an up-to-date feeGrowth value without a poke.
    /// @dev Stored fees base is rounded up and the current fees base is rounded down to minimize the amount of fees collected (Δfeesbase) in favor of the protocol.
    /// @param univ3pool The Uniswap pool
    /// @param liquidity The total amount of liquidity in the AMM for the specific position
    /// @param liquidityChunk The liquidity chunk in Uniswap to compute the feesBase for
    /// @param roundUp If true, round up the feesBase, otherwise round down
    function _getFeesBase(
        IUniswapV3Pool univ3pool,
        uint128 liquidity,
        LiquidityChunk liquidityChunk,
        bool roundUp
    ) private view returns (LeftRightSigned feesBase) {
        // read the latest feeGrowth directly from the Uniswap pool
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = univ3pool
            .positions(
                keccak256(
                    abi.encodePacked(
                        address(this),
                        liquidityChunk.tickLower(),
                        liquidityChunk.tickUpper()
                    )
                )
            );

        // (feegrowth * liquidity) / 2 ** 128
        // here we're converting the value to an int128 even though all values (feeGrowth, liquidity, Q128) are strictly positive.
        // That's because of the way feeGrowthInside works in Uniswap v3, where it can underflow when stored for the first time.
        // This is not a problem in Uniswap v3 because the fees are always calculated by taking the difference of the feeGrowths,
        // so that the net different is always positive.
        // So by using int128 instead of uint128, we remove the need to handle extremely large underflows and simply allow it to be negative
        feesBase = roundUp
            ? LeftRightSigned
                .wrap(0)
                .toRightSlot(
                    int128(int256(Math.mulDiv128RoundingUp(feeGrowthInside0LastX128, liquidity)))
                )
                .toLeftSlot(
                    int128(int256(Math.mulDiv128RoundingUp(feeGrowthInside1LastX128, liquidity)))
                )
            : LeftRightSigned
                .wrap(0)
                .toRightSlot(int128(int256(Math.mulDiv128(feeGrowthInside0LastX128, liquidity))))
                .toLeftSlot(int128(int256(Math.mulDiv128(feeGrowthInside1LastX128, liquidity))));
    }

    /// @notice Mint a chunk of liquidity (`liquidityChunk`) in the Uniswap v3 pool; return the amount moved.
    /// @dev Note that "moved" means: mint in Uniswap and move tokens from msg.sender.
    /// @param liquidityChunk The liquidity chunk in Uniswap to mint
    /// @param univ3pool The Uniswap v3 pool to mint liquidity in/to
    /// @return movedAmounts How many tokens were moved from msg.sender to Uniswap
    function _mintLiquidity(
        LiquidityChunk liquidityChunk,
        IUniswapV3Pool univ3pool
    ) internal returns (LeftRightSigned movedAmounts) {
        // build callback data
        bytes memory mintdata = abi.encode(
            CallbackLib.CallbackData({ // compute by reading values from univ3pool every time
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: univ3pool.token0(),
                        token1: univ3pool.token1(),
                        fee: univ3pool.fee()
                    }),
                    payer: msg.sender
                })
        );

        /// mint the required amount in the Uniswap pool
        /// @dev this triggers the uniswap mint callback function
        (uint256 amount0, uint256 amount1) = univ3pool.mint(
            address(this),
            liquidityChunk.tickLower(),
            liquidityChunk.tickUpper(),
            liquidityChunk.liquidity(),
            mintdata
        );

        // amount0 The amount of token0 that was paid to mint the given amount of liquidity
        // amount1 The amount of token1 that was paid to mint the given amount of liquidity
        // no need to safecast to int from uint here as the max position size is int128
        movedAmounts = LeftRightSigned.wrap(0).toRightSlot(int128(int256(amount0))).toLeftSlot(
            int128(int256(amount1))
        );
    }

    /// @notice Burn a chunk of liquidity (`liquidityChunk`) in the Uniswap v3 pool and send to msg.sender; return the amount moved.
    /// @dev Note that "moved" means: burn position in Uniswap and send tokens to msg.sender.
    /// @param liquidityChunk The liquidity chunk in Uniswap to burn
    /// @param univ3pool The Uniswap v3 pool to burn liquidity in/from
    /// @return movedAmounts How many tokens were moved from Uniswap to msg.sender
    function _burnLiquidity(
        LiquidityChunk liquidityChunk,
        IUniswapV3Pool univ3pool
    ) internal returns (LeftRightSigned movedAmounts) {
        // burn that option's liquidity in the Uniswap Pool.
        // This will send the underlying tokens back to the Panoptic Pool (msg.sender)
        (uint256 amount0, uint256 amount1) = univ3pool.burn(
            liquidityChunk.tickLower(),
            liquidityChunk.tickUpper(),
            liquidityChunk.liquidity()
        );

        // amount0 The amount of token0 that was sent back to the Panoptic Pool
        // amount1 The amount of token1 that was sent back to the Panoptic Pool
        // no need to safecast to int from uint here as the max position size is int128
        // decrement the amountsOut with burnt amounts. amountsOut = notional value of tokens moved
        unchecked {
            movedAmounts = LeftRightSigned.wrap(0).toRightSlot(-int128(int256(amount0))).toLeftSlot(
                -int128(int256(amount1))
            );
        }
    }

    /// @notice Helper to collect amounts between msg.sender and Uniswap and also to update the Uniswap fees collected to date from the AMM.
    /// @param liquidityChunk The liquidity chunk in Uniswap to collect from
    /// @param univ3pool The Uniswap pool where the position is deployed
    /// @param currentLiquidity The existing liquidity msg.sender owns in the AMM for this chunk before the SFPM was called
    /// @param positionKey The unique key to identify the liquidity chunk/tokenType pairing in this uniswap pool
    /// @param movedInLeg How much liquidity has been moved between msg.sender and Uniswap before this function call
    /// @param isLong Whether the leg in question is long (=1) or short (=0)
    /// @return collectedChunk The amount of tokens collected from Uniswap
    function _collectAndWritePositionData(
        LiquidityChunk liquidityChunk,
        IUniswapV3Pool univ3pool,
        LeftRightUnsigned currentLiquidity,
        bytes32 positionKey,
        LeftRightSigned movedInLeg,
        uint256 isLong
    ) internal returns (LeftRightUnsigned collectedChunk) {
        uint128 startingLiquidity = currentLiquidity.rightSlot();
        // round down current fees base to minimize Δfeesbase
        // If the current feesBase is close or identical to the stored one, the amountToCollect can be negative.
        // This is because the stored feesBase is rounded up, and the current feesBase is rounded down.
        // When this is the case, we want to behave as if there are 0 fees, so we just rectify the values.
        LeftRightSigned amountToCollect = _getFeesBase(
            univ3pool,
            startingLiquidity,
            liquidityChunk,
            false
        ).subRect(s_accountFeesBase[positionKey]);

        if (isLong == 1) {
            amountToCollect = amountToCollect.sub(movedInLeg);
        }

        if (LeftRightSigned.unwrap(amountToCollect) != 0) {
            // first collect amounts from Uniswap corresponding to this position
            // Collect only if there was existing startingLiquidity=liquidities.rightSlot() at that position: collect all fees

            // Collects tokens owed to a liquidity chunk
            (uint128 receivedAmount0, uint128 receivedAmount1) = univ3pool.collect(
                msg.sender,
                liquidityChunk.tickLower(),
                liquidityChunk.tickUpper(),
                uint128(amountToCollect.rightSlot()),
                uint128(amountToCollect.leftSlot())
            );

            // moved will be negative if the leg was long (funds left the caller, don't count it in collected fees)
            uint128 collected0;
            uint128 collected1;
            unchecked {
                collected0 = movedInLeg.rightSlot() < 0
                    ? receivedAmount0 - uint128(-movedInLeg.rightSlot())
                    : receivedAmount0;
                collected1 = movedInLeg.leftSlot() < 0
                    ? receivedAmount1 - uint128(-movedInLeg.leftSlot())
                    : receivedAmount1;
            }

            // CollectedOut is the amount of fees accumulated+collected (received - burnt)
            // That's because receivedAmount contains the burnt tokens and whatever amount of fees collected
            collectedChunk = LeftRightUnsigned.wrap(collected0).toLeftSlot(collected1);

            // record the collected amounts in the s_accountPremiumOwed and s_accountPremiumGross accumulators
            _updateStoredPremia(positionKey, currentLiquidity, collectedChunk);
        }
    }

    /// @notice Compute deltas for Owed/Gross premium given quantities of tokens collected from Uniswap.
    /// @dev Returned accumulators are capped at the max value (2**128 - 1) for each token if they overflow.
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

    /// @notice Return the liquidity associated with a given liquidity chunk/tokenType.
    /// @dev Computes accountLiquidity[keccak256(abi.encodePacked(univ3pool, owner, tokenType, tickLower, tickUpper))].
    /// @param univ3pool The address of the Uniswap v3 Pool
    /// @param owner The address of the account that is queried
    /// @param tokenType The tokenType of the position
    /// @param tickLower The lower end of the tick range for the position (int24)
    /// @param tickUpper The upper end of the tick range for the position (int24)
    /// @return accountLiquidities The amount of liquidity that has been shorted/added to the Uniswap contract (netLiquidity:removedLiquidity -> rightSlot:leftSlot)
    function getAccountLiquidity(
        address univ3pool,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (LeftRightUnsigned accountLiquidities) {
        // Extract the account liquidity for a given uniswap pool, owner, token type, and ticks
        // tokenType input here is the asset of the positions minted, this avoids put liquidity to be used for call, and vice-versa
        accountLiquidities = s_accountLiquidity[
            keccak256(abi.encodePacked(univ3pool, owner, tokenType, tickLower, tickUpper))
        ];
    }

    /// @notice Return the premium associated with a given position, where premium is an accumulator of feeGrowth for the touched position.
    /// @dev Computes s_accountPremium{isLong ? Owed : Gross}[keccak256(abi.encodePacked(univ3pool, owner, tokenType, tickLower, tickUpper))].
    /// @dev If an atTick parameter is provided that is different from type(int24).max, then it will update the premium up to the current
    /// block at the provided atTick value. We do this because this may be called immediately after the Uni v3 pool has been touched,
    /// so no need to read the feeGrowths from the Uni v3 pool.
    /// @param univ3pool The address of the Uniswap v3 Pool
    /// @param owner The address of the account that is queried
    /// @param tokenType The tokenType of the position
    /// @param tickLower The lower end of the tick range for the position (int24)
    /// @param tickUpper The upper end of the tick range for the position (int24)
    /// @param atTick The current tick. Set atTick < type(int24).max = 8388608 to get latest premium up to the current block
    /// @param isLong Whether the position is long (=1) or short (=0)
    /// @return The amount of premium (per liquidity X64) for token0 = sum (feeGrowthLast0X128) over every block where the position has been touched
    /// @return The amount of premium (per liquidity X64) for token1 = sum (feeGrowthLast0X128) over every block where the position has been touched
    function getAccountPremium(
        address univ3pool,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper,
        int24 atTick,
        uint256 isLong
    ) external view returns (uint128, uint128) {
        bytes32 positionKey = keccak256(
            abi.encodePacked(univ3pool, owner, tokenType, tickLower, tickUpper)
        );

        LeftRightUnsigned acctPremia;

        LeftRightUnsigned accountLiquidities = s_accountLiquidity[positionKey];
        uint128 netLiquidity = accountLiquidities.rightSlot();

        // Compute the premium up to the current block (ie. after last touch until now). Do not proceed if atTick == type(int24).max = 8388608
        if (atTick < type(int24).max && netLiquidity != 0) {
            // unique key to identify the liquidity chunk in this uniswap pool
            LeftRightUnsigned amountToCollect;
            {
                IUniswapV3Pool _univ3pool = IUniswapV3Pool(univ3pool);
                int24 _tickLower = tickLower;
                int24 _tickUpper = tickUpper;

                // how much fees have been accumulated within the liquidity chunk since last time we updated this chunk?
                // Compute (currentFeesGrowth - oldFeesGrowth), the amount to collect
                // currentFeesGrowth (calculated from FeesCalc.calculateAMMSwapFeesLiquidityChunk) is (ammFeesCollectedPerLiquidity * liquidityChunk.liquidity())
                // oldFeesGrowth is the last stored update of fee growth within the position range in the past (feeGrowthRange*liquidityChunk.liquidity()) (s_accountFeesBase[positionKey])
                LeftRightSigned feesBase = FeesCalc.calculateAMMSwapFees(
                    _univ3pool,
                    atTick,
                    _tickLower,
                    _tickUpper,
                    netLiquidity
                );

                // If the current feesBase is close or identical to the stored one, the amountToCollect can be negative.
                // This is because the stored feesBase is rounded up, and the current feesBase is rounded down.
                // When this is the case, we want to behave as if there are 0 fees, so we just rectify the values.
                // Guaranteed to be positive, so swap to unsigned type
                amountToCollect = LeftRightUnsigned.wrap(
                    uint256(
                        LeftRightSigned.unwrap(feesBase.subRect(s_accountFeesBase[positionKey]))
                    )
                );
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
            // Extract the account liquidity for a given uniswap pool, owner, token type, and ticks
            acctPremia = isLong == 1
                ? s_accountPremiumOwed[positionKey]
                : s_accountPremiumGross[positionKey];
        }
        return (acctPremia.rightSlot(), acctPremia.leftSlot());
    }

    /// @notice Return the feesBase associated with a given liquidity chunk.
    /// @dev Computes accountFeesBase[keccak256(abi.encodePacked(univ3pool, owner, tickLower, tickUpper))].
    /// @param univ3pool The address of the Uniswap v3 Pool
    /// @param owner The address of the account that is queried
    /// @param tokenType The tokenType of the position (the token it started as)
    /// @param tickLower The lower end of the tick range for the position (int24)
    /// @param tickUpper The upper end of the tick range for the position (int24)
    /// @return feesBase0 The feesBase of the position for token0
    /// @return feesBase1 The feesBase of the position for token1
    function getAccountFeesBase(
        address univ3pool,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (int128 feesBase0, int128 feesBase1) {
        // Get accumulated fees for token0 (rightSlot) and token1 (leftSlot)
        LeftRightSigned feesBase = s_accountFeesBase[
            keccak256(abi.encodePacked(univ3pool, owner, tokenType, tickLower, tickUpper))
        ];
        feesBase0 = feesBase.rightSlot();
        feesBase1 = feesBase.leftSlot();
    }

    /// @notice Returns the Uniswap pool for a given `poolId`.
    /// @param poolId The unique pool identifier for a Uni v3 pool
    /// @return uniswapV3Pool The Uniswap pool corresponding to `poolId`
    function getUniswapV3PoolFromId(
        uint64 poolId
    ) external view returns (IUniswapV3Pool uniswapV3Pool) {
        return s_poolIdToAddr[poolId];
    }

    /// @notice Returns the `poolId` for a given Uniswap pool.
    /// @param univ3pool The address of the Uniswap Pool
    /// @return poolId The unique pool identifier corresponding to `univ3pool`
    function getPoolId(address univ3pool) external view returns (uint64 poolId) {
        poolId = uint64(s_AddrToPoolIdData[univ3pool]);
    }
}
