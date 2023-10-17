// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {FeesCalc} from "@libraries/FeesCalc.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRight} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {FixedPoint128} from "v3-core/libraries/FixedPoint128.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v3-core/libraries/SqrtPriceMath.sol";
import {PoolAddress} from "v3-periphery/libraries/PoolAddress.sol";
import {PositionKey} from "v3-periphery/libraries/PositionKey.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticHelper} from "@contracts/periphery/PanopticHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionUtils} from "../testUtils/PositionUtils.sol";
import {UniPoolPriceMock} from "../testUtils/PriceMocks.sol";

contract SemiFungiblePositionManagerHarness is SemiFungiblePositionManager {
    constructor(IUniswapV3Factory _factory) SemiFungiblePositionManager(_factory) {}

    function poolContext(uint64 poolId) public view returns (PoolAddressAndLock memory) {
        return s_poolContext[poolId];
    }

    function addrToPoolId(address pool) public view returns (uint256) {
        return s_AddrToPoolIdData[pool];
    }
}

contract PanopticPoolHarness is PanopticPool {
    /// @notice get the positions hash of an account
    /// @param user the account to get the positions hash of
    /// @return _positionsHash positions hash of the account
    function positionsHash(address user) external view returns (uint248 _positionsHash) {
        _positionsHash = uint248(s_positionsHash[user]);
    }

    /**
     * @notice compute the TWAP price from the last 600s = 10mins
     * @return twapTick the TWAP price in ticks
     */
    function getUniV3TWAP_() external view returns (int24 twapTick) {
        twapTick = PanopticMath.twapFilter(s_univ3pool, TWAP_WINDOW);
    }

    constructor(SemiFungiblePositionManager _sfpm) PanopticPool(_sfpm) {}
}

contract PanopticPoolTest is PositionUtils {
    using TokenId for uint256;
    using LeftRight for uint256;
    using LeftRight for int256;
    using LeftRight for uint128;
    using LiquidityChunk for uint256;

    /*//////////////////////////////////////////////////////////////
                           MAINNET CONTRACTS
    //////////////////////////////////////////////////////////////*/

    // the instance of SFPM we are testing
    SemiFungiblePositionManagerHarness sfpm;

    // reference implemenatations used by the factory
    address poolReference;

    address collateralReference;

    // Mainnet factory address - SFPM is dependent on this for several checks and callbacks
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    // Mainnet router address - used for swaps to test fees/premia
    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // used as example of price parity
    IUniswapV3Pool constant USDC_USDT_5 =
        IUniswapV3Pool(0x7858E59e0C01EA06Df3aF3D20aC7B0003275D4Bf);

    // store a few different mainnet pairs - the pool used is part of the fuzz
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IUniswapV3Pool constant WBTC_ETH_30 =
        IUniswapV3Pool(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);
    IUniswapV3Pool constant USDC_WETH_30 =
        IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8);
    IUniswapV3Pool[3] public pools = [USDC_WETH_5, USDC_WETH_5, USDC_WETH_5];

    /*//////////////////////////////////////////////////////////////
                              WORLD STATE
    //////////////////////////////////////////////////////////////*/

    // store some data about the pool we are testing
    IUniswapV3Pool pool;
    uint64 poolId;
    address token0;
    address token1;
    // We range position size in terms of WETH, so need to figure out which token is WETH
    uint256 isWETH;
    uint24 fee;
    int24 tickSpacing;
    uint160 currentSqrtPriceX96;
    int24 currentTick;
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
    uint256 poolBalance0;
    uint256 poolBalance1;

    int24 medianTick;
    uint160 medianSqrtPriceX96;
    int24 TWAPtick;
    int24[] priceArray;

    int256 rangesFromStrike;
    int256[2] exerciseFeeAmounts;

    PanopticFactory factory;
    PanopticPoolHarness pp;
    CollateralTracker ct0;
    CollateralTracker ct1;

    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Swapper = address(0x123456789);
    address Charlie = address(0x1234567891);
    address Seller = address(0x12345678912);

    /*//////////////////////////////////////////////////////////////
                               TEST DATA
    //////////////////////////////////////////////////////////////*/

    // used to pass into libraries
    mapping(uint256 tokenId => uint256 balance) userBalance;

    mapping(address actor => uint256 lastBalance0) lastCollateralBalance0;
    mapping(address actor => uint256 lastBalance1) lastCollateralBalance1;

    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtLower;
    uint160 sqrtUpper;

    uint128 positionSize;
    uint128 positionSizeBurn;

    uint128 expectedLiq;
    uint128 expectedLiqMint;
    uint128 expectedLiqBurn;

    int256 $amount0Moved;
    int256 $amount1Moved;
    int256 $amount0MovedMint;
    int256 $amount1MovedMint;
    int256 $amount0MovedBurn;
    int256 $amount1MovedBurn;

    int128 $expectedPremia0;
    int128 $expectedPremia1;

    int24[] tickLowers;
    int24[] tickUppers;
    uint160[] sqrtLowers;
    uint160[] sqrtUppers;

    uint128[] positionSizes;
    uint128[] positionSizesBurn;

    uint128[] expectedLiqs;
    uint128[] expectedLiqsMint;
    uint128[] expectedLiqsBurn;

    int24 $width;
    int24 $strike;
    int24 $width2;
    int24 $strike2;

    uint256[] tokenIds;

    int256[] $amount0Moveds;
    int256[] $amount1Moveds;
    int256[] $amount0MovedsMint;
    int256[] $amount1MovedsMint;
    int256[] $amount0MovedsBurn;
    int256[] $amount1MovedsBurn;

    int128[] $expectedPremias0;
    int128[] $expectedPremias1;

    int256 $swap0;
    int256 $swap1;
    int256 $itm0;
    int256 $itm1;
    int256 $intrinsicValue0;
    int256 $intrinsicValue1;
    int256 $ITMSpread0;
    int256 $ITMSpread1;

    int256 $balanceDelta0;
    int256 $balanceDelta1;

    uint256 currentValue0;
    uint256 currentValue1;
    uint256 medianValue0;
    uint256 medianValue1;

    int24 atTick;

    /*//////////////////////////////////////////////////////////////
                               ENV SETUP
    //////////////////////////////////////////////////////////////*/

    function _initPool(uint256 seed) internal {
        _initWorld(seed);
    }

    function _initWorldAtTick(uint256 seed, int24 tick) internal {
        // Pick a pool from the seed and cache initial state
        _cacheWorldState(pools[bound(seed, 0, pools.length - 1)]);

        // replace pool with a mock and set the tick
        vm.etch(address(pool), address(new UniPoolPriceMock()).code);

        UniPoolPriceMock(address(pool)).construct(
            UniPoolPriceMock.Slot0(TickMath.getSqrtRatioAtTick(tick), tick, 0, 0, 0, 0, true),
            address(token0),
            address(token1),
            fee,
            tickSpacing
        );

        _deployPanopticPool();

        _initAccounts();
    }

    function _initWorld(uint256 seed) internal {
        // Pick a pool from the seed and cache initial state
        _cacheWorldState(pools[bound(seed, 0, pools.length - 1)]);

        _deployPanopticPool();

        _initAccounts();
    }

    function _cacheWorldState(IUniswapV3Pool _pool) internal {
        pool = _pool;
        poolId = PanopticMath.getPoolId(address(_pool));
        token0 = _pool.token0();
        token1 = _pool.token1();
        isWETH = token0 == address(WETH) ? 0 : 1;
        fee = _pool.fee();
        tickSpacing = _pool.tickSpacing();
        (currentSqrtPriceX96, currentTick, , , , , ) = _pool.slot0();
        feeGrowthGlobal0X128 = _pool.feeGrowthGlobal0X128();
        feeGrowthGlobal1X128 = _pool.feeGrowthGlobal1X128();
        poolBalance0 = IERC20Partial(token0).balanceOf(address(_pool));
        poolBalance1 = IERC20Partial(token1).balanceOf(address(_pool));
    }

    function _deployPanopticPool() internal {
        vm.startPrank(Deployer);

        factory = new PanopticFactory(WETH, sfpm, V3FACTORY, poolReference, collateralReference);

        deal(token0, Deployer, type(uint104).max);
        deal(token1, Deployer, type(uint104).max);
        IERC20Partial(token0).approve(address(factory), type(uint104).max);
        IERC20Partial(token1).approve(address(factory), type(uint104).max);

        pp = PanopticPoolHarness(address(factory.deployNewPool(token0, token1, fee, 1337)));

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();
    }

    function _initAccounts() internal {
        changePrank(Swapper);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        deal(token0, Swapper, type(uint104).max);
        deal(token1, Swapper, type(uint104).max);

        changePrank(Charlie);

        deal(token0, Charlie, type(uint104).max);
        deal(token1, Charlie, type(uint104).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);
        IERC20Partial(token0).approve(address(pp), type(uint256).max);
        IERC20Partial(token1).approve(address(pp), type(uint256).max);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);

        changePrank(Seller);

        deal(token0, Seller, type(uint104).max);
        deal(token1, Seller, type(uint104).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);
        IERC20Partial(token0).approve(address(pp), type(uint256).max);
        IERC20Partial(token1).approve(address(pp), type(uint256).max);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);

        ct0.deposit(type(uint104).max, Seller);
        ct1.deposit(type(uint104).max, Seller);

        // cancel out MEV tax and push exchange rate back to 1
        deal(address(ct0), Seller, type(uint104).max, true);
        deal(address(ct1), Seller, type(uint104).max, true);

        changePrank(Bob);
        // account for MEV tax
        deal(token0, Bob, (type(uint104).max * uint256(1010)) / 1000);
        deal(token1, Bob, (type(uint104).max * uint256(1010)) / 1000);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);
        IERC20Partial(token0).approve(address(pp), type(uint256).max);
        IERC20Partial(token1).approve(address(pp), type(uint256).max);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);

        ct0.deposit(type(uint104).max, Bob);
        ct1.deposit(type(uint104).max, Bob);

        // cancel out MEV tax and push exchange rate back to 1
        deal(address(ct0), Bob, type(uint104).max, true);
        deal(address(ct1), Bob, type(uint104).max, true);

        changePrank(Alice);

        deal(token0, Alice, type(uint104).max);
        deal(token1, Alice, type(uint104).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);
        IERC20Partial(token0).approve(address(pp), type(uint256).max);
        IERC20Partial(token1).approve(address(pp), type(uint256).max);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);

        ct0.deposit(type(uint104).max, Alice);
        ct1.deposit(type(uint104).max, Alice);

        // cancel out MEV tax and push exchange rate back to 1
        deal(address(ct0), Alice, type(uint104).max, true);
        deal(address(ct1), Alice, type(uint104).max, true);
    }

    function setUp() public {
        sfpm = new SemiFungiblePositionManagerHarness(V3FACTORY);

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPoolHarness(sfpm));
        collateralReference = address(new CollateralTracker());
    }

    /*//////////////////////////////////////////////////////////////
                          TEST DATA POPULATION
    //////////////////////////////////////////////////////////////*/

    function populatePositionData(int24 width, int24 strike, uint256 positionSizeSeed) internal {
        tickLower = int24(strike - (width * tickSpacing) / 2);
        tickLowers.push(tickLower);
        tickUpper = int24(strike + (width * tickSpacing) / 2);
        tickUppers.push(tickUpper);
        sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        sqrtLowers.push(sqrtLower);
        sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        sqrtUppers.push(sqrtUpper);

        // 0.0001 -> 10_000 WETH
        positionSizeSeed = bound(positionSizeSeed, 10 ** 15, 10 ** 22);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSize = uint128(
            getContractsForAmountAtTick(currentTick, tickLower, tickUpper, isWETH, positionSizeSeed)
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        expectedLiq = isWETH == 0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, positionSize)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, positionSize);
        expectedLiqs.push(expectedLiq);

        $amount0Moveds.push(
            sqrtUpper < currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    sqrtLower < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLower,
                    sqrtUpper,
                    int128(expectedLiq)
                )
        );

        $amount1Moveds.push(
            sqrtLower > currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount1Delta(
                    sqrtLower,
                    sqrtUpper > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUpper,
                    int128(expectedLiq)
                )
        );
    }

    // intended to be combined with a min-width position so that most of the pool's liquidity is consumed by the position
    function populatePositionDataLarge(
        int24 width,
        int24 strike,
        uint256 positionSizeSeed
    ) internal {
        tickLower = int24(strike - (width * tickSpacing) / 2);
        tickUpper = int24(strike + (width * tickSpacing) / 2);
        sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

        // 0.0001 -> 10_000 WETH
        positionSizeSeed = bound(positionSizeSeed, 10 ** 22, 10 ** 24);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSize = uint128(
            getContractsForAmountAtTick(currentTick, tickLower, tickUpper, isWETH, positionSizeSeed)
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        expectedLiq = isWETH == 0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, positionSize)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, positionSize);
    }

    function populatePositionData(
        int24 width,
        int24 strike,
        uint256[2] memory positionSizeSeeds
    ) internal {
        tickLower = int24(strike - (width * tickSpacing) / 2);
        tickUpper = int24(strike + (width * tickSpacing) / 2);
        sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

        positionSizeSeeds[0] = bound(positionSizeSeeds[0], 10 ** 15, 10 ** 22);
        positionSizeSeeds[1] = bound(positionSizeSeeds[1], 10 ** 15, 10 ** 22);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSizes.push(
            uint128(
                getContractsForAmountAtTick(
                    currentTick,
                    tickLower,
                    tickUpper,
                    isWETH,
                    positionSizeSeeds[0]
                )
            )
        );

        positionSizes.push(
            uint128(
                getContractsForAmountAtTick(
                    currentTick,
                    tickLower,
                    tickUpper,
                    isWETH,
                    positionSizeSeeds[1]
                )
            )
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, positionSizes[0])
                : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, positionSizes[0])
        );

        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, positionSizes[1])
                : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, positionSizes[1])
        );
    }

    function populatePositionData(
        int24[2] memory width,
        int24[2] memory strike,
        uint256 positionSizeSeed
    ) internal {
        tickLowers.push(int24(strike[0] - (width[0] * tickSpacing) / 2));
        tickUppers.push(int24(strike[0] + (width[0] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[0]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[0]));

        tickLowers.push(int24(strike[1] - (width[1] * tickSpacing) / 2));
        tickUppers.push(int24(strike[1] + (width[1] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[1]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[1]));

        // 0.0001 -> 10_000 WETH
        positionSizeSeed = bound(positionSizeSeed, 10 ** 15, 10 ** 22);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSize = uint128(
            getContractsForAmountAtTick(
                currentTick,
                tickLowers[0],
                tickUppers[0],
                isWETH,
                positionSizeSeed
            )
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtLowers[0],
                    sqrtUppers[0],
                    positionSize
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtLowers[0],
                    sqrtUppers[0],
                    positionSize
                )
        );

        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSize
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSize
                )
        );

        $amount0Moveds.push(
            sqrtUppers[0] < currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    sqrtLowers[0] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[0],
                    sqrtUppers[0],
                    int128(expectedLiqs[0])
                )
        );

        $amount0Moveds.push(
            sqrtUppers[1] < currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    sqrtLowers[1] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[1],
                    sqrtUppers[1],
                    int128(expectedLiqs[1])
                )
        );

        $amount1Moveds.push(
            sqrtLowers[0] > currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount1Delta(
                    sqrtLowers[0],
                    sqrtUppers[0] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[0],
                    int128(expectedLiqs[0])
                )
        );

        $amount1Moveds.push(
            sqrtLowers[1] > currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount1Delta(
                    sqrtLowers[1],
                    sqrtUppers[1] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[1],
                    int128(expectedLiqs[1])
                )
        );

        // ensure second leg is sufficiently large
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96,
            sqrtLowers[1],
            sqrtUppers[1],
            expectedLiqs[1]
        );
        uint256 priceX128 = FullMath.mulDiv(currentSqrtPriceX96, currentSqrtPriceX96, 2 ** 64);
        // total ETH value must be >= 10 ** 15
        uint256 ETHValue = isWETH == 0
            ? amount0 + FullMath.mulDiv(amount1, 2 ** 128, priceX128)
            : Math.mulDiv128(amount0, priceX128) + amount1;
        vm.assume(ETHValue >= 10 ** 15);
        vm.assume(ETHValue <= 10 ** 22);
    }

    // second positionSizeSeed is to back single long leg
    function populatePositionDataLong(
        int24[2] memory width,
        int24[2] memory strike,
        uint256[2] memory positionSizeSeed
    ) internal {
        tickLowers.push(int24(strike[0] - (width[0] * tickSpacing) / 2));
        tickUppers.push(int24(strike[0] + (width[0] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[0]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[0]));

        tickLowers.push(int24(strike[1] - (width[1] * tickSpacing) / 2));
        tickUppers.push(int24(strike[1] + (width[1] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[1]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[1]));

        // 0.0001 -> 10_000 WETH
        positionSizeSeed[0] = bound(positionSizeSeed[0], 2 * 10 ** 16, 10 ** 22);
        // since this is for a long leg it has to be smaller than the short liquidity it's trying to buy
        positionSizeSeed[1] = bound(positionSizeSeed[1], 10 ** 15, positionSizeSeed[0] / 20);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSizes.push(
            uint128(
                getContractsForAmountAtTick(
                    currentTick,
                    tickLowers[1],
                    tickUppers[1],
                    isWETH,
                    positionSizeSeed[0]
                )
            )
        );

        positionSizes.push(
            uint128(
                getContractsForAmountAtTick(
                    currentTick,
                    tickLowers[1],
                    tickUppers[1],
                    isWETH,
                    positionSizeSeed[1]
                )
            )
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSizes[0]
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSizes[0]
                )
        );

        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtLowers[0],
                    sqrtUppers[0],
                    positionSizes[1]
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtLowers[0],
                    sqrtUppers[0],
                    positionSizes[1]
                )
        );

        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSizes[1]
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSizes[1]
                )
        );

        $amount0Moveds.push(
            sqrtUppers[1] < currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    sqrtLowers[1] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[1],
                    sqrtUppers[1],
                    int128(expectedLiqs[0])
                )
        );

        $amount0Moveds.push(
            sqrtUppers[0] < currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    sqrtLowers[0] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[0],
                    sqrtUppers[0],
                    int128(expectedLiqs[1])
                )
        );

        $amount0Moveds.push(
            sqrtUppers[1] < currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    sqrtLowers[1] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[1],
                    sqrtUppers[1],
                    -int128(expectedLiqs[2])
                )
        );

        $amount1Moveds.push(
            sqrtLowers[1] > currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount1Delta(
                    sqrtLowers[1],
                    sqrtUppers[1] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[1],
                    int128(expectedLiqs[0])
                )
        );

        $amount1Moveds.push(
            sqrtLowers[0] > currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount1Delta(
                    sqrtLowers[0],
                    sqrtUppers[0] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[0],
                    int128(expectedLiqs[1])
                )
        );

        $amount1Moveds.push(
            sqrtLowers[1] > currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount1Delta(
                    sqrtLowers[1],
                    sqrtUppers[1] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[1],
                    -int128(expectedLiqs[2])
                )
        );

        // ensure second leg is sufficiently large
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96,
            sqrtLowers[0],
            sqrtUppers[0],
            expectedLiqs[1]
        );
        uint256 priceX128 = FullMath.mulDiv(currentSqrtPriceX96, currentSqrtPriceX96, 2 ** 64);
        // total ETH value must be >= 10 ** 15
        uint256 ETHValue = isWETH == 0
            ? amount0 + FullMath.mulDiv(amount1, 2 ** 128, priceX128)
            : Math.mulDiv128(amount0, priceX128) + amount1;
        vm.assume(ETHValue >= 10 ** 15);
        vm.assume(ETHValue <= 10 ** 22);
    }

    function updatePositionDataLong() public {
        $amount0Moveds[1] = sqrtUppers[0] < currentSqrtPriceX96
            ? int256(0)
            : SqrtPriceMath.getAmount0Delta(
                sqrtLowers[0] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[0],
                sqrtUppers[0],
                int128(expectedLiqs[1])
            );

        $amount0Moveds[2] = sqrtUppers[1] < currentSqrtPriceX96
            ? int256(0)
            : SqrtPriceMath.getAmount0Delta(
                sqrtLowers[1] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[1],
                sqrtUppers[1],
                -int128(expectedLiqs[2])
            );

        $amount1Moveds[1] = sqrtLowers[0] > currentSqrtPriceX96
            ? int256(0)
            : SqrtPriceMath.getAmount1Delta(
                sqrtLowers[0],
                sqrtUppers[0] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[0],
                int128(expectedLiqs[1])
            );

        $amount1Moveds[2] = sqrtLowers[1] > currentSqrtPriceX96
            ? int256(0)
            : SqrtPriceMath.getAmount1Delta(
                sqrtLowers[1],
                sqrtUppers[1] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[1],
                -int128(expectedLiqs[2])
            );
    }

    function updatePositionDataVariable(uint256 numLegs, uint256[4] memory isLongs) public {
        for (uint256 i = 0; i < numLegs; i++) {
            $amount0Moveds[i] = sqrtUppers[i] < currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    sqrtLowers[i] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[i],
                    sqrtUppers[i],
                    (isLongs[i] == 1 ? int8(1) : -1) * int128(expectedLiqs[i])
                );

            $amount1Moveds[i] = sqrtLowers[i] > currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount1Delta(
                    sqrtLowers[i],
                    sqrtUppers[i] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[i],
                    (isLongs[i] == 1 ? int128(1) : -1) * int128(expectedLiqs[i])
                );
            $amount0MovedBurn += $amount0Moveds[i];
            $amount1MovedBurn += $amount1Moveds[i];
        }
    }

    function updateITMAmountsBurn(uint256 numLegs, uint256[4] memory tokenTypes) public {
        for (uint256 i = 0; i < numLegs; i++) {
            if (tokenTypes[i] == 1) {
                $itm0 += $amount0Moveds[i];
            } else {
                $itm1 += $amount1Moveds[i];
            }
        }
    }

    function updateSwappedAmountsBurn(uint256 numLegs, uint256[4] memory isLongs) public {
        int128[] memory liquidityDeltas = new int128[](numLegs);
        for (uint256 i = 0; i < numLegs; i++) {
            liquidityDeltas[i] =
                int128(numLegs == 1 ? expectedLiq : expectedLiqs[i]) *
                (isLongs[i] == 1 ? int8(1) : -1);
        }
        bool zeroForOne; // The direction of the swap, true for token0 to token1, false for token1 to token0
        int256 swapAmount; // The amount of token0 or token1 to swap

        if (($itm0 != 0) && ($itm1 != 0)) {
            int256 net0 = $itm0 - PanopticMath.convert1to0($itm1, currentSqrtPriceX96);

            // if net0 is negative, then the protocol has a net shortage of token0
            zeroForOne = net0 < 0;

            //compute the swap amount, set as positive (exact input)
            swapAmount = -net0;
        } else if ($itm0 != 0) {
            zeroForOne = $itm0 < 0;
            swapAmount = -$itm0;
        } else {
            zeroForOne = $itm1 > 0;
            swapAmount = -$itm1;
        }

        if (numLegs == 1) {
            tickLowers.push(tickLower);
            tickUppers.push(tickUpper);
        }

        if (swapAmount != 0) {
            changePrank(address(sfpm));
            ($swap0, $swap1) = PositionUtils.simulateSwapSingleBurn(
                pool,
                tickLowers,
                tickUppers,
                liquidityDeltas,
                router,
                token0,
                token1,
                fee,
                zeroForOne,
                swapAmount
            );
            changePrank(Alice);
        }
    }

    function updateIntrinsicValueBurn(int256 longAmounts, int256 shortAmounts) public {
        $intrinsicValue0 =
            ($swap0 + $amount0MovedBurn) -
            longAmounts.rightSlot() +
            shortAmounts.rightSlot();
        $intrinsicValue1 =
            ($swap1 + $amount1MovedBurn) -
            longAmounts.leftSlot() +
            shortAmounts.leftSlot();
    }

    function populatePositionData(
        int24[3] memory width,
        int24[3] memory strike,
        uint256 positionSizeSeed
    ) internal {
        tickLowers.push(int24(strike[0] - (width[0] * tickSpacing) / 2));
        tickUppers.push(int24(strike[0] + (width[0] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[0]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[0]));

        tickLowers.push(int24(strike[1] - (width[1] * tickSpacing) / 2));
        tickUppers.push(int24(strike[1] + (width[1] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[1]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[1]));

        tickLowers.push(int24(strike[2] - (width[2] * tickSpacing) / 2));
        tickUppers.push(int24(strike[2] + (width[2] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[2]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[2]));

        // 0.0001 -> 10_000 WETH
        positionSizeSeed = bound(positionSizeSeed, 10 ** 15, 10 ** 22);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSize = uint128(
            getContractsForAmountAtTick(
                currentTick,
                tickLowers[0],
                tickUppers[0],
                isWETH,
                positionSizeSeed
            )
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        for (uint256 i = 0; i < 3; i++) {
            expectedLiqs.push(
                isWETH == 0
                    ? LiquidityAmounts.getLiquidityForAmount0(
                        sqrtLowers[i],
                        sqrtUppers[i],
                        positionSize
                    )
                    : LiquidityAmounts.getLiquidityForAmount1(
                        sqrtLowers[i],
                        sqrtUppers[i],
                        positionSize
                    )
            );

            $amount0Moveds.push(
                sqrtUppers[i] < currentSqrtPriceX96
                    ? int256(0)
                    : SqrtPriceMath.getAmount0Delta(
                        sqrtLowers[i] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[i],
                        sqrtUppers[i],
                        int128(expectedLiqs[i])
                    )
            );

            $amount1Moveds.push(
                sqrtLowers[i] > currentSqrtPriceX96
                    ? int256(0)
                    : SqrtPriceMath.getAmount1Delta(
                        sqrtLowers[i],
                        sqrtUppers[i] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[i],
                        int128(expectedLiqs[i])
                    )
            );
        }

        // ensure second leg is sufficiently large
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96,
            sqrtLowers[1],
            sqrtUppers[1],
            expectedLiqs[1]
        );

        uint256 priceX128 = FullMath.mulDiv(currentSqrtPriceX96, currentSqrtPriceX96, 2 ** 64);
        // total ETH value must be >= 10 ** 15
        uint256 ETHValue = isWETH == 0
            ? amount0 + FullMath.mulDiv(amount1, 2 ** 128, priceX128)
            : Math.mulDiv128(amount0, priceX128) + amount1;
        vm.assume(ETHValue >= 10 ** 15);
        vm.assume(ETHValue <= 10 ** 22);

        // ensure third leg is sufficiently large
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96,
            sqrtLowers[2],
            sqrtUppers[2],
            expectedLiqs[2]
        );

        // ETHValue = isWETH == 0 ? amount0  + FullMath.mulDiv(amount1, 2**128, priceX128) : Math.mulDiv128(amount0, priceX128) + amount1;
        // the fuzzer doesn't seem to be able to handle the third condition here
        // maybe it increases the difficulty too much? it will rarely and sporadically fail with this disabled
        vm.assume(ETHValue >= 10 ** 15);
    }

    function populatePositionData(
        int24[4] memory width,
        int24[4] memory strike,
        uint256 positionSizeSeed
    ) internal {
        tickLowers.push(int24(strike[0] - (width[0] * tickSpacing) / 2));
        tickUppers.push(int24(strike[0] + (width[0] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[0]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[0]));

        tickLowers.push(int24(strike[1] - (width[1] * tickSpacing) / 2));
        tickUppers.push(int24(strike[1] + (width[1] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[1]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[1]));

        tickLowers.push(int24(strike[2] - (width[2] * tickSpacing) / 2));
        tickUppers.push(int24(strike[2] + (width[2] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[2]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[2]));

        tickLowers.push(int24(strike[3] - (width[3] * tickSpacing) / 2));
        tickUppers.push(int24(strike[3] + (width[3] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[3]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[3]));

        // 0.0001 -> 10_000 WETH
        positionSizeSeed = bound(positionSizeSeed, 10 ** 15, 10 ** 22);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSize = uint128(
            getContractsForAmountAtTick(
                currentTick,
                tickLowers[0],
                tickUppers[0],
                isWETH,
                positionSizeSeed
            )
        );
        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        for (uint256 i = 0; i < 4; i++) {
            expectedLiqs.push(
                isWETH == 0
                    ? LiquidityAmounts.getLiquidityForAmount0(
                        sqrtLowers[i],
                        sqrtUppers[i],
                        positionSize
                    )
                    : LiquidityAmounts.getLiquidityForAmount1(
                        sqrtLowers[i],
                        sqrtUppers[i],
                        positionSize
                    )
            );

            $amount0Moveds.push(
                sqrtUppers[i] < currentSqrtPriceX96
                    ? int256(0)
                    : SqrtPriceMath.getAmount0Delta(
                        sqrtLowers[i] < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLowers[i],
                        sqrtUppers[i],
                        int128(expectedLiqs[i])
                    )
            );

            $amount1Moveds.push(
                sqrtLowers[i] > currentSqrtPriceX96
                    ? int256(0)
                    : SqrtPriceMath.getAmount1Delta(
                        sqrtLowers[i],
                        sqrtUppers[i] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[i],
                        int128(expectedLiqs[i])
                    )
            );
        }

        // ensure second leg is sufficiently large
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96,
            sqrtLowers[1],
            sqrtUppers[1],
            expectedLiqs[1]
        );

        uint256 priceX128 = FullMath.mulDiv(currentSqrtPriceX96, currentSqrtPriceX96, 2 ** 64);
        // total ETH value must be >= 10 ** 15
        uint256 ETHValue = isWETH == 0
            ? amount0 + FullMath.mulDiv(amount1, 2 ** 128, priceX128)
            : Math.mulDiv128(amount0, priceX128) + amount1;
        vm.assume(ETHValue >= 10 ** 15);
        vm.assume(ETHValue <= 10 ** 22);

        // ensure third leg is sufficiently large
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96,
            sqrtLowers[2],
            sqrtUppers[2],
            expectedLiqs[2]
        );

        vm.assume(ETHValue >= 10 ** 15);
        vm.assume(ETHValue <= 10 ** 22);

        // ensure fourth leg is sufficiently large
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96,
            sqrtLowers[3],
            sqrtUppers[3],
            expectedLiqs[3]
        );

        vm.assume(ETHValue >= 10 ** 15);
        vm.assume(ETHValue <= 10 ** 22);
    }

    function populatePositionData(
        int24[2] memory width,
        int24[2] memory strike,
        uint256[2] memory positionSizeSeeds
    ) internal {
        tickLowers.push(int24(strike[0] - (width[0] * tickSpacing) / 2));
        tickUppers.push(int24(strike[0] + (width[0] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[0]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[0]));

        tickLowers.push(int24(strike[1] - (width[1] * tickSpacing) / 2));
        tickUppers.push(int24(strike[1] + (width[1] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[1]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[1]));

        // 0.0001 -> 10_000 WETH
        positionSizeSeeds[0] = bound(positionSizeSeeds[0], 10 ** 15, 10 ** 22);
        positionSizeSeeds[1] = bound(positionSizeSeeds[1], 10 ** 15, 10 ** 22);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSizes.push(
            uint128(
                getContractsForAmountAtTick(
                    currentTick,
                    tickLowers[0],
                    tickUppers[0],
                    isWETH,
                    positionSizeSeeds[0]
                )
            )
        );

        positionSizes.push(
            uint128(
                getContractsForAmountAtTick(
                    currentTick,
                    tickLowers[1],
                    tickUppers[1],
                    isWETH,
                    positionSizeSeeds[1]
                )
            )
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtLowers[0],
                    sqrtUppers[0],
                    positionSizes[0]
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtLowers[0],
                    sqrtUppers[0],
                    positionSizes[0]
                )
        );

        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSizes[1]
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSizes[1]
                )
        );
    }

    function populatePositionData(
        int24 width,
        int24 strike,
        uint256 positionSizeSeed,
        uint256 positionSizeBurnSeed
    ) internal {
        tickLower = int24(strike - (width * tickSpacing) / 2);
        tickUpper = int24(strike + (width * tickSpacing) / 2);
        sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

        // 0.0001 -> 10_000 WETH
        positionSizeSeed = bound(positionSizeSeed, 10 ** 15, 10 ** 22);
        positionSizeBurnSeed = bound(positionSizeBurnSeed, 10 ** 14, positionSizeSeed);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSize = uint128(
            getContractsForAmountAtTick(currentTick, tickLower, tickUpper, isWETH, positionSizeSeed)
        );

        positionSizeBurn = uint128(
            getContractsForAmountAtTick(
                currentTick,
                tickLower,
                tickUpper,
                isWETH,
                positionSizeBurnSeed
            )
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        expectedLiq = isWETH == 0
            ? LiquidityAmounts.getLiquidityForAmount0(
                sqrtLower,
                sqrtUpper,
                positionSize - positionSizeBurn
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                sqrtLower,
                sqrtUpper,
                positionSize - positionSizeBurn
            );

        expectedLiqMint = isWETH == 0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, positionSize)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, positionSize);

        expectedLiqBurn = isWETH == 0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, positionSizeBurn)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, positionSizeBurn);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    // used to accumulate premia for testing
    function twoWaySwap(uint256 swapSize) public {
        changePrank(Swapper);

        swapSize = bound(swapSize, 10 ** 18, 10 ** 22);
        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams(
                isWETH == 0 ? token0 : token1,
                isWETH == 1 ? token0 : token1,
                fee,
                Bob,
                block.timestamp,
                swapSize,
                0,
                0
            )
        );

        router.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams(
                isWETH == 1 ? token0 : token1,
                isWETH == 0 ? token0 : token1,
                fee,
                Bob,
                block.timestamp,
                (swapSize * (1_000_000 - fee)) / 1_000_000,
                type(uint256).max,
                0
            )
        );

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
    }

    /*//////////////////////////////////////////////////////////////
                         POOL INITIALIZATION: -
    //////////////////////////////////////////////////////////////*/

    function test_Fail_startPool_PoolAlreadyInitialized(uint256 x) public {
        _initWorld(x);

        vm.expectRevert(Errors.PoolAlreadyInitialized.selector);

        pp.startPool(pool, tickSpacing, currentTick, token0, token1, ct0, ct1);
    }

    /*//////////////////////////////////////////////////////////////
                           SYSTEM PARAMETERS
    //////////////////////////////////////////////////////////////*/

    function test_Success_parameters_initialState(uint256 x) public {
        _initWorld(x);

        changePrank(Deployer);
        // the parameters aren't exposed, so we have to read directly from storage
        // all parameters start nonzero, so the easiest way is just to set them all to zero
        // and ensure that change was applied
        assertEq(
            vm.load(address(ct0), bytes32(uint256(9))),
            bytes32(
                uint256(
                    uint256(uint24(tickSpacing)) +
                        (uint256(fee / 100) << 24) +
                        (2230 << 48) +
                        (10 << 72)
                )
            )
        ); // tickSpacing + poolFee + tickDeviation + commission fee
        assertEq(
            vm.load(address(ct1), bytes32(uint256(9))),
            bytes32(
                uint256(
                    uint256(uint24(tickSpacing)) +
                        (uint256(fee / 100) << 24) +
                        (2230 << 48) +
                        (10 << 72)
                )
            )
        );
        assertEq(
            vm.load(address(ct0), bytes32(uint256(10))),
            bytes32(uint256((((2 * fee) / 100) + (2_000 << 128))))
        ); // itm spread fee + sellCollateralRatio
        assertEq(
            vm.load(address(ct1), bytes32(uint256(10))),
            bytes32(uint256((((2 * fee) / 100) + (2_000 << 128))))
        );
        assertEq(
            vm.load(address(ct0), bytes32(uint256(11))),
            bytes32(uint256(1_000 + (uint256(int256(-1_024)) << 128)))
        ); // buyCollateralRatio + exerciseCost
        assertEq(
            vm.load(address(ct1), bytes32(uint256(11))),
            bytes32(uint256(1_000 + (uint256(int256(-1_024)) << 128)))
        );
        assertEq(vm.load(address(ct0), bytes32(uint256(12))), bytes32(uint256(13_333))); // maintenance margin
        assertEq(vm.load(address(ct1), bytes32(uint256(12))), bytes32(uint256(13_333)));
        assertEq(
            vm.load(address(ct0), bytes32(uint256(13))),
            bytes32(uint256(5000 + (uint256(9000) << 128)))
        ); // target pool utilization + saturated utilization
        assertEq(
            vm.load(address(ct1), bytes32(uint256(13))),
            bytes32(uint256(5000 + (uint256(9000) << 128)))
        );
    }

    function test_Success_updateParameters(
        uint256 x,
        uint256 maintenanceMarginRatio,
        int256 sellCollateralRatio,
        int128[7] memory parameters
    ) public {
        _initWorld(x);

        changePrank(Deployer);

        sellCollateralRatio = bound(sellCollateralRatio, 10, 10_000);

        ct0.updateParameters(
            CollateralTracker.Parameters(
                maintenanceMarginRatio,
                parameters[0],
                parameters[1],
                int128(sellCollateralRatio),
                parameters[3],
                parameters[4],
                parameters[5],
                parameters[6]
            )
        );
        ct1.updateParameters(
            CollateralTracker.Parameters(
                maintenanceMarginRatio,
                parameters[0],
                parameters[1],
                int128(sellCollateralRatio),
                parameters[3],
                parameters[4],
                parameters[5],
                parameters[6]
            )
        );

        // the parameters aren't exposed, so we have to read directly from storage
        // all parameters start nonzero, so the easiest way is just to set them all to zero
        // and ensure that change was applied
        assertEq(
            vm.load(address(ct0), bytes32(uint256(9))),
            bytes32(
                uint256(
                    uint256(uint24(tickSpacing)) +
                        (uint256(fee / 100) << 24) +
                        (uint256(
                            uint128(
                                int128(2230) +
                                    (int128(12500) * (int128(sellCollateralRatio) - 2000)) /
                                    10_000 +
                                    (int128(7812) * (int128(sellCollateralRatio) - 2000) ** 2) /
                                    10_000 ** 2 +
                                    (int128(6510) * (int128(sellCollateralRatio) - 2000) ** 3) /
                                    10_000 ** 3
                            )
                        ) << 48) +
                        (uint256(uint128(parameters[0])) << 72)
                )
            )
        ); // tickSpacing + poolFee + tickDeviation + commission fee
        assertEq(
            vm.load(address(ct1), bytes32(uint256(9))),
            bytes32(
                uint256(
                    uint256(uint24(tickSpacing)) +
                        (uint256(fee / 100) << 24) +
                        (uint256(
                            uint128(
                                int128(2230) +
                                    (int128(12500) * (int128(sellCollateralRatio) - 2000)) /
                                    10_000 +
                                    (int128(7812) * (int128(sellCollateralRatio) - 2000) ** 2) /
                                    10_000 ** 2 +
                                    (int128(6510) * (int128(sellCollateralRatio) - 2000) ** 3) /
                                    10_000 ** 3
                            )
                        ) << 48) +
                        (uint256(uint128(parameters[0])) << 72)
                )
            )
        );
        assertEq(
            vm.load(address(ct0), bytes32(uint256(10))),
            bytes32(
                uint128(uint256(((int256(parameters[1]) * int24(fee)) / 100) / 10_000)) +
                    (uint256(int256(sellCollateralRatio)) << 128)
            )
        ); // itm spread fee + sellCollateralRatio
        assertEq(
            vm.load(address(ct1), bytes32(uint256(10))),
            bytes32(
                uint128(uint256(((int256(parameters[1]) * int24(fee)) / 100) / 10_000)) +
                    (uint256(int256(sellCollateralRatio)) << 128)
            )
        );
        assertEq(
            vm.load(address(ct0), bytes32(uint256(11))),
            bytes32(uint256(uint128(parameters[3]) + (uint256(int256(parameters[6])) << 128)))
        ); // buyCollateralRatio + exerciseCost
        assertEq(
            vm.load(address(ct1), bytes32(uint256(11))),
            bytes32(uint256(uint128(parameters[3]) + (uint256(int256(parameters[6])) << 128)))
        );
        assertEq(
            vm.load(address(ct0), bytes32(uint256(12))),
            bytes32(uint256(maintenanceMarginRatio))
        ); // maintenance margin
        assertEq(
            vm.load(address(ct1), bytes32(uint256(12))),
            bytes32(uint256(maintenanceMarginRatio))
        );
        assertEq(
            vm.load(address(ct0), bytes32(uint256(13))),
            bytes32(uint256(uint128(parameters[4]) + (uint256(int256(parameters[5])) << 128)))
        ); // target pool utilization + saturated utilization
        assertEq(
            vm.load(address(ct1), bytes32(uint256(13))),
            bytes32(uint256(uint128(parameters[4]) + (uint256(int256(parameters[5])) << 128)))
        );
    }

    function test_Fail_updateParameters_NotOwner(uint256 x) public {
        _initWorld(x);

        vm.expectRevert(Errors.NotOwner.selector);

        ct0.updateParameters(CollateralTracker.Parameters(0, 0, 0, 0, 0, 0, 0, 0));
    }

    /*//////////////////////////////////////////////////////////////
                             STATIC QUERIES
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.fuzz.runs = 10
    function test_Success_calculateAccumulatedFeesBatch_2xOTMShortCall(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256[2] memory positionSizeSeeds,
        uint256 swapSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            0
        );

        (int24 width2, int24 strike2) = PositionUtils.getOTMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );
        vm.assume(width2 != width || strike2 != strike);

        populatePositionData([width, width2], [strike, strike2], positionSizeSeeds);

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        // leg 2
        uint256 tokenId2 = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike2,
            width2
        );

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSizes[0], 0, 0, 0);
        }

        int256 poolUtilizationsAtMint;
        {
            (, , int128 currentPoolUtilization) = ct0.getPoolData();
            poolUtilizationsAtMint = int256(0).toRightSlot(currentPoolUtilization);
        }

        {
            (, , int128 currentPoolUtilization) = ct1.getPoolData();
            poolUtilizationsAtMint = int256(0).toLeftSlot(currentPoolUtilization);
        }

        {
            uint256[] memory posIdList = new uint256[](2);
            posIdList[0] = tokenId;
            posIdList[1] = tokenId2;

            pp.mintOptions(posIdList, positionSizes[1], 0, 0, 0);

            changePrank(Bob);

            twoWaySwap(swapSizeSeed);
        }

        uint256[2] memory expectedPremia;
        {
            (uint256 premiumToken0, uint256 premiumToken1) = sfpm.getAccountPremium(
                address(pool),
                address(pp),
                0,
                tickLowers[0],
                tickUppers[0],
                currentTick,
                0
            );

            expectedPremia[0] += (premiumToken0 * expectedLiqs[0]) / 2 ** 64;

            expectedPremia[1] += (premiumToken1 * expectedLiqs[0]) / 2 ** 64;
        }

        {
            (uint256 premiumToken0, uint256 premiumToken1) = sfpm.getAccountPremium(
                address(pool),
                address(pp),
                0,
                tickLowers[1],
                tickUppers[1],
                currentTick,
                0
            );

            expectedPremia[0] += (premiumToken0 * expectedLiqs[1]) / 2 ** 64;

            expectedPremia[1] += (premiumToken1 * expectedLiqs[1]) / 2 ** 64;
        }

        {
            uint256[] memory posIdList = new uint256[](2);
            posIdList[0] = tokenId;
            posIdList[1] = tokenId2;

            (int128 premium0, int128 premium1, uint256[2][] memory posBalanceArray) = pp
                .calculateAccumulatedFeesBatch(Alice, posIdList);
            assertEq(uint128(premium0), expectedPremia[0]);
            assertEq(uint128(premium1), expectedPremia[1]);
            assertEq(posBalanceArray[0][0], tokenId);
            assertEq(posBalanceArray[0][1].rightSlot(), positionSizes[0]);
            assertEq(posBalanceArray[0][1].leftSlot(), 0);
            assertEq(posBalanceArray[1][0], tokenId2);
            assertEq(posBalanceArray[1][1].rightSlot(), positionSizes[1]);
            assertEq(
                posBalanceArray[1][1].leftSlot(),
                uint128(poolUtilizationsAtMint.rightSlot()) +
                    (uint128(poolUtilizationsAtMint.leftSlot()) << 64)
            );
        }
    }

    function test_Success_calculateAccumulatedFeesBatch_VeryLargePremia(
        uint256 x,
        uint256 positionSizeSeed,
        uint256[2] memory premiaSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getMinWidthInRangeSW(
            uint24(tickSpacing),
            currentTick
        );

        populatePositionDataLarge(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        pp.mintOptions(posIdList, positionSize, 0, 0, 0);

        premiaSeed[0] = bound(premiaSeed[0], 2 ** 64, 2 ** 120);
        premiaSeed[1] = bound(premiaSeed[1], 2 ** 64, 2 ** 120);

        accruePoolFeesInRange(address(pool), expectedLiq, premiaSeed[0], premiaSeed[1]);

        changePrank(address(sfpm));
        pool.burn(tickLower, tickUpper, 0);

        (int256 premium0, int256 premium1, ) = pp.calculateAccumulatedFeesBatch(Alice, posIdList);
        assertApproxEqAbs(uint256(premium0), premiaSeed[0], premiaSeed[0] / 1_000_000);
        assertApproxEqAbs(uint256(premium1), premiaSeed[1], premiaSeed[1] / 1_000_000);
    }

    function test_Success_calculatePortfolioValue_2xOTMShortCall(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256[2] memory positionSizeSeeds,
        uint256 swapSize
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            0
        );

        (int24 width2, int24 strike2) = PositionUtils.getOTMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );
        vm.assume(width2 != width || strike2 != strike);

        populatePositionData([width, width2], [strike, strike2], positionSizeSeeds);

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        // leg 2
        uint256 tokenId2 = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike2,
            width2
        );

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSizes[0], 0, 0, 0);
        }

        {
            uint256[] memory posIdList = new uint256[](2);
            posIdList[0] = tokenId;
            posIdList[1] = tokenId2;

            pp.mintOptions(posIdList, positionSizes[1], 0, 0, 0);

            userBalance[tokenId] = positionSizes[0];
            userBalance[tokenId2] = positionSizes[1];

            (int256 value0, int256 value1) = FeesCalc.getPortfolioValue(
                pool,
                currentTick,
                userBalance,
                posIdList
            );

            (int256 calcValue0, int256 calcValue1) = pp.calculatePortfolioValue(
                Alice,
                currentTick,
                posIdList
            );

            assertEq(uint256(value0), uint256(calcValue0));
            assertEq(uint256(value1), uint256(calcValue1));
        }
    }

    /*//////////////////////////////////////////////////////////////
                     SLIPPAGE/EFFECTIVE LIQ LIMITS
    //////////////////////////////////////////////////////////////*/

    function test_Success_mintOptions_OTMShortCall_NoLiquidityLimit(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        changePrank(Bob);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        // mint option from another account to change the effective liquidity
        pp.mintOptions(posIdList, positionSize * 2, 0, 0, 0);

        changePrank(Alice);

        tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, isWETH, 1, 0, 0, strike, width);
        posIdList[0] = tokenId;

        // type(uint64).max = no limit, ensure the operation works given the changed liquidity limit
        pp.mintOptions(posIdList, positionSize, type(uint64).max, 0, 0);

        assertEq(sfpm.balanceOf(address(pp), tokenId), positionSize);

        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtLower,
            sqrtUpper,
            expectedLiq
        );

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertApproxEqAbs(inAMM, amount0, 10);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertEq(inAMM, 0);
        }

        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(tokenId))))
            );
            assertEq(pp.numberOfPositions(Alice), 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, positionSize);

            (, uint256 inAMM0, ) = ct0.getPoolData();

            assertEq(poolUtilization0, (inAMM0 * 10000) / ct0.totalSupply());
            assertEq(poolUtilization1, 0);
        }

        {
            (int256 longAmounts, ) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                uint128(positionSize),
                tickSpacing
            );

            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                uint256(type(uint104).max) - uint128((longAmounts.rightSlot() * 10) / 10000),
                10
            );

            assertEq(ct1.balanceOf(Alice), uint256(type(uint104).max));
        }
    }

    function test_Success_mintOptions_OTMShortCall_LiquidityLimit(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        changePrank(Bob);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;
        // mint option from another account to change the effective liquidity
        pp.mintOptions(posIdList, positionSize * 2, 0, 0, 0);

        changePrank(Alice);

        tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, isWETH, 1, 0, 0, strike, width);
        posIdList[0] = tokenId;

        // type(uint64).max = no limit, ensure the operation works given the changed liquidity limit
        pp.mintOptions(posIdList, positionSize, type(uint64).max - 1, 0, 0);

        assertEq(sfpm.balanceOf(address(pp), tokenId), positionSize);

        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtLower,
            sqrtUpper,
            expectedLiq
        );

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertApproxEqAbs(inAMM, amount0, 10);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertEq(inAMM, 0);
        }

        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(tokenId))))
            );

            assertEq(pp.numberOfPositions(Alice), 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, positionSize);

            (, uint256 inAMM0, ) = ct0.getPoolData();

            assertEq(poolUtilization0, (inAMM0 * 10000) / ct0.totalSupply());

            assertEq(poolUtilization1, 0);
        }

        {
            (int256 longAmounts, ) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );

            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                uint256(type(uint104).max) - uint128((longAmounts.rightSlot() * 10) / 10000),
                10
            );
            assertEq(ct1.balanceOf(Alice), uint256(type(uint104).max));
        }
    }

    function test_Fail_mintOptions_OTMShortCall_EffectiveLiquidityAboveThreshold(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        changePrank(Bob);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        pp.mintOptions(posIdList, positionSize * 2, 0, 0, 0);

        changePrank(Alice);

        tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, isWETH, 1, 0, 0, strike, width);
        posIdList[0] = tokenId;

        vm.expectRevert(Errors.EffectiveLiquidityAboveThreshold.selector);
        pp.mintOptions(posIdList, positionSize, 0, 0, 0);
    }

    function test_Success_mintOptions_OTMShortCall_SlippageSet(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        pp.mintOptions(posIdList, positionSize, 0, TickMath.MIN_TICK, TickMath.MAX_TICK);

        assertEq(sfpm.balanceOf(address(pp), tokenId), positionSize);

        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtLower,
            sqrtUpper,
            expectedLiq
        );

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertApproxEqAbs(inAMM, amount0, 10);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertEq(inAMM, 0);
        }
        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(tokenId))))
            );

            assertEq(pp.numberOfPositions(Alice), 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, positionSize);
            assertEq(poolUtilization0, (amount0 * 10000) / ct0.totalSupply());
            assertEq(poolUtilization1, 0);
        }

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                uint128(positionSize),
                tickSpacing
            );

            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                uint256(type(uint104).max) - uint128((shortAmounts.rightSlot() * 10) / 10000),
                uint256(int256(shortAmounts.rightSlot()) / 1_000_000 + 10)
            );

            assertEq(ct1.balanceOf(Alice), uint256(type(uint104).max));
        }
    }

    /*//////////////////////////////////////////////////////////////
                             OPTION MINTING
    //////////////////////////////////////////////////////////////*/

    function test_Success_mintOptions_OTMShortCall(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        pp.mintOptions(posIdList, positionSize, 0, 0, 0);

        assertEq(sfpm.balanceOf(address(pp), tokenId), positionSize);

        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            expectedLiq
        );

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertApproxEqAbs(inAMM, amount0, 10);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertEq(inAMM, 0);
        }
        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(tokenId))))
            );

            assertEq(pp.numberOfPositions(Alice), 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, positionSize);
            assertEq(poolUtilization0, (amount0 * 10000) / ct0.totalSupply());
            assertEq(poolUtilization1, 0);
        }

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                uint128(positionSize),
                tickSpacing
            );

            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                uint256(type(uint104).max) - uint128((shortAmounts.rightSlot() * 10) / 10000),
                uint256(int256(shortAmounts.rightSlot()) / 1_000_000 + 10)
            );

            assertEq(ct1.balanceOf(Alice), uint256(type(uint104).max));
        }
    }

    function test_Success_mintOptions_OTMShortPut(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            1
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            1,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        pp.mintOptions(posIdList, positionSize, 0, 0, 0);

        assertEq(sfpm.balanceOf(address(pp), tokenId), positionSize);

        uint256 amount1 = LiquidityAmounts.getAmount1ForLiquidity(
            sqrtLower,
            sqrtUpper,
            expectedLiq
        );

        {
            (, uint256 inAMM, ) = ct1.getPoolData();

            // there are some inevitable precision errors that occur when
            // converting between contract sizes and liquidity - ~.01 basis points error is acceptable
            assertApproxEqAbs(inAMM, amount1, amount1 / 1_000_000);
        }

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertEq(inAMM, 0);
        }

        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(tokenId))))
            );

            assertEq(pp.numberOfPositions(Alice), 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, positionSize);
            assertEq(poolUtilization1, (amount1 * 10000) / ct1.totalSupply());
            assertEq(poolUtilization0, 0);
        }

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );

            assertApproxEqAbs(
                ct1.balanceOf(Alice),
                uint256(type(uint104).max) - uint128((shortAmounts.leftSlot() * 10) / 10000),
                uint256(int256(shortAmounts.leftSlot()) / 1_000_000 + 10)
            );

            assertEq(ct0.balanceOf(Alice), uint256(type(uint104).max));
        }
    }

    function test_Success_mintOptions_ITMShortCall(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getITMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256 expectedSwap0;
        {
            int256 amount1Required = SqrtPriceMath.getAmount1Delta(
                sqrtLower,
                sqrtUpper > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUpper,
                int128(expectedLiq)
            );

            (expectedSwap0, ) = PositionUtils.simulateSwap(
                pool,
                tickLower,
                tickUpper,
                expectedLiq,
                router,
                token0,
                token1,
                fee,
                true,
                -amount1Required
            );

            changePrank(Alice);
        }

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            // reversing the tick limits here to make sure they get entered into the SFPM properly
            // this test will fail if it does not (because no ITM swaps will occur)
            pp.mintOptions(posIdList, positionSize, 0, TickMath.MAX_TICK, TickMath.MIN_TICK);
        }

        assertEq(sfpm.balanceOf(address(pp), tokenId), positionSize);

        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtLower,
            sqrtUpper,
            expectedLiq
        );

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertApproxEqAbs(inAMM, amount0, 10);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertEq(inAMM, 0);
        }
        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(tokenId))))
            );

            assertEq(pp.numberOfPositions(Alice), 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, positionSize);
            assertEq(poolUtilization0, (amount0 * 10000) / ct0.totalSupply());
            assertEq(poolUtilization1, 0);
        }

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );

            int256 amount0Moved = currentSqrtPriceX96 > sqrtUpper
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    currentSqrtPriceX96 < sqrtLower ? sqrtLower : currentSqrtPriceX96,
                    sqrtUpper,
                    int128(expectedLiq)
                );

            int256 notionalVal = int256(expectedSwap0) + amount0Moved - shortAmounts.rightSlot();
            int256 ITMSpread = notionalVal > 0
                ? (notionalVal * tickSpacing) / 10_000
                : -((notionalVal * tickSpacing) / 10_000);

            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                uint256(
                    int256(uint256(type(uint104).max)) -
                        notionalVal -
                        ITMSpread -
                        (shortAmounts.rightSlot() * 10) /
                        10_000
                ),
                uint256(int256(shortAmounts.rightSlot()) / 1_000_000 + 10)
            );

            assertEq(ct1.balanceOf(Alice), uint256(type(uint104).max));
        }
    }

    function test_Success_mintOptions_ITMShortPutShortCall(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width0, int24 strike0) = PositionUtils.getITMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            1
        );

        (int24 width1, int24 strike1) = PositionUtils.getITMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData([width0, width1], [strike0, strike1], positionSizeSeed);

        // put leg
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            1,
            0,
            strike0,
            width0
        );
        // call leg
        tokenId = tokenId.addLeg(1, 1, isWETH, 0, 0, 1, strike1, width1);

        int256 netSurplus0 = $amount0Moveds[0] -
            PanopticMath.convert1to0($amount1Moveds[1], currentSqrtPriceX96);

        (int256 amount0s, int256 amount1s) = PositionUtils.simulateSwap(
            pool,
            [tickLowers[0], tickLowers[1]],
            [tickUppers[0], tickUppers[1]],
            [expectedLiqs[0], expectedLiqs[1]],
            router,
            token0,
            token1,
            fee,
            netSurplus0 < 0,
            -netSurplus0
        );

        changePrank(Alice);

        (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
            tokenId,
            0,
            positionSize,
            tickSpacing
        );

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSize, 0, 0, 0);
        }
        (priceArray, medianTick) = pp.getPriceArray();
        (, currentTick, , , , , ) = pool.slot0();

        assertEq(sfpm.balanceOf(address(pp), tokenId), positionSize);

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertApproxEqAbs(inAMM, uint128(shortAmounts.rightSlot()), 10);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertApproxEqAbs(inAMM, uint128(shortAmounts.leftSlot()), 10);
        }

        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(tokenId))))
            );

            assertEq(pp.numberOfPositions(Alice), 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, positionSize);
            assertEq(
                poolUtilization0,
                Math.abs(currentTick - medianTick) > int24(2230)
                    ? 10_001
                    : (uint256($amount0Moveds[0] + $amount0Moveds[1]) * 10000) / ct0.totalSupply()
            );
            assertEq(
                poolUtilization1,
                Math.abs(currentTick - medianTick) > int24(2230)
                    ? 10_001
                    : (uint256($amount1Moveds[0] + $amount1Moveds[1]) * 10000) / ct1.totalSupply()
            );
        }

        {
            int256[2] memory notionalVals = [
                amount0s + $amount0Moveds[0] + $amount0Moveds[1] - shortAmounts.rightSlot(),
                amount1s + $amount1Moveds[0] + $amount1Moveds[1] - shortAmounts.leftSlot()
            ];
            int256[2] memory ITMSpreads = [
                notionalVals[0] > 0
                    ? (notionalVals[0] * tickSpacing) / 10_000
                    : -((notionalVals[0] * tickSpacing) / 10_000),
                notionalVals[1] > 0
                    ? (notionalVals[1] * tickSpacing) / 10_000
                    : -((notionalVals[1] * tickSpacing) / 10_000)
            ];

            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                uint256(
                    int256(uint256(type(uint104).max)) -
                        notionalVals[0] -
                        ITMSpreads[0] -
                        (shortAmounts.rightSlot() * 10) /
                        10_000
                ),
                uint256(int256(shortAmounts.rightSlot()) / 1_000_000 + 10)
            );

            assertApproxEqAbs(
                ct1.balanceOf(Alice),
                uint256(
                    int256(uint256(type(uint104).max)) -
                        notionalVals[1] -
                        ITMSpreads[1] -
                        (shortAmounts.leftSlot() * 10) /
                        10_000
                ),
                uint256(int256(shortAmounts.leftSlot()) / 1_000_000 + 10)
            );
        }
    }

    function test_Success_mintOptions_ITMShortPutLongCall(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256[2] memory positionSizeSeeds
    ) public {
        _initPool(x);

        (int24 width0, int24 strike0) = PositionUtils.getITMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            1
        );

        (int24 width1, int24 strike1) = PositionUtils.getITMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionDataLong([width0, width1], [strike0, strike1], positionSizeSeeds);

        // sell short companion to long option
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike1,
            width1
        );

        (, int256 shortAmountsSold) = PanopticMath.computeExercisedAmounts(
            tokenId,
            0,
            positionSizes[0],
            tickSpacing
        );

        changePrank(Seller);

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSizes[0], 0, 0, 0);
        }
        (priceArray, medianTick) = pp.getPriceArray();
        (, currentTick, , , , , ) = pool.slot0();

        // put leg
        tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, isWETH, 0, 1, 0, strike0, width0);
        // call leg (long)
        tokenId = tokenId.addLeg(1, 1, isWETH, 1, 0, 1, strike1, width1);

        // price changes afters swap at mint so we need to update the price
        (currentSqrtPriceX96, , , , , , ) = pool.slot0();
        updatePositionDataLong();

        int256 netSurplus0 = $amount0Moveds[1] -
            PanopticMath.convert1to0($amount1Moveds[2], currentSqrtPriceX96);

        changePrank(address(sfpm));
        (int256 amount0s, int256 amount1s) = PositionUtils.simulateSwapLong(
            pool,
            [tickLowers[0], tickLowers[1]],
            [tickUppers[0], tickUppers[1]],
            [int128(expectedLiqs[1]), -int128(expectedLiqs[2])],
            router,
            token0,
            token1,
            fee,
            netSurplus0 < 0,
            -netSurplus0
        );

        changePrank(Alice);

        (int256 longAmounts, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
            tokenId,
            0,
            positionSizes[1],
            tickSpacing
        );

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSizes[1], type(uint64).max, 0, 0);
        }

        assertEq(sfpm.balanceOf(address(pp), tokenId), positionSizes[1]);

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertApproxEqAbs(
                inAMM,
                uint128(shortAmountsSold.rightSlot() - longAmounts.rightSlot()),
                10
            );
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertApproxEqAbs(inAMM, uint128(shortAmounts.leftSlot()), 10);
        }

        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(tokenId))))
            );

            assertEq(pp.numberOfPositions(Alice), 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, positionSizes[1]);
            assertEq(
                int64(poolUtilization0),
                Math.abs(currentTick - medianTick) > int24(2230)
                    ? int64(10_001)
                    : ($amount0Moveds[0] + $amount0Moveds[1] + $amount0Moveds[2] * 10000) /
                        int256(ct0.totalSupply())
            );
            assertEq(
                int64(poolUtilization1),
                Math.abs(currentTick - medianTick) > int24(2230)
                    ? int64(10_001)
                    : ($amount1Moveds[0] + $amount1Moveds[1] + $amount1Moveds[2] * 10000) /
                        int256(ct1.totalSupply())
            );
        }

        {
            int256[2] memory notionalVals = [
                amount0s +
                    $amount0Moveds[1] +
                    $amount0Moveds[2] -
                    shortAmounts.rightSlot() +
                    longAmounts.rightSlot(),
                amount1s + $amount1Moveds[1] + $amount1Moveds[2] - shortAmounts.leftSlot()
            ];

            int256[2] memory ITMSpreads = [
                notionalVals[0] > 0
                    ? (notionalVals[0] * tickSpacing) / 10_000
                    : -((notionalVals[0] * tickSpacing) / 10_000),
                notionalVals[1] > 0
                    ? (notionalVals[1] * tickSpacing) / 10_000
                    : -((notionalVals[1] * tickSpacing) / 10_000)
            ];

            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                uint256(
                    int256(uint256(type(uint104).max)) -
                        notionalVals[0] -
                        ITMSpreads[0] -
                        ((shortAmounts.rightSlot() + longAmounts.rightSlot()) * 10) /
                        10_000
                ),
                uint256(int256(shortAmounts.rightSlot()) / 1_000_000 + 10)
            );

            assertApproxEqAbs(
                ct1.balanceOf(Alice),
                uint256(
                    int256(uint256(type(uint104).max)) -
                        notionalVals[1] -
                        ITMSpreads[1] -
                        (shortAmounts.leftSlot() * 10) /
                        10_000
                ),
                uint256(int256(shortAmounts.leftSlot()) / 1_000_000 + 10)
            );
        }
    }

    function test_Fail_mintOptions_LowerPriceBoundFail(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        vm.expectRevert(Errors.PriceBoundFail.selector);
        pp.mintOptions(posIdList, positionSize, 0, TickMath.MAX_TICK - 1, TickMath.MAX_TICK);
    }

    function test_Fail_mintOptions_UpperPriceBoundFail(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        vm.expectRevert(Errors.PriceBoundFail.selector);
        pp.mintOptions(posIdList, positionSize, 0, TickMath.MIN_TICK, TickMath.MIN_TICK + 1);
    }

    function test_Fail_mintOptions_IncorrectPool(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId + 1).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 0));
        pp.mintOptions(posIdList, positionSize, 0, 0, 0);
    }

    function test_Fail_mintOptions_PositionAlreadyMinted(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            1
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            1,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        pp.mintOptions(posIdList, positionSize, 0, 0, 0);

        posIdList = new uint256[](2);
        posIdList[0] = tokenId;
        posIdList[1] = tokenId;

        vm.expectRevert(Errors.PositionAlreadyMinted.selector);
        pp.mintOptions(posIdList, uint128(positionSize), 0, 0, 0);
    }

    function test_Fail_mintOptions_OTMShortCall_NotEnoughCollateral(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        // deposit commission so we can reach collateral check
        (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
            tokenId,
            0,
            positionSize,
            tickSpacing
        );

        changePrank(Charlie);

        ct0.mint(uint128((shortAmounts.rightSlot() * 10) / 10000 + 1), Charlie);

        vm.expectRevert(Errors.NotEnoughCollateral.selector);
        pp.mintOptions(posIdList, uint128(positionSize), 0, 0, 0);
    }

    function test_Fail_mintOptions_TooManyPositionsOpen() public {
        _initPool(0);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            0,
            0,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, 0);

        uint256[] memory posIdList = new uint256[](32);
        uint248 positionsHash;
        for (uint256 i = 0; i < 33; i++) {
            tokenIds.push(
                uint256(0).addUniv3pool(poolId).addLeg(
                    0,
                    i + 1, // increment the options ratio as an easy way to get unique tokenIds
                    isWETH,
                    0,
                    0,
                    0,
                    strike,
                    width
                )
            );
            if (i == 32) vm.expectRevert(Errors.TooManyPositionsOpen.selector);
            pp.mintOptions(tokenIds, positionSize, 0, 0, 0);

            if (i < 32) {
                positionsHash =
                    positionsHash ^
                    uint248(uint256(keccak256(abi.encodePacked(tokenIds[i]))));
                assertEq(pp.positionsHash(Alice), positionsHash);
                assertEq(pp.numberOfPositions(Alice), i + 1);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             OPTION BURNING
    //////////////////////////////////////////////////////////////*/

    function test_Success_burnOptions_OTMShortCall_noPremia(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        pp.mintOptions(posIdList, positionSize, 0, 0, 0);
        pp.burnOptions(tokenId, 0, 0);

        assertEq(sfpm.balanceOf(address(pp), tokenId), 0);

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertEq(inAMM, 0);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertEq(inAMM, 0);
        }
        {
            assertEq(pp.positionsHash(Alice), 0);

            assertEq(pp.numberOfPositions(Alice), 0);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, 0);
            assertEq(poolUtilization0, 0);
            assertEq(poolUtilization1, 0);
        }

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );

            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                (uint256(type(uint104).max) - uint128((shortAmounts.rightSlot() * 10) / 10000)),
                uint256(int256(shortAmounts.rightSlot()) / 1_000_000 + 10)
            );
            assertEq(ct1.balanceOf(Alice), uint256(type(uint104).max));
        }
    }

    function test_Success_burnOptions_ITMShortCall_noPremia(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getITMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        // take snapshot for swap simulation
        vm.snapshot();

        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        int256[2] memory amount0Moveds;
        int256[2] memory amount1Moveds;

        amount0Moveds[0] = currentSqrtPriceX96 > sqrtUpper
            ? int256(0)
            : SqrtPriceMath.getAmount0Delta(
                currentSqrtPriceX96 < sqrtLower ? sqrtLower : currentSqrtPriceX96,
                sqrtUpper,
                int128(expectedLiq)
            );

        amount1Moveds[0] = -SqrtPriceMath.getAmount1Delta(
            sqrtLower,
            sqrtUpper > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUpper,
            int128(expectedLiq)
        );

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSize, 0, 0, 0);
        }

        // poke uniswap pool to update tokens owed - needed because swap happens after mint
        changePrank(address(sfpm));
        pool.burn(tickLower, tickUpper, 0);
        changePrank(Alice);

        // calculate additional fees owed to position
        (, , , uint128 tokensOwed0, ) = pool.positions(
            PositionKey.compute(address(sfpm), tickLower, tickUpper)
        );

        // price changes afters swap at mint so we need to update the price
        (currentSqrtPriceX96, , , , , , ) = pool.slot0();

        amount0Moveds[1] = currentSqrtPriceX96 > sqrtUpper
            ? int256(0)
            : SqrtPriceMath.getAmount0Delta(
                currentSqrtPriceX96 < sqrtLower ? sqrtLower : currentSqrtPriceX96,
                sqrtUpper,
                int128(expectedLiq)
            );

        amount1Moveds[1] = SqrtPriceMath.getAmount1Delta(
            sqrtLower,
            sqrtUpper > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUpper,
            int128(expectedLiq)
        );

        pp.burnOptions(tokenId, 0, 0);

        assertEq(sfpm.balanceOf(address(pp), tokenId), 0);

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertEq(inAMM, 0);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertEq(inAMM, 0);
        }
        {
            assertEq(pp.positionsHash(Alice), 0);
            assertEq(pp.numberOfPositions(Alice), 0);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);
            assertEq(balance, 0);
            assertEq(poolUtilization0, 0);
            assertEq(poolUtilization1, 0);
        }

        //snapshot balances and revert to old snapshot
        uint256[2] memory balanceBefores = [ct0.balanceOf(Alice), ct1.balanceOf(Alice)];

        vm.revertTo(0);

        uint256 expectedSwap0;
        uint256 expectedSwap1;
        {
            (uint256[2] memory amount0, ) = PositionUtils.simulateSwap(
                pool,
                tickLower,
                tickUpper,
                expectedLiq,
                router,
                token0,
                token1,
                fee,
                [true, false],
                amount1Moveds
            );

            expectedSwap0 = amount0[0];
            expectedSwap1 = amount0[1];
        }

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                uint128(positionSize),
                tickSpacing
            );

            int256 amount0Moved = currentSqrtPriceX96 > sqrtUpper
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    currentSqrtPriceX96 < sqrtLower ? sqrtLower : currentSqrtPriceX96,
                    sqrtUpper,
                    int128(expectedLiq)
                );

            int256[2] memory notionalVals = [
                int256(expectedSwap0) + amount0Moveds[0] - shortAmounts.rightSlot(),
                -int256(expectedSwap1) - amount0Moveds[1] + shortAmounts.rightSlot()
            ];

            int256 ITMSpread = notionalVals[0] > 0
                ? (notionalVals[0] * tickSpacing) / 10_000
                : -((notionalVals[0] * tickSpacing) / 10_000);

            assertApproxEqAbs(
                balanceBefores[0],
                uint256(
                    int256(uint256(type(uint104).max)) -
                        ITMSpread -
                        notionalVals[0] -
                        notionalVals[1] -
                        (shortAmounts.rightSlot() * 10) /
                        10_000 +
                        int128(tokensOwed0)
                ),
                uint256(int256(shortAmounts.rightSlot()) / 1_000_000 + 10)
            );

            assertEq(balanceBefores[1], uint256(type(uint104).max));
        }
    }

    function test_Success_burnOptions_burnAllOptionsFrom(
        uint256 x,
        uint256 widthSeed,
        uint256 widthSeed2,
        int256 strikeSeed,
        int256 strikeSeed2,
        uint256 positionSizeSeed,
        uint256 positionSize2Seed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        (int24 width2, int24 strike2) = PositionUtils.getOTMSW(
            widthSeed2,
            strikeSeed2,
            uint24(tickSpacing),
            currentTick,
            0
        );
        vm.assume(width2 != width || strike2 != strike);

        populatePositionData(
            [width, width2],
            [strike, strike2],
            [positionSizeSeed, positionSize2Seed]
        );

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        // leg 2
        uint256 tokenId2 = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike2,
            width2
        );
        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSizes[0], 0, 0, 0);
        }

        {
            uint256[] memory posIdList = new uint256[](2);
            posIdList[0] = tokenId;
            posIdList[1] = tokenId2;

            pp.mintOptions(posIdList, uint128(positionSizes[1]), 0, 0, 0);
            pp.burnOptions(posIdList, 0, 0);

            (uint256 token0Balance, , ) = pp.optionPositionBalance(Alice, tokenId);
            (uint256 token1Balance, , ) = pp.optionPositionBalance(Alice, tokenId2);
            assertEq(token0Balance, 0);
            assertEq(token1Balance, 0);
        }
    }

    function test_Fail_burnOptions_OptionsBalanceZero(uint256 x) public {
        _initPool(x);

        vm.expectRevert(Errors.OptionsBalanceZero.selector);

        pp.burnOptions(0, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                             OPTION ROLLING
    //////////////////////////////////////////////////////////////*/

    function test_Success_rollOptions_2xOTMShortCall_noPremia(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            0
        );

        (int24 width2, int24 strike2) = PositionUtils.getOTMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );

        vm.assume(width2 != width || strike2 != strike);

        populatePositionData([width, width2], [strike, strike2], positionSizeSeed);

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        // leg 2
        tokenId = tokenId.addLeg(1, 1, isWETH, 0, 0, 1, strike2, width2);
        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSize, 0, 0, 0);
        }
        // fully roll leg 2 to the same as leg 1
        uint256 newTokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );
        newTokenId = newTokenId.addLeg(1, 1, isWETH, 0, 0, 1, strike, width);

        pp.rollOptions(tokenId, newTokenId, new uint256[](0), 0, 0, 0);

        assertEq(sfpm.balanceOf(address(pp), tokenId), 0);
        assertEq(sfpm.balanceOf(address(pp), newTokenId), positionSize);

        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtLowers[1],
            sqrtUppers[1],
            expectedLiqs[1]
        );

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );

            (, int256 shortAmountsNew) = PanopticMath.computeExercisedAmounts(
                tokenId,
                newTokenId,
                positionSize,
                tickSpacing
            );

            (, uint256 inAMM, ) = ct0.getPoolData();

            shortAmounts = shortAmounts.sub(shortAmountsNew);

            assertApproxEqAbs(inAMM, uint128(shortAmounts.rightSlot()), 10);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertEq(inAMM, 0);
        }
        {
            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);
            assertEq(balance, 0);
            assertEq(poolUtilization0, 0);
            assertEq(poolUtilization1, 0);
        }

        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(newTokenId))))
            );

            assertEq(pp.numberOfPositions(Alice), 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, newTokenId);
            assertEq(balance, positionSize);
            assertEq(poolUtilization0, (amount0 * 10000) / ct0.totalSupply());
            assertEq(poolUtilization1, 0);
        }

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );

            (, int256 shortAmounts2) = PanopticMath.computeExercisedAmounts(
                newTokenId,
                0,
                positionSize,
                tickSpacing
            );

            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                uint256(type(uint104).max) - uint128((shortAmounts2.rightSlot() * 10) / 10000),
                uint256(int256(shortAmounts2.rightSlot() / 1_000_000 + 10))
            );

            assertEq(ct1.balanceOf(Alice), uint256(type(uint104).max));
        }
    }

    function test_Success_rollOptions_BurnITMMintOTM2xShortCall(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            0
        );

        (int24 width2, int24 strike2) = PositionUtils.getITMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );
        vm.assume(width2 != width || strike2 != strike);

        populatePositionData([width, width2], [strike, strike2], positionSizeSeed);

        // take snapshot for swap simulation
        vm.snapshot();

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        // leg 2
        tokenId = tokenId.addLeg(1, 1, isWETH, 0, 0, 1, strike2, width2);

        int256[4] memory amount0Moveds;
        int256[2] memory amount1Moveds;

        // moved at original mint
        amount0Moveds[0] =
            (
                currentSqrtPriceX96 > sqrtUppers[0]
                    ? int256(0)
                    : SqrtPriceMath.getAmount0Delta(
                        currentSqrtPriceX96 < sqrtLowers[0] ? sqrtLowers[0] : currentSqrtPriceX96,
                        sqrtUppers[0],
                        int128(expectedLiqs[0])
                    )
            ) +
            (
                currentSqrtPriceX96 > sqrtUppers[1]
                    ? int256(0)
                    : SqrtPriceMath.getAmount0Delta(
                        currentSqrtPriceX96 < sqrtLowers[1] ? sqrtLowers[1] : currentSqrtPriceX96,
                        sqrtUppers[1],
                        int128(expectedLiqs[1])
                    )
            );

        amount1Moveds[0] = -SqrtPriceMath.getAmount1Delta(
            sqrtLowers[1],
            sqrtUppers[1] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[1],
            int128(expectedLiqs[1])
        );

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSize, 0, 0, 0);
        }

        // poke uniswap pool to update tokens owed - needed because swap happens after mint
        changePrank(address(sfpm));
        pool.burn(tickLowers[0], tickUppers[0], 0);
        pool.burn(tickLowers[1], tickUppers[1], 0);
        changePrank(Alice);

        // price changes afters swap at mint so we need to update the price
        (currentSqrtPriceX96, , , , , , ) = pool.slot0();

        // moved at roll
        amount0Moveds[1] =
            // burn ITM leg
            (
                currentSqrtPriceX96 > sqrtUppers[1]
                    ? int256(0)
                    : SqrtPriceMath.getAmount0Delta(
                        currentSqrtPriceX96 < sqrtLowers[1] ? sqrtLowers[1] : currentSqrtPriceX96,
                        sqrtUppers[1],
                        -int128(expectedLiqs[1])
                    )
            ) +
            // mint OTM leg
            (
                currentSqrtPriceX96 > sqrtUppers[0]
                    ? int256(0)
                    : SqrtPriceMath.getAmount0Delta(
                        currentSqrtPriceX96 < sqrtLowers[0] ? sqrtLowers[0] : currentSqrtPriceX96,
                        sqrtUppers[0],
                        int128(expectedLiqs[0])
                    )
            );

        amount1Moveds[1] = SqrtPriceMath.getAmount1Delta(
            sqrtLowers[1],
            sqrtUppers[1] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[1],
            int128(expectedLiqs[1])
        );

        // fully roll leg 2 to the same as leg 1
        uint256 newTokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );
        newTokenId = newTokenId.addLeg(1, 1, isWETH, 0, 0, 1, strike, width);

        // calculate additional fees owed to position
        (, , , uint128 tokensOwed0, ) = pool.positions(
            PositionKey.compute(address(sfpm), tickLowers[1], tickUppers[1])
        );

        pp.rollOptions(tokenId, newTokenId, new uint256[](0), 0, 0, 0);

        (priceArray, medianTick) = pp.getPriceArray();
        (, currentTick, , , , , ) = pool.slot0();

        assertEq(sfpm.balanceOf(address(pp), tokenId), 0);
        assertEq(sfpm.balanceOf(address(pp), newTokenId), positionSize);

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );

            (, int256 shortAmountsNew) = PanopticMath.computeExercisedAmounts(
                tokenId,
                newTokenId,
                positionSize,
                tickSpacing
            );
            (, uint256 inAMM, ) = ct0.getPoolData();
            shortAmounts = shortAmounts.sub(shortAmountsNew);
            assertApproxEqAbs(inAMM, uint128(shortAmounts.rightSlot()), 10);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertEq(inAMM, 0);
        }
        {
            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);
            assertEq(balance, 0);
            assertEq(poolUtilization0, 0);
            assertEq(poolUtilization1, 0);
        }

        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(newTokenId))))
            );
            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, newTokenId);

            assertEq(balance, positionSize);

            uint256 amount0OTM = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtLowers[0],
                sqrtUppers[0],
                expectedLiqs[0]
            );
            uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtLowers[1],
                sqrtUppers[1],
                expectedLiqs[1]
            );

            assertEq(
                poolUtilization0,
                Math.abs(currentTick - medianTick) > int24(2230)
                    ? 10_001
                    : ((amount0 + amount0OTM) * 10000) / ct0.totalSupply()
            );
            assertEq(
                poolUtilization1,
                Math.abs(currentTick - medianTick) > int24(2230) ? 10_001 : 0
            );
        }

        //snapshot balances before state is cleared
        uint256[2] memory balanceBefores = [ct0.balanceOf(Alice), ct1.balanceOf(Alice)];

        // we have to do this simulation after mint/burn because revertTo deletes all snapshots taken ahead of it
        vm.revertTo(0);

        (uint256[2] memory amount0s, ) = PositionUtils.simulateSwap(
            pool,
            tickLowers[1],
            tickUppers[1],
            expectedLiqs[1],
            router,
            token0,
            token1,
            fee,
            [true, false],
            amount1Moveds
        );

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );
            (, int256 shortAmounts2) = PanopticMath.computeExercisedAmounts(
                newTokenId,
                tokenId,
                positionSize,
                tickSpacing
            );

            int256[2] memory notionalVals = [
                int256(amount0s[0]) + amount0Moveds[0] - shortAmounts.rightSlot(),
                -int256(amount0s[1]) + (amount0Moveds[1]) - shortAmounts2.rightSlot()
            ];

            int256[2] memory ITMSpreads = [
                notionalVals[0] > 0
                    ? (notionalVals[0] * tickSpacing) / 10_000
                    : -((notionalVals[0] * tickSpacing) / 10_000),
                notionalVals[1] > 0
                    ? (notionalVals[1] * tickSpacing) / 10_000
                    : -((notionalVals[1] * tickSpacing) / 10_000)
            ];
            assertApproxEqAbs(
                int256(balanceBefores[0]),
                int256(uint256(type(uint104).max)) -
                    ITMSpreads[0] -
                    ITMSpreads[1] -
                    notionalVals[0] -
                    notionalVals[1] -
                    (shortAmounts.rightSlot() * 10) /
                    10_000 -
                    (shortAmounts2.rightSlot() * 10) /
                    10_000 +
                    int128(tokensOwed0),
                // the method used by SFPM to calculate fees without poking is slightly inaccurate at large scales
                // but it does save a non-insignificant amount of gas
                // we use the poking method here for convenience/differentiability, so very small discrepancies are acceptable (arbitrarily, 1/100 bp)
                // (&, +10 to still pass for off-by-one errors when tokensOwed0 is too small)
                uint128(
                    int128(tokensOwed0) + shortAmounts.rightSlot() + shortAmounts2.rightSlot()
                ) /
                    1_000_000 +
                    10
            );

            assertEq(balanceBefores[1], uint256(type(uint104).max));
        }
    }

    function test_Success_rollOptions_BurnOTMMintITMShortCall(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getITMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            0
        );

        (int24 width2, int24 strike2) = PositionUtils.getOTMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );
        vm.assume(width2 != width || strike2 != strike);

        populatePositionData([width, width2], [strike, strike2], positionSizeSeed);

        // take snapshot for swap simulation
        vm.snapshot();

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike2,
            width2
        );

        int256 amount0Moved;
        int256 amount1Moved;

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSize, 0, 0, 0);
        }

        // price changes afters swap at mint so we need to update the price
        (currentSqrtPriceX96, , , , , , ) = pool.slot0();

        // moved at roll
        amount0Moved =
            // burn OTM leg
            (
                currentSqrtPriceX96 > sqrtUppers[1]
                    ? int256(0)
                    : SqrtPriceMath.getAmount0Delta(
                        currentSqrtPriceX96 < sqrtLowers[1] ? sqrtLowers[1] : currentSqrtPriceX96,
                        sqrtUppers[1],
                        -int128(expectedLiqs[1])
                    )
            ) +
            // mint ITM leg
            (
                currentSqrtPriceX96 > sqrtUppers[0]
                    ? int256(0)
                    : SqrtPriceMath.getAmount0Delta(
                        currentSqrtPriceX96 < sqrtLowers[0] ? sqrtLowers[0] : currentSqrtPriceX96,
                        sqrtUppers[0],
                        int128(expectedLiqs[0])
                    )
            );

        amount1Moved = SqrtPriceMath.getAmount1Delta(
            sqrtLowers[0],
            sqrtUppers[0] > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUppers[0],
            int128(expectedLiqs[0])
        );

        // fully roll leg 2 to the same as leg 1
        uint256 newTokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        // calculate additional fees owed to position
        (, , , uint128 tokensOwed0, ) = pool.positions(
            PositionKey.compute(address(sfpm), tickLowers[0], tickUppers[0])
        );
        {
            // since we're rolling itm -> otm, the collateral requirement could be higher
            // so we need to provide the positionIdList - the collateral check cannot be skipped as
            // it can in -> otm rolls
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.rollOptions(tokenId, newTokenId, posIdList, 0, 0, 0);
        }

        (priceArray, medianTick) = pp.getPriceArray();
        (, currentTick, , , , , ) = pool.slot0();

        assertEq(sfpm.balanceOf(address(pp), tokenId), 0);
        assertEq(sfpm.balanceOf(address(pp), newTokenId), positionSize);

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );

            (, int256 shortAmountsNew) = PanopticMath.computeExercisedAmounts(
                tokenId,
                newTokenId,
                positionSize,
                tickSpacing
            );
            (, uint256 inAMM, ) = ct0.getPoolData();
            shortAmounts = shortAmounts.sub(shortAmountsNew);
            assertApproxEqAbs(inAMM, uint128(shortAmounts.rightSlot()), 10);
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertApproxEqAbs(inAMM, 0, 10);
        }
        {
            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);
            assertEq(balance, 0);
            assertEq(poolUtilization0, 0);
            assertEq(poolUtilization1, 0);
        }

        {
            assertEq(
                pp.positionsHash(Alice),
                uint248(uint256(keccak256(abi.encodePacked(newTokenId))))
            );
            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, newTokenId);

            assertEq(balance, positionSize);

            uint256 amount0OTM = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtLowers[0],
                sqrtUppers[0],
                expectedLiqs[0]
            );

            assertEq(
                poolUtilization0,
                Math.abs(currentTick - medianTick) > int24(2230)
                    ? 10_001
                    : (amount0OTM * 10000) / ct0.totalSupply()
            );
            assertEq(
                poolUtilization1,
                Math.abs(currentTick - medianTick) > int24(2230) ? 10_001 : 0
            );
        }

        //snapshot balances before state is cleared
        uint256[2] memory balanceBefores = [ct0.balanceOf(Alice), ct1.balanceOf(Alice)];

        // we have to do this simulation after mint/burn because revertTo deletes all snapshots taken ahead of it
        vm.revertTo(0);

        (uint256 amount0s, ) = PositionUtils.simulateSwap(
            pool,
            tickLowers[0],
            tickUppers[0],
            expectedLiqs[0],
            router,
            token0,
            token1,
            fee,
            true,
            -amount1Moved
        );

        {
            (, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                tickSpacing
            );

            (, int256 shortAmounts2) = PanopticMath.computeExercisedAmounts(
                newTokenId,
                tokenId,
                positionSize,
                tickSpacing
            );

            int256 notionalVal = int256(amount0s) + amount0Moved - shortAmounts2.rightSlot();

            int256 ITMSpread = notionalVal > 0
                ? (notionalVal * tickSpacing) / 10_000
                : -((notionalVal * tickSpacing) / 10_000);

            assertApproxEqAbs(
                int256(balanceBefores[0]),
                int256(uint256(type(uint104).max)) -
                    ITMSpread -
                    notionalVal -
                    (shortAmounts.rightSlot() * 10) /
                    10_000 -
                    (shortAmounts2.rightSlot() * 10) /
                    10_000 +
                    int128(tokensOwed0),
                // the method used by SFPM to calculate fees without poking is slightly inaccurate at large scales
                // but it does save a non-insignificant amount of gas
                // we use the poking method here for convenience/differentiability, so very small discrepancies are acceptable (arbitrarily, 1/100 bp)
                // (&, +10 to still pass for off-by-one errors when tokensOwed0 is too small)
                uint128(
                    int128(tokensOwed0) + shortAmounts.rightSlot() + shortAmounts2.rightSlot()
                ) /
                    1_000_000 +
                    10
            );

            assertEq(balanceBefores[1], uint256(type(uint104).max));
        }
    }

    function test_Fail_rollOptions_MintNotOTM(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            0
        );

        (int24 width2, int24 strike2) = PositionUtils.getITMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData([width, width2], [strike, strike2], positionSizeSeed);

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        // leg 2 (identical)
        tokenId = tokenId.addLeg(1, 1, isWETH, 0, 0, 1, strike, width);
        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, uint128(positionSize), 0, 0, 0);
        }

        {
            // roll leg 1 to ITM
            uint256 newTokenId = uint256(0).addUniv3pool(poolId).addLeg(
                0,
                1,
                isWETH,
                0,
                0,
                0,
                strike2,
                width2
            );

            newTokenId = newTokenId.addLeg(1, 1, isWETH, 0, 0, 1, strike, width);

            vm.expectRevert(Errors.OptionsNotOTM.selector);

            pp.rollOptions(tokenId, newTokenId, new uint256[](0), 0, 0, 0);
        }
    }

    function test_Fail_rollOptions_notATokenRoll(uint256 oldTokenId, uint256 newTokenId) public {
        _initPool(0);

        vm.assume(
            ((oldTokenId & 0xFFF_000000000FFF_000000000FFF_000000000FFF_FFFFFFFFFFFFFFFF) !=
                (newTokenId & 0xFFF_000000000FFF_000000000FFF_000000000FFF_FFFFFFFFFFFFFFFF))
        );

        vm.expectRevert(Errors.NotATokenRoll.selector);
        pp.rollOptions(oldTokenId, newTokenId, new uint256[](0), 0, 0, 0);
    }

    // ensure position list is validated if we roll w/ itm positions
    function test_Fail_rollOptions_validatePositionList(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getITMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            0
        );

        (int24 width2, int24 strike2) = PositionUtils.getOTMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );
        vm.assume(width2 != width || strike2 != strike);

        populatePositionData([width, width2], [strike, strike2], positionSizeSeed);

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike2,
            width2
        );

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSize, 0, 0, 0);
        }

        // fully roll leg 2 to the same as leg 1
        uint256 newTokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        {
            // provide incorrect positionIdList to make sure it's being validated when we roll w/ ITM
            uint256[] memory posIdList = new uint256[](2);
            posIdList[0] = 0;
            posIdList[1] = tokenId;

            vm.expectRevert(Errors.InputListFail.selector);

            pp.rollOptions(tokenId, newTokenId, posIdList, 0, 0, 0);
        }
    }

    // if a position list is provided for rolling ITM, we require the burn tokenId to be at the end
    function test_Fail_rollOptions_BurnedTokenIdNotLastIndex(
        uint256 x,
        uint256[2] memory widthSeeds,
        int256[2] memory strikeSeeds,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getITMSW(
            widthSeeds[0],
            strikeSeeds[0],
            uint24(tickSpacing),
            currentTick,
            0
        );

        (int24 width2, int24 strike2) = PositionUtils.getOTMSW(
            widthSeeds[1],
            strikeSeeds[1],
            uint24(tickSpacing),
            currentTick,
            0
        );
        vm.assume(width2 != width || strike2 != strike);

        populatePositionData([width, width2], [strike, strike2], positionSizeSeed);

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike2,
            width2
        );

        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            pp.mintOptions(posIdList, positionSize, 0, 0, 0);
        }

        // fully roll leg 2 to the same as leg 1
        uint256 newTokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        {
            // provide incorrect positionIdList to make sure it's being validated when we roll w/ ITM
            uint256[] memory posIdList = new uint256[](2);
            posIdList[0] = newTokenId;
            posIdList[1] = 0;

            vm.expectRevert(Errors.BurnedTokenIdNotLastIndex.selector);

            pp.rollOptions(tokenId, newTokenId, posIdList, 0, 0, 0);
        }
    }

    function test_Success_forceExerciseNoDelta(
        uint256 x,
        uint256 numLegs,
        uint256[4] memory isLongs,
        uint256[4] memory tokenTypes,
        uint256[4] memory widthSeeds,
        int256[4] memory strikeSeeds,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        numLegs = bound(numLegs, 1, 4);

        int24[4] memory widths;
        int24[4] memory strikes;

        for (uint256 i = 0; i < numLegs; ++i) {
            tokenTypes[i] = bound(tokenTypes[i], 0, 1);
            isLongs[i] = bound(isLongs[i], 0, 1);
            (widths[i], strikes[i]) = getOTMOutOfRangeSW(
                widthSeeds[i],
                strikeSeeds[i],
                uint24(tickSpacing),
                // distancing tickSpacing ensures this position stays OTM throughout this test case. ITM is tested elsewhere.
                currentTick,
                tokenTypes[i]
            );
        }
        if (numLegs == 1) populatePositionData(widths[0], strikes[0], positionSizeSeed);
        if (numLegs == 2)
            populatePositionData(
                [widths[0], widths[1]],
                [strikes[0], strikes[1]],
                positionSizeSeed
            );
        if (numLegs == 3)
            populatePositionData(
                [widths[0], widths[1], widths[2]],
                [strikes[0], strikes[1], strikes[2]],
                positionSizeSeed
            );
        if (numLegs == 4) populatePositionData(widths, strikes, positionSizeSeed);
        {
            uint256 exerciseableCount;
            // make sure position is exercisable - the uniswap twap is used to determine exercisability
            // so it could potentially be both OTM and non-exercisable (in-range)
            TWAPtick = pp.getUniV3TWAP_();
            for (uint256 i = 0; i < numLegs; ++i) {
                if (
                    (TWAPtick < (numLegs == 1 ? tickLower : tickLowers[i]) ||
                        TWAPtick >= (numLegs == 1 ? tickUpper : tickUppers[i])) && isLongs[i] == 1
                ) exerciseableCount++;
            }
            vm.assume(exerciseableCount > 0);
        }

        // this is a long option; so need to sell before it can be bought (let's say 2x position size for now)
        changePrank(Seller);

        uint256 tokenId = uint256(0).addUniv3pool(poolId);

        for (uint256 i = 0; i < numLegs; ++i) {
            tokenId = tokenId.addLeg(i, 1, isWETH, 0, tokenTypes[i], i, strikes[i], widths[i]);
            if (isLongs[i] == 0) continue;
            int256 range = (tickSpacing * widths[i]) / 2;

            int256 legRanges = currentTick < strikes[i] - range
                ? (2 * (strikes[i] - range - currentTick)) / range
                : (2 * (currentTick - strikes[i] - range)) / range;

            rangesFromStrike = legRanges > rangesFromStrike ? legRanges : rangesFromStrike;
        }

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        pp.mintOptions(posIdList, positionSize * 2, 0, 0, 0);

        // now we can mint the long option we are force exercising
        changePrank(Alice);

        // reset tokenId so we can fill for what we're actually testing (the bought option)
        tokenId = uint256(0).addUniv3pool(poolId);

        for (uint256 i = 0; i < numLegs; ++i) {
            tokenId = tokenId.addLeg(
                i,
                1,
                isWETH,
                isLongs[i],
                tokenTypes[i],
                i,
                strikes[i],
                widths[i]
            );
        }

        posIdList[0] = tokenId;

        (int256 longAmounts, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
            tokenId,
            0,
            positionSize,
            tickSpacing
        );

        uint256[2] memory commissionFeeAmounts = [
            ct0.convertToShares(
                uint256((int256(longAmounts.rightSlot() + shortAmounts.rightSlot()) * 10) / 10_000)
            ),
            ct1.convertToShares(
                uint256((int256(longAmounts.leftSlot() + shortAmounts.leftSlot()) * 10) / 10_000)
            )
        ];

        pp.mintOptions(posIdList, positionSize, type(uint64).max, 0, 0);

        changePrank(Bob);

        // since the position is sufficiently OTM, the spread between value at current tick and median tick is 0
        // given that it is OTM at both points. Therefore, that spread is not charged as a fee and we just have the proximity fee
        // note: we HAVE to start with a negative number as the base exercise cost because when shifting a negative number right by n bits,
        // the result is rounded DOWN and NOT toward zero
        // this divergence is observed when n (the number of half ranges) is > 10 (ensuring the floor is not zero, but -1 = 1bps at that point)
        int256 exerciseFee = int256(-1024) >> uint256(rangesFromStrike);

        exerciseFeeAmounts = [
            int256(
                ct0.convertToShares(uint256((longAmounts.rightSlot() * (-exerciseFee)) / 10_000))
            ),
            int256(ct1.convertToShares(uint256((longAmounts.leftSlot() * (-exerciseFee)) / 10_000)))
        ];

        pp.forceExercise(Alice, 0, 0, posIdList, new uint256[](0));

        assertApproxEqAbs(
            ct0.balanceOf(Bob),
            type(uint104).max - uint256(exerciseFeeAmounts[0]),
            10
        );
        assertApproxEqAbs(
            ct1.balanceOf(Bob),
            type(uint104).max - uint256(exerciseFeeAmounts[1]),
            10
        );

        assertEq(sfpm.balanceOf(address(pp), tokenId), 0);

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertApproxEqAbs(
                inAMM,
                uint128(longAmounts.rightSlot() + shortAmounts.rightSlot()) * 2,
                10
            );
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertApproxEqAbs(
                inAMM,
                uint128(longAmounts.leftSlot() + shortAmounts.leftSlot()) * 2,
                10
            );
        }
        {
            assertEq(pp.positionsHash(Alice), 0);

            assertEq(pp.numberOfPositions(Alice), 0);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, 0);
            assertEq(poolUtilization0, 0);
            assertEq(poolUtilization1, 0);
        }

        {
            assertApproxEqAbs(
                ct0.balanceOf(Alice),
                (uint256(type(uint104).max) +
                    uint256(exerciseFeeAmounts[0]) -
                    commissionFeeAmounts[0]),
                uint256(
                    int256((longAmounts.rightSlot() + shortAmounts.rightSlot()) / 1_000_000 + 10)
                )
            );

            assertApproxEqAbs(
                ct1.balanceOf(Alice),
                (uint256(type(uint104).max) +
                    uint256(exerciseFeeAmounts[1]) -
                    commissionFeeAmounts[1]),
                uint256(int256((longAmounts.leftSlot() + shortAmounts.leftSlot()) / 1_000_000 + 10))
            );
        }
    }

    // more general test - may end up "no delta" for certain fuzz inputs
    function test_Success_forceExerciseDelta(
        uint256 x,
        uint256 numLegs,
        uint256[4] memory isLongs,
        uint256[4] memory tokenTypes,
        uint256[4] memory widthSeeds,
        int256[4] memory strikeSeeds,
        uint256 positionSizeSeed,
        uint256 swapSizeSeed
    ) public {
        _initPool(x);

        numLegs = bound(numLegs, 1, 4);

        int24[4] memory widths;
        int24[4] memory strikes;

        for (uint256 i = 0; i < numLegs; ++i) {
            tokenTypes[i] = bound(tokenTypes[i], 0, 1);
            isLongs[i] = bound(isLongs[i], 0, 1);
            (widths[i], strikes[i]) = getValidSW(
                widthSeeds[i],
                strikeSeeds[i],
                uint24(tickSpacing),
                // distancing tickSpacing ensures this position stays OTM throughout this test case. ITM is tested elsewhere.
                currentTick
            );
        }
        if (numLegs == 1) populatePositionData(widths[0], strikes[0], positionSizeSeed);
        if (numLegs == 2)
            populatePositionData(
                [widths[0], widths[1]],
                [strikes[0], strikes[1]],
                positionSizeSeed
            );
        if (numLegs == 3)
            populatePositionData(
                [widths[0], widths[1], widths[2]],
                [strikes[0], strikes[1], strikes[2]],
                positionSizeSeed
            );
        if (numLegs == 4) populatePositionData(widths, strikes, positionSizeSeed);
        {
            uint256 exerciseableCount;
            // make sure position is exercisable - the uniswap twap is used to determine exercisability
            // so it could potentially be both OTM and non-exercisable (in-range)
            TWAPtick = pp.getUniV3TWAP_();
            for (uint256 i = 0; i < numLegs; ++i) {
                if (
                    (TWAPtick < (numLegs == 1 ? tickLower : tickLowers[i]) ||
                        TWAPtick >= (numLegs == 1 ? tickUpper : tickUppers[i])) && isLongs[i] == 1
                ) exerciseableCount++;
            }
            vm.assume(exerciseableCount > 0);
        }

        // this is a long option; so need to sell before it can be bought (let's say 2x position size for now)
        changePrank(Seller);

        uint256 tokenId = uint256(0).addUniv3pool(poolId);

        for (uint256 i = 0; i < numLegs; ++i) {
            tokenId = tokenId.addLeg(i, 1, isWETH, 0, tokenTypes[i], i, strikes[i], widths[i]);
        }

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        pp.mintOptions(posIdList, positionSize * 2, 0, 0, 0);

        // now we can mint the long option we are force exercising
        changePrank(Alice);

        // reset tokenId so we can fill for what we're actually testing (the bought option)
        tokenId = uint256(0).addUniv3pool(poolId);

        for (uint256 i = 0; i < numLegs; ++i) {
            tokenId = tokenId.addLeg(
                i,
                1,
                isWETH,
                isLongs[i],
                tokenTypes[i],
                i,
                strikes[i],
                widths[i]
            );
        }

        posIdList[0] = tokenId;

        (int256 longAmounts, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
            tokenId,
            0,
            positionSize,
            tickSpacing
        );

        uint256[2] memory commissionFeeAmounts = [
            ct0.convertToShares(
                uint256((int256(longAmounts.rightSlot() + shortAmounts.rightSlot()) * 10) / 10_000)
            ),
            ct1.convertToShares(
                uint256((int256(longAmounts.leftSlot() + shortAmounts.leftSlot()) * 10) / 10_000)
            )
        ];

        pp.mintOptions(posIdList, positionSize, type(uint64).max, 0, 0);

        lastCollateralBalance0[Alice] = ct0.convertToAssets(ct0.balanceOf(Alice));
        lastCollateralBalance1[Alice] = ct1.convertToAssets(ct1.balanceOf(Alice));

        twoWaySwap(swapSizeSeed);

        updatePositionDataVariable(numLegs, isLongs);

        updateITMAmountsBurn(numLegs, tokenTypes);

        updateSwappedAmountsBurn(numLegs, isLongs);

        updateIntrinsicValueBurn(longAmounts, shortAmounts);

        ($expectedPremia0, $expectedPremia1, ) = pp.calculateAccumulatedFeesBatch(Alice, posIdList);

        changePrank(Bob);

        (priceArray, medianTick) = pp.getPriceArray();

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        for (uint256 i = 0; i < numLegs; ++i) {
            if (isLongs[i] == 0) continue;
            int256 range = (tickSpacing * widths[i]) / 2;

            int256 legRanges = currentTick < strikes[i] - range
                ? (2 * (strikes[i] - range - currentTick)) / range
                : (2 * (currentTick - strikes[i] - range)) / range;

            rangesFromStrike = legRanges > rangesFromStrike ? legRanges : rangesFromStrike;

            medianSqrtPriceX96 = TickMath.getSqrtRatioAtTick(medianTick);

            uint256 liquidityChunk = PanopticMath.getLiquidityChunk(
                tokenId,
                i,
                positionSize,
                tickSpacing
            );

            (currentValue0, currentValue1) = LiquidityAmounts.getAmountsForLiquidity(
                TickMath.getSqrtRatioAtTick(currentTick),
                TickMath.getSqrtRatioAtTick(liquidityChunk.tickLower()),
                TickMath.getSqrtRatioAtTick(liquidityChunk.tickUpper()),
                liquidityChunk.liquidity()
            );

            (medianValue0, medianValue1) = LiquidityAmounts.getAmountsForLiquidity(
                medianSqrtPriceX96,
                TickMath.getSqrtRatioAtTick(liquidityChunk.tickLower()),
                TickMath.getSqrtRatioAtTick(liquidityChunk.tickUpper()),
                liquidityChunk.liquidity()
            );

            // compensate user for loss in value if chunk has lost money between current and median tick
            // note: the delta for one token will be positive and the other will be negative. This cancels out any moves in their positions
            if (
                (tokenTypes[i] == 0 && currentValue1 < medianValue1) ||
                (tokenTypes[i] == 1 && currentValue0 < medianValue0)
            ) {
                exerciseFeeAmounts[0] += int256(medianValue0) - int256(currentValue0);
                exerciseFeeAmounts[1] += int256(medianValue1) - int256(currentValue1);
            }
        }

        // since the position is sufficiently OTM, the spread between value at current tick and median tick is 0
        // given that it is OTM at both points. Therefore, that spread is not charged as a fee and we just have the proximity fee
        // note: we HAVE to start with a negative number as the base exercise cost because when shifting a negative number right by n bits,
        // the result is rounded DOWN and NOT toward zero
        // this divergence is observed when n (the number of half ranges) is > 10 (ensuring the floor is not zero, but -1 = 1bps at that point)
        int256 exerciseFee = int256(-1024) >> uint256(rangesFromStrike);

        exerciseFeeAmounts[0] += (longAmounts.rightSlot() * (-exerciseFee)) / 10_000;
        exerciseFeeAmounts[1] += (longAmounts.leftSlot() * (-exerciseFee)) / 10_000;

        pp.forceExercise(Alice, 0, 0, posIdList, new uint256[](0));

        assertApproxEqAbs(
            int256(ct0.balanceOf(Bob)),
            int256(uint256(type(uint104).max)) -
                (exerciseFeeAmounts[0] < 0 ? -1 : int8(1)) *
                int256(ct0.convertToShares(uint256(Math.abs(exerciseFeeAmounts[0])))),
            10
        );
        assertApproxEqAbs(
            int256(ct1.balanceOf(Bob)),
            int256(uint256(type(uint104).max)) -
                (exerciseFeeAmounts[1] < 0 ? -1 : int8(1)) *
                int256(ct1.convertToShares(uint256(Math.abs(exerciseFeeAmounts[1])))),
            10
        );

        assertEq(sfpm.balanceOf(address(pp), tokenId), 0);

        {
            (, uint256 inAMM, ) = ct0.getPoolData();
            assertApproxEqAbs(
                inAMM,
                uint128(longAmounts.rightSlot() + shortAmounts.rightSlot()) * 2,
                10
            );
        }

        {
            (, uint256 inAMM, ) = ct1.getPoolData();
            assertApproxEqAbs(
                inAMM,
                uint128(longAmounts.leftSlot() + shortAmounts.leftSlot()) * 2,
                10
            );
        }
        {
            assertEq(pp.positionsHash(Alice), 0);

            assertEq(pp.numberOfPositions(Alice), 0);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pp
                .optionPositionBalance(Alice, tokenId);

            assertEq(balance, 0);
            assertEq(poolUtilization0, 0);
            assertEq(poolUtilization1, 0);
        }

        {
            $balanceDelta0 = int256(exerciseFeeAmounts[0]) - $intrinsicValue0 + $expectedPremia0;

            $balanceDelta0 = $balanceDelta0 > 0
                ? int256(uint256($balanceDelta0))
                : -int256(uint256(-$balanceDelta0));

            $balanceDelta1 = int256(exerciseFeeAmounts[1]) - $intrinsicValue1 + $expectedPremia1;

            $balanceDelta1 = $balanceDelta1 > 0
                ? int256(uint256($balanceDelta1))
                : -int256(uint256(-$balanceDelta1));

            assertApproxEqAbs(
                ct0.convertToAssets(ct0.balanceOf(Alice)),
                uint256(int256(lastCollateralBalance0[Alice]) + $balanceDelta0),
                uint256(
                    int256((longAmounts.rightSlot() + shortAmounts.rightSlot()) / 1_000_000 + 10)
                )
            );
            assertApproxEqAbs(
                ct1.convertToAssets(ct1.balanceOf(Alice)),
                uint256(int256(lastCollateralBalance1[Alice]) + $balanceDelta1),
                uint256(int256((longAmounts.leftSlot() + shortAmounts.leftSlot()) / 1_000_000 + 10))
            );
        }
    }

    function test_Success_forceExercise_BurningOpenPosition(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        int24 TWAPtick = pp.getUniV3TWAP_();

        // make sure position is exercisable
        vm.assume(TWAPtick < tickLower || TWAPtick >= tickUpper);

        // mint a short leg
        uint256 tokenIdShort = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenIdShort;

        pp.mintOptions(posIdList, uint128(positionSize), 0, 0, 0);

        // mint a long leg to exercise
        uint256 tokenIdLong = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            1,
            0,
            0,
            strike,
            width
        );

        posIdList = new uint256[](2);
        posIdList[0] = tokenIdShort;
        posIdList[1] = tokenIdLong;

        pp.mintOptions(posIdList, uint128(positionSize / 2), type(uint64).max, 0, 0);

        changePrank(Bob);

        posIdList = new uint256[](1);
        posIdList[0] = tokenIdShort;

        // Bob just needs to have any open position, doesn't matter what it is since he will not provide it
        pp.mintOptions(posIdList, uint128(positionSize), 0, 0, 0);

        posIdList = new uint256[](1);
        posIdList[0] = tokenIdLong;

        uint256[] memory idsToBurn = new uint256[](1);
        idsToBurn[0] = tokenIdShort;

        // Bob will now attempt to force exercise Alice.
        // He has an open position, which he provides the list of idsToBurn when he exercises
        // This position is more than enough to cover the exercise fee, so the force exercise should succeed
        pp.forceExercise(Alice, 0, 0, posIdList, idsToBurn);

        // check that both positions are burnt

        (uint128 balance, , ) = pp.optionPositionBalance(Alice, tokenIdLong);
        assertEq(balance, 0);

        (balance, , ) = pp.optionPositionBalance(Bob, tokenIdShort);
        assertEq(balance, 0);
    }

    function test_Fail_forceExercise_InsufficientCollateralDecrease_NoPositions(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        _initPool(x);

        (int24 width, int24 strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        int24 TWAPtick = pp.getUniV3TWAP_();

        // make sure position is exercisable
        vm.assume(TWAPtick < tickLower || TWAPtick >= tickUpper);

        // mint a short leg
        uint256 tokenIdShort = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenIdShort;

        pp.mintOptions(posIdList, uint128(positionSize), 0, 0, 0);

        // mint a long leg to exercise
        uint256 tokenIdLong = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            1,
            0,
            0,
            strike,
            width
        );

        posIdList = new uint256[](2);
        posIdList[0] = tokenIdShort;
        posIdList[1] = tokenIdLong;

        pp.mintOptions(posIdList, uint128(positionSize / 2), type(uint64).max, 0, 0);

        changePrank(Bob);

        posIdList = new uint256[](1);
        posIdList[0] = tokenIdShort;

        // Bob just needs to have any open position, doesn't matter what it is since he will not provide it
        pp.mintOptions(posIdList, uint128(positionSize), 0, 0, 0);

        posIdList = new uint256[](1);
        posIdList[0] = tokenIdLong;

        // Bob will now attempt to force exercise Alice.
        // He has an open position, but he did not provide it in the list of idsToBurn when he exercises
        // Thus, he will experience an overall decrease in buying power due to the exercise fee and our system should revert
        vm.expectRevert(Errors.InsufficientCollateralDecrease.selector);
        pp.forceExercise(Alice, 0, 0, posIdList, new uint256[](0));
    }

    function test_Success_getRefundAmounts(
        uint256 x,
        uint256 balance0,
        uint256 balance1,
        int256 refund0,
        int256 refund1,
        int256 atTick
    ) public {
        _initPool(x);

        balance0 = bound(balance0, 0, type(uint104).max);
        balance1 = bound(balance1, 0, type(uint104).max);
        refund0 = bound(
            refund0,
            -int256(uint256(type(uint104).max)),
            int256(uint256(type(uint104).max))
        );
        refund1 = bound(
            refund1,
            -int256(uint256(type(uint104).max)),
            int256(uint256(type(uint104).max))
        );
        // possible for the amounts used here to overflow beyond these ticks
        // convert0To1 is tested on the full tickrange elsewhere
        atTick = bound(atTick, -159_000, 159_000);

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(int24(atTick));

        changePrank(Charlie);
        ct0.deposit(balance0, Charlie);
        ct1.deposit(balance1, Charlie);

        int256 shortage = refund0 - int(ct0.convertToAssets(ct0.balanceOf(Charlie)));

        if (shortage > 0) {
            int256 refundAmounts = ct0.getRefundAmounts(
                Charlie,
                int256(0).toRightSlot(int128(refund0)).toLeftSlot(int128(refund1)),
                int24(atTick),
                ct1
            );

            refund0 = refund0 - shortage;
            refund1 = PanopticMath.convert0to1(shortage, sqrtPriceX96) + refund1;

            assertEq(refundAmounts.rightSlot(), refund0);
            assertEq(refundAmounts.leftSlot(), refund1);
            // if there is a shortage of token1, it won't be reached since it's only considered possible to have a shortage
            // of one token with force exercises. If there is a shortage of both the account is insolvent and it will fail
            // when trying to transfer the tokens
            return;
        }

        shortage = refund1 - int(ct1.convertToAssets(ct1.balanceOf(Charlie)));

        if (shortage > 0) {
            int256 refundAmounts = ct0.getRefundAmounts(
                Charlie,
                int256(0).toRightSlot(int128(refund0)).toLeftSlot(int128(refund1)),
                int24(atTick),
                ct1
            );

            refund1 = refund1 - shortage;
            refund0 = PanopticMath.convert1to0(shortage, sqrtPriceX96) + refund0;

            assertEq(refundAmounts.rightSlot(), refund0);
            assertEq(refundAmounts.leftSlot(), refund1);
        }
    }

    function test_Fail_forceExercise_1PositionNotSpecified(
        uint256 x,
        uint256[] memory touchedIds
    ) public {
        _initPool(x);

        vm.assume(touchedIds.length != 1);

        vm.expectRevert(Errors.InputListFail.selector);

        pp.forceExercise(Alice, 0, 0, touchedIds, new uint256[](0));
    }

    function test_Fail_forceExercise_PositionNotExercisable(uint256 x) public {
        _initPool(x);

        uint256 tokenId;

        tokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            PanopticMath.twapFilter(pool, 600) - tickSpacing * 2,
            1
        );

        vm.expectRevert(Errors.NoLegsExercisable.selector);

        uint256[] memory touchedIds = new uint256[](1);
        touchedIds[0] = tokenId;
        pp.forceExercise(Alice, 0, 0, touchedIds, new uint256[](0));
    }

    /*//////////////////////////////////////////////////////////////
                                  TWAP
    //////////////////////////////////////////////////////////////*/

    function test_Success_getPriceArray_Initialization(uint256 x, int256 initTick) public {
        initTick = bound(initTick, TickMath.MIN_TICK, TickMath.MAX_TICK);
        _initWorldAtTick(x, int24(initTick));

        (priceArray, medianTick) = pp.getPriceArray();

        int24[8] memory expectedArray = [
            // padding
            TickMath.MIN_TICK - 1,
            TickMath.MAX_TICK + 1,
            TickMath.MIN_TICK - 1,
            TickMath.MAX_TICK + 1,
            TickMath.MIN_TICK - 1,
            TickMath.MAX_TICK + 1,
            // initial tick
            int24(initTick),
            int24(initTick)
        ];

        assertEq(medianTick, int24(initTick));

        for (uint256 i = 0; i < 8; ++i) {
            assertEq(priceArray[i], expectedArray[i]);
        }
    }

    function test_Success_getPriceArray_Poking(
        uint256 x,
        int256[50] memory pokeTicks,
        uint256[50] memory blockTimes
    ) public {
        for (uint256 i = 0; i < 50; ++i) {
            pokeTicks[i] = bound(pokeTicks[i], TickMath.MIN_TICK, TickMath.MAX_TICK);
            blockTimes[i] = bound(blockTimes[i], 0, 21990232555);
        }

        _initWorldAtTick(x, int24(pokeTicks[0]));

        int24[9] memory expectedArray = [
            // padding
            TickMath.MIN_TICK - 1,
            TickMath.MAX_TICK + 1,
            TickMath.MIN_TICK - 1,
            TickMath.MAX_TICK + 1,
            TickMath.MIN_TICK - 1,
            TickMath.MAX_TICK + 1,
            // initial tick
            int24(pokeTicks[0]),
            int24(pokeTicks[0]),
            0
        ];

        uint256 lastTimestamp = block.timestamp;

        for (uint256 i = 1; i < 10; ++i) {
            vm.warp(block.timestamp + blockTimes[i]);

            UniPoolPriceMock(address(pool)).updatePrice(int24(pokeTicks[i]));

            pp.pokeMedian();

            // put new tick into array to be shifted down into main 8 slots
            expectedArray[8] = int24(pokeTicks[i]);
            (priceArray, medianTick) = pp.getPriceArray();
            for (uint256 j = 0; j < 8; ++j) {
                console2.log(expectedArray[j]);
                console2.log(expectedArray[j + 1]);
                console2.log(priceArray[j]);
                console2.log(block.timestamp);
                console2.log(lastTimestamp);
                // only shift array if an update occured, i.e more than 60 seconds passed since the last update
                expectedArray[j] = block.timestamp >= lastTimestamp + 60
                    ? expectedArray[j + 1]
                    : expectedArray[j];
                assertEq(priceArray[j], expectedArray[j]);
                if (priceArray[j] != expectedArray[j]) revert();
            }

            // sort the array using quicksort and verify correctness of the median
            int24[] memory sortedPriceArray = Math.sort(priceArray);

            assertEq(medianTick, (sortedPriceArray[3] + sortedPriceArray[4]) / 2);

            // bump last updated block number if an update occured
            if (block.timestamp >= lastTimestamp + 60) {
                lastTimestamp = block.timestamp;
            }
        }
    }
}
