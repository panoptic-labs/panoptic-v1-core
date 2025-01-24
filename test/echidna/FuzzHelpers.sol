// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PropertiesAsserts} from "./PropertiesHelper.sol";
import {IUniDeployer} from "./fuzz-mocks/IUniDeployer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticHelper} from "@test_periphery/PanopticHelper.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {TokenId} from "@types/TokenId.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {Math} from "@libraries/Math.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {SqrtPriceMath} from "v3-core/libraries/SqrtPriceMath.sol";
// V4 types
import {Pool} from "v4-core/libraries/Pool.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {V4RouterSimple} from "../foundry/testUtils/V4RouterSimple.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {IV3CompatibleOracle} from "@contracts/interfaces/IV3CompatibleOracle.sol";

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

interface IHevm {
    function warp(uint256 newTimestamp) external;

    function roll(uint256 newNumber) external;

    function load(address where, bytes32 slot) external returns (bytes32);

    function store(address where, bytes32 slot, bytes32 value) external;

    function sign(
        uint256 privateKey,
        bytes32 digest
    ) external returns (uint8 r, bytes32 v, bytes32 s);

    function addr(uint256 privateKey) external returns (address add);

    function ffi(string[] calldata inputs) external returns (bytes memory result);

    function prank(address newSender) external;

    function createFork(string calldata urlOrAlias) external returns (uint256);

    function selectFork(uint256 forkId) external;

    function activeFork() external returns (uint256);

    function label(address addr, string calldata label) external;
}

// Copy of test/foundry/core/Misc.t.sol:SwapperC
contract SwapperC {
    struct PoolFeatures {
        address token0;
        address token1;
        uint24 fee;
    }

    struct CallbackData {
        PoolFeatures poolFeatures;
        address payer;
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode the swap callback data, checks that the UniswapV3Pool has the correct address.
        CallbackData memory decoded = abi.decode(data, (CallbackData));

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

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        // Decode the mint callback data
        CallbackData memory decoded = abi.decode(data, (CallbackData));

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

    function mint(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(
                CallbackData({
                    poolFeatures: PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }

    function burn(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.burn(tickLower, tickUpper, liquidity);
    }

    function swapTo(IUniswapV3Pool pool, uint160 sqrtPriceX96) public {
        (uint160 sqrtPriceX96Before, , , , , , ) = pool.slot0();

        if (sqrtPriceX96Before == sqrtPriceX96) return;

        pool.swap(
            msg.sender,
            sqrtPriceX96Before > sqrtPriceX96 ? true : false,
            type(int128).max,
            sqrtPriceX96,
            abi.encode(
                CallbackData({
                    poolFeatures: PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }
}

contract PanopticPoolWrapper is PanopticPool {
    /// @notice get the positions hash of an account
    /// @param user the account to get the positions hash of
    /// @return _positionsHash positions hash of the account
    function positionsHash(address user) external view returns (uint248 _positionsHash) {
        _positionsHash = uint248(s_positionsHash[user]);
    }

    function miniMedian() external view returns (uint256) {
        return s_miniMedian;
    }

    function settledTokens(bytes32 chunk) external view returns (LeftRightUnsigned) {
        return s_settledTokens[chunk];
    }

    function addSettledTokens(bytes32 chunk, LeftRightUnsigned settled) external {
        s_settledTokens[chunk] = s_settledTokens[chunk].add(settled);
    }

    function burnAllOptionsFrom_noCommit(
        TokenId[] calldata positionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external returns (LeftRightSigned[4][] memory, LeftRightSigned) {
        (
            LeftRightSigned netExchanged,
            LeftRightSigned[4][] memory premiasByLeg
        ) = _burnAllOptionsFrom(
                msg.sender,
                tickLimitLow,
                tickLimitHigh,
                DONOT_COMMIT_LONG_SETTLED,
                positionIdList
            );

        return (premiasByLeg, netExchanged);
    }

    function burnAllOptionsFrom_commit(
        TokenId[] calldata positionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external returns (LeftRightSigned[4][] memory, LeftRightSigned) {
        (
            LeftRightSigned netExchanged,
            LeftRightSigned[4][] memory premiasByLeg
        ) = _burnAllOptionsFrom(
                msg.sender,
                tickLimitLow,
                tickLimitHigh,
                COMMIT_LONG_SETTLED,
                positionIdList
            );

        return (premiasByLeg, netExchanged);
    }

    function burnOptionsAndSkipCollateralCheck(
        TokenId tokenId,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external {
        _burnOptions(COMMIT_LONG_SETTLED, tokenId, msg.sender, tickLimitLow, tickLimitHigh);
    }

    function premiaSettlementData(
        TokenId tokenId,
        uint256 leg
    ) public view returns (uint128, uint128, uint128, uint128) {
        bytes32 chunkKey = keccak256(
            abi.encodePacked(tokenId.strike(leg), tokenId.width(leg), tokenId.tokenType(leg))
        );

        LeftRightUnsigned settled = s_settledTokens[chunkKey];
        LeftRightUnsigned gross = s_grossPremiumLast[chunkKey];

        return (settled.rightSlot(), settled.leftSlot(), gross.rightSlot(), gross.leftSlot());
    }

    function premiaSettlementData(
        FuzzHelpers.ChunkWithTokenType memory _chunk
    ) public view returns (uint128, uint128, uint128, uint128) {
        bytes32 chunkKey = keccak256(
            abi.encodePacked(_chunk.strike, _chunk.width, _chunk.tokenType)
        );

        LeftRightUnsigned settled = s_settledTokens[chunkKey];
        LeftRightUnsigned gross = s_grossPremiumLast[chunkKey];

        return (settled.rightSlot(), settled.leftSlot(), gross.rightSlot(), gross.leftSlot());
    }

    function optionData(
        TokenId tokenId,
        address account,
        uint256 leg
    ) public view returns (uint128, uint128) {
        LeftRightUnsigned legData = s_options[account][tokenId][leg];

        return (legData.rightSlot(), legData.leftSlot());
    }

    function validateSolvency(
        address user,
        TokenId[] calldata positionIdList,
        uint256 buffer
    ) public {
        _validateSolvency(user, positionIdList, buffer, true);
    }

    constructor(
        SemiFungiblePositionManager _sfpm,
        IPoolManager _manager
    ) PanopticPool(_sfpm, _manager) {}
}

contract CollateralTrackerWrapper is CollateralTracker {
    constructor(
        uint256 _commissionFee,
        uint256 _sellerCollateralRatio,
        uint256 _buyerCollateralRatio,
        int256 _forceExerciseCost,
        uint256 _targetPoolUtilization,
        uint256 _saturatedPoolUtilization,
        uint256 _ITMSpreadFee,
        IPoolManager _manager
    )
        CollateralTracker(
            _commissionFee,
            _sellerCollateralRatio,
            _buyerCollateralRatio,
            _forceExerciseCost,
            _targetPoolUtilization,
            _saturatedPoolUtilization,
            _ITMSpreadFee,
            _manager
        )
    {}

    function decreaseBalance(address account, uint256 amount) external {
        balanceOf[account] -= amount;
    }

    function increaseBalanceByAssets(address account, uint256 assets) external {
        balanceOf[account] += convertToShares(assets);
    }

    function credit(address account, uint256 assets) external {
        _mint(account, convertToShares(assets));
        s_poolAssets += uint128(assets);
    }
}

contract FuzzHelpers is PropertiesAsserts {
    using Math for uint256;
    using Math for int256;

    error BurnSimSettledRes(uint256);

    error PpfeesCollectedSimRes(LeftRightUnsigned, LeftRightUnsigned, uint256[2][]);

    error SwapSimulationResults(int256, int256, int24);

    error UniMintSimulationResults(uint256, uint256, bool);

    error UniMintAndCollectSimulationResults(uint256, uint256, uint128, uint128, bool);

    error UniBurnAndCollectSimulationResults(uint256, uint256, uint128, uint128, bool);

    error LiqBurnSimResults(BurnSimulationResults);

    error SFPMMintResError(LeftRightUnsigned[4], LeftRightSigned, int24[4], bool);

    error SFPMBurnResError(LeftRightUnsigned[4], LeftRightSigned, int24[4], bool);

    error PPBurnSimResError(int256, int256, bool);

    error FeeQuotePostBurnSimResError(LeftRightUnsigned, LeftRightUnsigned, uint256[2][]);

    error PPBurnManySimResError(uint256, uint256, BurnManySimResults, bool);

    struct SFPMMintResults {
        LeftRightUnsigned[4] collectedByLeg;
        LeftRightSigned totalSwapped;
    }

    struct BurnSimulationResults {
        uint256 totalSupply0;
        uint256 totalSupply1;
        uint256 totalAssets0;
        uint256 totalAssets1;
        uint256 settledTokens0;
        int256 shareDelta0;
        int256 shareDelta1;
        int256 longPremium0;
        int256 burnDelta0C;
        int256 burnDelta0;
        int256 burnDelta1;
        LeftRightSigned netExchanged;
        uint256 delegateeBalance0;
        uint256 delegateeBalance1;
        bool sRevert;
    }

    struct LiquidationResults {
        LeftRightUnsigned margin0;
        LeftRightUnsigned margin1;
        int256 bonus0;
        int256 bonus1;
        int256 sharesD0;
        int256 sharesD1;
        uint256 liquidatorValueBefore0;
        int256 liquidatorValueAfter0;
        uint256 settledTokens0;
        LeftRightUnsigned shortPremium;
        int256 bonusCombined0;
        int256 protocolLoss0Actual;
        int256 protocolLoss0Expected;
        uint256[2][4][32] settledTokens;
    }

    struct ChunkWithTokenType {
        int24 strike;
        int24 width;
        uint256 tokenType;
    }

    struct BurnManySimResults {
        uint256[4][] grossPremiaL0Portfolio;
        uint256[4][] grossPremiaL1Portfolio;
        uint256[4][] settledTokens0Portfolio;
        uint256[4][] settledTokens1Portfolio;
        uint256[] sfpmBals;
    }

    uint256 private constant MAX_UINT128 = type(uint128).max;

    int256 private constant INT256_MIN =
        -57896044618658097711785492504343953926634992332820282019728792003956564819968;

    uint256 internal constant FAST_ORACLE_CARDINALITY = 3;
    uint256 internal constant FAST_ORACLE_PERIOD = 1;

    bool internal constant SLOW_ORACLE_UNISWAP_MODE = false;
    uint256 internal constant SLOW_ORACLE_CARDINALITY = 7;
    uint256 internal constant SLOW_ORACLE_PERIOD = 5;

    uint256 internal constant MEDIAN_PERIOD = 60;

    uint256 internal constant BP_DECREASE_BUFFER = 13_333;
    int256 internal constant MAX_SLOW_FAST_DELTA = 1800;

    bool internal constant ONLY_AVAILABLE_PREMIUM = false;
    /// *** storage SFPM ***

    mapping(address => TokenId[]) userPositionsSFPMShort;
    mapping(address => TokenId[]) userPositionsSFPMLong;
    mapping(address => TokenId[]) userPositionsSFPMix; // combo of short and long pos

    address $activeUser;

    TokenId $activeTokenId;

    int24 sfpmTickSpacing;

    uint8 $activeNumLegs;

    bytes32[4] $positionKey;

    uint256 $activeLegIndex;

    int24 $tickLowerActive;
    int24 $tickUpperActive;
    uint128 $LiqAmountActive;

    uint128 $positionSize;

    uint256 $prevSPFMTokenBal;

    int24[4] $sTickLower;
    int24[4] $sTickUpper;
    uint128[4] $sLiqAmounts;

    LiquidityChunk[4] $liquidityChunk;
    uint128[4] $posLiquidity;
    uint256[4] $removedLiquidityBefore;
    uint256[4] $netLiquidityBefore;
    uint256[4] $removedLiquidityAfter;
    uint256[4] $netLiquidityAfter;

    uint128[4] uniLiquidityBefore;
    uint128[4] uniLiquidityAfter;

    uint256[4] $feeGrowthInside0LastX128Before;
    uint256[4] $feeGrowthInside1LastX128Before;
    uint256[4] $feeGrowthInside0LastX128After;
    uint256[4] $feeGrowthInside1LastX128After;

    uint256[4] $amountMinted0;
    uint256[4] $amountMinted1;
    int256[4] $amountBurned0;
    int256[4] $amountBurned1;

    uint128[4] $collected0;
    uint128[4] $collected1;
    int128[4] $amountToCollect0;
    int128[4] $amountToCollect1;
    uint128[4] $recievedAmount0;
    uint128[4] $recievedAmount1;

    uint128[4] $accountPremiumOwedBefore0;
    uint128[4] $accountPremiumOwedBefore1;

    uint128[4] $accountPremiumOwedAfter0;
    uint128[4] $accountPremiumOwedAfter1;

    uint128[4] $accountPremiumGrossBefore0;
    uint128[4] $accountPremiumGrossBefore1;

    uint128[4] $accountPremiumGrossAfter0;
    uint128[4] $accountPremiumGrossAfter1;

    uint256[4] $accountPremiumOwedCalculated0;
    uint256[4] $accountPremiumOwedCalculated1;

    uint256[4] $accountPremiumGrossCalculated0;
    uint256[4] $accountPremiumGrossCalculated1;

    bytes32[4] positionKey_from;
    bytes32[4] positionKey_to;

    uint256 tokenBalanceSenderBefore;
    uint256 tokenBalanceRecipientBefore;
    uint256 tokenBalanceSenderAfter;
    uint256 tokenBalanceRecipientAfter;

    LeftRightUnsigned[4] accountLiquiditiesSenderBefore;
    LeftRightUnsigned[4] accountLiquiditiesRecipientBefore;

    LeftRightUnsigned[4] accountLiquiditiesSenderAfter;
    LeftRightUnsigned[4] accountLiquiditiesRecipientAfter;

    LeftRightUnsigned[4] $sCollectedByLeg;
    LeftRightSigned $sTotalSwapped;

    bool $shouldRevertSFPM;

    /// ^^ SFPM

    address[] $allPositionOwners;
    TokenId[] $allPositions;

    PanopticHelper panopticHelper;
    SemiFungiblePositionManager sfpm;
    IUniswapV3Factory univ3factory;
    address poolReference;
    address collateralReference;
    PanopticFactory panopticFactory;
    PanopticPoolWrapper panopticPool;
    uint64 poolId;
    uint64 sfpmPoolId;

    IUniswapV3Pool pool;

    IUniswapV3Pool cyclingPool;
    uint cyclingPoolIndex;

    address token0;
    address token1;
    uint24 poolFee;
    int24 poolTickSpacing;
    uint160 currentSqrtPriceX96;
    int24 currentTick;
    int24 currentTickOld;

    uint16 observationIndex;
    uint16 observationCardinality;

    CollateralTrackerWrapper collToken0;
    CollateralTrackerWrapper collToken1;

    int24[4] $widths;
    int24[4] $strikes;
    uint256[4] $assets;
    uint256[4] $tokenTypes;
    uint256[4] $ratios;
    uint256[4] $riskPartners;
    uint256[4] $isLongs;

    LeftRightUnsigned[4] $collectedByLeg;
    LeftRightSigned $totalSwapped;

    address $caller;

    TokenId $tokenIdActive;
    TokenId $tokenIdBkp;

    uint128 $positionSizeActive;
    uint128 $positionSizeBkp;

    uint256 $numLegs;

    uint256 $numOptions;

    uint256 $netLiquidity;
    uint256 $removedLiquidity;

    uint256 $spreadRatio;

    uint256 $sfpmBal;

    int256 $netTokenTransfers0;
    int256 $netTokenTransfers1;

    int256 $maxTransfer0;
    int256 $maxTransfer1;

    LeftRightSigned $shortAmounts;
    LeftRightSigned $longAmounts;

    int256 $colDelta0;
    int256 $colDelta1;

    uint256 $poolAssets0;
    uint256 $poolAssets1;

    uint256 $inAMM0;
    uint256 $inAMM1;

    // x10k
    uint256 $poolUtil0;
    uint256 $poolUtil1;

    bool $found;

    LeftRightUnsigned $shortPremiumIdeal;

    LeftRightUnsigned $shortPremium;
    LeftRightUnsigned $longPremium;

    uint256 $balanceCross;
    uint256 $thresholdCross;

    uint256 $balance0ExpectedP;
    uint256 $balance1ExpectedP;

    int256 $balance0Origin;
    int256 $balance1Origin;

    int256 $balance0Exercisee;
    int256 $balance1Exercisee;

    int256 $balance0Final;
    int256 $balance1Final;

    uint256 $totalAssets0;
    uint256 $totalAssets1;
    uint256 $totalSupply0;
    uint256 $totalSupply1;

    int256 $commission0;
    int256 $commission1;

    LeftRightUnsigned $tokenData0;
    LeftRightUnsigned $tokenData1;

    TokenId[] $posIdListOld;
    TokenId[] $positionsNew;

    uint256[2][] $posBalanceArray;

    bool $shouldRevert;
    bool $shouldBurnRevert;

    int24 $fastOracleTick;
    int24 $slowOracleTick;

    int24 $twapTick;

    int24 $tickLower;
    int24 $tickUpper;

    int24 $tickLimitLow;
    int24 $tickLimitHigh;

    address[] actors;
    address pool_manipulator;

    int24[4] $colTicks;

    int256 $allPositionCount;
    int256 $failedPositionCount;

    address $settlee;
    uint256 $settleIndex;

    bool $safeMode;

    bool $isBurn;

    uint256 $sizeMultiplierDenominator;

    address $exercisee;
    TokenId[] $positionListExercisor;
    TokenId[] $positionListExercisee;

    uint256[4] $settledToken0;
    uint256[4] $settledToken1;
    uint256 $settledToken0Post;
    uint256 $settledToken1Post;
    uint128 $grossPremiaLast0;
    uint128 $grossPremiaLast1;
    uint128 $grossPremia0;
    uint128 $grossPremia1;
    uint256[4] $grossPremiaTotal0;
    uint256[4] $grossPremiaTotal1;

    uint128 $owedPremia0;
    uint128 $owedPremia1;

    bool $gross0Correct;
    bool $gross1Correct;

    uint256[4] $idealPremium0;
    uint256[4] $idealPremium1;

    uint256[4] $proratedPremium0;
    uint256[4] $proratedPremium1;

    int256 $premiumDelta0Net;
    int256 $premiumDelta1Net;

    uint256 $grossPremiumTotalSumLegs0;
    uint256 $grossPremiumTotalSumLegs1;

    uint256[4] $premiumGrowth0;
    uint256[4] $premiumGrowth1;

    uint256[4][] $settledTokens0Portfolio;
    uint256[4][] $settledTokens1Portfolio;

    uint256[4][] $grossPremiaL0Portfolio;
    uint256[4][] $grossPremiaL1Portfolio;

    uint256[] $sfpmBals;

    BurnManySimResults $burnManySimResults;

    uint256 $premiumGrowthLeg0;
    uint256 $premiumGrowthLeg1;

    uint256 $undelegatedShares0;
    uint256 $undelegatedShares1;

    uint256 $undelegatedValue0T;

    uint256 $shortLiquidity;

    uint256 $legLiquidity;

    uint256 $TSSubliquidateeBalancePre0;
    uint256 $TSSubliquidateeBalancePre1;

    SwapperC swapperc;

    uint256 canonicalTimestamp;
    uint256 canonicalBlock;

    mapping(address => TokenId[]) userPositions;

    mapping(address => mapping(TokenId => LeftRightUnsigned)) $userBalance;

    mapping(bytes32 chunk => LeftRightUnsigned removedAndNet) $panopticChunkLiquidity;

    ChunkWithTokenType[] touchedPanopticChunks;

    uint256 constant MAX_DEPOSIT = 100 ether;
    uint256 constant MIN_DEPOSIT = 0.01 ether;

    BurnSimulationResults burnSimResults;
    LiquidationResults liqResults;

    IHevm hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    //Testing uni deployment
    IUniDeployer deployer;

    IUniswapV3Pool[4] pools;

    PoolKey[4] poolKeys;

    PoolKey cyclingPoolKey;

    IPoolManager manager;

    V4RouterSimple routerV4;

    PoolKey poolKey;

    IERC20 USDC;
    IERC20 WETH;

    function abs(int256 a) internal pure returns (uint256) {
        // Required or it will fail when `a = type(int256).min`
        if (a == INT256_MIN) {
            return 57896044618658097711785492504343953926634992332820282019728792003956564819968;
        }

        return uint256(a > 0 ? a : -a);
    }

    function delta(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function delta(int256 a, int256 b) internal pure returns (uint256) {
        // a and b are of the same sign
        // this works thanks to two's complement, the left-most bit is the sign bit
        if ((a ^ b) > -1) {
            return delta(abs(a), abs(b));
        }

        // a and b are of opposite signs
        return abs(a) + abs(b);
    }

    function percentDelta(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 absDelta = delta(a, b);

        return (absDelta * 1e18) / b;
    }

    function percentDelta(int256 a, int256 b) internal pure returns (uint256) {
        uint256 absDelta = delta(a, b);
        uint256 absB = abs(b);

        return (absDelta * 1e18) / absB;
    }

    function assertApproxEqAbs(int256 a, int256 b, uint256 maxDelta, string memory err) internal {
        if (abs(a - b) > maxDelta) {
            emit LogUint256("assertApproxEqAbs failed with tol:", maxDelta);
            emit LogInt256("a:", a);
            emit LogInt256("b:", b);
            assertWithMsg(false, err);
        }
    }

    function assertApproxEqRel(
        int256 a,
        int256 b,
        uint256 maxPercentDelta, // An 18 decimal fixed point number, where 1e18 == 100%
        string memory err
    ) internal {
        uint256 _percentDelta = percentDelta(a, b);

        if (_percentDelta > maxPercentDelta) {
            assertWithMsg(false, err);
        }
    }

    function assertApproxEqRel(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta, // An 18 decimal fixed point number, where 1e18 == 100%
        string memory err
    ) internal {
        uint256 _percentDelta = percentDelta(a, b);

        if (_percentDelta > maxPercentDelta) {
            assertWithMsg(false, err);
        }
    }

    function bound(uint256 value, uint256 _min, uint256 _max) internal pure returns (uint256) {
        uint256 range = _max - _min + 1;
        return _min + (value % range);
    }

    function boundLog(uint256 value, uint256 _min, uint256 _max) internal returns (uint256) {
        emit LogUint256("logboundingmin", _min);
        emit LogUint256("logboundingmax", _max);
        uint256 power = bound(value, FixedPointMathLib.log2(_min), FixedPointMathLib.log2(_max));
        uint256 remainder = bound(
            uint256(keccak256(abi.encode(value))),
            _min > 2 ** power ? _min - 2 ** power : 0,
            min(_max - 2 ** power, 2 ** power - 1)
        );

        emit LogUint256("logboundres", 2 ** power + remainder);
        return 2 ** power + remainder;
    }

    function bound(int256 value, int256 _min, int256 _max) internal pure returns (int256) {
        int256 range = _max - _min + 1;
        return _min + Math.abs(value % range);
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return ((a >= b) ? a : b);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return ((a <= b) ? a : b);
    }

    function mulDivInt(int256 x, int256 y, int256 z) internal pure returns (int256) {
        uint256 negs = (x < 0 ? 1 : 0) ^ (y < 0 ? 1 : 0) ^ (z < 0 ? 1 : 0);
        return
            (negs % 2 == 0 ? int8(1) : -1) *
            int256(Math.mulDiv(uint256(Math.abs(x)), uint256(Math.abs(y)), uint256(Math.abs(z))));
    }

    function mulDivIntRoundingUp(int256 x, int256 y, int256 z) internal pure returns (int256) {
        uint256 negs = (x < 0 ? 1 : 0) ^ (y < 0 ? 1 : 0) ^ (z < 0 ? 1 : 0);
        return
            (negs % 2 == 0 ? int8(1) : -1) *
            int256(
                Math.mulDivRoundingUp(
                    uint256(Math.abs(x)),
                    uint256(Math.abs(y)),
                    uint256(Math.abs(z))
                )
            );
    }

    function deal_USDC(address to, uint256 amt) internal {
        deployer.mintToken(false, to, amt);
    }

    function deal_WETH(address to, uint256 amt) internal {
        deployer.mintToken(true, to, amt);
    }

    function alter_USDC(address to, uint256 bal) internal {
        // Balances in slot 0
        uint256 slot_balances = uint256(0);
        hevm.store(address(USDC), keccak256(abi.encode(address(to), slot_balances)), bytes32(bal));
    }

    function alter_WETH(address to, uint256 bal) internal {
        // Balances in slot 3 (verify with "slither --print variable-order 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
        hevm.store(address(WETH), keccak256(abi.encode(address(to), uint256(0))), bytes32(bal));
    }

    function deal_Generic(
        address token,
        uint256 slot,
        address to,
        uint256 amt,
        bool alter_supply,
        uint256 supply_slot
    ) internal {
        uint256 slot_balances = slot;
        uint256 original_balance = uint256(
            hevm.load(token, keccak256(abi.encode(address(to), slot_balances)))
        );
        int256 _delta = int256(amt) - int256(original_balance);
        hevm.store(token, keccak256(abi.encode(address(to), slot_balances)), bytes32(amt));

        if (alter_supply) {
            bytes32 slot_supply = bytes32(supply_slot);
            uint256 orig_supply = uint256(hevm.load(token, slot_supply));
            uint256 new_supply = uint256(int256(orig_supply) + _delta);
            hevm.store(token, slot_supply, bytes32(new_supply));
        }
    }

    /////////////////////////////////////////////////////////////
    // Calculation helpers
    /////////////////////////////////////////////////////////////

    // given an itm0 and itm1 values return the swapped amounts and swap direction
    function _compute_swap_amounts(
        int256 itm0,
        int256 itm1
    ) internal view returns (int256 swapAmount, bool zeroForOne) {
        if ((itm0 != 0) && (itm1 != 0)) {
            uint160 sqrtPriceX96 = V4StateReader.getSqrtPriceX96(manager, cyclingPoolKey.toId());

            int256 net0 = itm0 - PanopticMath.convert1to0(itm1, sqrtPriceX96);

            zeroForOne = net0 < 0;

            swapAmount = -net0;
        } else if (itm0 != 0) {
            zeroForOne = itm0 < 0;
            swapAmount = -itm0;
        } else {
            zeroForOne = itm1 > 0;
            swapAmount = -itm1;
        }
    }

    function simulate_swap(bool zeroForOne, int256 amountSpecified) external {
        require(msg.sender == address(this));

        int256 swap0;
        int256 swap1;

        if (amountSpecified != 0) {
            for (uint256 i = 0; i < $activeTokenId.countLegs(); ++i) {
                (int24 tickLower, int24 tickUpper) = $activeTokenId.asTicks(i);

                hevm.prank(address(pool_manipulator));
                routerV4.modifyLiquidity(
                    address(0),
                    cyclingPoolKey,
                    tickLower,
                    tickUpper,
                    int128(
                        PanopticMath.getLiquidityChunk($activeTokenId, i, $positionSize).liquidity()
                    )
                );
            }
            hevm.prank(address(pool_manipulator));
            (int256 amt0, int256 amt1) = routerV4.swap(
                address(0),
                cyclingPoolKey,
                amountSpecified,
                zeroForOne
            );

            swap0 = -amt0;
            swap1 = -amt1;
        }

        int24 tickAfterSwap = V4StateReader.getTick(manager, cyclingPoolKey.toId());

        revert SwapSimulationResults(swap0, swap1, tickAfterSwap);
    }

    function _execute_swap_simulation(
        bool zeroForOne,
        int256 amountSpecified
    ) internal returns (int256 swap0, int256 swap1, int24 tickAfterSwap) {
        try this.simulate_swap(zeroForOne, amountSpecified) {
            assertWithMsg(false, "swap succeeded ??");
        } catch (bytes memory results) {
            bytes4 selector = bytes4(results);
            require(selector == SwapSimulationResults.selector);
            emit LogBytes("r", results);

            assembly ("memory-safe") {
                results := add(results, 0x04)
            }

            (swap0, swap1, tickAfterSwap) = abi.decode(results, (int256, int256, int24));

            return (swap0, swap1, tickAfterSwap);
        }
    }

    function _getAmountsForLiquidity(
        uint160 sqrtPriceCurrent,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidityDelta,
        bool roundUp
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceCurrent < sqrtPriceAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidityDelta,
                roundUp
            );
        } else if (sqrtPriceCurrent < sqrtPriceBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceCurrent,
                sqrtPriceBX96,
                liquidityDelta,
                roundUp
            );

            amount1 = SqrtPriceMath.getAmount1Delta(
                sqrtPriceAX96,
                sqrtPriceCurrent,
                liquidityDelta,
                roundUp
            );
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidityDelta,
                roundUp
            );
        }
    }

    // for multiple legs
    function _calculate_moved_amounts(
        TokenId tokenId,
        uint128 positionSize,
        bool roundUp
    ) internal returns (int256, int256) {
        //
        int256 moved0;
        int256 moved1;

        uint128 _positionSize = positionSize;
        TokenId _tokenId = tokenId;

        // update to latest current tick
        currentTick = V4StateReader.getTick(manager, cyclingPoolKey.toId());
        currentSqrtPriceX96 = V4StateReader.getSqrtPriceX96(manager, cyclingPoolKey.toId());

        //
        uint256 numLegs = _tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; leg++) {
            //create liquidity chunk object
            LiquidityChunk currChunk = PanopticMath.getLiquidityChunk(_tokenId, leg, _positionSize);

            // tick lower
            emit LogInt256("tick lower", currChunk.tickLower());
            // tick upper
            emit LogInt256("tick upper", currChunk.tickUpper());
            // amount of liquidity
            emit LogUint256("liquidity", currChunk.liquidity());
            // current tick
            emit LogInt256("current tick", currentTick);

            emit LogUint256("current sqrt price x96", currentSqrtPriceX96);
            emit LogUint256(
                "sqrt ratio at tick lower",
                Math.getSqrtRatioAtTick(currChunk.tickLower())
            );
            emit LogUint256(
                "sqrt ratio at tick upper",
                Math.getSqrtRatioAtTick(currChunk.tickUpper())
            );
            bool _roundUp = roundUp;
            (uint256 amount0, uint256 amount1) = _getAmountsForLiquidity(
                currentSqrtPriceX96,
                Math.getSqrtRatioAtTick(currChunk.tickLower()),
                Math.getSqrtRatioAtTick(currChunk.tickUpper()),
                currChunk.liquidity(),
                _roundUp
            );
            // actual moved amounts when minting rounds up (round down when burning)

            if (_tokenId.isLong(leg) == 1) {
                moved0 -= int256(amount0);
                moved1 -= int256(amount1);
            } else {
                moved0 += int256(amount0);
                moved1 += int256(amount1);
            }
        }

        return (moved0, moved1);
    }

    function _calculate_itm_amounts(
        uint256 tokenType,
        int256 moved0,
        int256 moved1
    ) internal pure returns (int256 itm0, int256 itm1) {
        if (tokenType == 0) {
            itm1 += moved1;
        } else {
            // tt = 1
            itm0 += moved0;
        }
    }

    function _calculate_moved_and_ITM_amounts(
        TokenId tokenId,
        uint128 positionSize
    ) internal returns (int256, int256, int256, int256) {
        //
        int256 moved0;
        int256 moved1;

        //
        int256 itm0;
        int256 itm1;

        uint128 _positionSize = positionSize;
        TokenId _tokenId = tokenId;

        // update to latest current tick
        currentTick = V4StateReader.getTick(manager, cyclingPoolKey.toId());
        currentSqrtPriceX96 = V4StateReader.getSqrtPriceX96(manager, cyclingPoolKey.toId());

        uint256 numLegs = _tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; leg++) {
            //create liquidity chunk object
            LiquidityChunk currChunk = PanopticMath.getLiquidityChunk(_tokenId, leg, _positionSize);

            emit LogUint256("current sqrt price x96", currentSqrtPriceX96);
            emit LogUint256(
                "sqrt ratio at tick lower",
                Math.getSqrtRatioAtTick(currChunk.tickLower())
            );
            emit LogUint256(
                "sqrt ratio at tick upper",
                Math.getSqrtRatioAtTick(currChunk.tickUpper())
            );
            emit LogUint256("liquidity", currChunk.liquidity());
            (uint256 amount0, uint256 amount1) = _getAmountsForLiquidity(
                currentSqrtPriceX96,
                Math.getSqrtRatioAtTick(currChunk.tickLower()),
                Math.getSqrtRatioAtTick(currChunk.tickUpper()),
                currChunk.liquidity(),
                true
            );

            emit LogUint256("movedLeg0", amount0);
            emit LogUint256("movedLeg1", amount1);

            if (_tokenId.isLong(leg) == 1) {
                moved0 -= int256(amount0);
                moved1 -= int256(amount1);
            } else {
                moved0 += int256(amount0);
                moved1 += int256(amount1);
            }

            if (_tokenId.tokenType(leg) == 0) {
                itm1 += int256(amount1);
            } else {
                // tt = 1
                itm0 += int256(amount0);
            }

            //
            emit LogUint256("_tokenId.tokenType(leg)", _tokenId.tokenType(leg));

            // amounts
            emit LogUint256("amount0", amount0);
            emit LogUint256("amount1", amount1);
        }

        return (moved0, moved1, itm0, itm1);
    }

    function getPremiaDeltasChecked(
        uint256 netLiquidity,
        uint256 removedLiquidity,
        uint128 collected0,
        uint128 collected1
    ) external returns (LeftRightUnsigned deltaPremiumOwed, LeftRightUnsigned deltaPremiumGross) {
        require(msg.sender == address(this));

        // premia spread equations are graphed and documented here: https://www.desmos.com/calculator/mdeqob2m04
        // explains how we get from the premium per liquidity (calculated here) to the total premia collected and the multiplier
        // as well as how the value of VEGOID affects the premia
        // note that the "base" premium is just a common factor shared between the owed (long) and gross (short)
        // premia, and is only seperated to simplify the calculation
        // (the graphed equations include this factor without separating it)
        uint256 totalLiquidity = netLiquidity + removedLiquidity;

        uint256 premium0X64_base;
        uint256 premium1X64_base;

        emit LogUint256("inside premia deltas checked removed liq", removedLiquidity);
        emit LogUint256("inside premia deltas checked netLiq", netLiquidity);

        {
            // compute the base premium as collected * total / net^2 (from Eqn 3)
            premium0X64_base = Math.mulDiv(collected0, totalLiquidity * 2 ** 64, netLiquidity ** 2);
            premium1X64_base = Math.mulDiv(collected1, totalLiquidity * 2 ** 64, netLiquidity ** 2);
        }

        {
            uint128 premium0X64_owed;
            uint128 premium1X64_owed;
            {
                // compute the owed premium (from Eqn 3)
                uint256 numerator = netLiquidity + (removedLiquidity / 2 ** 2);

                premium0X64_owed = Math
                    .mulDiv(premium0X64_base, numerator, totalLiquidity)
                    .toUint128Capped();
                premium1X64_owed = Math
                    .mulDiv(premium1X64_base, numerator, totalLiquidity)
                    .toUint128Capped();

                deltaPremiumOwed = LeftRightUnsigned
                    .wrap(0)
                    .toRightSlot(premium0X64_owed)
                    .toLeftSlot(premium1X64_owed);
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
                    ((removedLiquidity ** 2) / 2 ** (2));

                premium0X64_gross = Math
                    .mulDiv(premium0X64_base, numerator, totalLiquidity ** 2)
                    .toUint128Capped();
                premium1X64_gross = Math
                    .mulDiv(premium1X64_base, numerator, totalLiquidity ** 2)
                    .toUint128Capped();

                deltaPremiumGross = LeftRightUnsigned
                    .wrap(0)
                    .toRightSlot(premium0X64_gross)
                    .toLeftSlot(premium1X64_gross);
            }
        }
    }

    // takes a premia accumulator and adds the computed amounts
    // checks for freeze if one side is equivalent to uint128.max
    // or ensures there isn't an overflow if the amounts roll over
    function incrementPremiaAccumulator(
        uint256 premiumOwed0,
        uint256 premiumOwed1,
        uint256 deltaPremiumOwed0,
        uint256 deltaPremiumOwed1,
        uint256 premiumGross0,
        uint256 premiumGross1,
        uint256 deltaPremiumGross0,
        uint256 deltaPremiumGross1
    ) internal pure returns (uint256 owed0, uint256 owed1, uint256 gross0, uint256 gross1) {
        // add together the new owed premiums
        uint256 newOwed0 = premiumOwed0 + deltaPremiumOwed0;
        uint256 newOwed1 = premiumOwed1 + deltaPremiumOwed1;

        // add together the new gross premiums
        uint256 newGross0 = premiumGross0 + deltaPremiumGross0;
        uint256 newGross1 = premiumGross1 + deltaPremiumGross1;

        // assign final values and check for cap / overflow
        owed0 = (newOwed0 >= MAX_UINT128 || newGross0 >= MAX_UINT128) ? premiumOwed0 : newOwed0;
        owed1 = (newOwed1 >= MAX_UINT128 || newGross1 >= MAX_UINT128) ? premiumOwed1 : newOwed1;
        //
        gross0 = (newOwed0 >= MAX_UINT128 || newGross0 >= MAX_UINT128) ? premiumGross0 : newGross0;
        gross1 = (newOwed1 >= MAX_UINT128 || newGross1 >= MAX_UINT128) ? premiumGross1 : newGross1;
    }

    function _getSolvencyBalances(
        LeftRightUnsigned tokenData0,
        LeftRightUnsigned tokenData1,
        uint160 sqrtPriceX96,
        uint256 amountWithdrawn,
        bool isToken0
    ) internal pure returns (uint256 balanceCross, uint256 thresholdCross) {
        unchecked {
            // the cross-collateral balance, computed in terms of liquidity X*√P + Y/√P
            // We use mulDiv to compute Y/√P + X*√P while correctly handling overflows, round down
            balanceCross =
                Math.mulDiv(
                    uint256(tokenData1.rightSlot()) - (isToken0 ? 0 : amountWithdrawn),
                    2 ** 96,
                    sqrtPriceX96
                ) +
                Math.mulDiv96(
                    tokenData0.rightSlot() - (isToken0 ? amountWithdrawn : 0),
                    sqrtPriceX96
                );
            // the amount of cross-collateral balance needed for the account to be solvent, computed in terms of liquidity
            // overestimate by rounding up
            thresholdCross =
                Math.mulDivRoundingUp(uint256(tokenData1.leftSlot()), 2 ** 96, sqrtPriceX96) +
                Math.mulDiv96RoundingUp(tokenData0.leftSlot(), sqrtPriceX96);
        }
    }

    function _write_liquidation_solvency_revert(address sUser) internal {
        ($shortPremium, $longPremium, $posBalanceArray) = panopticPool
            .getAccumulatedFeesAndPositionsData(sUser, false, userPositions[sUser]);

        uint256 insolventTicks;
        for (uint256 i = 0; i < $colTicks.length; i++) {
            $tokenData0 = collToken0.getAccountMarginDetails(
                sUser,
                $colTicks[i],
                $posBalanceArray,
                $shortPremium.rightSlot(),
                $longPremium.rightSlot()
            );
            $tokenData1 = collToken1.getAccountMarginDetails(
                sUser,
                $colTicks[i],
                $posBalanceArray,
                $shortPremium.leftSlot(),
                $longPremium.leftSlot()
            );

            ($balanceCross, $thresholdCross) = PanopticMath.getCrossBalances(
                $tokenData0,
                $tokenData1,
                TickMath.getSqrtRatioAtTick($colTicks[i])
            );

            insolventTicks += $thresholdCross > $balanceCross ? 1 : 0;
        }

        emit LogBool("revert due to solvency", insolventTicks != $colTicks.length);
        if (insolventTicks != $colTicks.length) $shouldRevert = true;
    }

    function _write_revert_due_solvency(address sUser, uint256 buffer) internal {
        // current - fast
        // fast - slow
        // latest - slow
        if (
            int256($colTicks[0] - $colTicks[2]) ** 2 +
                int256($colTicks[1] - $colTicks[2]) ** 2 +
                int256($colTicks[3] - $colTicks[2]) ** 2 >
            953 ** 2
        ) {
            for (uint256 i = 0; i < $colTicks.length; i++) {
                $tokenData0 = collToken0.getAccountMarginDetails(
                    sUser,
                    $colTicks[i],
                    $posBalanceArray,
                    $shortPremium.rightSlot(),
                    $longPremium.rightSlot()
                );
                $tokenData1 = collToken1.getAccountMarginDetails(
                    sUser,
                    $colTicks[i],
                    $posBalanceArray,
                    $shortPremium.leftSlot(),
                    $longPremium.leftSlot()
                );

                $tokenData0 = LeftRightUnsigned
                    .wrap(0)
                    .toRightSlot(uint128($balance0ExpectedP + $shortPremium.rightSlot()))
                    .toLeftSlot($tokenData0.leftSlot());
                $tokenData1 = LeftRightUnsigned
                    .wrap(0)
                    .toRightSlot(uint128($balance1ExpectedP + $shortPremium.leftSlot()))
                    .toLeftSlot($tokenData1.leftSlot());

                ($balanceCross, $thresholdCross) = PanopticMath.getCrossBalances(
                    $tokenData0,
                    $tokenData1,
                    TickMath.getSqrtRatioAtTick($colTicks[i])
                );

                $shouldRevert = $shouldRevert
                    ? $shouldRevert
                    : Math.mulDivRoundingUp($thresholdCross, buffer, 10_000) > $balanceCross;
            }
        } else {
            $tokenData0 = collToken0.getAccountMarginDetails(
                sUser,
                $colTicks[1],
                $posBalanceArray,
                $shortPremium.rightSlot(),
                $longPremium.rightSlot()
            );
            $tokenData1 = collToken1.getAccountMarginDetails(
                sUser,
                $colTicks[1],
                $posBalanceArray,
                $shortPremium.leftSlot(),
                $longPremium.leftSlot()
            );

            $tokenData0 = LeftRightUnsigned
                .wrap(0)
                .toRightSlot(uint128($balance0ExpectedP + $shortPremium.rightSlot()))
                .toLeftSlot($tokenData0.leftSlot());
            $tokenData1 = LeftRightUnsigned
                .wrap(0)
                .toRightSlot(uint128($balance1ExpectedP + $shortPremium.leftSlot()))
                .toLeftSlot($tokenData1.leftSlot());

            ($balanceCross, $thresholdCross) = PanopticMath.getCrossBalances(
                $tokenData0,
                $tokenData1,
                TickMath.getSqrtRatioAtTick($colTicks[1])
            );

            $shouldRevert = $shouldRevert
                ? $shouldRevert
                : Math.mulDivRoundingUp($thresholdCross, buffer, 10_000) > $balanceCross;
        }
    }

    // verifies the token balance of a user tracked externally matches internal accounting
    function _check_tokenBalance(bool mint) internal {
        //
        uint256 currBalance = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        emit LogAddress("query address ", $activeUser);
        emit LogUint256("positionSize ", $positionSize);
        emit LogUint256("prevSPFMTokenBal", $prevSPFMTokenBal);
        emit LogUint256("currBalanceReal", currBalance);
        //

        if (mint) {
            assertWithMsg(
                $prevSPFMTokenBal + $positionSize == currBalance,
                "SFPM token balance invalid"
            );
        } else {
            assertWithMsg(
                $prevSPFMTokenBal - $positionSize == currBalance,
                "SFPM token balance invalid"
            );
        }
    }

    function _get_effective_liq_factor(
        uint256 legTokenType,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint64 effectiveLiquidityFactorX32) {
        LeftRightUnsigned accountLiquidities = sfpm.getAccountLiquidity(
            poolKey.toId(),
            address(panopticPool),
            legTokenType,
            tickLower,
            tickUpper
        );

        uint128 netLiquidity = accountLiquidities.rightSlot();
        uint128 totalLiquidity = accountLiquidities.leftSlot();
        // compute and return effective liquidity. Return if short=net=0, which is closing short position
        if (netLiquidity == 0) return 0;

        effectiveLiquidityFactorX32 = uint64((uint256(totalLiquidity) * 2 ** 32) / netLiquidity);
    }

    function _get_assets_in_token0(address who, int24 tick) internal view returns (uint256 assets) {
        assets =
            collToken0.convertToAssets(collToken0.balanceOf(who)) +
            IERC20(token0).balanceOf(who) +
            PanopticMath.convert1to0(
                collToken1.convertToAssets(collToken1.balanceOf(who)) +
                    IERC20(token1).balanceOf(who),
                TickMath.getSqrtRatioAtTick(tick)
            );
    }

    function _get_assets_in_token1(address who, int24 tick) internal view returns (uint256 assets) {
        assets =
            collToken1.convertToAssets(collToken1.balanceOf(who)) +
            PanopticMath.convert0to1(
                collToken0.convertToAssets(collToken0.balanceOf(who)),
                TickMath.getSqrtRatioAtTick(tick)
            );
    }

    function _get_list_without_tokenid(
        TokenId[] memory list,
        TokenId target
    ) internal pure returns (TokenId[] memory out) {
        // Assumes target is in list

        uint256 l = list.length;
        out = new TokenId[](l - 1);
        uint256 out_idx = 0;

        for (uint i = 0; i < l; i++) {
            if (keccak256(abi.encode(list[i])) != keccak256(abi.encode(target))) {
                out[out_idx] = list[i];
                out_idx++;
            }
        }
    }

    function _move_tokenid_to_end(
        TokenId[] memory list,
        TokenId target
    ) internal pure returns (TokenId[] memory out) {
        uint256 l = list.length;
        out = new TokenId[](l);

        uint256 idx = 0;
        for (uint i = 0; i < l; i++) {
            if (keccak256(abi.encode(list[i])) != keccak256(abi.encode(target))) {
                out[idx] = list[i];
                idx++;
            }
        }

        out[l - 1] = target;
    }

    function convertToAssets(
        CollateralTrackerWrapper ct,
        int256 amount
    ) internal view returns (int256) {
        return (amount > 0 ? int8(1) : -1) * int256(ct.convertToAssets(uint256(Math.abs(amount))));
    }

    /////////////////////////////////////////////////////////////
    // Liquidation calculation helpers
    /////////////////////////////////////////////////////////////

    function _calculate_protocol_loss_0(int24 tick) internal {
        uint256 totalSupply0 = burnSimResults.totalSupply0;
        uint256 totalSupply1 = burnSimResults.totalSupply1;
        uint256 totalAssets0 = burnSimResults.totalAssets0;
        uint256 totalAssets1 = burnSimResults.totalAssets1;

        unchecked {
            liqResults.protocolLoss0Actual =
                (int256(Math.mulDiv($TSSubliquidateeBalancePre0, totalAssets0, totalSupply0)) -
                    int256(collToken0.convertToAssets($TSSubliquidateeBalancePre0))) +
                PanopticMath.convert1to0(
                    int256(Math.mulDiv($TSSubliquidateeBalancePre1, totalAssets1, totalSupply1)) -
                        int256(collToken1.convertToAssets($TSSubliquidateeBalancePre1)),
                    TickMath.getSqrtRatioAtTick(tick)
                );
        }
    }

    function _calculate_protocol_loss_expected_0(int24 twaptick) internal {
        int256 balRemaining0Combined = mulDivInt(
            int256(burnSimResults.delegateeBalance0) - int256(2 ** 248 - 1),
            int256(burnSimResults.totalAssets0),
            int256(burnSimResults.totalSupply0)
        ) +
            PanopticMath.convert1to0(
                mulDivInt(
                    int256(burnSimResults.delegateeBalance1) - int256(2 ** 248 - 1),
                    int256(burnSimResults.totalAssets1),
                    int256(burnSimResults.totalSupply1)
                ),
                TickMath.getSqrtRatioAtTick(twaptick)
            );

        emit LogInt256("PL bonusCombined0", liqResults.bonusCombined0);
        liqResults.protocolLoss0Expected = Math.max(
            -(balRemaining0Combined - liqResults.bonusCombined0),
            0
        );
    }

    function _calculate_settled_tokens(
        TokenId[] memory positions,
        int24 tick
    ) internal view returns (uint256, bytes memory) {
        uint256 settledTokens0;

        uint256[2][4][32] memory settledTokens;
        for (uint256 i = 0; i < positions.length; ++i) {
            for (uint256 j = 0; j < positions[i].countLegs(); ++j) {
                bytes32 chunk = keccak256(
                    abi.encodePacked(
                        positions[i].strike(j),
                        positions[i].width(j),
                        positions[i].tokenType(j)
                    )
                );
                settledTokens[i][j] = [
                    uint256(chunk),
                    LeftRightUnsigned.unwrap(panopticPool.settledTokens(chunk))
                ];
                settledTokens0 += panopticPool.settledTokens(chunk).rightSlot();
                settledTokens0 += PanopticMath.convert1to0(
                    panopticPool.settledTokens(chunk).leftSlot(),
                    TickMath.getSqrtRatioAtTick(tick)
                );
            }
        }

        return (settledTokens0, abi.encode(settledTokens));
    }

    function simulate_burnWithSettled(address who) external {
        require(msg.sender == address(this));

        hevm.prank(who);
        try
            panopticPool.burnAllOptionsFrom_commit(
                userPositions[who],
                type(int24).min,
                type(int24).max
            )
        {
            (uint256 settledT0, ) = _calculate_settled_tokens(userPositions[who], $twapTick);
            revert BurnSimSettledRes(settledT0);
        } catch {
            revert BurnSimSettledRes(0);
        }
    }

    function simulate_burning(address who, address liquidator) external {
        require(msg.sender == address(this));

        delete burnSimResults;

        hevm.prank(address(panopticPool));
        collToken0.delegate(who);
        hevm.prank(address(panopticPool));
        collToken1.delegate(who);

        int256[2] memory shareDeltasLiquidatee = [
            int256(collToken0.balanceOf(who)),
            int256(collToken1.balanceOf(who))
        ];

        try this.simulate_burnWithSettled(who) {} catch (bytes memory results) {
            emit LogBytes("r", results);

            assembly ("memory-safe") {
                results := add(results, 0x04)
            }

            burnSimResults.settledTokens0 = abi.decode(results, (uint256));
        }

        LeftRightSigned[4][] memory premiasByLeg;

        $shouldBurnRevert = false;
        hevm.prank(who);
        try
            panopticPool.burnAllOptionsFrom_noCommit(
                userPositions[who],
                type(int24).min,
                type(int24).max
            )
        returns (LeftRightSigned[4][] memory _premiasByLeg, LeftRightSigned _netExchanged) {
            premiasByLeg = _premiasByLeg;
            burnSimResults.netExchanged = _netExchanged;

            ($shortPremium, $longPremium, $posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(liquidator, false, userPositions[liquidator]);

            int24[4] memory liquidatorTicks;
            liquidatorTicks[0] = V4StateReader.getTick(manager, poolKey.toId());
            (, liquidatorTicks[1], liquidatorTicks[2], liquidatorTicks[3], ) = panopticPool
                .getOracleTicks();
            for (uint256 i = 0; i < liquidatorTicks.length; ++i) {
                if (
                    liquidator != who &&
                    collToken0
                        .getAccountMarginDetails(
                            liquidator,
                            liquidatorTicks[i],
                            $posBalanceArray,
                            $shortPremium.rightSlot(),
                            $longPremium.rightSlot()
                        )
                        .rightSlot() >
                    (2 ** 104 - 1) * 5_000
                ) revert();
                if (
                    liquidator != who &&
                    collToken1
                        .getAccountMarginDetails(
                            liquidator,
                            liquidatorTicks[i],
                            $posBalanceArray,
                            $shortPremium.leftSlot(),
                            $longPremium.leftSlot()
                        )
                        .rightSlot() >
                    (2 ** 104 - 1) * 5_000
                ) revert();
            }
        } catch {
            $shouldBurnRevert = true;
        }

        currentTickOld = currentTick;
        currentTick = V4StateReader.getTick(manager, poolKey.toId());

        shareDeltasLiquidatee = [
            int256(collToken0.balanceOf(who)) - shareDeltasLiquidatee[0],
            int256(collToken1.balanceOf(who)) - shareDeltasLiquidatee[1]
        ];

        for (uint256 i = 0; i < userPositions[who].length; ++i) {
            for (uint256 j = 0; j < userPositions[who][i].countLegs(); ++j) {
                burnSimResults.longPremium0 += premiasByLeg[i][j].rightSlot() < 0
                    ? -premiasByLeg[i][j].rightSlot()
                    : int128(0);
                burnSimResults.longPremium0 += PanopticMath.convert1to0(
                    premiasByLeg[i][j].leftSlot() < 0 ? -premiasByLeg[i][j].leftSlot() : int128(0),
                    TickMath.getSqrtRatioAtTick(currentTick)
                );
            }
        }

        burnSimResults.totalSupply0 = collToken0.totalSupply();
        burnSimResults.totalSupply1 = collToken1.totalSupply();
        burnSimResults.totalAssets0 = collToken0.totalAssets();
        burnSimResults.totalAssets1 = collToken1.totalAssets();
        burnSimResults.shareDelta0 = shareDeltasLiquidatee[0];
        burnSimResults.shareDelta1 = shareDeltasLiquidatee[1];

        burnSimResults.burnDelta0C =
            convertToAssets(collToken0, shareDeltasLiquidatee[0]) +
            PanopticMath.convert1to0(
                convertToAssets(collToken1, shareDeltasLiquidatee[1]),
                TickMath.getSqrtRatioAtTick(currentTick)
            );

        burnSimResults.delegateeBalance0 = collToken0.balanceOf(who);
        burnSimResults.delegateeBalance1 = collToken1.balanceOf(who);

        burnSimResults.burnDelta0 = convertToAssets(collToken0, shareDeltasLiquidatee[0]);
        burnSimResults.burnDelta1 = convertToAssets(collToken1, shareDeltasLiquidatee[1]);

        revert LiqBurnSimResults(burnSimResults);
    }

    function _execute_burn_simulation(address liquidatee, address liquidator) internal {
        try this.simulate_burning(liquidatee, liquidator) {} catch (bytes memory results) {
            bytes4 selector = bytes4(results);
            require(selector == LiqBurnSimResults.selector);
            emit LogBytes("r", results);

            assembly ("memory-safe") {
                results := add(results, 0x04)
            }

            burnSimResults = abi.decode(results, (BurnSimulationResults));
        }
    }

    function _calculate_margins_and_premia(address who, int24 tick) internal {
        uint256[2][] memory posBal;
        ($shortPremium, $longPremium, posBal) = panopticPool.getAccumulatedFeesAndPositionsData(
            who,
            false,
            userPositions[who]
        );

        liqResults.margin0 = collToken0.getAccountMarginDetails(
            who,
            tick,
            posBal,
            $shortPremium.rightSlot(),
            $longPremium.rightSlot()
        );
        liqResults.margin1 = collToken1.getAccountMarginDetails(
            who,
            tick,
            posBal,
            $shortPremium.leftSlot(),
            $longPremium.leftSlot()
        );
        liqResults.shortPremium = $shortPremium;
    }

    function _calculate_liquidation_bonus(int24 twaptick) external {
        emit LogInt256("twaptick", twaptick);
        emit LogUint256("liqResults.margin0.rightSlot()", liqResults.margin0.rightSlot());
        emit LogUint256("liqResults.margin0.leftSlot()", liqResults.margin0.leftSlot());
        emit LogUint256("liqResults.margin1.rightSlot()", liqResults.margin1.rightSlot());
        emit LogUint256("liqResults.margin1.leftSlot()", liqResults.margin1.leftSlot());
        emit LogInt256(
            "burnSimResults.netExchanged.rightSlot()",
            burnSimResults.netExchanged.rightSlot()
        );
        emit LogInt256(
            "burnSimResults.netExchanged.leftSlot()",
            burnSimResults.netExchanged.leftSlot()
        );
        emit LogUint256("liqResults.shortPremium.rightSlot()", liqResults.shortPremium.rightSlot());
        emit LogUint256("liqResults.shortPremium.leftSlot()", liqResults.shortPremium.leftSlot());

        (LeftRightSigned _bonus, ) = PanopticMath.getLiquidationBonus(
            liqResults.margin0,
            liqResults.margin1,
            Math.getSqrtRatioAtTick(twaptick),
            burnSimResults.netExchanged,
            liqResults.shortPremium
        );
        liqResults.bonus0 = _bonus.rightSlot();
        liqResults.bonus1 = _bonus.leftSlot();
    }

    function _calculate_bonus(int24 tick) internal {
        (uint256 balanceCross, uint256 thresholdCross) = PanopticMath.getCrossBalances(
            liqResults.margin0,
            liqResults.margin1,
            TickMath.getSqrtRatioAtTick(tick)
        );

        uint256 bonusCross = Math.min(balanceCross / 2, thresholdCross - balanceCross);

        uint256 bonus0;
        uint256 bonus1;
        // `bonusCross` and `thresholdCross` are returned in terms of the lowest-priced token
        if (TickMath.getSqrtRatioAtTick(tick) < Constants.FP96) {
            // required0 / (required0 + token0(required1))
            uint256 requiredRatioX128 = Math.mulDiv(
                liqResults.margin0.leftSlot(),
                2 ** 128,
                thresholdCross
            );

            bonus0 = Math.mulDiv128(bonusCross, requiredRatioX128);

            bonus1 = PanopticMath.convert0to1(
                Math.mulDiv128(bonusCross, 2 ** 128 - requiredRatioX128),
                TickMath.getSqrtRatioAtTick(tick)
            );
        } else {
            // required1 / (token1(required0) + required1)
            uint256 requiredRatioX128 = Math.mulDiv(
                liqResults.margin1.leftSlot(),
                2 ** 128,
                thresholdCross
            );

            bonus1 = Math.mulDiv128(bonusCross, requiredRatioX128);

            bonus0 = PanopticMath.convert1to0(
                Math.mulDiv128(bonusCross, 2 ** 128 - requiredRatioX128),
                TickMath.getSqrtRatioAtTick(tick)
            );
        }
        emit LogUint256("calc bonus0", bonus0);
        emit LogUint256("calc bonus1", bonus1);

        liqResults.bonusCombined0 = int256(
            bonus0 + PanopticMath.convert1to0(bonus1, TickMath.getSqrtRatioAtTick(tick))
        );
        emit LogInt256("calc bonusCombined0", liqResults.bonusCombined0);
    }

    function getContext(
        uint256 ts_,
        int24 _currentTick,
        int24 _width,
        bool distribution
    ) internal pure returns (int24 strikeOffset, int24 minTick, int24 maxTick) {
        int256 ts = int256(ts_);

        strikeOffset = int24(_width % 2 == 0 ? int256(0) : ts / 2);

        if (distribution) {
            minTick = int24((TickMath.MIN_TICK / ts) * ts);
            maxTick = int24((TickMath.MAX_TICK / ts) * ts);
        } else {
            minTick = int24(((_currentTick - 4096) / ts) * ts);
            maxTick = int24(((_currentTick + 4096) / ts) * ts);
        }
    }

    function getValidSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick,
        bool distribution
    ) internal returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = distribution
            ? int24(int256(bound(_widthSeed, 1, 4095)))
            : int24(int256(bound(_widthSeed, 1, 4095 / ts_)));

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        emit LogInt256("rangeDown", rangeDown);
        emit LogInt256("rangeUp", rangeUp);
        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(
            ts_,
            _currentTick,
            width,
            distribution
        );

        emit LogInt256("minTick", minTick);
        emit LogInt256("maxTick", maxTick);
        emit LogInt256("strikeOffset", strikeOffset);

        int24 lowerBound = int24(minTick + rangeDown - strikeOffset);
        int24 upperBound = int24(maxTick - rangeUp - strikeOffset);

        emit LogInt256("lowerBound", lowerBound);
        emit LogInt256("upperBound", upperBound);

        emit LogInt256("lowerBound / ts", lowerBound / ts);
        emit LogInt256("upperBound / ts", upperBound / ts);

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(_strikeSeed, lowerBound / ts, upperBound / ts));

        emit LogInt256("strike", strike);

        strike = int24(strike * ts + strikeOffset);
    }

    function size_for_collateral_solo(
        uint256 multiplierX64,
        uint256 collateral0,
        uint256 collateral1
    ) public returns (uint256) {
        unchecked {
            $sizeMultiplierDenominator = 0;
            uint256 size_long = type(uint256).max;
            for (uint256 i = 0; i < $numLegs; i++) {
                emit LogInt256("$strikes[i]", $strikes[i]);
                emit LogInt256("$widths[i]", $widths[i]);
                emit LogInt256("poolTickSpacing", poolTickSpacing);

                ($tickLower, $tickUpper) = PanopticMath.getTicks(
                    $strikes[i],
                    $widths[i],
                    poolTickSpacing
                );
                emit LogUint256("1", 1);
                emit LogUint256(
                    "Math.getSqrtRatioAtTick($strikes[i])",
                    Math.getSqrtRatioAtTick($strikes[i])
                );
                uint256 baseCR = uint256($isLongs[i] == 0 ? 2_000 : 1_000) * 2 ** 117;

                emit LogUint256("baseCR", baseCR);
                if ($assets[i] != $tokenTypes[i]) {
                    baseCR = $tokenTypes[i] == 0
                        ? PanopticMath.convert1to0(baseCR, Math.getSqrtRatioAtTick($strikes[i]))
                        : PanopticMath.convert0to1(baseCR, Math.getSqrtRatioAtTick($strikes[i]));
                }
                emit LogUint256("11", 11);

                emit LogUint256("baseCR", baseCR);

                emit LogInt256("fastOracleTick", $fastOracleTick);
                emit LogUint256("tokenTypes[i]", $tokenTypes[i]);
                emit LogUint256("ratios[i]", $ratios[i]);
                emit LogUint256("isLongs[i]", $isLongs[i]);
                emit LogUint256("$assets[i]", $assets[i]);

                if ($riskPartners[i] != i) {
                    if (
                        $riskPartners[$riskPartners[i]] != i &&
                        $ratios[i] == $ratios[$riskPartners[i]]
                    ) {
                        $shouldRevert = true;
                    } else if (
                        $isLongs[i] == $isLongs[$riskPartners[i]] &&
                        $tokenTypes[i] == $tokenTypes[$riskPartners[i]]
                    ) {
                        if ($isLongs[i] == 1) $shouldRevert = true;
                        baseCR /= 2;
                    } else if (
                        $isLongs[i] == 0 && $tokenTypes[i] != $tokenTypes[$riskPartners[i]]
                    ) {
                        // spreads are complicated to get collateral multipliers for, and should be covered by the default sizing range (as a small efficiency improvement)
                    } else {
                        $shouldRevert = true;
                    }
                }

                $sizeMultiplierDenominator += (((
                    (($tokenTypes[i] == 0 && $fastOracleTick > 0) ||
                        ($tokenTypes[i] == 1 && $fastOracleTick <= 0))
                        ? baseCR
                        : $tokenTypes[i] == 0
                        ? PanopticMath.convert0to1(baseCR, Math.getSqrtRatioAtTick($fastOracleTick))
                        : PanopticMath.convert1to0(baseCR, Math.getSqrtRatioAtTick($fastOracleTick))
                ) *
                    13_333 *
                    $ratios[i]) / 10_000);
                emit LogUint256("2", 2);

                $netLiquidity = sfpm
                    .getAccountLiquidity(
                        poolKey.toId(),
                        address(panopticPool),
                        $tokenTypes[i],
                        $tickLower,
                        $tickUpper
                    )
                    .rightSlot();

                if ($netLiquidity > 0 && $isLongs[i] == 1) {
                    size_long = Math.min(
                        size_long,
                        $assets[i] == 0
                            ? LiquidityAmounts.getAmount0ForLiquidity(
                                Math.getSqrtRatioAtTick($tickLower),
                                Math.getSqrtRatioAtTick($tickUpper),
                                uint128(
                                    Math.mulDiv($netLiquidity, multiplierX64, 2 ** 64) / $ratios[i]
                                )
                            )
                            : LiquidityAmounts.getAmount1ForLiquidity(
                                Math.getSqrtRatioAtTick($tickLower),
                                Math.getSqrtRatioAtTick($tickUpper),
                                uint128(
                                    Math.mulDiv($netLiquidity, multiplierX64, 2 ** 64) / $ratios[i]
                                )
                            )
                    );
                }

                if (
                    $isLongs[i] == 0 &&
                    !((($fastOracleTick >= $tickUpper) && ($tokenTypes[i] == 1)) ||
                        (($fastOracleTick < $tickLower) && ($tokenTypes[i] == 0)))
                ) {
                    // amountMoved for 2k posSize
                    uint256 ITMCR = baseCR * 5;

                    uint160 ratio = $tokenTypes[i] == 1
                        ? Math.getSqrtRatioAtTick(
                            Math.max24(
                                2 * ($fastOracleTick - $strikes[i]),
                                Constants.MIN_V4POOL_TICK
                            )
                        )
                        : Math.getSqrtRatioAtTick(
                            Math.max24(
                                2 * ($strikes[i] - $fastOracleTick),
                                Constants.MIN_V4POOL_TICK
                            )
                        );

                    if (
                        (($fastOracleTick < $tickLower) && ($tokenTypes[i] == 1)) ||
                        (($fastOracleTick >= $tickUpper) && ($tokenTypes[i] == 0))
                    ) {
                        uint256 c2 = Constants.FP96 - ratio;

                        ITMCR = Math.mulDiv96RoundingUp(ITMCR, c2);
                    } else {
                        uint160 scaleFactor = Math.getSqrtRatioAtTick(
                            ($tickUpper - $strikes[i]) + ($strikes[i] - $tickLower)
                        );
                        ITMCR = Math.mulDivRoundingUp(
                            ITMCR,
                            scaleFactor - ratio,
                            scaleFactor + Constants.FP96
                        );
                    }
                    emit LogUint256("3", 4);
                    emit LogUint256("ITMCR", ITMCR);

                    $sizeMultiplierDenominator = (((
                        (($tokenTypes[i] == 0 && $fastOracleTick > 0) ||
                            ($tokenTypes[i] == 1 && $fastOracleTick <= 0))
                            ? ITMCR
                            : $tokenTypes[i] == 0
                            ? PanopticMath.convert0to1(
                                ITMCR,
                                Math.getSqrtRatioAtTick($fastOracleTick)
                            )
                            : PanopticMath.convert1to0(
                                ITMCR,
                                Math.getSqrtRatioAtTick($fastOracleTick)
                            )
                    ) *
                        13_333 *
                        $ratios[i]) / 10_000);
                }
            }
            emit LogUint256("4", 4);

            uint256 targetCross = Math.mulDiv64(
                $fastOracleTick > 0
                    ? collateral0 +
                        PanopticMath.convert1to0(
                            collateral1,
                            Math.getSqrtRatioAtTick($fastOracleTick)
                        )
                    : PanopticMath.convert0to1(
                        collateral0,
                        Math.getSqrtRatioAtTick($fastOracleTick)
                    ) + collateral1,
                multiplierX64
            );

            $sizeMultiplierDenominator = max($sizeMultiplierDenominator, 1);
            emit LogUint256("5", 5);

            emit LogUint256("targetCross", targetCross);
            emit LogUint256("sizeMultiplierNumerator", 10_000 * 2 ** 117);
            emit LogUint256("sizeMultiplierDenominator", $sizeMultiplierDenominator);
            // emit LogUint256("sizeMultiplierX128", Math.mulDiv(2**128, $sizeMultiplierNumerator, $sizeMultiplierDenominator));

            emit LogUint256(
                "size_collat",
                Math.mulDiv(targetCross, 10_000 * 2 ** 117, $sizeMultiplierDenominator)
            );
            emit LogUint256("size_long", size_long);

            // desired_collateral * (position_size / colReq) = desired_position_size
            // or, bound it to the long position size (based on available liq)
            return
                Math.min(
                    size_long,
                    Math.mulDiv(targetCross, 10_000 * 2 ** 117, $sizeMultiplierDenominator)
                );
        }
    }

    function write_mintburn_transfer_amts() internal {
        currentSqrtPriceX96 = V4StateReader.getSqrtPriceX96(manager, poolKey.toId());
        for (uint256 i = 0; i < $tokenIdActive.countLegs(); ++i) {
            LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                $tokenIdActive,
                i,
                $positionSizeActive
            );

            emit LogUint256("$positionSizeActive", $positionSizeActive);
            emit LogInt256("liquidityChunk.tickLower()", liquidityChunk.tickLower());
            emit LogInt256("liquidityChunk.tickUpper()", liquidityChunk.tickUpper());
            emit LogUint256("liquidityChunk.liquidity()", liquidityChunk.liquidity());

            $tickLower = liquidityChunk.tickLower();
            $tickUpper = liquidityChunk.tickUpper();

            (uint256 amount0, uint256 amount1) = _getAmountsForLiquidity(
                currentSqrtPriceX96,
                Math.getSqrtRatioAtTick(liquidityChunk.tickLower()),
                Math.getSqrtRatioAtTick(liquidityChunk.tickUpper()),
                liquidityChunk.liquidity(),
                false
            );

            emit LogUint256("amount0", amount0);
            emit LogUint256("amount1", amount1);

            $netLiquidity = sfpm
                .getAccountLiquidity(
                    poolKey.toId(),
                    address(panopticPool),
                    $tokenTypes[i],
                    $tickLower,
                    $tickUpper
                )
                .rightSlot();

            $removedLiquidity = sfpm
                .getAccountLiquidity(
                    poolKey.toId(),
                    address(panopticPool),
                    $tokenTypes[i],
                    $tickLower,
                    $tickUpper
                )
                .leftSlot();

            if ($tokenIdActive.isLong(i) == 0) {
                $shouldRevert = $shouldRevert ? $shouldRevert : liquidityChunk.liquidity() == 0;

                emit LogBool("should revert due to 0 liquidity", $shouldRevert);

                $netTokenTransfers0 += int256(amount0);
                $netTokenTransfers1 += int256(amount1);
                $spreadRatio =
                    ($removedLiquidity * 100_000_000) /
                    uint256(Math.max(1, $netLiquidity + liquidityChunk.liquidity()));
                emit LogUint256("$spreadRatioS", $spreadRatio);
            } else {
                $netTokenTransfers0 -= int256(amount0);
                $netTokenTransfers0 -= int256(amount1);
                $spreadRatio =
                    (($removedLiquidity + ($isBurn ? 0 : liquidityChunk.liquidity())) * (2 ** 32)) /
                    uint256(
                        Math.max(
                            1,
                            uint256(
                                int256($netLiquidity) - int256(uint256(liquidityChunk.liquidity()))
                            )
                        )
                    );
                emit LogUint256("$spreadRatioL", $spreadRatio);

                $shouldRevert = $shouldRevert || $isBurn
                    ? $shouldRevert
                    : int256($netLiquidity) - int256(uint256(liquidityChunk.liquidity())) == 0;
                $shouldRevert = $shouldRevert ? $shouldRevert : $spreadRatio > 9 * (2 ** 32);
                emit LogBool("should revert due to spread ratio", $shouldRevert);
            }

            $maxTransfer0 = Math.max($maxTransfer0, $netTokenTransfers0);
            $maxTransfer1 = Math.max($maxTransfer1, $netTokenTransfers1);
        }
    }

    function quote_ppfees_includecollectedbyleg(
        address acc,
        LeftRightUnsigned[4] memory collectedByLeg,
        TokenId tokenIdAct,
        TokenId[] memory posList
    ) internal {
        try this.ppfees_includecollected_sim(acc, collectedByLeg, tokenIdAct, posList) {} catch (
            bytes memory results
        ) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }
            ($shortPremium, $longPremium, $posBalanceArray) = abi.decode(
                results,
                (LeftRightUnsigned, LeftRightUnsigned, uint256[2][])
            );
        }
    }

    function ppfees_includecollected_sim(
        address acc,
        LeftRightUnsigned[4] memory collectedByLeg,
        TokenId tokenIdAct,
        TokenId[] memory posList
    ) external {
        require(msg.sender == address(this));

        for (uint256 i = 0; i < tokenIdAct.countLegs(); ++i) {
            bytes32 chunkKey = keccak256(
                abi.encodePacked(tokenIdAct.strike(i), tokenIdAct.width(i), tokenIdAct.tokenType(i))
            );

            panopticPool.addSettledTokens(chunkKey, collectedByLeg[i]);
        }

        ($shortPremium, $longPremium, $posBalanceArray) = panopticPool
            .getAccumulatedFeesAndPositionsData(acc, false, posList);

        revert PpfeesCollectedSimRes($shortPremium, $longPremium, $posBalanceArray);
    }

    function quote_sfpm_mint() internal {
        try this.sfpm_mint_sim() {} catch (bytes memory results) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }
            bool sRevert;
            ($collectedByLeg, $totalSwapped, $colTicks, sRevert) = abi.decode(
                results,
                (LeftRightUnsigned[4], LeftRightSigned, int24[4], bool)
            );

            $shouldRevert = $shouldRevert || sRevert;
        }
    }

    function quote_sfpm_burn() internal {
        try this.sfpm_burn_sim() {} catch (bytes memory results) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }
            bool sRevert;
            ($collectedByLeg, $totalSwapped, $colTicks, sRevert) = abi.decode(
                results,
                (LeftRightUnsigned[4], LeftRightSigned, int24[4], bool)
            );

            $shouldRevert = $shouldRevert || sRevert;
        }
    }

    function quote_pp_burn() internal {
        try this.pp_burn_sim() {} catch (bytes memory results) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }
            bool sRevert;
            ($colDelta0, $colDelta1, sRevert) = abi.decode(results, (int256, int256, bool));

            $shouldRevert = $shouldRevert || sRevert;
        }
    }

    function quote_pp_burn_many() internal {
        $caller = msg.sender;

        try this.pp_burn_many_sim() {} catch (bytes memory results) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }

            ($balance0ExpectedP, $balance1ExpectedP, $burnManySimResults, $shouldRevert) = abi
                .decode(results, (uint256, uint256, BurnManySimResults, bool));
        }
    }

    // this might seem circular, but the point is really just so we can use grossPremium/settledTokens values that are independently verified later for collateral calcs
    function quote_fees_postburn() internal {
        $caller = msg.sender;
        try this.feequote_postburn_sim() {} catch (bytes memory results) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }
            ($shortPremium, $longPremium, $posBalanceArray) = abi.decode(
                results,
                (LeftRightUnsigned, LeftRightUnsigned, uint256[2][])
            );
        }
    }

    function pp_burn_sim() external {
        // prevent fuzzer from calling this directly with weird out-of-bounds numbers
        require(msg.sender == address(this));

        hevm.prank($exercisee);
        try
            panopticPool.burnOptions(
                $tokenIdActive,
                $positionListExercisee,
                TickMath.MIN_TICK - 1,
                TickMath.MAX_TICK + 1,
                true
            )
        {
            revert PPBurnSimResError(
                int256(collToken0.balanceOf($exercisee)) - $balance0Exercisee,
                int256(collToken1.balanceOf($exercisee)) - $balance1Exercisee,
                false
            );
        } catch (bytes memory reason) {
            if (keccak256(reason) == keccak256(abi.encodeWithSignature("Panic(uint256)", 0x11))) {
                hevm.prank(address(panopticPool));
                collToken0.delegate($exercisee);
                hevm.prank(address(panopticPool));
                collToken1.delegate($exercisee);
                int256 balExerciseeOrig0 = int256(collToken0.balanceOf($exercisee));
                int256 balExerciseeOrig1 = int256(collToken1.balanceOf($exercisee));

                hevm.prank($exercisee);
                try
                    panopticPool.burnOptionsAndSkipCollateralCheck(
                        $tokenIdActive,
                        TickMath.MIN_TICK - 1,
                        TickMath.MAX_TICK + 1
                    )
                {
                    revert PPBurnSimResError(
                        int256(collToken0.balanceOf($exercisee)) - balExerciseeOrig0,
                        int256(collToken1.balanceOf($exercisee)) - balExerciseeOrig1,
                        false
                    );
                } catch {
                    revert PPBurnSimResError(0, 0, true);
                }
            } else {
                revert PPBurnSimResError(0, 0, true);
            }
        }
    }

    function pp_burn_many_sim() external {
        // prevent fuzzer from calling this directly with weird out-of-bounds numbers
        require(msg.sender == address(this));

        $settledTokens0Portfolio = new uint256[4][]($numOptions);
        $settledTokens1Portfolio = new uint256[4][]($numOptions);
        $grossPremiaL0Portfolio = new uint256[4][]($numOptions);
        $grossPremiaL1Portfolio = new uint256[4][]($numOptions);
        $sfpmBals = new uint256[]($numOptions);

        delete $burnManySimResults;
        for (uint256 i = 0; i < $numOptions; i++) {
            (, , observationIndex, observationCardinality, , , ) = pool.slot0();
            currentTick = V4StateReader.getTick(manager, poolKey.toId());

            ($slowOracleTick, ) = panopticHelper.computeInternalMedian(
                60,
                uint256(hevm.load(address(panopticPool), bytes32(uint256(0)))),
                IV3CompatibleOracle(address(pool))
            );

            $tokenIdActive = userPositions[$caller][0];
            userPositions[$caller] = _get_list_without_tokenid(
                userPositions[$caller],
                $tokenIdActive
            );
            hevm.prank($caller);

            try
                panopticPool.burnOptions(
                    $tokenIdActive,
                    userPositions[$caller],
                    $tickLimitLow,
                    $tickLimitHigh,
                    true
                )
            {} catch {
                revert PPBurnManySimResError(
                    collToken0.balanceOf($caller),
                    collToken1.balanceOf($caller),
                    $burnManySimResults,
                    true
                );
            }
        }

        for (uint256 i = 0; i < $numOptions; ++i) {
            $sfpmBals[i] = sfpm.balanceOf(address(panopticPool), TokenId.unwrap($posIdListOld[i]));

            for (uint256 j = 0; j < $posIdListOld[i].countLegs(); ++j) {
                (
                    $settledTokens0Portfolio[i][j],
                    $settledTokens1Portfolio[i][j],
                    $grossPremiaL0Portfolio[i][j],
                    $grossPremiaL1Portfolio[i][j]
                ) = panopticPool.premiaSettlementData($posIdListOld[i], j);
            }
        }
        $burnManySimResults.settledTokens0Portfolio = $settledTokens0Portfolio;
        $burnManySimResults.settledTokens1Portfolio = $settledTokens1Portfolio;
        $burnManySimResults.grossPremiaL0Portfolio = $grossPremiaL0Portfolio;
        $burnManySimResults.grossPremiaL1Portfolio = $grossPremiaL1Portfolio;
        $burnManySimResults.sfpmBals = $sfpmBals;
        revert PPBurnManySimResError(
            collToken0.balanceOf($caller),
            collToken1.balanceOf($caller),
            $burnManySimResults,
            false
        );
    }

    function feequote_postburn_sim() external {
        // prevent fuzzer from calling this directly with weird out-of-bounds numbers
        require(msg.sender == address(this));

        // ensures they have sufficient collateral - if it fails with another type of error it can be caught elsewhere
        hevm.prank(address(panopticPool));
        collToken0.delegate($caller);
        hevm.prank(address(panopticPool));
        collToken1.delegate($caller);

        hevm.prank($caller);
        try
            panopticPool.burnOptionsAndSkipCollateralCheck(
                $tokenIdActive,
                $tickLimitLow,
                $tickLimitHigh
            )
        {
            ($shortPremium, $longPremium, $posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData($caller, false, userPositions[$caller]);
            revert FeeQuotePostBurnSimResError($shortPremium, $longPremium, $posBalanceArray);
        } catch {
            revert FeeQuotePostBurnSimResError(
                LeftRightUnsigned.wrap(0),
                LeftRightUnsigned.wrap(0),
                new uint256[2][](0)
            );
        }
    }

    function sfpm_mint_sim() external {
        // prevent fuzzer from calling this directly with weird out-of-bounds numbers
        require(msg.sender == address(this));

        hevm.prank(address(panopticPool));
        try
            sfpm.mintTokenizedPosition(
                poolKey,
                $tokenIdActive,
                $positionSizeActive,
                $tickLimitLow,
                $tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            int24[4] memory __colTicks;
            (__colTicks[1], __colTicks[2], __colTicks[3], ) = PanopticMath.getOracleTicks(
                IV3CompatibleOracle(address(pool)),
                uint256(hevm.load(address(panopticPool), bytes32(uint256(0))))
            );
            __colTicks[0] = V4StateReader.getTick(manager, poolKey.toId());

            revert SFPMMintResError(collectedByLeg, totalSwapped, __colTicks, false);
        } catch {
            LeftRightUnsigned[4] memory collectedByLeg;
            LeftRightSigned totalSwapped;

            int24[4] memory __colTicks;
            (__colTicks[1], __colTicks[2], __colTicks[3], ) = PanopticMath.getOracleTicks(
                IV3CompatibleOracle(address(pool)),
                uint256(hevm.load(address(panopticPool), bytes32(uint256(0))))
            );
            __colTicks[0] = V4StateReader.getTick(manager, poolKey.toId());

            revert SFPMMintResError(collectedByLeg, totalSwapped, __colTicks, true);
        }
    }

    function sfpm_burn_sim() external {
        // prevent fuzzer from calling this directly with weird out-of-bounds numbers
        require(msg.sender == address(this));

        hevm.prank(address(panopticPool));
        try
            sfpm.burnTokenizedPosition(
                poolKey,
                $tokenIdActive,
                $positionSizeActive,
                $tickLimitLow,
                $tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            int24[4] memory __colTicks;
            (__colTicks[1], __colTicks[2], __colTicks[3], ) = PanopticMath.getOracleTicks(
                IV3CompatibleOracle(address(pool)),
                uint256(hevm.load(address(panopticPool), bytes32(uint256(0))))
            );
            __colTicks[0] = V4StateReader.getTick(manager, poolKey.toId());

            revert SFPMBurnResError(collectedByLeg, totalSwapped, __colTicks, false);
        } catch {
            LeftRightUnsigned[4] memory collectedByLeg;
            LeftRightSigned totalSwapped;

            int24[4] memory __colTicks;
            (__colTicks[1], __colTicks[2], __colTicks[3], ) = PanopticMath.getOracleTicks(
                IV3CompatibleOracle(address(pool)),
                uint256(hevm.load(address(panopticPool), bytes32(uint256(0))))
            );
            __colTicks[0] = V4StateReader.getTick(manager, poolKey.toId());

            revert SFPMBurnResError(collectedByLeg, totalSwapped, __colTicks, true);
        }
    }

    function validate_exercisable_ext(TokenId eid, int24 tickEat) external view {
        // prevent fuzzer from calling this directly with weird out-of-bounds numbers
        require(msg.sender == address(this));
        eid.validateIsExercisable(tickEat);
    }

    ////////////////////////////////////////////////////
    // Loggers
    ////////////////////////////////////////////////////

    function log_tokenid_leg(TokenId t, uint256 leg) internal {
        emit LogString("TokenId");
        emit LogUint256("  Asset", t.asset(leg));
        emit LogUint256("  Option ratio", t.optionRatio(leg));
        emit LogUint256("  Is long", t.isLong(leg));
        emit LogUint256("  Token type", t.tokenType(leg));
        emit LogUint256("  Risk partner", t.riskPartner(leg));
        emit LogInt256("  Strike tick", t.strike(leg));
        emit LogInt256("  Width", t.width(leg));
    }

    function log_account_collaterals(address account) internal {
        uint c0s = collToken0.balanceOf(account);
        uint c1s = collToken1.balanceOf(account);
        uint c0a = collToken0.convertToAssets(collToken0.balanceOf(account));
        uint c1a = collToken1.convertToAssets(collToken1.balanceOf(account));

        emit LogAddress("Collaterals for address", account);
        emit LogUint256("  Token0 (shares)", c0s);
        emit LogUint256("  Token0 (assets)", c0a);
        emit LogUint256("  Token1 (shares)", c1s);
        emit LogUint256("  Token1 (assets)", c1a);
    }

    function log_trackers_status() internal {
        uint ts0 = collToken0.totalSupply();
        uint ta0 = collToken0.totalAssets();
        uint ts1 = collToken1.totalSupply();
        uint ta1 = collToken1.totalAssets();
        emit LogUint256("Total shares collateral 0:", ts0);
        emit LogUint256("Total assets collateral 0:", ta0);
        emit LogUint256("Total shares collateral 1:", ts1);
        emit LogUint256("Total assets collateral 1:", ta1);
    }

    function log_burn_simulation_results() internal {
        emit LogString("Burn simulation results");
        emit LogUint256("    totalSupply0", burnSimResults.totalSupply0);
        emit LogUint256("    totalSupply1", burnSimResults.totalSupply1);
        emit LogUint256("    totalAssets0", burnSimResults.totalAssets0);
        emit LogUint256("    totalAssets1", burnSimResults.totalAssets1);
        emit LogUint256("    settledTokens0", burnSimResults.settledTokens0);
        emit LogInt256("    shareDelta0", burnSimResults.shareDelta0);
        emit LogInt256("    shareDelta1", burnSimResults.shareDelta1);
        emit LogInt256("    longPremium0", burnSimResults.longPremium0);
        emit LogInt256("    burnDelta0C", burnSimResults.burnDelta0C);
        emit LogInt256("    burnDelta0", burnSimResults.burnDelta0);
        emit LogInt256("    burnDelta1", burnSimResults.burnDelta1);
        emit LogInt256("    netExchanged L", burnSimResults.netExchanged.leftSlot());
        emit LogInt256("    netExchanged R", burnSimResults.netExchanged.rightSlot());
    }

    function log_liquidation_results() internal {
        emit LogString("Liquidation results");
        emit LogUint256("    margin0 L", liqResults.margin0.leftSlot());
        emit LogUint256("    margin0 R", liqResults.margin0.rightSlot());
        emit LogUint256("    margin1 L", liqResults.margin1.leftSlot());
        emit LogUint256("    margin1 R", liqResults.margin1.rightSlot());
        emit LogInt256("    bonus0", liqResults.bonus0);
        emit LogInt256("    bonus1", liqResults.bonus1);
        emit LogInt256("    sharesD0", liqResults.sharesD0);
        emit LogInt256("    sharesD1", liqResults.sharesD1);
        emit LogUint256("    liquidatorValueBefore0", liqResults.liquidatorValueBefore0);
        emit LogInt256("    liquidatorValueAfter0", liqResults.liquidatorValueAfter0);
        emit LogUint256("    settledTokens0", liqResults.settledTokens0);
        emit LogUint256("    premia L", liqResults.shortPremium.leftSlot());
        emit LogUint256("    premia R", liqResults.shortPremium.rightSlot());
        emit LogInt256("    bonusCombined0", liqResults.bonusCombined0);
        emit LogInt256("    protocolLoss0Actual", liqResults.protocolLoss0Actual);
        emit LogInt256("    protocolLoss0Expected", liqResults.protocolLoss0Expected);
    }
}
