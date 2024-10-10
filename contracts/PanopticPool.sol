// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Inherited implementations
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Multicall} from "@base/Multicall.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {InteractionHelper} from "@libraries/InteractionHelper.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
// Custom types
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {TokenId} from "@types/TokenId.sol";

/// @title The Panoptic Pool: Create permissionless options on a CLAMM.
/// @author Axicon Labs Limited
/// @notice Manages positions, collateral, liquidations and forced exercises.
contract PanopticPool is ERC1155Holder, Multicall {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an account is liquidated.
    /// @dev Need to unpack bonusAmounts to get raw numbers, which are always positive.
    /// @param liquidator Address of the caller liquidating the distressed account
    /// @param liquidatee Address of the distressed/liquidatable account
    /// @param bonusAmounts LeftRight encoding for the the bonus paid for token 0 (right slot) and 1 (left slot) from the Panoptic Pool to the liquidator
    event AccountLiquidated(
        address indexed liquidator,
        address indexed liquidatee,
        LeftRightSigned bonusAmounts
    );

    /// @notice Emitted when a position is force exercised.
    /// @param exercisor Address of the account that forces the exercise of the position
    /// @param user Address of the owner of the liquidated position
    /// @param tokenId TokenId of the liquidated position
    /// @param exerciseFee LeftRight encoding for the cost paid by the exercisor to force the exercise of the token;
    /// the cost for token 0 (right slot) and 1 (left slot) is represented as negative
    event ForcedExercised(
        address indexed exercisor,
        address indexed user,
        TokenId indexed tokenId,
        LeftRightSigned exerciseFee
    );

    /// @notice Emitted when premium is settled independent of a mint/burn (e.g. during `settleLongPremium`).
    /// @param user Address of the owner of the settled position
    /// @param tokenId TokenId of the settled position
    /// @param settledAmounts LeftRight encoding for the amount of premium settled for token0 (right slot) and token1 (left slot)
    event PremiumSettled(
        address indexed user,
        TokenId indexed tokenId,
        LeftRightSigned settledAmounts
    );

    /// @notice Emitted when an option is burned.
    /// @param recipient User that burnt the option
    /// @param positionSize The number of contracts burnt, expressed in terms of the asset
    /// @param tokenId TokenId of the burnt option
    /// @param premia LeftRight packing for the amount of premia collected for token0 (right) and token1 (left)
    event OptionBurnt(
        address indexed recipient,
        uint128 positionSize,
        TokenId indexed tokenId,
        LeftRightSigned premia
    );

    /// @notice Emitted when an option is minted.
    /// @param recipient User that minted the option
    /// @param positionSize The number of contracts minted, expressed in terms of the asset
    /// @param tokenId TokenId of the created option
    /// @param poolUtilizations Packing of the pool utilization (how much funds are in the Panoptic pool versus the AMM pool at the time of minting),
    /// right 64bits for token0 and left 64bits for token1, defined as (inAMM * 10_000) / totalAssets()
    /// where totalAssets is the total tracked assets in the AMM and PanopticPool minus fees and donations to the Panoptic pool
    event OptionMinted(
        address indexed recipient,
        uint128 positionSize,
        TokenId indexed tokenId,
        uint128 poolUtilizations
    );

    /*//////////////////////////////////////////////////////////////
                         IMMUTABLES & CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lower price bound used when no slippage check is required.
    int24 internal constant MIN_SWAP_TICK = Constants.MIN_V3POOL_TICK - 1;

    /// @notice Upper price bound used when no slippage check is required.
    int24 internal constant MAX_SWAP_TICK = Constants.MAX_V3POOL_TICK + 1;

    /// @notice Flag that signals to compute premia for both the short and long legs of a position.
    bool internal constant COMPUTE_ALL_PREMIA = true;
    /// @notice Flag that signals to compute premia only for the long legs of a position.
    bool internal constant COMPUTE_LONG_PREMIA = false;

    /// @notice Flag that indicates only to include the share of (settled) premium that is available to collect when calling `_calculateAccumulatedPremia`.
    bool internal constant ONLY_AVAILABLE_PREMIUM = false;

    /// @notice Flag that signals to commit both collected Uniswap fees and settled long premium to `s_settledTokens`.
    bool internal constant COMMIT_LONG_SETTLED = true;
    /// @notice Flag that signals to only commit collected Uniswap fees to `s_settledTokens`.
    bool internal constant DONOT_COMMIT_LONG_SETTLED = false;

    /// @notice Flag for `_checkSolvency` to indicate that an account should be solvent at all input ticks.
    bool internal constant ASSERT_SOLVENCY = true;

    /// @notice Flag for `_checkSolvency` to indicate that an account should be insolvent at all input ticks.
    bool internal constant ASSERT_INSOLVENCY = false;

    /// @notice Flag that signals to add a new position to the user's positions hash (as opposed to removing an existing position).
    bool internal constant ADD = true;

    /// @notice The minimum window (in seconds) used to calculate the TWAP price for solvency checks during liquidations.
    uint32 internal constant TWAP_WINDOW = 600;

    /// @notice The maximum allowed delta between the currentTick and the Uniswap TWAP tick during a liquidation (~5% down, ~5.26% up).
    /// @dev Mitigates manipulation of the currentTick that causes positions to be liquidated at a less favorable price.
    int256 internal constant MAX_TWAP_DELTA_LIQUIDATION = 513;

    /// @notice The maximum allowed cumulative delta between the fast & slow oracle tick, the current & slow oracle tick, and the last-observed & slow oracle tick.
    /// @dev Falls back on the more conservative (less solvent) tick during times of extreme volatility, where the price moves ~10% in <4 minutes.
    int256 internal constant MAX_TICKS_DELTA = 953;

    /// @notice The maximum allowed ratio for a single chunk, defined as: removedLiquidity / netLiquidity.
    /// @dev The long premium spread multiplier that corresponds with the MAX_SPREAD value depends on VEGOID,
    /// which can be explored in this calculator: https://www.desmos.com/calculator/mdeqob2m04.
    uint64 internal constant MAX_SPREAD = 9 * (2 ** 32);

    /// @notice The maximum allowed number of opened positions for a user.
    uint64 internal constant MAX_POSITIONS = 32;

    /// @notice Multiplier in basis points for the collateral requirement in the event of a buying power decrease, such as minting or force exercising another user.
    uint256 internal constant BP_DECREASE_BUFFER = 13_333;

    /// @notice Multiplier for the collateral requirement in the general case.
    uint256 internal constant NO_BUFFER = 10_000;

    /// @notice The "engine" of Panoptic - manages AMM liquidity and executes all mints/burns/exercises.
    SemiFungiblePositionManager internal immutable SFPM;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Uniswap v3 pool that this instance of Panoptic is deployed on.
    IUniswapV3Pool internal s_univ3pool;

    /// @notice Stores a sorted set of 8 price observations used to compute the internal median oracle price.
    // The data for the last 8 interactions is stored as such:
    // LAST UPDATED BLOCK TIMESTAMP (40 bits)
    // [BLOCK.TIMESTAMP]
    // (00000000000000000000000000000000) // dynamic
    //
    // ORDERING of tick indices least --> greatest (24 bits)
    // The value of the bit codon ([#]) is a pointer to a tick index in the tick array.
    // The position of the bit codon from most to least significant is the ordering of the
    // tick index it points to from least to greatest.
    //
    // [7] [5] [3] [1] [0] [2] [4] [6]
    // 111 101 011 001 000 010 100 110
    //
    // [Constants.MIN_V3POOL_TICK-1] [7]
    // 111100100111011000010111
    //
    // [Constants.MAX_V3POOL_TICK+1] [0]
    // 000011011000100111101001
    //
    // [Constants.MIN_V3POOL_TICK-1] [6]
    // 111100100111011000010111
    //
    // [Constants.MAX_V3POOL_TICK+1] [1]
    // 000011011000100111101001
    //
    // [Constants.MIN_V3POOL_TICK-1] [5]
    // 111100100111011000010111
    //
    // [Constants.MAX_V3POOL_TICK+1] [2]
    // 000011011000100111101001
    //
    // [CURRENT TICK] [4]
    // (000000000000000000000000) // dynamic
    //
    // [CURRENT TICK] [3]
    // (000000000000000000000000) // dynamic
    uint256 internal s_miniMedian;

    // ERC4626 vaults that users collateralize their positions with
    // Each token has its own vault, listed in the same order as the tokens in the pool
    // In addition to collateral deposits, these vaults also handle various collateral/bonus/exercise computations

    /// @notice Collateral vault for token0 in the Uniswap pool.
    CollateralTracker internal s_collateralToken0;
    /// @notice Collateral vault for token1 in the Uniswap pool.
    CollateralTracker internal s_collateralToken1;

    /// @notice Nested mapping that tracks the option formation: address => tokenId => leg => premiaGrowth.
    /// @dev Premia growth is taking a snapshot of the chunk premium in SFPM, which is measuring the amount of fees
    /// collected for every chunk per unit of liquidity (net or short, depending on the isLong value of the specific leg index).
    mapping(address account => mapping(TokenId tokenId => mapping(uint256 leg => LeftRightUnsigned premiaGrowth)))
        internal s_options;

    /// @notice Per-chunk `last` value that gives the aggregate amount of premium owed to all sellers when multiplied by the total amount of liquidity `totalLiquidity`.
    /// @dev totalGrossPremium = totalLiquidity * (grossPremium(perLiquidityX64) - lastGrossPremium(perLiquidityX64)) / 2**64.
    /// @dev Used to compute the denominator for the fraction of premium available to sellers to collect.
    /// @dev LeftRight - right slot is token0, left slot is token1.
    mapping(bytes32 chunkKey => LeftRightUnsigned lastGrossPremium) internal s_grossPremiumLast;

    /// @notice Per-chunk accumulator for tokens owed to sellers that have been settled and are now available.
    /// @dev This number increases when buyers pay long premium and when tokens are collected from Uniswap.
    /// @dev It decreases when sellers close positions and collect the premium they are owed.
    /// @dev LeftRight - right slot is token0, left slot is token1.
    mapping(bytes32 chunkKey => LeftRightUnsigned settledTokens) internal s_settledTokens;

    /// @notice Tracks the amount of liquidity for a user+tokenId (right slot) and the initial pool utilizations when that position was minted (left slot).
    //    poolUtilizations when minted (left)    liquidity=ERC1155 balance (right)
    //        token0          token1
    //  |<-- 64 bits -->|<-- 64 bits -->|<---------- 128 bits ---------->|
    //  |<-------------------------- 256 bits -------------------------->|
    mapping(address account => mapping(TokenId tokenId => PositionBalance positionBalance))
        internal s_positionBalance;

    //    numPositions (32 positions max)    user positions hash
    //  |<-- 8 bits -->|<------------------ 248 bits ------------------->|
    //  |<---------------------- 256 bits ------------------------------>|
    /// @notice Tracks the position list hash i.e keccak256(XORs of abi.encodePacked(positionIdList)).
    /// @dev The order and content of this list (the preimage for the hash) is emitted in an event every time it is changed.
    /// @dev A component of this hash also tracks the total number of positions (i.e. makes sure the length of the provided positionIdList matches).
    /// @dev The purpose of this system is to reduce storage usage when a user has more than one active position.
    /// @dev Instead of having to manage an unwieldy storage array and do lots of loads, we just store a hash of the array.
    /// @dev This hash can be cheaply verified on every operation with a user provided positionIdList - which can then be used for operations
    /// without having to every load any other data from storage.
    //    numPositions (32 positions max)    user positions hash
    //  |<-- 8 bits -->|<------------------ 248 bits ------------------->|
    //  |<---------------------- 256 bits ------------------------------>|
    mapping(address account => uint256 positionsHash) internal s_positionsHash;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Store the address of the canonical SemiFungiblePositionManager (SFPM) contract.
    /// @param _sfpm The address of the SFPM
    constructor(SemiFungiblePositionManager _sfpm) {
        SFPM = _sfpm;
    }

    /// @notice Initializes a Panoptic Pool on top of an existing Uniswap v3 + collateral vault pair.
    /// @dev Must be called first (by a factory contract) before any transaction can occur.
    /// @param _univ3pool Address of the target Uniswap v3 pool
    /// @param token0 Address of the pool's token0
    /// @param token1 Address of the pool's token1
    /// @param collateralTracker0 Address of the collateral vault for token0
    /// @param collateralTracker1 Address of the collateral vault for token1
    function startPool(
        IUniswapV3Pool _univ3pool,
        address token0,
        address token1,
        CollateralTracker collateralTracker0,
        CollateralTracker collateralTracker1
    ) external {
        // reverts if the Uniswap pool has already been initialized
        if (address(s_univ3pool) != address(0)) revert Errors.PoolAlreadyInitialized();

        // Store the univ3Pool variable
        s_univ3pool = IUniswapV3Pool(_univ3pool);

        (, int24 currentTick, , , , , ) = IUniswapV3Pool(_univ3pool).slot0();

        // Store the median data
        unchecked {
            s_miniMedian =
                (uint256(block.timestamp) << 216) +
                // magic number which adds (7,5,3,1,0,2,4,6) order and minTick in positions 7, 5, 3 and maxTick in 6, 4, 2
                // see comment on s_miniMedian initialization for format of this magic number
                (uint256(0xF590A6F276170D89E9F276170D89E9F276170D89E9000000000000)) +
                (uint256(uint24(currentTick)) << 24) + // add to slot 4
                (uint256(uint24(currentTick))); // add to slot 3
        }

        // Store the collateral token0
        s_collateralToken0 = collateralTracker0;
        s_collateralToken1 = collateralTracker1;

        // consolidate all 4 approval calls to one library delegatecall in order to reduce bytecode size
        // approves:
        // SFPM: token0, token1
        // CollateralTracker0 - token0
        // CollateralTracker1 - token1
        InteractionHelper.doApprovals(SFPM, collateralTracker0, collateralTracker1, token0, token1);
    }

    /*//////////////////////////////////////////////////////////////
                             QUERY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts if the caller has a lower collateral balance than required to meet the provided `minValue0` and `minValue1`.
    /// @dev Can be used for composable slippage checks with `multicall` (such as for a force exercise or liquidation).
    /// @param minValue0 The minimum acceptable `token0` value of collateral
    /// @param minValue1 The minimum acceptable `token1` value of collateral
    function assertMinCollateralValues(uint256 minValue0, uint256 minValue1) external view {
        CollateralTracker ct0 = s_collateralToken0;
        CollateralTracker ct1 = s_collateralToken1;
        if (
            ct0.convertToAssets(ct0.balanceOf(msg.sender)) < minValue0 ||
            ct1.convertToAssets(ct1.balanceOf(msg.sender)) < minValue1
        ) revert Errors.AccountInsolvent();
    }

    /// @notice Determines if account is eligible to withdraw or transfer collateral.
    /// @dev Checks whether account is solvent with `BP_DECREASE_BUFFER` according to `_validateSolvency`.
    /// @dev Prevents insolvent and near-insolvent accounts from withdrawing collateral before they are liquidated.
    /// @dev Reverts if account is not solvent with `BP_DECREASE_BUFFER`.
    /// @param user The account to check for collateral withdrawal eligibility
    /// @param positionIdList The list of all option positions held by `user`
    function validateCollateralWithdrawable(
        address user,
        TokenId[] calldata positionIdList
    ) external view {
        _validateSolvency(user, positionIdList, BP_DECREASE_BUFFER);
    }

    /// @notice Compute the total amount of premium accumulated for a list of positions.
    /// @param user Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @param includePendingPremium If true, include premium that is owed to the user but has not yet settled; if false, only include premium that is available to collect
    /// @return shortPremium The total amount of premium owed (which may `includePendingPremium`) to the short legs in `positionIdList` (token0: right slot, token1: left slot)
    /// @return longPremium The total amount of premium owed by the long legs in `positionIdList` (token0: right slot, token1: left slot)
    /// @return A list of balances and pool utilization for each position, of the form [[tokenId0, balances0], [tokenId1, balances1], ...]
    function calculateAccumulatedFeesBatch(
        address user,
        bool includePendingPremium,
        TokenId[] calldata positionIdList
    ) external view returns (LeftRightUnsigned, LeftRightUnsigned, uint256[2][] memory) {
        // Get the current tick of the Uniswap pool
        (, int24 currentTick, , , , , ) = s_univ3pool.slot0();

        // Compute the accumulated premia for all tokenId in positionIdList (includes short+long premium)
        return
            _calculateAccumulatedPremia(
                user,
                positionIdList,
                COMPUTE_ALL_PREMIA,
                includePendingPremium,
                currentTick
            );
    }

    /// @notice Calculate the accumulated premia owed from the option buyer to the option seller.
    /// @param user The holder of options
    /// @param positionIdList The list of all option positions held by user
    /// @param computeAllPremia Whether to compute accumulated premia for all legs held by the user (true), or just owed premia for long legs (false)
    /// @param includePendingPremium If true, include premium that is owed to the user but has not yet settled; if false, only include premium that is available to collect
    /// @return shortPremium The total amount of premium owed (which may `includePendingPremium`) to the short legs in `positionIdList` (token0: right slot, token1: left slot)
    /// @return longPremium The total amount of premium owed by the long legs in `positionIdList` (token0: right slot, token1: left slot)
    /// @return balances A list of balances and pool utilization for each position, of the form [[tokenId0, balances0], [tokenId1, balances1], ...]
    function _calculateAccumulatedPremia(
        address user,
        TokenId[] calldata positionIdList,
        bool computeAllPremia,
        bool includePendingPremium,
        int24 atTick
    )
        internal
        view
        returns (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            uint256[2][] memory balances
        )
    {
        uint256 pLength = positionIdList.length;
        balances = new uint256[2][](pLength);

        address c_user = user;
        // loop through each option position/tokenId
        for (uint256 k = 0; k < pLength; ) {
            TokenId tokenId = positionIdList[k];

            balances[k][0] = TokenId.unwrap(tokenId);
            balances[k][1] = PositionBalance.unwrap(s_positionBalance[c_user][tokenId]);

            (
                LeftRightSigned[4] memory premiaByLeg,
                uint256[2][4] memory premiumAccumulatorsByLeg
            ) = _getPremia(
                    tokenId,
                    LeftRightUnsigned.wrap(balances[k][1]).rightSlot(),
                    c_user,
                    computeAllPremia,
                    atTick
                );

            uint256 numLegs = tokenId.countLegs();
            for (uint256 leg = 0; leg < numLegs; ) {
                if (tokenId.isLong(leg) == 0) {
                    if (!includePendingPremium) {
                        bytes32 chunkKey = keccak256(
                            abi.encodePacked(
                                tokenId.strike(leg),
                                tokenId.width(leg),
                                tokenId.tokenType(leg)
                            )
                        );

                        (uint256 totalLiquidity, , ) = _getLiquidities(tokenId, leg);
                        LeftRightUnsigned availablePremium = _getAvailablePremium(
                            totalLiquidity,
                            s_settledTokens[chunkKey],
                            s_grossPremiumLast[chunkKey],
                            LeftRightUnsigned.wrap(
                                uint256(LeftRightSigned.unwrap(premiaByLeg[leg]))
                            ),
                            premiumAccumulatorsByLeg[leg]
                        );
                        shortPremium = shortPremium.add(availablePremium);
                    } else {
                        shortPremium = shortPremium.add(
                            LeftRightUnsigned.wrap(
                                uint256(LeftRightSigned.unwrap(premiaByLeg[leg]))
                            )
                        );
                    }
                } else {
                    longPremium = LeftRightUnsigned.wrap(
                        uint256(
                            LeftRightSigned.unwrap(
                                LeftRightSigned
                                    .wrap(int256(LeftRightUnsigned.unwrap(longPremium)))
                                    .sub(premiaByLeg[leg])
                            )
                        )
                    );
                }
                unchecked {
                    ++leg;
                }
            }

            unchecked {
                ++k;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ONBOARD MEDIAN TWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the internal median with the last Uniswap observation if the MEDIAN_PERIOD has elapsed.
    function pokeMedian() external {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = s_univ3pool.slot0();

        (, uint256 medianData) = PanopticMath.computeInternalMedian(
            observationIndex,
            observationCardinality,
            Constants.MEDIAN_PERIOD,
            s_miniMedian,
            s_univ3pool
        );

        if (medianData != 0) s_miniMedian = medianData;
    }

    /*//////////////////////////////////////////////////////////////
                          MINT/BURN INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates the current options of the user, and mints a new position.
    /// @param positionIdList The list of currently held positions by the user, where the newly minted position(token) will be the last element in 'positionIdList'
    /// @param positionSize The size of the position to be minted, expressed in terms of the asset
    /// @param effectiveLiquidityLimitX32 Maximum amount of "spread" defined as removedLiquidity/netLiquidity for a new position and
    /// denominated as X32 = (ratioLimit * 2**32)
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price
    function mintOptions(
        TokenId[] calldata positionIdList,
        uint128 positionSize,
        uint64 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external {
        _mintOptions(
            positionIdList,
            positionSize,
            effectiveLiquidityLimitX32,
            tickLimitLow,
            tickLimitHigh
        );
    }

    /// @notice Closes and burns the caller's entire balance of `tokenId`.
    /// @param tokenId The tokenId of the option position to be burnt
    /// @param newPositionIdList The new positionIdList without the token being burnt
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price
    function burnOptions(
        TokenId tokenId,
        TokenId[] calldata newPositionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external {
        _burnOptions(COMMIT_LONG_SETTLED, tokenId, msg.sender, tickLimitLow, tickLimitHigh);

        uint256 medianData = _validateSolvency(msg.sender, newPositionIdList, NO_BUFFER);

        // Update `s_miniMedian` with a new observation if the last observation is old enough (returned medianData is nonzero)
        if (medianData != 0) s_miniMedian = medianData;
    }

    /// @notice Closes and burns the caller's entire balance of each `tokenId` in `positionIdList.
    /// @param positionIdList The list of tokenIds for the option positions to be burnt
    /// @param newPositionIdList The new positionIdList without the token(s) being burnt
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price
    function burnOptions(
        TokenId[] calldata positionIdList,
        TokenId[] calldata newPositionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external {
        _burnAllOptionsFrom(
            msg.sender,
            tickLimitLow,
            tickLimitHigh,
            COMMIT_LONG_SETTLED,
            positionIdList
        );

        uint256 medianData = _validateSolvency(msg.sender, newPositionIdList, NO_BUFFER);

        // Update `s_miniMedian` with a new observation if the last observation is old enough (returned medianData is nonzero)
        if (medianData != 0) s_miniMedian = medianData;
    }

    /*//////////////////////////////////////////////////////////////
                         POSITION MINTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates the current options of the user, and mints a new position.
    /// @param positionIdList The list of currently held positions by the user, where the newly minted position(token) will be the last element in 'positionIdList'
    /// @param positionSize The size of the position to be minted, expressed in terms of the asset
    /// @param effectiveLiquidityLimitX32 Maximum amount of "spread" defined as removedLiquidity/netLiquidity for a new position and
    /// denominated as X32 = (ratioLimit * 2**32)
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price
    function _mintOptions(
        TokenId[] calldata positionIdList,
        uint128 positionSize,
        uint64 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) internal {
        // the new tokenId will be the last element in 'positionIdList'
        TokenId tokenId;
        unchecked {
            tokenId = positionIdList[positionIdList.length - 1];
        }

        // do duplicate checks and the checks related to minting and positions
        _validatePositionList(msg.sender, positionIdList, 1);

        // make sure the tokenId is for this Panoptic pool
        if (tokenId.poolId() != SFPM.getPoolId(address(s_univ3pool)))
            revert Errors.InvalidTokenIdParameter(0);

        // disallow user to mint exact same position
        // in order to do it, user should burn it first and then mint
        if (PositionBalance.unwrap(s_positionBalance[msg.sender][tokenId]) != 0)
            revert Errors.PositionAlreadyMinted();

        // Mint in the SFPM and update state of collateral
        uint32 poolUtilizations = _mintInSFPMAndUpdateCollateral(
            tokenId,
            positionSize,
            effectiveLiquidityLimitX32,
            tickLimitLow,
            tickLimitHigh
        );

        (
            int24 currentTick,
            int24 fastOracleTick,
            int24 slowOracleTick,
            int24 lastObservedTick,
            uint256 medianData
        ) = PanopticMath.getOracleTicks(s_univ3pool, s_miniMedian);

        uint96 tickData = PositionBalanceLibrary.packTickData(
            currentTick,
            fastOracleTick,
            slowOracleTick,
            lastObservedTick
        );

        // Update `s_miniMedian` with a new observation if the last observation is old enough (returned medianData is nonzero)
        if (medianData != 0) s_miniMedian = medianData;

        // update the users options balance of position 'tokenId'
        // NOTE: user can't mint same position multiple times, so set the positionSize instead of adding
        // NOTE: cannot add the tickData yet because it is computed in _validateSolvency
        s_positionBalance[msg.sender][tokenId] = PositionBalanceLibrary.storeBalanceData(
            positionSize,
            poolUtilizations,
            uint96(tickData)
        );

        // Perform solvency check on user's account to ensure they had enough buying power to mint the option
        // Add an initial buffer to the collateral requirement to prevent users from minting their account close to insolvency
        _checkSolvency(msg.sender, positionIdList, tickData, BP_DECREASE_BUFFER);

        emit OptionMinted(msg.sender, positionSize, tokenId, poolUtilizations);
    }

    /// @notice Move all the required liquidity to/from the AMM and settle any required collateral deltas.
    /// @param tokenId The option position to be minted
    /// @param positionSize The size of the position, expressed in terms of the asset
    /// @param effectiveLiquidityLimitX32 Maximum amount of "spread" defined as `removedLiquidity/netLiquidity`
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @return poolUtilizations Packing of the pool utilization (how much funds are in the Panoptic pool versus the AMM pool) at the time of minting,
    /// right 64bits for token0 and left 64bits for token1. When safeMode is active, it returns 100% pool utilization for both tokens
    function _mintInSFPMAndUpdateCollateral(
        TokenId tokenId,
        uint128 positionSize,
        uint64 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) internal returns (uint32) {
        bool safeMode = isSafeMode();

        // if safeMode, enforce covered deployment
        if (safeMode) {
            if (tickLimitLow > tickLimitHigh) {
                (tickLimitLow, tickLimitHigh) = (tickLimitHigh, tickLimitLow);
            }
        }

        (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) = SFPM
            .mintTokenizedPosition(tokenId, positionSize, tickLimitLow, tickLimitHigh);

        _updateSettlementPostMint(
            tokenId,
            collectedByLeg,
            positionSize,
            effectiveLiquidityLimitX32
        );

        uint32 poolUtilizations = _payCommissionAndWriteData(tokenId, positionSize, totalSwapped);

        if (safeMode) {
            return uint32(10_000 + (10_000 << 16));
        } else {
            return poolUtilizations;
        }
    }

    /// @notice Take the commission fees for minting `tokenId` and settle any other required collateral deltas.
    /// @param tokenId The option position
    /// @param positionSize The size of the position, expressed in terms of the asset
    /// @param totalSwapped The amount of tokens moved during creation of the option position
    /// @return Packing of the pool utilization (how much funds are in the Panoptic pool versus the AMM pool at the time of minting),
    /// right 64bits for token0 and left 64bits for token1, defined as (inAMM * 10_000) / totalAssets()
    /// where totalAssets is the total tracked assets in the AMM and PanopticPool minus fees and donations to the Panoptic pool
    function _payCommissionAndWriteData(
        TokenId tokenId,
        uint128 positionSize,
        LeftRightSigned totalSwapped
    ) internal returns (uint32) {
        // compute how much of tokenId is long and short positions
        (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
            .computeExercisedAmounts(tokenId, positionSize);

        uint32 utilization0 = s_collateralToken0.takeCommissionAddData(
            msg.sender,
            longAmounts.rightSlot(),
            shortAmounts.rightSlot(),
            totalSwapped.rightSlot()
        );
        uint32 utilization1 = s_collateralToken1.takeCommissionAddData(
            msg.sender,
            longAmounts.leftSlot(),
            shortAmounts.leftSlot(),
            totalSwapped.leftSlot()
        );

        // return pool utilizations as two uint16 (pool Utilization is always < 10000)
        unchecked {
            return utilization0 + (utilization1 << 16);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         POSITION BURNING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Close all options in `positionIdList.
    /// @param owner The owner of the option position to be closed
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price on each option close
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price on each option close
    /// @param commitLongSettled Whether to commit the long premium that will be settled to storage (disabled during liquidations)
    /// @param positionIdList The list of option positions to close
    /// @return netPaid The net amount of tokens paid after closing the positions
    /// @return premiasByLeg The amount of premia owed to the user for each leg of the position
    function _burnAllOptionsFrom(
        address owner,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool commitLongSettled,
        TokenId[] calldata positionIdList
    ) internal returns (LeftRightSigned netPaid, LeftRightSigned[4][] memory premiasByLeg) {
        premiasByLeg = new LeftRightSigned[4][](positionIdList.length);
        for (uint256 i = 0; i < positionIdList.length; ) {
            LeftRightSigned paidAmounts;
            (paidAmounts, premiasByLeg[i]) = _burnOptions(
                commitLongSettled,
                positionIdList[i],
                owner,
                tickLimitLow,
                tickLimitHigh
            );
            netPaid = netPaid.add(paidAmounts);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Close a single option position.
    /// @param tokenId The option position to burn
    /// @param owner The owner of the option position to be burned
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price on each option close
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price on each option close
    /// @param commitLongSettled Whether to commit the long premium that will be settled to storage (disabled during liquidations)
    /// @return paidAmounts The net amount of tokens paid after closing the position
    /// @return premiaByLeg The amount of premia owed to the user for each leg of the position
    function _burnOptions(
        bool commitLongSettled,
        TokenId tokenId,
        address owner,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) internal returns (LeftRightSigned paidAmounts, LeftRightSigned[4] memory premiaByLeg) {
        uint128 positionSize = s_positionBalance[owner][tokenId].positionSize();

        LeftRightSigned premiaOwed;
        // burn position and do exercise checks
        (premiaOwed, premiaByLeg, paidAmounts) = _burnAndHandleExercise(
            commitLongSettled,
            tickLimitLow,
            tickLimitHigh,
            tokenId,
            positionSize,
            owner
        );

        emit OptionBurnt(owner, positionSize, tokenId, premiaOwed);
    }

    /// @notice Validates the solvency of `user`.
    /// @dev Falls back to the more conservative tick if the delta between the fast and slow oracle exceeds `MAX_TICKS_DELTA`.
    /// @dev Effectively, this means that the users must be solvent at both the fast and slow oracle ticks if one of them is stale to mint or burn options.
    /// @param user The account to validate
    /// @param positionIdList The list of positions to validate solvency for
    /// @param buffer The buffer to apply to the collateral requirement for `user`
    /// @return medianData If nonzero (enough time has passed since last observation), the updated value for `s_miniMedian` with a new observation
    function _validateSolvency(
        address user,
        TokenId[] calldata positionIdList,
        uint256 buffer
    ) internal view returns (uint256) {
        (
            int24 currentTick,
            int24 fastOracleTick,
            int24 slowOracleTick,
            int24 lastObservedTick,
            uint256 medianData
        ) = PanopticMath.getOracleTicks(s_univ3pool, s_miniMedian);

        uint96 tickData = PositionBalanceLibrary.packTickData(
            currentTick,
            fastOracleTick,
            slowOracleTick,
            lastObservedTick
        );

        _checkSolvency(user, positionIdList, tickData, buffer);

        return medianData;
    }

    /// @notice Validates the solvency of `user` from tickData.
    /// @param user The account to validate
    /// @param positionIdList The list of positions to validate solvency for
    /// @param tickData the packed tick data to check solvency at
    /// @param buffer The buffer to apply to the collateral requirement for `user`
    function _checkSolvency(
        address user,
        TokenId[] calldata positionIdList,
        uint96 tickData,
        uint256 buffer
    ) internal view {
        // check that the provided positionIdList matches the positions in memory
        _validatePositionList(user, positionIdList, 0);

        (
            int24 currentTick,
            int24 fastOracleTick,
            int24 slowOracleTick,
            int24 lastObservedTick
        ) = PositionBalanceLibrary.unpackTickData(tickData);

        int24[] memory atTicks;
        // Fall back to a conservative approach if there's high deviation between internal ticks:
        // Check solvency at the slowOracleTick, currentTick, and lastObservedTick instead of just the fastOracleTick.
        // Deviation is measured as the magnitude of a 3D vector:
        // (fastOracleTick - slowOracleTick, lastObservedTick - slowOracleTick, currentTick - slowOracleTick)
        // This approach is more conservative than checking each tick difference individually,
        // as the Euclidean norm is always greater than or equal to the maximum of the individual differences.
        if (
            int256(fastOracleTick - slowOracleTick) ** 2 +
                int256(lastObservedTick - slowOracleTick) ** 2 +
                int256(currentTick - slowOracleTick) ** 2 >
            MAX_TICKS_DELTA ** 2
        ) {
            atTicks = new int24[](4);
            atTicks[0] = fastOracleTick;
            atTicks[1] = slowOracleTick;
            atTicks[2] = lastObservedTick;
            atTicks[3] = currentTick;
        } else {
            atTicks = new int24[](1);
            atTicks[0] = fastOracleTick;
        }

        _checkSolvencyAtTicks(user, positionIdList, currentTick, atTicks, buffer, ASSERT_SOLVENCY);
    }

    /// @notice Burns and handles the exercise of options.
    /// @param commitLongSettled Whether to commit the long premium that will be settled to storage (disabled during liquidations)
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @param tokenId The option position to burn
    /// @param positionSize The size of the option position, expressed in terms of the asset
    /// @param owner The owner of the option position
    /// @return realizedPremia The net premia paid/received from the option position
    /// @return premiaByLeg The premia owed to the user for each leg of the option position
    /// @return paidAmounts The net amount of tokens paid after closing the position
    function _burnAndHandleExercise(
        bool commitLongSettled,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        TokenId tokenId,
        uint128 positionSize,
        address owner
    )
        internal
        returns (
            LeftRightSigned realizedPremia,
            LeftRightSigned[4] memory premiaByLeg,
            LeftRightSigned paidAmounts
        )
    {
        // if safeMode, enforce covered at assignment
        if (isSafeMode()) {
            if (tickLimitLow > tickLimitHigh) {
                (tickLimitLow, tickLimitHigh) = (tickLimitHigh, tickLimitLow);
            }
        }

        (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) = SFPM
            .burnTokenizedPosition(tokenId, positionSize, tickLimitLow, tickLimitHigh);

        (realizedPremia, premiaByLeg) = _updateSettlementPostBurn(
            owner,
            tokenId,
            collectedByLeg,
            positionSize,
            commitLongSettled
        );

        (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
            .computeExercisedAmounts(tokenId, positionSize);

        {
            int128 paid0 = s_collateralToken0.exercise(
                owner,
                longAmounts.rightSlot(),
                shortAmounts.rightSlot(),
                totalSwapped.rightSlot(),
                realizedPremia.rightSlot()
            );
            paidAmounts = paidAmounts.toRightSlot(paid0);
        }

        {
            int128 paid1 = s_collateralToken1.exercise(
                owner,
                longAmounts.leftSlot(),
                shortAmounts.leftSlot(),
                totalSwapped.leftSlot(),
                realizedPremia.leftSlot()
            );
            paidAmounts = paidAmounts.toLeftSlot(paid1);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    LIQUIDATIONS & FORCED EXERCISES
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidates a distressed account. Will burn all positions and issue a bonus to the liquidator.
    /// @dev Will revert if liquidated account is solvent at the TWAP tick or if TWAP tick is too far away from the current tick.
    /// @param positionIdListLiquidator List of positions owned by the liquidator
    /// @param liquidatee Address of the distressed account
    /// @param positionIdList List of positions owned by the user. Written as [tokenId1, tokenId2, ...]
    function liquidate(
        TokenId[] calldata positionIdListLiquidator,
        address liquidatee,
        TokenId[] calldata positionIdList
    ) external {
        _validatePositionList(liquidatee, positionIdList, 0);

        // Assert the account we are liquidating is actually insolvent
        int24 twapTick = getUniV3TWAP();

        int24 currentTick;
        {
            // Enforce maximum delta between TWAP and currentTick to prevent extreme price manipulation
            int24 fastOracleTick;
            int24 lastObservedTick;
            (currentTick, fastOracleTick, , lastObservedTick, ) = PanopticMath.getOracleTicks(
                s_univ3pool,
                s_miniMedian
            );

            unchecked {
                if (Math.abs(currentTick - twapTick) > MAX_TWAP_DELTA_LIQUIDATION)
                    revert Errors.StaleTWAP();
            }

            // Ensure the account is insolvent at twapTick (in place of slowOracleTick), currentTick, fastOracleTick, and lastObservedTick
            int24[] memory atTicks = new int24[](4);
            atTicks[0] = fastOracleTick;
            atTicks[1] = twapTick;
            atTicks[2] = lastObservedTick;
            atTicks[3] = currentTick;

            _checkSolvencyAtTicks(
                liquidatee,
                positionIdList,
                currentTick,
                atTicks,
                NO_BUFFER,
                ASSERT_INSOLVENCY
            );
        }

        LeftRightUnsigned tokenData0;
        LeftRightUnsigned tokenData1;
        LeftRightUnsigned shortPremium;
        {
            uint256[2][] memory positionBalanceArray = new uint256[2][](positionIdList.length);
            LeftRightUnsigned longPremium;
            (shortPremium, longPremium, positionBalanceArray) = _calculateAccumulatedPremia(
                liquidatee,
                positionIdList,
                COMPUTE_ALL_PREMIA,
                ONLY_AVAILABLE_PREMIUM,
                currentTick
            );

            tokenData0 = s_collateralToken0.getAccountMarginDetails(
                liquidatee,
                twapTick,
                positionBalanceArray,
                shortPremium.rightSlot(),
                longPremium.rightSlot()
            );

            tokenData1 = s_collateralToken1.getAccountMarginDetails(
                liquidatee,
                twapTick,
                positionBalanceArray,
                shortPremium.leftSlot(),
                longPremium.leftSlot()
            );
        }

        // The protocol delegates some virtual shares to ensure the burn can be settled.
        s_collateralToken0.delegate(liquidatee);
        s_collateralToken1.delegate(liquidatee);

        LeftRightSigned bonusAmounts;
        {
            LeftRightSigned netPaid;
            LeftRightSigned[4][] memory premiasByLeg;
            // burn all options from the liquidatee

            // Do not commit any settled long premium to storage - we will do this after we determine if any long premium must be revoked
            // This is to prevent any short positions the liquidatee has being settled with tokens that will later be revoked
            // NOTE: tick limits are not applied here since it is not the liquidator's position being liquidated
            (netPaid, premiasByLeg) = _burnAllOptionsFrom(
                liquidatee,
                MIN_SWAP_TICK,
                MAX_SWAP_TICK,
                DONOT_COMMIT_LONG_SETTLED,
                positionIdList
            );

            LeftRightSigned collateralRemaining;
            // compute bonus amounts using latest tick data
            (bonusAmounts, collateralRemaining) = PanopticMath.getLiquidationBonus(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(twapTick),
                netPaid,
                shortPremium
            );

            // premia cannot be paid if there is protocol loss associated with the liquidatee
            // otherwise, an economic exploit could occur if the liquidator and liquidatee collude to
            // manipulate the fees in a liquidity area they control past the protocol loss threshold
            // such that the PLPs are forced to pay out premia to the liquidator
            // thus, we haircut any premium paid by the liquidatee (converting tokens as necessary) until the protocol loss is covered or the premium is exhausted
            // note that the haircutPremia function also commits the settled amounts (adjusted for the haircut) to storage, so it will be called even if there is no haircut

            // if premium is haircut from a token that is not in protocol loss, some of the liquidation bonus will be converted into that token
            address _liquidatee = liquidatee;
            int24 _twapTick = twapTick;
            TokenId[] memory _positionIdList = positionIdList;

            LeftRightSigned bonusDeltas = PanopticMath.haircutPremia(
                _liquidatee,
                _positionIdList,
                premiasByLeg,
                collateralRemaining,
                s_collateralToken0,
                s_collateralToken1,
                Math.getSqrtRatioAtTick(_twapTick),
                s_settledTokens
            );

            bonusAmounts = bonusAmounts.add(bonusDeltas);
        }

        // revoke delegated virtual shares and settle any bonus deltas with the liquidator
        s_collateralToken0.settleLiquidation(msg.sender, liquidatee, bonusAmounts.rightSlot());
        s_collateralToken1.settleLiquidation(msg.sender, liquidatee, bonusAmounts.leftSlot());

        // ensure the liquidator is still solvent after the liquidation
        _validateSolvency(msg.sender, positionIdListLiquidator, NO_BUFFER);

        emit AccountLiquidated(msg.sender, liquidatee, bonusAmounts);
    }

    /// @notice Force the exercise of a single position. Exercisor will have to pay a fee to the force exercisee.
    /// @param account Address of the distressed account
    /// @param touchedId List of position to be force exercised. Can only contain one tokenId, written as [tokenId]
    /// @param positionIdListExercisee Post-burn list of open positions in the exercisee's (account) account
    /// @param positionIdListExercisor List of open positions in the exercisor's (msg.sender) account
    function forceExercise(
        address account,
        TokenId[] calldata touchedId,
        TokenId[] calldata positionIdListExercisee,
        TokenId[] calldata positionIdListExercisor
    ) external {
        // revert if multiple positions are specified
        // the reason why the singular touchedId is an array is so it composes well with the rest of the system
        // '_calculateAccumulatedPremia' expects a list of positions to be touched, and this is the only way to pass a single position
        if (touchedId.length != 1) revert Errors.InputListFail();

        // validate the exercisor's position list (the exercisee's list will be evaluated after their position is force exercised)
        _validatePositionList(msg.sender, positionIdListExercisor, 0);

        int24 twapTick = getUniV3TWAP();

        // to be eligible for force exercise, the price *must* be outside the position's range for at least 1 leg
        touchedId[0].validateIsExercisable(twapTick);

        LeftRightSigned exerciseFees;
        {
            (, int24 currentTick, , , , , ) = s_univ3pool.slot0();

            uint128 positionSize = s_positionBalance[account][touchedId[0]].positionSize();

            (LeftRightSigned longAmounts, ) = PanopticMath.computeExercisedAmounts(
                touchedId[0],
                positionSize
            );

            // Compute the exerciseFee, this will decrease the further away the price is from the exercised position
            // Include any deltas in long legs between the current and oracle tick in the exercise fee
            exerciseFees = s_collateralToken0.exerciseCost(
                currentTick,
                twapTick,
                touchedId[0],
                positionSize,
                longAmounts
            );
        }

        // The protocol delegates some virtual shares to ensure the burn can be settled.
        s_collateralToken0.delegate(account);
        s_collateralToken1.delegate(account);

        // Exercise the option
        // Turn off ITM swapping to prevent swap at potentially unfavorable price
        _burnAllOptionsFrom(account, MIN_SWAP_TICK, MAX_SWAP_TICK, COMMIT_LONG_SETTLED, touchedId);

        // redistribute token composition of refund amounts if user doesn't have enough of one token to pay
        LeftRightSigned refundAmounts = PanopticMath.getExerciseDeltas(
            account,
            exerciseFees,
            twapTick,
            s_collateralToken0,
            s_collateralToken1
        );

        // settle difference between delegated amounts (from the protocol) and exercise fees/substituted tokens
        s_collateralToken0.refund(account, msg.sender, refundAmounts.rightSlot());
        s_collateralToken1.refund(account, msg.sender, refundAmounts.leftSlot());

        // revoke the virtual shares that were delegated after settling the difference with the exercisor
        s_collateralToken0.revoke(account);
        s_collateralToken1.revoke(account);

        _validateSolvency(account, positionIdListExercisee, NO_BUFFER);

        // the exercisor's position list is validated above
        // we need to assert their solvency against their collateral requirement plus a buffer
        // force exercises involve a collateral decrease with open positions, so there is a higher standard for solvency
        // a similar buffer is also invoked when minting options, which also decreases the available collateral
        if (positionIdListExercisor.length > 0)
            _validateSolvency(msg.sender, positionIdListExercisor, BP_DECREASE_BUFFER);

        emit ForcedExercised(msg.sender, account, touchedId[0], exerciseFees);
    }

    /*//////////////////////////////////////////////////////////////
                            SOLVENCY CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check whether an account is solvent at a given `atTick` with a collateral requirement of `buffer`/10_000 multiplied by the requirement of `positionIdList`.
    /// @dev this will return true if solvent at any of the provided tick, and return false iff the account is insolvent at all ticks.
    /// @param account The account to check solvency for
    /// @param positionIdList The list of positions to check solvency for
    /// @param currentTick The current tick of the Uniswap pool (needed for fee calculations)
    /// @param atTicks An array of ticks to check solvency at
    /// @param buffer The buffer to apply to the collateral requirement
    /// @param expectedSolvent Whether the account is expected to be solvent (true) or insolvent (false) at all provided `atTicks`
    function _checkSolvencyAtTicks(
        address account,
        TokenId[] calldata positionIdList,
        int24 currentTick,
        int24[] memory atTicks,
        uint256 buffer,
        bool expectedSolvent
    ) internal view {
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            uint256[2][] memory positionBalanceArray
        ) = _calculateAccumulatedPremia(
                account,
                positionIdList,
                COMPUTE_ALL_PREMIA,
                ONLY_AVAILABLE_PREMIUM,
                currentTick
            );

        uint256 numberOfTicks = atTicks.length;

        // must combine solvency checks as uint because bool would automatically return false for (false && _check),
        uint8 solvent;
        for (uint256 i; i < numberOfTicks; ) {
            unchecked {
                solvent += (
                    _isAccountSolvent(
                        account,
                        atTicks[i],
                        positionBalanceArray,
                        shortPremium,
                        longPremium,
                        buffer
                    )
                        ? uint8(1)
                        : uint8(0)
                );

                ++i;
            }
        }

        if (expectedSolvent && solvent != numberOfTicks) revert Errors.AccountInsolvent();
        if (!expectedSolvent && solvent != 0) revert Errors.NotMarginCalled();
    }

    /// @notice Check whether an account is solvent at a given `atTick` with a collateral requirement of `buffer`/10_000 multiplied by the requirement of `positionBalanceArray`.
    /// @param account The account to check solvency for
    /// @param atTick The tick to check solvency at
    /// @param positionBalanceArray A list of balances and pool utilization for each position, of the form [[tokenId0, balances0], [tokenId1, balances1], ...]
    /// @param shortPremium The total amount of premium (prorated by available settled tokens) owed to the short legs of `account`
    /// @param longPremium The total amount of premium owed by the long legs of `account`
    /// @param buffer The buffer to apply to the collateral requirement
    /// @return Whether the account is solvent at the given tick
    function _isAccountSolvent(
        address account,
        int24 atTick,
        uint256[2][] memory positionBalanceArray,
        LeftRightUnsigned shortPremium,
        LeftRightUnsigned longPremium,
        uint256 buffer
    ) internal view returns (bool) {
        LeftRightUnsigned tokenData0 = s_collateralToken0.getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            shortPremium.rightSlot(),
            longPremium.rightSlot()
        );
        LeftRightUnsigned tokenData1 = s_collateralToken1.getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            shortPremium.leftSlot(),
            longPremium.leftSlot()
        );

        (uint256 balanceCross, uint256 thresholdCross) = PanopticMath.getCrossBalances(
            tokenData0,
            tokenData1,
            Math.getSqrtRatioAtTick(atTick)
        );

        // compare balance and required tokens, can use unsafe div because denominator is always nonzero
        return balanceCross >= Math.mulDivRoundingUp(thresholdCross, buffer, 10_000);
    }

    /// @notice Checks whether the current tick has deviated too much from the slow oracle median tick.
    /// @return Whether the current tick has deviated from the median by > MAX_TICKS_DELTA
    function isSafeMode() public view returns (bool) {
        // check if the price has deviated too much recently
        (, int24 currentTick, , , , , ) = s_univ3pool.slot0();

        uint256 medianData = s_miniMedian;
        unchecked {
            int24 medianTick = (int24(
                uint24(medianData >> ((uint24(medianData >> (192 + 3 * 3)) % 8) * 24))
            ) + int24(uint24(medianData >> ((uint24(medianData >> (192 + 3 * 4)) % 8) * 24)))) / 2;

            // If ticks have recently deviated more than +/- 10%, enforce covered mints
            return Math.abs(currentTick - medianTick) > MAX_TICKS_DELTA;
        }
    }

    /*//////////////////////////////////////////////////////////////
                 POSITIONS HASH GENERATION & VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Makes sure that the positions in the incoming user's list match the existing active option positions.
    /// @param account The owner of the incoming list of positions
    /// @param positionIdList The existing list of active options for the owner
    /// @param offset The amount of positions from the end of the list to exclude from validation
    function _validatePositionList(
        address account,
        TokenId[] calldata positionIdList,
        uint256 offset
    ) internal view {
        uint256 pLength;
        uint256 currentHash = s_positionsHash[account];

        unchecked {
            pLength = positionIdList.length - offset;
        }

        uint256 fingerprintIncomingList;

        for (uint256 i = 0; i < pLength; ) {
            fingerprintIncomingList = PanopticMath.updatePositionsHash(
                fingerprintIncomingList,
                positionIdList[i],
                ADD
            );
            unchecked {
                ++i;
            }
        }

        // revert if fingerprint for provided '_positionIdList' does not match the one stored for the '_account'
        if (fingerprintIncomingList != currentHash) revert Errors.InputListFail();
    }

    /// @notice Updates the hash for all positions owned by an account. This fingerprints the list of all incoming options with a single hash.
    /// @dev The outcome of this function will be to update the hash of positions.
    /// This is done as a duplicate/validation check of the incoming list O(N).
    /// @dev The positions hash is stored as the XOR of the keccak256 of each tokenId. Updating will XOR the existing hash with the new tokenId.
    /// The same update can either add a new tokenId (when minting an option), or remove an existing one (when burning it).
    /// @param account The owner of `tokenId`
    /// @param tokenId The option position
    /// @param addFlag Whether to add `tokenId` to the hash (true) or remove it (false)
    function _updatePositionsHash(address account, TokenId tokenId, bool addFlag) internal {
        // Get the current position hash value (fingerprint of all pre-existing positions created by '_account')
        // Add the current tokenId to the positionsHash as XOR'd
        // since 0 ^ x = x, no problem on first mint
        // Store values back into the user option details with the updated hash (leaves the other parameters unchanged)
        uint256 newHash = PanopticMath.updatePositionsHash(
            s_positionsHash[account],
            tokenId,
            addFlag
        );
        if ((newHash >> 248) > MAX_POSITIONS) revert Errors.TooManyPositionsOpen();
        s_positionsHash[account] = newHash;
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the address of the AMM pool connected to this Panoptic pool.
    /// @return AMM pool corresponding to this Panoptic pool
    function univ3pool() external view returns (IUniswapV3Pool) {
        return s_univ3pool;
    }

    /// @notice Get the collateral token corresponding to token0 of the AMM pool.
    /// @return Collateral token corresponding to token0 in the AMM
    function collateralToken0() external view returns (CollateralTracker) {
        return s_collateralToken0;
    }

    /// @notice Get the collateral token corresponding to token1 of the AMM pool.
    /// @return Collateral token corresponding to token1 in the AMM
    function collateralToken1() external view returns (CollateralTracker) {
        return s_collateralToken1;
    }

    /// @notice Computes and returns all oracle ticks.
    /// @return currentTick The current tick in the Uniswap pool
    /// @return fastOracleTick The fast oracle tick computed as the median of the past N observations in the Uniswap Pool
    /// @return slowOracleTick The slow oracle tick (either composed of Uniswap observations or tracked by `s_miniMedian`)
    /// @return latestObservation The latest observation from the Uniswap pool
    /// @return medianData The updated value for `s_miniMedian` (0 if MEDIAN_PERIOD not elapsed) if `pokeMedian` is called at the current state
    function getOracleTicks()
        external
        view
        returns (
            int24 currentTick,
            int24 fastOracleTick,
            int24 slowOracleTick,
            int24 latestObservation,
            uint256 medianData
        )
    {
        (currentTick, fastOracleTick, slowOracleTick, latestObservation, ) = PanopticMath
            .getOracleTicks(s_univ3pool, s_miniMedian);
        medianData = s_miniMedian;
    }

    /// @notice Get the current number of open positions for an account.
    /// @param user The account to query
    /// @return Number of open positions for `user`
    function numberOfPositions(address user) external view returns (uint256) {
        return s_positionsHash[user] >> 248;
    }

    /// @notice Get the `tokenId` position data for `user`.
    /// @param user The account that owns `tokenId`
    /// @param tokenId The position to query
    /// @return `currentTick` at mint
    /// @return Fast oracle tick at mint
    /// @return Slow oracle tick at mint
    /// @return Last observed tick at mint
    /// @return Utilization of token0 at mint
    /// @return Utilization of token1 at mint
    /// @return Size of the position
    function positionData(
        address user,
        TokenId tokenId
    ) external view returns (int24, int24, int24, int24, int256, int256, uint128) {
        return s_positionBalance[user][tokenId].unpackAll();
    }

    /// @notice Get the oracle price used to check solvency in liquidations.
    /// @return twapTick The current oracle price used to check solvency in liquidations
    function getUniV3TWAP() internal view returns (int24 twapTick) {
        twapTick = PanopticMath.twapFilter(s_univ3pool, TWAP_WINDOW);
    }

    /*//////////////////////////////////////////////////////////////
                  PREMIA & PREMIA SPREAD CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensure the effective liquidity in a given chunk is above a certain threshold.
    /// @param tokenId An option position
    /// @param leg A leg index of `tokenId` corresponding to a tickLower-tickUpper chunk
    /// @param effectiveLiquidityLimitX32 Maximum amount of "spread" defined as removedLiquidity/netLiquidity for a new position
    /// denominated as X32 = (ratioLimit * 2**32)
    /// @return totalLiquidity The total liquidity deposited in that chunk: `totalLiquidity = netLiquidity + removedLiquidity`
    function _checkLiquiditySpread(
        TokenId tokenId,
        uint256 leg,
        uint64 effectiveLiquidityLimitX32
    ) internal view returns (uint256 totalLiquidity) {
        uint128 netLiquidity;
        uint128 removedLiquidity;
        (totalLiquidity, netLiquidity, removedLiquidity) = _getLiquidities(tokenId, leg);

        // compute and return effective liquidity. Return if short=net=0, which is closing short position
        if (netLiquidity == 0 && removedLiquidity == 0) return totalLiquidity;

        uint256 effectiveLiquidityFactorX32;
        unchecked {
            effectiveLiquidityFactorX32 = (uint256(removedLiquidity) * 2 ** 32) / netLiquidity;
        }

        // put a limit on how much new liquidity in one transaction can be deployed into this leg
        // the effective liquidity measures how many times more the newly added liquidity is compared to the existing/base liquidity
        if (effectiveLiquidityFactorX32 > uint256(effectiveLiquidityLimitX32))
            revert Errors.EffectiveLiquidityAboveThreshold();
    }

    /// @notice Compute the premia collected for a single option position 'tokenId'.
    /// @param tokenId The option position
    /// @param positionSize The number of contracts (size) of the option position
    /// @param owner The holder of the tokenId option
    /// @param computeAllPremia Whether to compute accumulated premia for all legs held by the user (true), or just owed premia for long legs (false)
    /// @param atTick The tick at which the premia is calculated -> use (atTick < type(int24).max) to compute it
    /// up to current block. atTick = type(int24).max will only consider fees as of the last on-chain transaction
    /// @return premiaByLeg The amount of premia owed to the user for each leg of the position
    /// @return premiumAccumulatorsByLeg The amount of premia accumulated for each leg of the position
    function _getPremia(
        TokenId tokenId,
        uint128 positionSize,
        address owner,
        bool computeAllPremia,
        int24 atTick
    )
        internal
        view
        returns (
            LeftRightSigned[4] memory premiaByLeg,
            uint256[2][4] memory premiumAccumulatorsByLeg
        )
    {
        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            uint256 isLong = tokenId.isLong(leg);
            if ((isLong == 1) || computeAllPremia) {
                LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize
                );
                uint256 tokenType = tokenId.tokenType(leg);

                (premiumAccumulatorsByLeg[leg][0], premiumAccumulatorsByLeg[leg][1]) = SFPM
                    .getAccountPremium(
                        address(s_univ3pool),
                        address(this),
                        tokenType,
                        liquidityChunk.tickLower(),
                        liquidityChunk.tickUpper(),
                        atTick,
                        isLong
                    );

                unchecked {
                    LeftRightUnsigned premiumAccumulatorLast = s_options[owner][tokenId][leg];

                    premiaByLeg[leg] = LeftRightSigned
                        .wrap(0)
                        .toRightSlot(
                            int128(
                                int256(
                                    ((premiumAccumulatorsByLeg[leg][0] -
                                        premiumAccumulatorLast.rightSlot()) *
                                        (liquidityChunk.liquidity())) / 2 ** 64
                                )
                            )
                        )
                        .toLeftSlot(
                            int128(
                                int256(
                                    ((premiumAccumulatorsByLeg[leg][1] -
                                        premiumAccumulatorLast.leftSlot()) *
                                        (liquidityChunk.liquidity())) / 2 ** 64
                                )
                            )
                        );
                }

                if (isLong == 1) {
                    premiaByLeg[leg] = LeftRightSigned.wrap(0).sub(premiaByLeg[leg]);
                }
            }
            unchecked {
                ++leg;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        AVAILABLE PREMIUM LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle unpaid premium for one `legIndex` on a position owned by `owner`.
    /// @dev Called by sellers on buyers of their chunk to increase the available premium for withdrawal (before closing their position).
    /// @dev This feature is only available when `owner` is solvent and has the requisite tokens to settle the premium.
    /// @param positionIdList Exhaustive list of open positions for `owner` used for solvency checks where the tokenId to settle is placed at the last index
    /// @param owner The owner of the option position to make premium payments on
    /// @param legIndex the index of the leg in tokenId that is to be collected on (must be isLong=1)
    function settleLongPremium(
        TokenId[] calldata positionIdList,
        address owner,
        uint256 legIndex
    ) external {
        _validatePositionList(owner, positionIdList, 0);

        TokenId tokenId = positionIdList[positionIdList.length - 1];

        if (tokenId.isLong(legIndex) == 0 || legIndex > 3) revert Errors.NotALongLeg();

        LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
            tokenId,
            legIndex,
            s_positionBalance[owner][tokenId].positionSize()
        );

        (, int24 currentTick, , , , , ) = s_univ3pool.slot0();

        LeftRightUnsigned accumulatedPremium;
        {
            uint256 tokenType = tokenId.tokenType(legIndex);
            (uint128 premiumAccumulator0, uint128 premiumAccumulator1) = SFPM.getAccountPremium(
                address(s_univ3pool),
                address(this),
                tokenType,
                liquidityChunk.tickLower(),
                liquidityChunk.tickUpper(),
                currentTick,
                1
            );
            accumulatedPremium = LeftRightUnsigned.wrap(premiumAccumulator0).toLeftSlot(
                premiumAccumulator1
            );

            // update the premium accumulator for the long position to the latest value
            // (the entire premia delta will be settled)
            LeftRightUnsigned premiumAccumulatorsLast = s_options[owner][tokenId][legIndex];
            s_options[owner][tokenId][legIndex] = accumulatedPremium;

            accumulatedPremium = accumulatedPremium.sub(premiumAccumulatorsLast);
        }

        unchecked {
            uint256 liquidity = liquidityChunk.liquidity();

            // update the realized premia
            LeftRightSigned realizedPremia = LeftRightSigned
                .wrap(0)
                .toRightSlot(int128(int256((accumulatedPremium.rightSlot() * liquidity) / 2 ** 64)))
                .toLeftSlot(int128(int256((accumulatedPremium.leftSlot() * liquidity) / 2 ** 64)));

            // deduct the paid premium tokens from the owner's balance and add them to the cumulative settled token delta
            s_collateralToken0.exercise(owner, 0, 0, 0, -realizedPremia.rightSlot());
            s_collateralToken1.exercise(owner, 0, 0, 0, -realizedPremia.leftSlot());

            bytes32 chunkKey = keccak256(
                abi.encodePacked(
                    tokenId.strike(legIndex),
                    tokenId.width(legIndex),
                    tokenId.tokenType(legIndex)
                )
            );
            // commit the delta in settled tokens (all of the premium paid by long chunks in the tokenIds list) to storage
            s_settledTokens[chunkKey] = s_settledTokens[chunkKey].add(
                LeftRightUnsigned.wrap(uint256(LeftRightSigned.unwrap(realizedPremia)))
            );

            emit PremiumSettled(owner, tokenId, realizedPremia);
        }

        // ensure the owner is solvent (insolvent accounts are not permitted to pay premium unless they are being liquidated)
        _validateSolvency(owner, positionIdList, NO_BUFFER);
    }

    /// @notice Adds collected tokens to `s_settledTokens` and adjusts `s_grossPremiumLast` for any liquidity added.
    /// @dev Always called after `mintTokenizedPosition`
    /// @param tokenId The option position that was minted
    /// @param collectedByLeg The amount of tokens collected in the corresponding chunk for each leg of the position
    /// @param positionSize The size of the position, expressed in terms of the asset
    /// @param effectiveLiquidityLimitX32 Maximum amount of "spread" defined as `removedLiquidity/netLiquidity`
    function _updateSettlementPostMint(
        TokenId tokenId,
        LeftRightUnsigned[4] memory collectedByLeg,
        uint128 positionSize,
        uint64 effectiveLiquidityLimitX32
    ) internal {
        // ADD the current tokenId to the position list hash (hash = XOR of all keccak256(tokenId))
        // and increase the number of positions counter by 1.
        _updatePositionsHash(msg.sender, tokenId, ADD);

        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ++leg) {
            uint256 isLong = tokenId.isLong(leg);

            bytes32 chunkKey = keccak256(
                abi.encodePacked(tokenId.strike(leg), tokenId.width(leg), tokenId.tokenType(leg))
            );

            // add any tokens collected from Uniswap in a given chunk to the settled tokens available for withdrawal by sellers
            s_settledTokens[chunkKey] = s_settledTokens[chunkKey].add(collectedByLeg[leg]);

            LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                tokenId,
                leg,
                positionSize
            );

            uint256 grossCurrent0;
            uint256 grossCurrent1;
            {
                uint256 tokenType = tokenId.tokenType(leg);
                // can use (type(int24).max flag because premia accumulators were updated during the mintTokenizedPosition step.
                (grossCurrent0, grossCurrent1) = SFPM.getAccountPremium(
                    address(s_univ3pool),
                    address(this),
                    tokenType,
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper(),
                    type(int24).max,
                    isLong
                );

                s_options[msg.sender][tokenId][leg] = LeftRightUnsigned
                    .wrap(uint128(grossCurrent0))
                    .toLeftSlot(uint128(grossCurrent1));
            }

            // if position is long, ensure that removed liquidity does not deplete strike beyond min(MAX_SPREAD, user-provided effectiveLiquidityLimit)
            // new totalLiquidity (total sold) = removedLiquidity + netLiquidity (R + N)
            uint256 totalLiquidity = _checkLiquiditySpread(
                tokenId,
                leg,
                isLong == 0 ? MAX_SPREAD : uint64(Math.min(effectiveLiquidityLimitX32, MAX_SPREAD))
            );

            // if position is short, adjust `grossPremiumLast` upward to account for the increase in short liquidity
            if (isLong == 0) {
                unchecked {
                    // L
                    LeftRightUnsigned grossPremiumLast = s_grossPremiumLast[chunkKey];
                    // R
                    uint256 positionLiquidity = liquidityChunk.liquidity();
                    // T (totalLiquidity is (T + R) after minting)
                    uint256 totalLiquidityBefore = totalLiquidity - positionLiquidity;

                    // We need to adjust the grossPremiumLast value such that the result of
                    // (grossPremium - adjustedGrossPremiumLast) * updatedTotalLiquidityPostMint / 2**64 is equal to (grossPremium - grossPremiumLast) * totalLiquidityBeforeMint / 2**64
                    // G: total gross premium
                    // T: totalLiquidityBeforeMint
                    // R: positionLiquidity
                    // C: current grossPremium value
                    // L: current grossPremiumLast value
                    // Ln: updated grossPremiumLast value
                    // T * (C - L) = G
                    // (T + R) * (C - Ln) = G
                    //
                    // T * (C - L) = (T + R) * (C - Ln)
                    // (TC - TL) / (T + R) = C - Ln
                    // Ln = C - (TC - TL)/(T + R)
                    // Ln = (CT + CR - TC + TL)/(T+R)
                    // Ln = (CR + TL)/(T+R)

                    s_grossPremiumLast[chunkKey] = LeftRightUnsigned
                        .wrap(
                            uint128(
                                (grossCurrent0 *
                                    positionLiquidity +
                                    grossPremiumLast.rightSlot() *
                                    totalLiquidityBefore) / totalLiquidity
                            )
                        )
                        .toLeftSlot(
                            uint128(
                                (grossCurrent1 *
                                    positionLiquidity +
                                    grossPremiumLast.leftSlot() *
                                    totalLiquidityBefore) / totalLiquidity
                            )
                        );
                }
            }
        }
    }

    /// @notice Query the amount of premium available for withdrawal given a certain `premiumOwed` for a chunk.
    /// @dev Based on the ratio between `settledTokens` and the total premium owed to sellers in a chunk.
    /// @dev The ratio is capped at 1 (as the base ratio can be greater than one if some seller forfeits enough premium).
    /// @param totalLiquidity The updated total liquidity amount for the chunk
    /// @param settledTokens LeftRight accumulator for the amount of tokens that have been settled (collected or paid)
    /// @param grossPremiumLast The `last` values used with `premiumAccumulators` to compute the total premium owed to sellers
    /// @param premiumOwed The amount of premium owed to sellers in the chunk
    /// @param premiumAccumulators The current values of the premium accumulators for the chunk
    /// @return The amount of token0/token1 premium available for withdrawal
    function _getAvailablePremium(
        uint256 totalLiquidity,
        LeftRightUnsigned settledTokens,
        LeftRightUnsigned grossPremiumLast,
        LeftRightUnsigned premiumOwed,
        uint256[2] memory premiumAccumulators
    ) internal pure returns (LeftRightUnsigned) {
        unchecked {
            // long premium only accumulates as it is settled, so compute the ratio
            // of total settled tokens in a chunk to total premium owed to sellers and multiply
            // cap the ratio at 1 (it can be greater than one if some seller forfeits enough premium)
            uint256 accumulated0 = ((premiumAccumulators[0] - grossPremiumLast.rightSlot()) *
                totalLiquidity) / 2 ** 64;
            uint256 accumulated1 = ((premiumAccumulators[1] - grossPremiumLast.leftSlot()) *
                totalLiquidity) / 2 ** 64;

            return (
                LeftRightUnsigned
                    .wrap(
                        uint128(
                            Math.min(
                                (uint256(premiumOwed.rightSlot()) * settledTokens.rightSlot()) /
                                    (accumulated0 == 0 ? type(uint256).max : accumulated0),
                                premiumOwed.rightSlot()
                            )
                        )
                    )
                    .toLeftSlot(
                        uint128(
                            Math.min(
                                (uint256(premiumOwed.leftSlot()) * settledTokens.leftSlot()) /
                                    (accumulated1 == 0 ? type(uint256).max : accumulated1),
                                premiumOwed.leftSlot()
                            )
                        )
                    )
            );
        }
    }

    /// @notice Query the total amount of liquidity sold in the corresponding chunk for a position leg.
    /// @dev totalLiquidity (total sold) = removedLiquidity + netLiquidity (in AMM).
    /// @param tokenId The option position
    /// @param leg The leg of the option position to get `totalLiquidity` for
    /// @return totalLiquidity The total amount of liquidity sold in the corresponding chunk for a position leg
    /// @return netLiquidity The amount of liquidity available in the corresponding chunk for a position leg
    /// @return removedLiquidity The amount of liquidity removed through buying in the corresponding chunk for a position leg
    function _getLiquidities(
        TokenId tokenId,
        uint256 leg
    )
        internal
        view
        returns (uint256 totalLiquidity, uint128 netLiquidity, uint128 removedLiquidity)
    {
        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(leg);

        LeftRightUnsigned accountLiquidities = SFPM.getAccountLiquidity(
            address(s_univ3pool),
            address(this),
            tokenId.tokenType(leg),
            tickLower,
            tickUpper
        );

        netLiquidity = accountLiquidities.rightSlot();
        removedLiquidity = accountLiquidities.leftSlot();

        unchecked {
            totalLiquidity = netLiquidity + removedLiquidity;
        }
    }

    /// @notice Updates settled tokens and grossPremiumLast for a chunk after a burn and returns premium info.
    /// @param owner The owner of the option position that was burnt
    /// @param tokenId The option position that was burnt
    /// @param collectedByLeg The amount of tokens collected in the corresponding chunk for each leg of the position
    /// @param positionSize The size of the position, expressed in terms of the asset
    /// @param commitLongSettled Whether to commit the long premium that will be settled to storage
    /// @return realizedPremia The amount of premia owed to the user
    /// @return premiaByLeg The amount of premia owed to the user for each leg of the position
    function _updateSettlementPostBurn(
        address owner,
        TokenId tokenId,
        LeftRightUnsigned[4] memory collectedByLeg,
        uint128 positionSize,
        bool commitLongSettled
    ) internal returns (LeftRightSigned realizedPremia, LeftRightSigned[4] memory premiaByLeg) {
        uint256 numLegs = tokenId.countLegs();
        uint256[2][4] memory premiumAccumulatorsByLeg;

        // compute accumulated fees
        (premiaByLeg, premiumAccumulatorsByLeg) = _getPremia(
            tokenId,
            positionSize,
            owner,
            COMPUTE_ALL_PREMIA,
            type(int24).max
        );

        for (uint256 leg = 0; leg < numLegs; ) {
            LeftRightSigned legPremia = premiaByLeg[leg];

            bytes32 chunkKey = keccak256(
                abi.encodePacked(tokenId.strike(leg), tokenId.width(leg), tokenId.tokenType(leg))
            );

            // collected from Uniswap
            LeftRightUnsigned settledTokens = s_settledTokens[chunkKey].add(collectedByLeg[leg]);

            // (will be) paid by long legs
            if (tokenId.isLong(leg) == 1) {
                if (commitLongSettled)
                    settledTokens = LeftRightUnsigned.wrap(
                        uint256(
                            LeftRightSigned.unwrap(
                                LeftRightSigned
                                    .wrap(int256(LeftRightUnsigned.unwrap(settledTokens)))
                                    .sub(legPremia)
                            )
                        )
                    );
                realizedPremia = realizedPremia.add(legPremia);
            } else {
                uint256 positionLiquidity;
                uint256 totalLiquidity;
                {
                    LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                        tokenId,
                        leg,
                        positionSize
                    );
                    positionLiquidity = liquidityChunk.liquidity();

                    // if position is short, ensure that removed liquidity does not deplete strike beyond MAX_SPREAD when closed
                    // new totalLiquidity (total sold) = removedLiquidity + netLiquidity (T - R)
                    totalLiquidity = _checkLiquiditySpread(tokenId, leg, MAX_SPREAD);
                }
                // T (totalLiquidity is (T - R) after burning)
                uint256 totalLiquidityBefore = totalLiquidity + positionLiquidity;

                LeftRightUnsigned grossPremiumLast = s_grossPremiumLast[chunkKey];

                LeftRightUnsigned availablePremium = _getAvailablePremium(
                    totalLiquidity + positionLiquidity,
                    settledTokens,
                    grossPremiumLast,
                    LeftRightUnsigned.wrap(uint256(LeftRightSigned.unwrap(legPremia))),
                    premiumAccumulatorsByLeg[leg]
                );

                // subtract settled tokens sent to seller
                settledTokens = settledTokens.sub(availablePremium);

                // add available premium to amount that should be settled
                realizedPremia = realizedPremia.add(
                    LeftRightSigned.wrap(int256(LeftRightUnsigned.unwrap(availablePremium)))
                );

                // We need to adjust the grossPremiumLast value such that the result of
                // (grossPremium - adjustedGrossPremiumLast) * updatedTotalLiquidityPostBurn / 2**64 is equal to
                // (grossPremium - grossPremiumLast) * totalLiquidityBeforeBurn / 2**64 - premiumOwedToPosition
                // G: total gross premium (- premiumOwedToPosition)
                // T: totalLiquidityBeforeMint
                // R: positionLiquidity
                // C: current grossPremium value
                // L: current grossPremiumLast value
                // Ln: updated grossPremiumLast value
                // T * (C - L) = G
                // (T - R) * (C - Ln) = G - P
                //
                // T * (C - L) = (T - R) * (C - Ln) + P
                // (TC - TL - P) / (T - R) = C - Ln
                // Ln = C - (TC - TL - P) / (T - R)
                // Ln = (TC - CR - TC + LT + P) / (T-R)
                // Ln = (LT - CR + P) / (T-R)

                unchecked {
                    uint256[2][4] memory _premiumAccumulatorsByLeg = premiumAccumulatorsByLeg;
                    uint256 _leg = leg;

                    // if there's still liquidity, compute the new grossPremiumLast
                    // otherwise, we just reset grossPremiumLast to the current grossPremium
                    s_grossPremiumLast[chunkKey] = totalLiquidity != 0
                        ? LeftRightUnsigned
                            .wrap(
                                uint128(
                                    uint256(
                                        Math.max(
                                            (int256(
                                                grossPremiumLast.rightSlot() * totalLiquidityBefore
                                            ) -
                                                int256(
                                                    _premiumAccumulatorsByLeg[_leg][0] *
                                                        positionLiquidity
                                                )) + int256(legPremia.rightSlot() * 2 ** 64),
                                            0
                                        )
                                    ) / totalLiquidity
                                )
                            )
                            .toLeftSlot(
                                uint128(
                                    uint256(
                                        Math.max(
                                            (int256(
                                                grossPremiumLast.leftSlot() * totalLiquidityBefore
                                            ) -
                                                int256(
                                                    _premiumAccumulatorsByLeg[_leg][1] *
                                                        positionLiquidity
                                                )) + int256(legPremia.leftSlot()) * 2 ** 64,
                                            0
                                        )
                                    ) / totalLiquidity
                                )
                            )
                        : LeftRightUnsigned
                            .wrap(uint128(premiumAccumulatorsByLeg[_leg][0]))
                            .toLeftSlot(uint128(premiumAccumulatorsByLeg[_leg][1]));
                }
            }
            // update settled tokens in storage with all local deltas
            s_settledTokens[chunkKey] = settledTokens;

            // erase the s_options entry for that leg
            s_options[owner][tokenId][leg] = LeftRightUnsigned.wrap(0);

            unchecked {
                ++leg;
            }
        }

        // reset balances and delete stored option data
        s_positionBalance[owner][tokenId] = PositionBalance.wrap(0);

        // REMOVE the current tokenId from the position list hash (hash = XOR of all keccak256(tokenId), remove by XOR'ing again)
        // and decrease the number of positions counter by 1.
        _updatePositionsHash(owner, tokenId, !ADD);
    }
}
