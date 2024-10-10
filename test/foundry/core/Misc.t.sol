// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {PanopticHelper} from "@test_periphery/PanopticHelper.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {PositionUtils} from "../testUtils/PositionUtils.sol";
import {Math} from "@libraries/Math.sol";
import {Errors} from "@libraries/Errors.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Constants} from "@libraries/Constants.sol";
import {Pointer} from "@types/Pointer.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract ERC20S is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) ERC20(name, symbol, decimals) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SwapperC {
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode the swap callback data, checks that the UniswapV3Pool has the correct address.
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

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
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

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
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
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
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
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

// mostly just fixed one-off tests/PoC
contract Misctest is Test, PositionUtils {
    // the instance of SFPM we are testing
    SemiFungiblePositionManager sfpm;

    // reference implemenatations used by the factory
    address poolReference;

    address collateralReference;

    // Mainnet factory address - SFPM is dependent on this for several checks and callbacks
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    // Mainnet router address - used for swaps to test fees/premia
    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    PanopticFactory factory;
    PanopticPool pp;
    CollateralTracker ct0;
    CollateralTracker ct1;
    PanopticHelper ph;

    int24 currentTick;
    int256 twapTick;
    int24 slowOracleTick;
    int24 fastOracleTick;
    int24 lastObservedTick;

    uint256 medianData;

    uint256 assetsBefore0;
    uint256 assetsBefore1;

    uint256[] assetsBefore0Arr;
    uint256[] assetsBefore1Arr;

    uint256 basalCR;
    uint256 amountBorrowed;
    uint256 amountITM;
    int256 util;
    LeftRightUnsigned amountsMoved;
    uint256 remainingCR;
    uint160 sqrtPriceTargetX96;

    IUniswapV3Pool uniPool;
    ERC20S token0;
    ERC20S token1;

    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Swapper = address(0x123456789);
    address Charlie = address(0x1234567891);
    address Seller = address(0x12345678912);
    address Eve = address(0x123456789123);

    address[] Buyers;
    address[] Buyer;
    SwapperC swapperc;

    TokenId[] $setupIdList;
    TokenId[] $posIdList;
    TokenId[][] $posIdLists;
    TokenId[] $tempIdList;

    address[] owners;
    TokenId[] tokenIdsTemp;
    TokenId[][] tokenIds;
    TokenId[][] positionIdLists;
    TokenId[][] collateralIdLists;

    function setUp() public {
        vm.startPrank(Deployer);

        sfpm = new SemiFungiblePositionManager(V3FACTORY);

        ph = new PanopticHelper(sfpm);

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPool(sfpm));
        collateralReference = address(
            new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20_000)
        );
        token0 = new ERC20S("token0", "T0", 18);
        token1 = new ERC20S("token1", "T1", 18);
        uniPool = IUniswapV3Pool(V3FACTORY.createPool(address(token0), address(token1), 500));

        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // This price causes exactly one unit of liquidity to be minted
        // above here reverts b/c 0 liquidity cannot be minted
        IUniswapV3Pool(uniPool).initialize(2 ** 96);

        IUniswapV3Pool(uniPool).increaseObservationCardinalityNext(100);

        // move back to price=1 while generating 100 observations (min required for pool to function)
        for (uint256 i = 0; i < 100; ++i) {
            vm.warp(block.timestamp + 1);
            vm.roll(block.number + 1);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
        }
        swapperc.mint(uniPool, -887270, 887270, 10 ** 18);

        swapperc.swapTo(uniPool, 10 ** 17 * 2 ** 96);

        swapperc.burn(uniPool, -887270, 887270, 10 ** 18);

        _createPanopticPool();

        vm.startPrank(Alice);

        token0.mint(Alice, uint256(type(uint104).max) * 2);
        token1.mint(Alice, uint256(type(uint104).max) * 2);

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();

        token0.approve(address(ct0), type(uint256).max);
        token1.approve(address(ct1), type(uint256).max);

        ct0.deposit(type(uint104).max, Alice);
        ct1.deposit(type(uint104).max, Alice);

        vm.startPrank(Bob);

        token0.mint(Bob, type(uint104).max);
        token1.mint(Bob, type(uint104).max);

        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        ct0.deposit(type(uint104).max, Bob);
        ct1.deposit(type(uint104).max, Bob);

        vm.startPrank(Charlie);

        token0.mint(Charlie, type(uint104).max);
        token1.mint(Charlie, type(uint104).max);

        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        ct0.deposit(type(uint104).max, Charlie);
        ct1.deposit(type(uint104).max, Charlie);

        vm.startPrank(Seller);

        token0.mint(Seller, type(uint104).max / 1_000_000);
        token1.mint(Seller, type(uint104).max / 1_000_000);

        token0.approve(address(ct0), type(uint104).max / 1_000_000);
        token1.approve(address(ct1), type(uint104).max / 1_000_000);

        ct0.deposit(type(uint104).max / 1_000_000, Seller);
        ct1.deposit(type(uint104).max / 1_000_000, Seller);

        for (uint256 i = 0; i < 3; i++) {
            Buyers.push(address(uint160(uint256(keccak256(abi.encodePacked(i + 1337))))));

            vm.startPrank(Buyers[i]);

            token0.mint(Buyers[i], type(uint104).max / 1_000_000);
            token1.mint(Buyers[i], type(uint104).max / 1_000_000);

            token0.approve(address(ct0), type(uint104).max / 1_000_000);
            token1.approve(address(ct1), type(uint104).max / 1_000_000);

            ct0.deposit(type(uint104).max / 1_000_000, Buyers[i]);
            ct1.deposit(type(uint104).max / 1_000_000, Buyers[i]);
        }

        // // setup mini-median price array
        // for (uint256 i = 0; i < 8; ++i) {
        //     vm.warp(block.timestamp + 120);
        //     vm.roll(block.number + 1);
        //     pp.pokeMedian();
        // }

        for (uint256 i = 0; i < 20; ++i) {
            $posIdLists.push(new TokenId[](0));
        }
    }

    function _createPanopticPool() internal {
        vm.startPrank(Deployer);

        factory = new PanopticFactory(
            address(token1),
            sfpm,
            V3FACTORY,
            poolReference,
            collateralReference,
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );

        token0.mint(Deployer, type(uint104).max);
        token1.mint(Deployer, type(uint104).max);
        token0.approve(address(factory), type(uint104).max);
        token1.approve(address(factory), type(uint104).max);

        pp = PanopticPool(
            address(
                factory.deployNewPool(
                    address(token0),
                    address(token1),
                    500,
                    uint96(block.timestamp),
                    type(uint256).max,
                    type(uint256).max
                )
            )
        );

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, 2 ** 96);

        // Update median
        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();
    }

    // Test that risk-partnered positions can be minted/burned succesfully
    function test_success_MintBurnStraddle() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(0, 1, 1, 0, 0, 1, 15, 1)
                .addLeg(1, 1, 1, 0, 1, 0, 15, 1)
        );

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    function test_success_MintBurnStrangle() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(0, 1, 1, 0, 0, 1, 15, 1)
                .addLeg(1, 1, 1, 0, 1, 0, -15, 1)
        );

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    function test_fail_mint0liquidity_SFPM() public {
        vm.startPrank(Seller);

        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                0,
                0,
                0,
                0,
                -224040,
                3540
            )
        );

        vm.expectRevert(Errors.ZeroLiquidity.selector);
        pp.mintOptions($posIdList, 537, 0, Constants.MIN_V3POOL_TICK, Constants.MAX_V3POOL_TICK);

        pp.mintOptions(
            $posIdList,
            2_000_000,
            0,
            Constants.MIN_V3POOL_TICK,
            Constants.MAX_V3POOL_TICK
        );

        vm.startPrank(Alice);
        $posIdList[0] = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
            0,
            1,
            0,
            1,
            0,
            0,
            -224040,
            3540
        );

        vm.expectRevert(Errors.ZeroLiquidity.selector);
        pp.mintOptions($posIdList, 537, 0, Constants.MIN_V3POOL_TICK, Constants.MAX_V3POOL_TICK);
    }

    function test_success_MintBurnCallSpread() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        vm.startPrank(Seller);

        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                35,
                1
            )
        );

        pp.mintOptions(
            $posIdList,
            2_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // mint OTM position
        $posIdList[0] = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, 1, 0, 0, 1, 15, 1)
            .addLeg(1, 1, 1, 1, 0, 0, 35, 1);

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            type(uint64).max,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    function test_success_MintBurnPutSpread() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        vm.startPrank(Seller);

        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                -35,
                1
            )
        );

        pp.mintOptions(
            $posIdList,
            2_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // mint OTM position
        $posIdList[0] = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, 1, 0, 1, 1, -15, 1)
            .addLeg(1, 1, 1, 1, 1, 0, -35, 1);

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            type(uint64).max,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    // are delegations for ITM positions sufficient?
    function test_success_exercise_crossDelegate() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Seller);

        pp.mintOptions(
            $posIdList,
            2_000_000,
            0,
            Constants.MIN_V3POOL_TICK,
            Constants.MAX_V3POOL_TICK
        );

        $posIdList[0] = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
            0,
            1,
            1,
            1,
            0,
            0,
            15,
            1
        );

        vm.startPrank(Alice);
        pp.mintOptions(
            $posIdList,
            1_000_000,
            type(uint64).max,
            Constants.MIN_V3POOL_TICK,
            Constants.MAX_V3POOL_TICK
        );

        editCollateral(ct1, Alice, 0);

        vm.startPrank(Swapper);

        PanopticMath.twapFilter(uniPool, 600);

        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);

        swapperc.swapTo(uniPool, 10 * 2 ** 96);

        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);

        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        swapperc.burn(uniPool, -10, 10, 10 ** 18);

        PanopticMath.twapFilter(uniPool, 600);

        vm.startPrank(Bob);
        pp.forceExercise(Alice, $posIdList, new TokenId[](0), new TokenId[](0));
    }

    function test_success_ITMspreadfee_0_01bp() public {
        CollateralTracker(collateralReference).startToken(
            true,
            address(token0),
            address(token1),
            1,
            pp
        );

        vm.startPrank(Bob);
        token0.mint(Bob, type(uint104).max);
        token0.approve(collateralReference, type(uint104).max);
        CollateralTracker(collateralReference).deposit(type(uint104).max, Bob);

        vm.startPrank(Alice);
        token0.mint(Alice, (uint256(1_000_000_000_000_000) * 10_000) / 9_990);
        token0.approve(collateralReference, (uint256(1_000_000_000_000_000) * 10_000) / 9_990);
        CollateralTracker(collateralReference).deposit(
            (uint256(1_000_000_000_000_000) * 10_000) / 9_990,
            Alice
        );

        vm.startPrank(address(pp));
        CollateralTracker(collateralReference).takeCommissionAddData(Alice, 0, 0, 1_000_000_000);
        assertEq(
            1_000_000_000_000_000 -
                1 -
                CollateralTracker(collateralReference).convertToAssets(
                    CollateralTracker(collateralReference).balanceOf(Alice)
                ),
            1_000_000_000 + 2000
        );
    }

    function test_parity_maxmint_previewmint() public {
        assertEq(ct0.previewMint(ct0.maxMint(Alice)), type(uint104).max);
    }

    function test_fail_buyAllLiquidity() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        $tempIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                1,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Alice);
        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Bob);

        vm.expectRevert(stdError.divisionError);
        pp.mintOptions(
            $tempIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    // position length in hash should fail instead of overflowing its slot during construction
    function test_fail_validate_longpositionlist() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Alice);
        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        TokenId[] memory longPositionList = new TokenId[](257);

        for (uint256 i; i < 257; ++i) longPositionList[i] = $posIdList[0];

        vm.expectRevert(stdError.arithmeticError);
        pp.mintOptions(
            longPositionList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    // ensure all large mint/deposit amounts revert (instead of overflowing)
    function test_fail_mintmax() public {
        vm.startPrank(Eve);
        token0.mint(Eve, type(uint256).max / 10);
        token1.mint(Eve, type(uint256).max / 10);
        token0.approve(address(ct0), type(uint256).max / 10);
        token1.approve(address(ct0), type(uint256).max / 10);

        vm.expectRevert();
        ct0.mint(type(uint256).max / 10_000 + 1, Eve);

        for (uint256 i = 160; i < 256; ++i) {
            vm.expectRevert();
            ct0.mint(2 ** i - 1, Eve);
        }
    }

    function test_fail_depositmax() public {
        vm.startPrank(Eve);
        token0.mint(Eve, type(uint256).max / 10);
        token1.mint(Eve, type(uint256).max / 10);
        token0.approve(address(ct0), type(uint256).max / 10);
        token1.approve(address(ct0), type(uint256).max / 10);

        vm.expectRevert();
        ct0.deposit(type(uint256).max / 10_000 + 1, Eve);

        for (uint256 i = 105; i < 256; ++i) {
            vm.expectRevert();
            ct0.deposit(2 ** i - 1, Eve);
        }
    }

    // total owed/grossPremiumLast should not change when positions with 0 premia are minted/burnt
    function test_settledtracking_premia0() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        $tempIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        $tempIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                1,
                0,
                0,
                15,
                1
            )
        );

        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);
        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Bob);
        pp.mintOptions(
            $posIdList,
            1_000_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        pp.mintOptions(
            $tempIdList,
            900_000_000,
            type(uint64).max,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);

        accruePoolFeesInRange(
            address(uniPool),
            uniPool.liquidity() - 1,
            1_000_000_000_000_000_000_000,
            1_000_000_000_000
        );
        swapperc.swapTo(uniPool, 2 ** 96);

        uint256 snap = vm.snapshot();
        vm.startPrank(Charlie);

        for (uint256 i = 0; i < 10; i++) {
            pp.mintOptions(
                $posIdList,
                250_000_000,
                type(uint64).max,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            pp.burnOptions(
                $posIdList[0],
                new TokenId[](0),
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );
        }

        vm.startPrank(Alice);
        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        uint256 delta0 = ct0.convertToAssets(ct0.balanceOf(Alice)) - assetsBefore0;
        uint256 delta1 = ct1.convertToAssets(ct1.balanceOf(Alice)) - assetsBefore1;
        vm.revertTo(snap);

        vm.startPrank(Alice);
        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // there is a small amount of error in token0 -- this is the commissions from Charlie
        assertApproxEqAbs(
            delta0,
            ct0.convertToAssets(ct0.balanceOf(Alice)) - assetsBefore0,
            3_000_000
        );
        assertEq(delta1, ct1.convertToAssets(ct1.balanceOf(Alice)) - assetsBefore1);
    }

    // these tests are PoCs for rounding issues in the premium distribution
    // to demonstrate the issue log the settled, gross, and owed premia at burn
    function test_settledPremiumDistribution_demoInflatedGross() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        $tempIdList = $posIdList;

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                1,
                0,
                0,
                15,
                1
            )
        );

        // the collectedAmount will always be a round number, so it's actually not possible to get a greater grossPremium than sum(collected, owed)
        // (owed and gross are both calculated from collectedAmount)
        for (uint256 i = 0; i < 1000; i++) {
            vm.startPrank(Alice);
            $tempIdList[0] = $posIdList[1];
            pp.mintOptions(
                $tempIdList,
                250_000,
                type(uint64).max,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            vm.startPrank(Bob);
            pp.mintOptions(
                $posIdList,
                250_000,
                type(uint64).max,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            vm.startPrank(Swapper);
            swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);
            // 1998600539
            accruePoolFeesInRange(address(uniPool), (uniPool.liquidity() * 2) / 3, 1, 1);
            swapperc.swapTo(uniPool, 2 ** 96);

            vm.startPrank(Bob);
            $tempIdList[0] = $posIdList[0];
            pp.burnOptions(
                $posIdList[1],
                $tempIdList,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            vm.startPrank(Alice);
            pp.burnOptions(
                $posIdList[1],
                new TokenId[](0),
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );
        }

        vm.startPrank(Bob);
        // burn Bob's short option
        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    function test_settledPremiumDistribution_demoInflatedOwed() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        $tempIdList = $posIdList;

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                1,
                0,
                0,
                15,
                1
            )
        );

        // only 20 tokens actually settled, but 22 owed... 2 tokens taken from PLPs
        // we may need to redefine availablePremium as max(availablePremium, settledTokens)
        for (uint256 i = 0; i < 10; i++) {
            pp.mintOptions(
                $posIdList,
                499_999,
                type(uint64).max,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );
            vm.startPrank(Swapper);
            swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);
            // 1998600539
            accruePoolFeesInRange(address(uniPool), uniPool.liquidity() - 1, 1, 1);
            swapperc.swapTo(uniPool, 2 ** 96);
            vm.startPrank(Bob);
            pp.burnOptions(
                $posIdList[1],
                $tempIdList,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );
        }

        // burn Bob's short option
        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    function test_success_settleLongPremium() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // sell primary chunk
        $posIdLists[0].push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        // mint some amount of liquidity with Alice owning 1/2 and Bob and Charlie owning 1/4 respectively
        // then, remove 9.737% of that liquidity at the same ratio
        // Once this state is in place, accumulate some amount of fees on the existing liquidity in the pool
        // The fees should be immediately available for withdrawal because they have been paid to liquidity already in the pool
        // 8.896% * 1.022x vegoid = +~10% of the fee amount accumulated will be owed by sellers
        vm.startPrank(Alice);

        pp.mintOptions(
            $posIdLists[0],
            500_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdLists[0],
            250_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Charlie);

        pp.mintOptions(
            $posIdLists[0],
            250_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // sell unrelated, non-overlapping, dummy chunk (to buy for match testing)
        vm.startPrank(Seller);

        $posIdLists[1].push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                -15,
                1
            )
        );

        pp.mintOptions(
            $posIdLists[1],
            1_000_000_000 - 9_884_444 * 3,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // position type A: 1-leg long primary
        $posIdLists[2].push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                1,
                0,
                0,
                15,
                1
            )
        );

        for (uint256 i = 0; i < Buyers.length; ++i) {
            vm.startPrank(Buyers[i]);
            pp.mintOptions(
                $posIdLists[2],
                9_884_444,
                type(uint64).max,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );
        }

        // position type B: 2-leg long primary and long dummy
        $posIdLists[2].push(
            TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(0, 1, 1, 1, 0, 0, 15, 1)
                .addLeg(1, 1, 1, 1, 1, 1, -15, 1)
        );

        for (uint256 i = 0; i < Buyers.length; ++i) {
            vm.startPrank(Buyers[i]);
            pp.mintOptions(
                $posIdLists[2],
                9_884_444,
                type(uint64).max,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );
        }

        // position type C: 2-leg long primary and short dummy
        $posIdLists[2].push(
            TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(0, 1, 1, 1, 0, 0, 15, 1)
                .addLeg(1, 1, 1, 0, 1, 1, -15, 1)
        );

        for (uint256 i = 0; i < Buyers.length; ++i) {
            vm.startPrank(Buyers[i]);
            pp.mintOptions(
                $posIdLists[2],
                9_884_444,
                type(uint64).max,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );
        }

        // position type D: 1-leg long dummy
        $posIdLists[2].push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                1,
                1,
                0,
                -15,
                1
            )
        );

        for (uint256 i = 0; i < Buyers.length; ++i) {
            vm.startPrank(Buyers[i]);
            pp.mintOptions(
                $posIdLists[2],
                19_768_888,
                type(uint64).max,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );
        }

        // populate collateralIdLists with each ending at a different token
        {
            $posIdLists[3] = $posIdLists[2];
            $posIdLists[3][0] = $posIdLists[2][3];
            $posIdLists[3][3] = $posIdLists[2][0];
            collateralIdLists.push($posIdLists[3]);
            $posIdLists[3] = $posIdLists[2];
            $posIdLists[3][1] = $posIdLists[2][3];
            $posIdLists[3][3] = $posIdLists[2][1];
            collateralIdLists.push($posIdLists[3]);
            $posIdLists[3] = $posIdLists[2];
            $posIdLists[3][2] = $posIdLists[2][3];
            $posIdLists[3][3] = $posIdLists[2][2];
            collateralIdLists.push($posIdLists[3]);
            collateralIdLists.push($posIdLists[2]);
        }

        vm.startPrank(Swapper);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);

        // There are some precision issues with this (1B is not exactly 1B) but close enough to see the effects
        accruePoolFeesInRange(address(uniPool), uniPool.liquidity() - 1, 1_000_000, 1_000_000_000);
        console2.log("liquidity", uniPool.liquidity());

        // accumulate lower order of fees on dummy chunk
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-10));

        accruePoolFeesInRange(address(uniPool), uniPool.liquidity() - 1, 10_000, 100_000);
        console2.log("liquidity", uniPool.liquidity());

        swapperc.swapTo(uniPool, 2 ** 96);
        {
            (, currentTick, , , , , ) = uniPool.slot0();
            LeftRightUnsigned accountLiquidityPrimary = sfpm.getAccountLiquidity(
                address(uniPool),
                address(pp),
                0,
                10,
                20
            );
            console2.log(
                "accountLiquidityPrimaryShort",
                accountLiquidityPrimary.rightSlot() + accountLiquidityPrimary.leftSlot()
            );
            console2.log("accountLiquidityPrimaryRemoved", accountLiquidityPrimary.leftSlot());

            (uint256 shortPremium0Primary, uint256 shortPremium1Primary) = sfpm.getAccountPremium(
                address(uniPool),
                address(pp),
                0,
                10,
                20,
                currentTick,
                0
            );

            console2.log(
                "shortPremium0Primary",
                (shortPremium0Primary *
                    (accountLiquidityPrimary.rightSlot() + accountLiquidityPrimary.leftSlot())) /
                    2 ** 64
            );
            console2.log(
                "shortPremium1Primary",
                (shortPremium1Primary *
                    (accountLiquidityPrimary.rightSlot() + accountLiquidityPrimary.leftSlot())) /
                    2 ** 64
            );

            (uint256 longPremium0Primary, uint256 longPremium1Primary) = sfpm.getAccountPremium(
                address(uniPool),
                address(pp),
                0,
                10,
                20,
                currentTick,
                1
            );

            console2.log(
                "longPremium0Primary",
                (longPremium0Primary * accountLiquidityPrimary.leftSlot()) / 2 ** 64
            );
            console2.log(
                "longPremium1Primary",
                (longPremium1Primary * accountLiquidityPrimary.leftSlot()) / 2 ** 64
            );
        }

        {
            LeftRightUnsigned accountLiquidityDummy = sfpm.getAccountLiquidity(
                address(uniPool),
                address(pp),
                1,
                -20,
                -10
            );

            console2.log(
                "accountLiquidityDummyShort",
                accountLiquidityDummy.rightSlot() + accountLiquidityDummy.leftSlot()
            );
            console2.log("accountLiquidityDummyRemoved", accountLiquidityDummy.leftSlot());

            (uint256 shortPremium0Dummy, uint256 shortPremium1Dummy) = sfpm.getAccountPremium(
                address(uniPool),
                address(pp),
                1,
                -20,
                -10,
                0,
                0
            );

            console2.log(
                "shortPremium0Dummy",
                (shortPremium0Dummy *
                    (accountLiquidityDummy.rightSlot() + accountLiquidityDummy.leftSlot())) /
                    2 ** 64
            );
            console2.log(
                "shortPremium1Dummy",
                (shortPremium1Dummy *
                    (accountLiquidityDummy.rightSlot() + accountLiquidityDummy.leftSlot())) /
                    2 ** 64
            );

            (uint256 longPremium0Dummy, uint256 longPremium1Dummy) = sfpm.getAccountPremium(
                address(uniPool),
                address(pp),
                1,
                -20,
                -10,
                0,
                1
            );

            console2.log(
                "longPremium0Dummy",
                (longPremium0Dummy * accountLiquidityDummy.leftSlot()) / 2 ** 64
            );
            console2.log(
                "longPremium1Dummy",
                (longPremium1Dummy * accountLiquidityDummy.leftSlot()) / 2 ** 64
            );
        }

        // >>> s1p = 1100030357
        // >>> l1p = 100030357
        // >>> s1c = 1_000_000_000
        // >>> l1p//3
        // 33343452
        // >>> (s1c+l1p/3)*(0.25*s1p)//(s1p)
        // 258335863.0 (Bob)
        // >>> 258335863.0*2
        // 516671726.0 (Alice)

        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Buyers[0]));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Buyers[0]));

        // collect buyer 1's three relevant chunks
        for (uint256 i = 0; i < 3; ++i) {
            pp.settleLongPremium(collateralIdLists[i], Buyers[0], 0);
        }

        assertEq(
            assetsBefore0 - ct0.convertToAssets(ct0.balanceOf(Buyers[0])),
            33_342,
            "Incorrect Buyer 1 1st Collect 0"
        );

        assertEq(
            assetsBefore1 - ct1.convertToAssets(ct1.balanceOf(Buyers[0])),
            33_343_452,
            "Incorrect Buyer 1 1st Collect 1"
        );

        vm.startPrank(Bob);

        // burn Bob's position, should get 25% of fees paid (no long fees avail.)
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Bob));

        pp.burnOptions(
            $posIdLists[0][0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Bob)) - assetsBefore0,
            258_334,
            "Incorrect Bob Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Bob)) - assetsBefore1,
            258_335_862,
            "Incorrect Bob Delta 1"
        );

        // sell unrelated, non-overlapping, dummy chunk to replenish removed liquidity
        vm.startPrank(Seller);

        $posIdLists[1].push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        pp.mintOptions(
            $posIdLists[1],
            1_000_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        assetsBefore0Arr.push(ct0.convertToAssets(ct0.balanceOf(Buyers[0])));
        assetsBefore1Arr.push(ct1.convertToAssets(ct1.balanceOf(Buyers[0])));
        assetsBefore0Arr.push(ct0.convertToAssets(ct0.balanceOf(Buyers[1])));
        assetsBefore1Arr.push(ct1.convertToAssets(ct1.balanceOf(Buyers[1])));
        assetsBefore0Arr.push(ct0.convertToAssets(ct0.balanceOf(Buyers[2])));
        assetsBefore1Arr.push(ct1.convertToAssets(ct1.balanceOf(Buyers[2])));

        // now, settle the dummy chunks for all the buyers/positions and see that the settled ratio for primary doesn't change

        for (uint256 i = 0; i < Buyers.length; ++i) {
            pp.settleLongPremium(collateralIdLists[1], Buyers[i], 1);

            pp.settleLongPremium(collateralIdLists[3], Buyers[i], 0);
        }

        assertEq(
            assetsBefore0Arr[0] - ct0.convertToAssets(ct0.balanceOf(Buyers[0])),
            333,
            "Incorrect Buyer 1 2nd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[0] - ct1.convertToAssets(ct1.balanceOf(Buyers[0])),
            3_333,
            "Incorrect Buyer 1 2nd Collect 1"
        );

        assertEq(
            assetsBefore0Arr[1] - ct0.convertToAssets(ct0.balanceOf(Buyers[1])),
            333,
            "Incorrect Buyer 2 2nd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[1] - ct1.convertToAssets(ct1.balanceOf(Buyers[1])),
            3_333,
            "Incorrect Buyer 2 2nd Collect 1"
        );

        assertEq(
            assetsBefore0Arr[2] - ct0.convertToAssets(ct0.balanceOf(Buyers[2])),
            333,
            "Incorrect Buyer 3 2nd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[2] - ct1.convertToAssets(ct1.balanceOf(Buyers[2])),
            3_333,
            "Incorrect Buyer 3 2nd Collect 1"
        );

        vm.startPrank(Alice);

        // burn Alice's position
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        pp.burnOptions(
            $posIdLists[0][0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Alice)) - assetsBefore0,
            516_670,
            "Incorrect Alice Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Alice)) - assetsBefore1,
            516_671_726,
            "Incorrect Alice Delta 1"
        );

        // try collecting all the dummy chunks again - see that no additional premium is collected
        assetsBefore0Arr[0] = ct0.convertToAssets(ct0.balanceOf(Buyers[0]));
        assetsBefore1Arr[0] = ct1.convertToAssets(ct1.balanceOf(Buyers[0]));
        assetsBefore0Arr[1] = ct0.convertToAssets(ct0.balanceOf(Buyers[1]));
        assetsBefore1Arr[1] = ct1.convertToAssets(ct1.balanceOf(Buyers[1]));
        assetsBefore0Arr[2] = ct0.convertToAssets(ct0.balanceOf(Buyers[2]));
        assetsBefore1Arr[2] = ct1.convertToAssets(ct1.balanceOf(Buyers[2]));

        for (uint256 i = 0; i < Buyers.length; ++i) {
            pp.settleLongPremium(collateralIdLists[1], Buyers[i], 1);

            pp.settleLongPremium(collateralIdLists[3], Buyers[i], 0);
        }

        assertEq(
            assetsBefore0Arr[0] - ct0.convertToAssets(ct0.balanceOf(Buyers[0])),
            0,
            "Incorrect Buyer 1 3rd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[0] - ct1.convertToAssets(ct1.balanceOf(Buyers[0])),
            0,
            "Incorrect Buyer 1 3rd Collect 1"
        );

        assertEq(
            assetsBefore0Arr[1] - ct0.convertToAssets(ct0.balanceOf(Buyers[1])),
            0,
            "Incorrect Buyer 2 3rd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[1] - ct1.convertToAssets(ct1.balanceOf(Buyers[1])),
            0,
            "Incorrect Buyer 2 3rd Collect 1"
        );

        assertEq(
            assetsBefore0Arr[2] - ct0.convertToAssets(ct0.balanceOf(Buyers[2])),
            0,
            "Incorrect Buyer 3 3rd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[2] - ct1.convertToAssets(ct1.balanceOf(Buyers[2])),
            0,
            "Incorrect Buyer 3 3rd Collect 1"
        );

        // now, collect the rest of the long (primary) legs, premium should be collected from 2nd & 3rd buyers
        assetsBefore0Arr[0] = ct0.convertToAssets(ct0.balanceOf(Buyers[0]));
        assetsBefore1Arr[0] = ct1.convertToAssets(ct1.balanceOf(Buyers[0]));
        assetsBefore0Arr[1] = ct0.convertToAssets(ct0.balanceOf(Buyers[1]));
        assetsBefore1Arr[1] = ct1.convertToAssets(ct1.balanceOf(Buyers[1]));
        assetsBefore0Arr[2] = ct0.convertToAssets(ct0.balanceOf(Buyers[2]));
        assetsBefore1Arr[2] = ct1.convertToAssets(ct1.balanceOf(Buyers[2]));

        for (uint256 i = 0; i < Buyers.length; ++i) {
            pp.settleLongPremium(collateralIdLists[0], Buyers[i], 0);

            pp.settleLongPremium(collateralIdLists[1], Buyers[i], 0);

            pp.settleLongPremium(collateralIdLists[2], Buyers[i], 0);
        }

        assertEq(
            assetsBefore0Arr[0] - ct0.convertToAssets(ct0.balanceOf(Buyers[0])),
            0,
            "Incorrect Buyer 1 4th Collect 0"
        );

        assertEq(
            assetsBefore1Arr[0] - ct1.convertToAssets(ct1.balanceOf(Buyers[0])),
            0,
            "Incorrect Buyer 1 4th Collect 1"
        );

        assertEq(
            assetsBefore0Arr[1] - ct0.convertToAssets(ct0.balanceOf(Buyers[1])),
            33_342,
            "Incorrect Buyer 2 4th Collect 0"
        );

        assertEq(
            assetsBefore1Arr[1] - ct1.convertToAssets(ct1.balanceOf(Buyers[1])),
            33_343_452,
            "Incorrect Buyer 2 4th Collect 1"
        );

        assertEq(
            assetsBefore0Arr[2] - ct0.convertToAssets(ct0.balanceOf(Buyers[2])),
            33_342,
            "Incorrect Buyer 3 4th Collect 0"
        );

        assertEq(
            assetsBefore1Arr[2] - ct1.convertToAssets(ct1.balanceOf(Buyers[2])),
            33_343_452,
            "Incorrect Buyer 3 4th Collect 1"
        );

        vm.startPrank(Charlie);

        // Finally, burn Charlie's position, he should get 27.5% (25% + full 10% long paid (* 25% owned))
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Charlie));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Charlie));

        pp.burnOptions(
            $posIdLists[0][0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Charlie)) - assetsBefore0,
            275_006,
            "Incorrect Charlie Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Charlie)) - assetsBefore1,
            275_007_589,
            "Incorrect Charlie Delta 1"
        );

        // test long leg validation
        vm.expectRevert(Errors.NotALongLeg.selector);
        pp.settleLongPremium(collateralIdLists[2], Buyers[0], 1);

        // test positionIdList validation
        // snapshot so we don't have to reset changes to collateralIdLists array
        uint256 snap = vm.snapshot();

        collateralIdLists[0].pop();
        vm.expectRevert(Errors.InputListFail.selector);
        pp.settleLongPremium(collateralIdLists[0], Buyers[0], 0);
        vm.revertTo(snap);

        // test collateral checking (basic)
        for (uint256 i = 0; i < 3; ++i) {
            // snapshot so we don't have to reset changes to collateralIdLists array
            snap = vm.snapshot();

            deal(address(ct0), Buyers[i], i ** 15);
            deal(address(ct1), Buyers[i], i ** 15);
            vm.expectRevert(Errors.AccountInsolvent.selector);
            pp.settleLongPremium(collateralIdLists[0], Buyers[i], 0);
            vm.revertTo(snap);
        }

        // burn all buyer positions - they should pay 0 premium since it has all been settled already
        for (uint256 i = 0; i < Buyers.length; ++i) {
            assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Buyers[i]));
            assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Buyers[i]));
            vm.startPrank(Buyers[i]);
            pp.burnOptions(
                $posIdLists[2],
                new TokenId[](0),
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            // the positive premium is from the dummy short chunk
            assertEq(
                int256(ct0.convertToAssets(ct0.balanceOf(Buyers[i]))) - int256(assetsBefore0),
                i == 0 ? int256(107) : int256(108),
                "Buyer paid premium twice"
            );

            assertEq(
                ct1.convertToAssets(ct1.balanceOf(Buyers[i])) - assetsBefore1,
                1085,
                "Buyer paid premium twice"
            );
        }
    }

    function test_success_settledPremiumDistribution() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        // mint some amount of liquidity with Alice owning 1/2 and Bob and Charlie owning 1/4 respectively
        // then, remove 9.737% of that liquidity at the same ratio
        // Once this state is in place, accumulate some amount of fees on the existing liquidity in the pool
        // The fees should be immediately available for withdrawal because they have been paid to liquidity already in the pool
        // 8.896% * 1.022x vegoid = +~10% of the fee amount accumulated will be owed by sellers
        // First close Bob's position; they should receive 25% of the initial amount because no fees were paid on their position
        // Close half (4.4468%) of the removed liquidity
        // Then close Alice's position, they should receive ~53.3% (50%+ 2/3*5%)
        // Close the other half of the removed liquidity (4.4468%)
        // Finally, close Charlie's position, they should receive ~27.5% (25% + 10% * 25%)
        vm.startPrank(Alice);

        pp.mintOptions(
            $posIdList,
            500_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            250_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Charlie);

        pp.mintOptions(
            $posIdList,
            250_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                1,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Alice);

        // mint finely tuned amount of long options for Alice so premium paid = 1.1x
        pp.mintOptions(
            $posIdList,
            44_468,
            type(uint64).max,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Bob);

        // mint finely tuned amount of long options for Bob so premium paid = 1.1x
        pp.mintOptions(
            $posIdList,
            44_468,
            type(uint64).max,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Swapper);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);

        // There are some precision issues with this (1B is not exactly 1B) but close enough to see the effects
        accruePoolFeesInRange(address(uniPool), uniPool.liquidity() - 1, 1_000_000, 1_000_000_000);

        swapperc.swapTo(uniPool, 2 ** 96);

        vm.startPrank(Bob);

        // burn Bob's position, should get 25% of fees paid (no long fees avail.)
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Bob));

        $tempIdList.push($posIdList[1]);

        // burn Bob's short option
        pp.burnOptions(
            $posIdList[0],
            $tempIdList,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Bob)) - assetsBefore0,
            249_999,
            "Incorrect Bob Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Bob)) - assetsBefore1,
            249_999_999,
            "Incorrect Bob Delta 1"
        );

        // re-mint the short option
        $posIdList[1] = $posIdList[0];
        $posIdList[0] = $tempIdList[0];
        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        $tempIdList[0] = $posIdList[1];

        // Burn the long options, adds 1/2 of the removed liq
        // amount of premia paid = 50_000
        pp.burnOptions(
            $posIdList[0],
            $tempIdList,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Alice);

        // burn Alice's position, should get 53.3̅% of fees paid back (50% + (5% long paid) * (2/3 owned by Alice))
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        $tempIdList[0] = $posIdList[0];
        pp.burnOptions(
            $posIdList[1],
            $tempIdList,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Alice)) - assetsBefore0,
            533_332,
            "Incorrect Alice Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Alice)) - assetsBefore1,
            533_333_345,
            "Incorrect Alice Delta 1"
        );

        // Burn other half of the removed liq
        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Charlie);

        // Finally, burn Charlie's position, he should get 27.5% (25% + full 10% long paid (* 25% owned))
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Charlie));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Charlie));

        pp.burnOptions(
            $posIdList[1],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Charlie)) - assetsBefore0,
            274_999,
            "Incorrect Charlie Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Charlie)) - assetsBefore1,
            275_000_008,
            "Incorrect Charlie Delta 1"
        );
    }

    function test_Success_validateCollateralWithdrawable() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        editCollateral(ct0, Bob, ct0.convertToShares(266263));
        editCollateral(ct1, Bob, 0);

        pp.validateCollateralWithdrawable(Bob, $posIdList);
    }

    function test_Success_WithdrawWithOpenPositions() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        editCollateral(ct0, Bob, ct0.convertToShares(1_000_000));
        editCollateral(ct1, Bob, 0);

        ct0.withdraw(1_000_000 - 266263, Bob, Bob, $posIdList);
    }

    function test_Fail_validateCollateralWithdrawable() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        editCollateral(ct0, Bob, ct0.convertToShares(266262));
        editCollateral(ct1, Bob, 0);

        vm.expectRevert(Errors.AccountInsolvent.selector);
        pp.validateCollateralWithdrawable(Bob, $posIdList);
    }

    function test_Fail_WithdrawWithOpenPositions_AccountInsolvent() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        editCollateral(ct0, Bob, ct0.convertToShares(1_000_000));
        editCollateral(ct1, Bob, 0);

        vm.expectRevert(Errors.AccountInsolvent.selector);
        ct0.withdraw(1_000_000 - 266262, Bob, Bob, $posIdList);
    }

    function test_Fail_InsolventAtCurrentTick_itmPut() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                (0 / tickSpacing) * tickSpacing,
                2
            )
        );

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));

        assertTrue(pp.isSafeMode(), "in safe mode");

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum
        ct0.deposit(100_200, Bob);
        ct1.deposit(0, Bob);

        // mint fails
        vm.expectRevert(Errors.AccountInsolvent.selector);
        //vm.expectRevert();
        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    function test_Fail_InsolventAtCurrentTick_itmCall() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (0 / tickSpacing) * tickSpacing,
                2
            )
        );

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(954));

        assertTrue(pp.isSafeMode(), "in safe mode");

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum - covered
        ct0.deposit(0, Bob);
        ct1.deposit(100_200, Bob);

        // mint fails
        vm.expectRevert(Errors.AccountInsolvent.selector);
        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    function test_Success_InsolventAtCurrentTick_itmPut() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                (0 / tickSpacing) * tickSpacing,
                2
            )
        );

        (, int24 staleTick, , , , , ) = uniPool.slot0();

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-954));

        console2.log("isSafeMode", pp.isSafeMode() ? "safe mode ON" : "safe mode OFF");
        assertTrue(pp.isSafeMode() == false);
        vm.startPrank(Bob);

        uint256 snapshot = vm.snapshot();

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum for naked mints
        ct0.deposit(0, Bob);
        ct1.deposit(17_818, Bob);

        // mint succeeds
        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
        (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            staleTick,
            $posIdList
        );

        assertTrue(totalCollateralBalance0 > totalCollateralRequired0, "Is solvent at stale tick!");

        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );

        console2.log("reqs", totalCollateralBalance0, totalCollateralRequired0);

        assertTrue(
            totalCollateralBalance0 <= totalCollateralRequired0,
            "Is liquidatable at current tick!"
        );

        vm.startPrank(Swapper);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -100000, 100000, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -100000, 100000, 10 ** 18);
        }

        vm.startPrank(Alice);

        deal(ct0.asset(), Alice, 1_000_000);
        deal(ct1.asset(), Alice, 1_000_000);

        IERC20Partial(ct0.asset()).approve(address(ct0), 1_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 1_000_000);

        pp.liquidate(new TokenId[](0), Bob, $posIdList);

        (uint256 after0, uint256 after1) = (
            ct0.convertToAssets(ct0.balanceOf(Bob)),
            ct1.convertToAssets(ct1.balanceOf(Bob))
        );

        assertTrue((after0 > 0) || (after1 > 0), "no protocol loss");

        vm.revertTo(snapshot);

        vm.startPrank(Swapper);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));

        console2.log("isSafeMode", pp.isSafeMode() ? "safe mode ON" : "safe mode OFF");
        assertTrue(pp.isSafeMode());

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum for covered mints
        ct0.deposit(150504, Bob);
        ct1.deposit(0, Bob);

        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        (uint128 balance, uint64 utilization0, uint64 utilization1) = ph.optionPositionInfo(
            pp,
            Bob,
            $posIdList[0]
        );

        assertEq(balance, 100_000);
        assertEq(utilization0, 10_000);
        assertEq(utilization1, 10_000);

        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );

        console2.log("reqs", totalCollateralBalance0, totalCollateralRequired0);
        assertTrue(
            totalCollateralBalance0 >= totalCollateralRequired0,
            "Is solvent at current tick!"
        );
    }

    function test_Success_InsolventAtCurrentTick_itmCall() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (0 / tickSpacing) * tickSpacing,
                2
            )
        );

        (, int24 staleTick, , , , , ) = uniPool.slot0();

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(952));
        console2.log("isSafeMode", pp.isSafeMode() ? "safe mode ON" : "safe mode OFF");
        assertTrue(pp.isSafeMode() == false);

        vm.startPrank(Bob);

        uint256 snapshot = vm.snapshot();

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum for naked mints
        ct0.deposit(0, Bob);
        ct1.deposit(17_820, Bob);

        // mint succeeds
        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
        (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            staleTick,
            $posIdList
        );

        assertTrue(totalCollateralBalance0 > totalCollateralRequired0, "Is solvent at stale tick!");

        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );

        assertTrue(
            totalCollateralBalance0 <= totalCollateralRequired0,
            "Is liquidatable at current tick!"
        );

        vm.startPrank(Swapper);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -100000, 100000, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -100000, 100000, 10 ** 18);
        }

        vm.startPrank(Alice);

        deal(ct0.asset(), Alice, 1_000_000);
        deal(ct1.asset(), Alice, 1_000_000);

        IERC20Partial(ct0.asset()).approve(address(ct0), 1_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 1_000_000);

        pp.liquidate(new TokenId[](0), Bob, $posIdList);

        (uint256 after0, uint256 after1) = (
            ct0.convertToAssets(ct0.balanceOf(Bob)),
            ct1.convertToAssets(ct1.balanceOf(Bob))
        );

        assertTrue((after0 > 0) || (after1 > 0), "no protocol loss");

        vm.revertTo(snapshot);

        vm.startPrank(Swapper);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(953));

        console2.log("isSafeMode", pp.isSafeMode() ? "safe mode ON" : "safe mode OFF");
        assertTrue(pp.isSafeMode());

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum for covered mints
        ct0.deposit(0, Bob);
        ct1.deposit(150466, Bob);

        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        (uint128 balance, uint64 utilization0, uint64 utilization1) = ph.optionPositionInfo(
            pp,
            Bob,
            $posIdList[0]
        );

        assertEq(balance, 100_000);
        assertEq(utilization0, 10_000);
        assertEq(utilization1, 10_000);

        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );

        console2.log("reqs", totalCollateralBalance0, totalCollateralRequired0);
        assertTrue(
            totalCollateralBalance0 >= totalCollateralRequired0,
            "Is solvent at current tick!"
        );
    }

    function test_Fail_WithdrawWithOpenPositions_SolventReceiver_AccountInsolvent() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Bob);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        editCollateral(ct0, Bob, ct0.convertToShares(1_000_000));
        editCollateral(ct1, Bob, 0);

        vm.expectRevert(Errors.AccountInsolvent.selector);
        ct0.withdraw(1_000_000 - 266262, Alice, Bob, $posIdList);
    }

    function test_Success_SafeMode_down() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        assertTrue(pp.isSafeMode() == false, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-953));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        assertTrue(Math.abs(currentTick - slowOracleTick) <= 953, "small price deviation");
        assertTrue(pp.isSafeMode() == false, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-954));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();
        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation");
        assertTrue(pp.isSafeMode(), "in safe mode");
    }

    function test_Success_SafeMode_up() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        assertTrue(pp.isSafeMode() == false, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(953));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        assertTrue(Math.abs(currentTick - slowOracleTick) <= 953, "small price deviation");
        assertTrue(pp.isSafeMode() == false, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(954));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();
        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation");
        assertTrue(pp.isSafeMode(), "in safe mode");
    }

    function test_Success_SafeMode_pokes() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        assertTrue(pp.isSafeMode() == false, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation");
        assertTrue(pp.isSafeMode(), "in safe mode");

        // setup mini-median price array
        for (uint256 i = 0; i < 4; ++i) {
            swapperc.mint(uniPool, -10000, 10000, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10000, 10000, 10 ** 18);
        }

        assertTrue(pp.isSafeMode() == true, "slow oracle tick did not catch up");

        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 1);
        pp.pokeMedian();
        swapperc.burn(uniPool, -10000, 10000, 10 ** 18);

        assertTrue(pp.isSafeMode() == false, "slow oracle tick caught up");
    }

    function test_Success_SafeMode_mint_otm() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        assertTrue(pp.isSafeMode() == false, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-954));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        assertTrue(Math.abs(currentTick - slowOracleTick) <= 953, "small price deviation");
        assertTrue(!pp.isSafeMode(), "not in safe mode");

        int24 tickSpacing = uniPool.tickSpacing();
        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (-900 / tickSpacing) * tickSpacing,
                2
            )
        );

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        uint256 snap = vm.snapshot();

        // deposit only token0
        token0.approve(address(ct0), 1_000_000);
        ct0.deposit(41874, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(0, Bob);

        // not in safeMode, mint with minimum
        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.revertTo(snap);

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));
        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        console2.log("currentTick", currentTick);
        console2.log("slowOracleTick", slowOracleTick);
        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "large price deviation");

        assertTrue(pp.isSafeMode(), "in safe mode");
        vm.startPrank(Bob);

        // deposit only token1
        token0.approve(address(ct0), 1_000_000);
        ct0.deposit(158699, Bob); // 1.3333 * (1.0001**900 * 100000) * (1 + 1 - 1.0001**-1 / 1.0001**900  -> 100 % collateralization, requirement evaluated at tick=-1.
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(0, Bob);

        // can mint covered positions
        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        (uint128 balance, uint64 utilization0, uint64 utilization1) = ph.optionPositionInfo(
            pp,
            Bob,
            $posIdList[0]
        );

        assertEq(balance, 100_000);
        assertEq(utilization0, 10_000);
        assertEq(utilization1, 10_000);
    }

    function test_Success_SafeMode_mint_itm() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        assertTrue(pp.isSafeMode() == false, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation");
        assertTrue(pp.isSafeMode(), "in safe mode");

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (-2500 / tickSpacing) * tickSpacing,
                2
            )
        );

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        // deposit only token0
        token0.approve(address(ct0), 1_000_000);
        ct0.deposit(102_000, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(0, Bob);

        // in safeMode, enforce covered mints, reverts
        vm.expectRevert();
        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        // deposit only token1
        ct0.deposit(0, Bob);
        ct1.deposit(181_183, Bob); //

        // can mint covered positions
        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        (uint128 balance, uint64 utilization0, uint64 utilization1) = ph.optionPositionInfo(
            pp,
            Bob,
            $posIdList[0]
        );

        assertEq(balance, 100_000);
        assertEq(utilization0, 10_000);
        assertEq(utilization1, 10_000);
    }

    function test_Success_SafeMode_burn() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        assertTrue(pp.isSafeMode() == false, "not in safe mode");

        int24 tickSpacing = uniPool.tickSpacing();
        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                (-500 / tickSpacing) * tickSpacing,
                2
            )
        );

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        ct0.deposit(28_000, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(2_000, Bob);

        pp.mintOptions(
            $posIdList,
            100_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation");
        assertTrue(pp.isSafeMode(), "in safe mode");

        vm.startPrank(Bob);

        console2.log("00");
        vm.expectRevert();
        pp.burnOptions(
            $posIdList,
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        uint256 before0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        uint256 before1 = ct1.convertToAssets(ct1.balanceOf(Bob));

        // Add just enough to cover the covered exercise:
        ct1.deposit(98_300, Bob);

        pp.burnOptions(
            $posIdList,
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        uint256 after0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        uint256 after1 = ct1.convertToAssets(ct1.balanceOf(Bob));

        console2.log(before0, before1, after0, after1);
    }

    function test_Success_OraclePoke_mint() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        (, , slowOracleTick, , medianData) = pp.getOracleTicks();

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                4095
            )
        );

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));

        vm.warp(block.timestamp + 59);
        vm.roll(block.number + 1);

        vm.startPrank(Alice);

        pp.mintOptions(
            $posIdList,
            500_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        (, , int24 slowOracleTickStale, , uint256 medianDataStale) = pp.getOracleTicks();

        assertEq(slowOracleTick, slowOracleTickStale, "no slow oracle update");
        assertEq(medianData, medianDataStale, "no slow oracle update");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        pp.mintOptions(
            $posIdList,
            500_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        (, , slowOracleTickStale, , medianDataStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(medianData != medianDataStale, "oracle median data update");

        vm.warp(block.timestamp + 61);
        vm.roll(block.number + 1);
        pp.pokeMedian();

        (, , slowOracleTickStale, , medianDataStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(medianData != medianDataStale, "oracle median data update");

        vm.warp(block.timestamp + 61);
        vm.roll(block.number + 1);
        pp.pokeMedian();

        (, , slowOracleTickStale, , medianDataStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(medianData != medianDataStale, "oracle median data update");

        vm.warp(block.timestamp + 61);
        vm.roll(block.number + 1);
        pp.pokeMedian();

        (, , slowOracleTickStale, , medianDataStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick != slowOracleTickStale, "no slow oracle update");
        assertTrue(medianData != medianDataStale, "oracle median data update");
    }

    function test_Success_OraclePoke_burn() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        (, , slowOracleTick, , medianData) = pp.getOracleTicks();

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                4095
            )
        );

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));

        vm.warp(block.timestamp + 59);
        vm.roll(block.number + 1);

        vm.startPrank(Alice);

        pp.mintOptions(
            $posIdList,
            500_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        (, , int24 slowOracleTickStale, , uint256 medianDataStale) = pp.getOracleTicks();

        assertEq(slowOracleTick, slowOracleTickStale, "no slow oracle update");
        assertEq(medianData, medianDataStale, "no slow oracle update");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        pp.burnOptions(
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        (, , slowOracleTickStale, , medianDataStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(medianData != medianDataStale, "oracle median data updated");

        vm.warp(block.timestamp + 61);
        vm.roll(block.number + 1);
        pp.pokeMedian();

        (, , slowOracleTickStale, , medianDataStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(medianData != medianDataStale, "oracle median data updated");

        vm.warp(block.timestamp + 61);
        vm.roll(block.number + 1);
        pp.pokeMedian();

        (, , slowOracleTickStale, , medianDataStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(medianData != medianDataStale, "oracle median data updated");

        vm.warp(block.timestamp + 61);
        vm.roll(block.number + 1);
        pp.pokeMedian();

        (, , slowOracleTickStale, , medianDataStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick != slowOracleTickStale, "slow oracle updated");
        assertTrue(medianData != medianDataStale, "oracle median data updated");
    }

    function test_success_NotionalRounding() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);
        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                0,
                0,
                1,
                0,
                int24(-665450),
                2
            )
        );

        vm.startPrank(Bob);

        pp.mintOptions($posIdList, 2 ** 95, 0, int24(887272), int24(-887272));

        (, , uint256[2][] memory positionBalanceArray) = pp.calculateAccumulatedFeesBatch(
            Bob,
            false,
            $posIdList
        );

        (, currentTick, , , , , ) = uniPool.slot0();

        LeftRightUnsigned tokenData0 = ct0.getAccountMarginDetails(
            Bob,
            currentTick,
            positionBalanceArray,
            0,
            0
        );

        LeftRightUnsigned tokenData1 = ct1.getAccountMarginDetails(
            Bob,
            currentTick,
            positionBalanceArray,
            0,
            0
        );
        (uint256 balanceCross, uint256 requiredCross) = PanopticMath.getCrossBalances(
            tokenData0,
            tokenData1,
            Math.getSqrtRatioAtTick(currentTick)
        );

        assertTrue(requiredCross > 0, "zero collateral requirement");
        assertTrue(requiredCross <= balanceCross, "account is solvent");

        pp.burnOptions($posIdList[0], new TokenId[](0), int24(887272), int24(-887272));
    }

    function test_success_PremiumRollover() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        TokenId tokenId = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, 1, 0, 0, 0, 0, 4094);

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        vm.startPrank(Bob);
        // mint 1 liquidity unit of wideish centered position
        pp.mintOptions(posIdList, 3, 0, Constants.MAX_V3POOL_TICK, Constants.MIN_V3POOL_TICK);

        vm.startPrank(Swapper);
        swapperc.burn(uniPool, -10, 10, 10 ** 18);

        // L = 2
        uniPool.liquidity();

        // accumulate the maximum fees per liq SFPM supports
        accruePoolFeesInRange(address(uniPool), 1, 2 ** 64 - 1, 0);

        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        vm.startPrank(Bob);
        // works fine
        pp.burnOptions(
            tokenId,
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        uint256 balanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 balanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);

        // lock in almost-overflowed fees per liquidity
        pp.mintOptions(
            posIdList,
            1_000_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Swapper);
        swapperc.burn(uniPool, -10, 10, 10 ** 18);

        // overflow back to ~1_000_000_000_000 (fees per liq)
        accruePoolFeesInRange(address(uniPool), 412639631, 1_000_000_000_000, 1_000_000_000_000);

        // this should behave like the actual accumulator does and rollover, not revert on overflow
        (uint256 premium0, uint256 premium1) = sfpm.getAccountPremium(
            address(uniPool),
            address(pp),
            0,
            -20470,
            20470,
            0,
            0
        );
        assertEq(premium0, 340282366920938463444927863358058659840);
        assertEq(premium1, 44704247211996718928643);

        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        vm.startPrank(Alice);

        // tough luck... PLPs just stole ~2**64 tokens per liquidity Alice had because of an overflow
        // Alice can be frontrun if her transaction goes to a public mempool (or is otherwise anticipated),
        // so the cost of the attack is just ~2**64 * active liquidity (shown here to be as low as 1 even with initial full-range!)
        // + fee to move price initially (if applicable)
        // The solution is to freeze fee accumulation if one of the token accumulators overflow
        pp.burnOptions(
            tokenId,
            new TokenId[](0),
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // make sure Alice earns no fees on token 0 (her delta is slightly negative due to commission fees/precision etc)
        // the accumulator overflowed, so the accumulation was frozen. If she had poked before the accumulator overflowed,
        // she could have still earned some fees, but now the accumulation is frozen forever.
        assertEq(
            int256(ct0.convertToAssets(ct0.balanceOf(Alice))) - int256(balanceBefore0),
            -1244790
        );

        // but she earns all of fees on token 1 since the premium accumulator did not overflow (!)
        assertEq(
            int256(ct1.convertToAssets(ct1.balanceOf(Alice))) - int256(balanceBefore1),
            999_999_999_998
        );
    }

    function test_Success_ReverseIronCondor() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        vm.startPrank(Seller);

        $posIdList.push(
            TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(
                    0,
                    1,
                    1,
                    0,
                    1,
                    0,
                    4055, // 1.5 put
                    1
                )
                .addLeg(
                    1,
                    1,
                    1,
                    0,
                    0,
                    1,
                    -6935, // 0.5 call
                    1
                )
        );

        pp.mintOptions(
            $posIdList,
            2_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // long put = 1.5, short put 1.25, short call 0.75, long call 0.5
        $posIdList[0] = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, 1, 1, 1, 0, 4055, 1)
            .addLeg(1, 1, 1, 0, 1, 1, 2235, 1)
            .addLeg(2, 1, 1, 0, 0, 2, -2875, 1)
            .addLeg(3, 1, 1, 1, 0, 3, -6935, 1);

        uint256 balanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 balanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            type(uint64).max,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // 0.25, 0.6, 0.9, 1.1, 1.4, 1.6
        int16[6] memory ticks = [-13862, -5108, -1053, 952, 3364, 4699];

        for (uint256 i = 0; i < ticks.length; ++i) {
            uint256 snap = vm.snapshot();
            vm.startPrank(Swapper);
            swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(ticks[i]));

            vm.startPrank(Alice);
            pp.burnOptions(
                $posIdList[0],
                new TokenId[](0),
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            console2.log(
                "balance0Delta",
                int256(ct0.convertToAssets(ct0.balanceOf(Alice))) - int256(balanceBefore0)
            );
            console2.log(
                "balance1Delta",
                int256(ct1.convertToAssets(ct1.balanceOf(Alice))) - int256(balanceBefore1)
            );
            vm.revertTo(snap);
        }
    }

    function test_Success_CallCondor() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeMedian();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        vm.startPrank(Seller);

        $posIdList.push(
            TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(
                    0,
                    1,
                    1,
                    0,
                    0,
                    0,
                    2235, // 1.25 call
                    1
                )
                .addLeg(
                    1,
                    1,
                    1,
                    0,
                    0,
                    1,
                    6935, // 2 call
                    1
                )
        );

        pp.mintOptions(
            $posIdList,
            2_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // long call = 1.25, short call = 1.5, short call = 1.75, long call = 2
        $posIdList[0] = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, 1, 1, 0, 0, 2235, 1)
            .addLeg(1, 1, 1, 0, 0, 1, 4055, 1)
            .addLeg(2, 1, 1, 0, 0, 2, 5595, 1)
            .addLeg(3, 1, 1, 1, 0, 3, 6935, 1);

        uint256 balanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 balanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            type(uint64).max,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // 1.3, 1.6, 1.8, 2.1
        uint16[4] memory ticks = [2623, 4699, 5877, 7419];

        for (uint256 i = 0; i < ticks.length; ++i) {
            uint256 snap = vm.snapshot();
            vm.startPrank(Swapper);
            swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(int16(ticks[i])));

            vm.startPrank(Alice);
            pp.burnOptions(
                $posIdList[0],
                new TokenId[](0),
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            console2.log(
                "balance0Delta",
                int256(ct0.convertToAssets(ct0.balanceOf(Alice))) - int256(balanceBefore0)
            );
            console2.log(
                "balance1Delta",
                int256(ct1.convertToAssets(ct1.balanceOf(Alice))) - int256(balanceBefore1)
            );
            vm.revertTo(snap);
        }
    }

    function test_Success_PutCondor() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        vm.startPrank(Seller);

        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                -13_865, // 0.25 put
                1
            )
        );

        pp.mintOptions(
            $posIdList,
            2_000_000,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // long put = 0.25, short put = 0.5, short put = 0.75, short call = 0.9
        $posIdList[0] = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, 1, 1, 1, 0, -13_865, 1)
            .addLeg(1, 1, 1, 0, 1, 1, -6935, 1)
            .addLeg(2, 1, 1, 0, 1, 2, -2875, 1)
            .addLeg(3, 1, 1, 0, 0, 3, -1055, 1);

        uint256 balanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 balanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);

        pp.mintOptions(
            $posIdList,
            1_000_000,
            type(uint64).max,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        // 0.2, 0.4, 0.6, 0.8, 1.1
        int16[5] memory ticks = [-16093, -9162, -5108, -2231, 952];

        for (uint256 i = 0; i < ticks.length; ++i) {
            uint256 snap = vm.snapshot();
            vm.startPrank(Swapper);
            swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(ticks[i]));

            vm.startPrank(Alice);
            pp.burnOptions(
                $posIdList[0],
                new TokenId[](0),
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            console2.log(
                "balance0Delta",
                int256(ct0.convertToAssets(ct0.balanceOf(Alice))) - int256(balanceBefore0)
            );
            console2.log(
                "balance1Delta",
                int256(ct1.convertToAssets(ct1.balanceOf(Alice))) - int256(balanceBefore1)
            );
            vm.revertTo(snap);
        }
    }

    function test_success_liquidate_100p_protocolLoss() public {
        _createPanopticPool();
        vm.startPrank(Alice);

        token1.mint(Alice, 1_000_000);

        token1.approve(address(ct1), 1_000_000);

        ct1.deposit(1_000_000, Alice);

        vm.startPrank(Bob);

        token0.mint(Bob, type(uint104).max);

        token0.approve(address(ct0), type(uint104).max);

        ct0.deposit(1_500_000, Bob);

        token1.mint(Bob, 1_005);
        token1.approve(address(ct1), 1_005);
        ct1.deposit(1_005, Bob);

        vm.startPrank(Charlie);
        token1.mint(Charlie, 1_003_003);
        token1.approve(address(ct1), 1_003_003);

        ct1.deposit(1_003_003, Charlie);

        vm.startPrank(Bob);

        $posIdList.push(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool))).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                -15,
                1
            )
        );

        uint256 totalSupplyBefore = ct1.totalSupply() - ct1.convertToShares(1_003_003);

        pp.mintOptions(
            $posIdList,
            1_003_003,
            0,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-800_000));

        for (uint256 j = 0; j < 100; ++j) {
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 10);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 10);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 10);
        }

        vm.startPrank(Charlie);
        pp.liquidate(new TokenId[](0), Bob, $posIdList);

        assertLe(ct1.totalSupply() / totalSupplyBefore, 10_000, "protocol loss failed to cap");
    }

    function test_success_liquidation_fuzzedSwapITM(uint256[4] memory prices) public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -887270, 887270, 10 ** 24);

        // L = 1
        uniPool.liquidity();

        uint256 snapshot = vm.snapshot();

        /// @dev single leg, liquidation through price move making options ITM, no-cross collateral
        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;
            TokenId tokenId = TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(0, 1, asset, 0, tokenType, 0, 0, 2);

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
            } else {
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            // get base (OTM) collateral requirement for the position we just minted
            // uint256 basalCR;

            // amount of tokens borrowed to create position -- also amount of tokenType when OTM
            // uint256 amountBorrowed;

            // amount of other token when deep ITM
            // uint256 amountITM;
            (, , uint256 _utilization) = tokenType == 0 ? ct0.getPoolData() : ct1.getPoolData();

            util = int256(_utilization);
            amountsMoved = PanopticMath.getAmountsMoved(tokenId, 3000, 0);
            (amountBorrowed, amountITM) = tokenType == 0
                ? (amountsMoved.rightSlot(), amountsMoved.leftSlot())
                : (amountsMoved.leftSlot(), amountsMoved.rightSlot());
            basalCR = (getSCR(util) * amountBorrowed) / 10_000;

            // compute ITM collateral requirement we would need for the position to be liquidatable
            remainingCR =
                (
                    tokenType == 0
                        ? ct0.convertToAssets(ct0.balanceOf(Bob))
                        : ct1.convertToAssets(ct1.balanceOf(Bob))
                ) -
                basalCR;

            // find price where the difference between the borrowed tokens and the value of the LP position is equal to the remaining collateral requirement (the "liquidation price")
            // unless this is an extremely wide/full-range position, this will be deep ITM
            sqrtPriceTargetX96 = uint160(
                tokenType == 0
                    ? FixedPointMathLib.sqrt(
                        Math.mulDiv(amountITM, 2 ** 192, amountBorrowed - remainingCR - 1)
                    )
                    : FixedPointMathLib.sqrt(
                        Math.mulDiv(amountBorrowed - remainingCR - 1, 2 ** 192, amountITM)
                    )
            );

            vm.startPrank(Swapper);

            // swap to somewhere between the liquidation price and maximum/minimum prices
            // limiting "max/min prices" to reasonable levels for now because protocol breaks at tail ends of AMM curve (can't handle >2**128 tokens)
            swapperc.swapTo(
                uniPool,
                uint160(
                    bound(
                        prices[i],
                        tokenType == 0 ? sqrtPriceTargetX96 : Constants.MIN_V3POOL_SQRT_RATIO + 2,
                        tokenType == 0 ? Constants.MAX_V3POOL_SQRT_RATIO - 2 : sqrtPriceTargetX96
                    )
                )
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            assertTrue(totalCollateralBalance0 <= totalCollateralRequired0, "Is liquidatable!");

            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 10);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 10);
            }

            // deal alice a bunch of collateral tokens without touching the supply
            editCollateral(ct0, Alice, ct0.convertToShares(type(uint120).max));
            editCollateral(ct1, Alice, ct1.convertToShares(type(uint120).max));
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
    }

    function test_Fail_DivergentSolvencyCheck_mint() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        uint256 asset = 0;
        uint256 tokenType = 0;
        TokenId tokenId = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, asset, 0, tokenType, 0, 0, 2);

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, ) = pp.getOracleTicks();

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(int24(currentTick) + 950));

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
        swapperc.burn(uniPool, -887200, 887200, 10 ** 18);

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
        swapperc.burn(uniPool, -887200, 887200, 10 ** 18);

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, ) = pp.getOracleTicks();

        assertTrue(!pp.isSafeMode(), "not in safe mode");

        assertTrue(
            int256(fastOracleTick - slowOracleTick) ** 2 +
                int256(lastObservedTick - slowOracleTick) ** 2 +
                int256(currentTick - slowOracleTick) ** 2 >
                int256(953) ** 2,
            "will check at multiple ticks"
        );

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        if (tokenType == 0) {
            token0.approve(address(ct0), 1000);
            ct0.deposit(600, Bob);
        } else {
            token1.approve(address(ct1), 1000);
            ct1.deposit(0, Bob);
        }

        vm.startPrank(Bob);

        vm.expectRevert(Errors.AccountInsolvent.selector);
        pp.mintOptions(posIdList, 3000, 0, Constants.MAX_V3POOL_TICK, Constants.MIN_V3POOL_TICK);
    }

    function test_Fail_DivergentSolvencyCheck_burn() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        /// @dev single leg, wide atm call, liquidation through price move making options ITM, no-cross collateral

        uint256 asset = 0;
        uint256 tokenType = 0;
        TokenId tokenId = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, asset, 0, tokenType, 0, 0, 2);

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        if (tokenType == 0) {
            token0.approve(address(ct0), 1650);
            ct0.deposit(850, Bob);
        } else {
            token1.approve(address(ct1), 1000);
            ct1.deposit(0, Bob);
        }

        vm.startPrank(Bob);

        pp.mintOptions(posIdList, 3000, 0, Constants.MAX_V3POOL_TICK, Constants.MIN_V3POOL_TICK);

        TokenId[] memory posIdList2 = new TokenId[](2);

        posIdList2[0] = tokenId;

        TokenId tokenId2 = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 2, asset, 0, tokenType, 0, 0, 2);

        posIdList2[1] = tokenId2;

        // mint second option
        pp.mintOptions(posIdList2, 10, 0, Constants.MAX_V3POOL_TICK, Constants.MIN_V3POOL_TICK);

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, ) = pp.getOracleTicks();

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(int24(currentTick) + 950));

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
        swapperc.burn(uniPool, -887200, 887200, 10 ** 18);

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
        swapperc.burn(uniPool, -887200, 887200, 10 ** 18);

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, ) = pp.getOracleTicks();

        assertTrue(!pp.isSafeMode(), "not in safe mode");

        assertTrue(
            int256(fastOracleTick - slowOracleTick) ** 2 +
                int256(lastObservedTick - slowOracleTick) ** 2 +
                int256(currentTick - slowOracleTick) ** 2 >
                int256(953) ** 2,
            "will check at multiple ticks"
        );

        vm.startPrank(Bob);

        // burn second option
        vm.expectRevert(Errors.AccountInsolvent.selector);
        pp.burnOptions(
            posIdList2[1],
            posIdList,
            Constants.MAX_V3POOL_TICK,
            Constants.MIN_V3POOL_TICK
        );
    }

    function test_Fail_DivergentSolvencyCheck_liquidation() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        /// @dev single leg, wide atm call, liquidation through price move making options ITM, no-cross collateral

        uint256 asset = 0;
        uint256 tokenType = 0;
        TokenId tokenId = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, asset, 0, tokenType, 0, 0, 100);

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        (, currentTick, , , , , ) = uniPool.slot0();

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        if (tokenType == 0) {
            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
        } else {
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);
        }

        pp.mintOptions(posIdList, 3000, 0, Constants.MAX_V3POOL_TICK, Constants.MIN_V3POOL_TICK);

        (, currentTick, , , , , ) = uniPool.slot0();

        (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            posIdList
        );

        assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

        vm.startPrank(Swapper);

        // swap to 1.21 or 0.82, depending on tokenType
        swapperc.swapTo(
            uniPool,
            tokenType == 0 ? 87150978765690778389772763136 : 72025602285694849958832766976
        );
        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            posIdList
        );

        assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");

        // update twaps
        for (uint256 j = 0; j < 100; ++j) {
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 10);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
        }

        twapTick = PanopticMath.twapFilter(uniPool, 600);
        {
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                int24(twapTick),
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable twap!");
        }

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(int24(twapTick) - 500));

        (currentTick, fastOracleTick, , lastObservedTick, ) = pp.getOracleTicks();

        {
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                fastOracleTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable fast!");

            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                lastObservedTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable last!");

            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );

            assertTrue(
                totalCollateralBalance0 > totalCollateralRequired0,
                "Is NOT liquidatable current!"
            );
        }

        vm.startPrank(Alice);

        vm.expectRevert(Errors.NotMarginCalled.selector);
        pp.liquidate(new TokenId[](0), Bob, posIdList);
    }

    function test_success_liquidation_currentTick_bonusOptimization_scenarios() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        /// @dev single leg, wide atm call, liquidation through price move making options ITM, no-cross collateral

        uint256 asset = 0;
        uint256 tokenType = 0;
        TokenId tokenId = TokenId
            .wrap(0)
            .addPoolId(PanopticMath.getPoolId(address(uniPool)))
            .addLeg(0, 1, asset, 0, tokenType, 0, 0, 100);

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        (, currentTick, , , , , ) = uniPool.slot0();

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        if (tokenType == 0) {
            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
        } else {
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);
        }

        pp.mintOptions(posIdList, 3000, 0, Constants.MAX_V3POOL_TICK, Constants.MIN_V3POOL_TICK);

        (, currentTick, , , , , ) = uniPool.slot0();

        (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            posIdList
        );

        assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

        vm.startPrank(Swapper);

        // swap to 1.21 or 0.82, depending on tokenType
        swapperc.swapTo(
            uniPool,
            tokenType == 0 ? 87150978765690778389772763136 : 72025602285694849958832766976
        );
        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            posIdList
        );

        assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");

        // update twaps
        for (uint256 j = 0; j < 100; ++j) {
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 10);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
        }

        twapTick = PanopticMath.twapFilter(uniPool, 600);
        {
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                int24(twapTick),
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable twap!");
        }

        (, uint256 liquidatorBalance1) = (
            ct0.convertToAssets(ct0.balanceOf(Alice)),
            ct1.convertToAssets(ct1.balanceOf(Alice))
        );

        int256 maxBonus1;

        int256 maxTick;
        uint256 snapshot = vm.snapshot();

        for (int24 t = -350; t <= 510; t += 10) {
            // swap to 1.21*1.05 or 0.82/1.05, depending on tokenType
            vm.startPrank(Swapper);
            swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(int24(twapTick) + t));

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            unchecked {
                if (
                    int256(ct1.convertToAssets(ct1.balanceOf(Alice)) - liquidatorBalance1) >
                    maxBonus1
                ) {
                    maxBonus1 = int256(
                        ct1.convertToAssets(ct1.balanceOf(Alice)) - liquidatorBalance1
                    );
                    maxTick = twapTick + t;
                }
            }
            vm.revertTo(snapshot);
        }

        console2.log("maxBonus1", maxBonus1);
        console2.log("twapTick", twapTick);
        console2.log("maxTick", maxTick);
    }

    function test_success_liquidation_ITM_scenarios() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        uint256 snapshot = vm.snapshot();

        /// @dev single leg, liquidation through price move making options ITM, no-cross collateral

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;
            TokenId tokenId = TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(0, 1, asset, 0, tokenType, 0, 0, 2);
            //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
            } else {
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

            vm.startPrank(Swapper);

            // swap to 1.21 or 0.82, depending on tokenType
            swapperc.swapTo(
                uniPool,
                tokenType == 0 ? 87150978765690778389772763136 : 72025602285694849958832766976
            );
            (, currentTick, , , , , ) = uniPool.slot0();

            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");

            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Alice);
            console2.log("");
            console2.log("no-cross collateral", i);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev single leg, liquidation through price move making options ITM, with cross collateral
        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;
            TokenId tokenId = TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(0, 1, asset, 0, tokenType, 0, 0, 2);
            //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 7);
                ct0.deposit(7, Bob);
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            } else {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
                token1.approve(address(ct1), 7);
                ct1.deposit(7, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

            vm.startPrank(Swapper);

            // swap to 1.21 or 0.82, depending on tokenType
            swapperc.swapTo(
                uniPool,
                tokenType == 0 ? 87150978765690778389772763136 : 72025602285694849958832766976
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");

            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            console2.log("");
            console2.log("cross collateral", i);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
        console2.log("");
        console2.log("");

        /// @dev strangles, liquidation through price move making on leg of the option ITM

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);
            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            // swap to 1.41 or 0.62, depending on tokenType
            swapperc.swapTo(
                uniPool,
                i > 3 ? 110919427519970065594087112704 : 56591544653045956680544681984
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev strangles, liquidation through price move making on leg of the option ITM, with cross-collateral (token0)

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);
            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 5);
            ct1.deposit(5, Bob);

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            // swap to 1.41 or 0.62, depending on tokenType
            swapperc.swapTo(
                uniPool,
                i > 3 ? 110919427519970065594087112704 : 56591544653045956680544681984
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev strangles, liquidation through price move making on leg of the option ITM, with cross-collateral (token1)

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);
            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 5);
            ct0.deposit(5, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            // swap to 1.41 or 0.62, depending on tokenType
            swapperc.swapTo(
                uniPool,
                i > 3 ? 110919427519970065594087112704 : 56591544653045956680544681984
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);

            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
    }

    function test_success_liquidation_LowCollateral_scenarios() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        uint256 snapshot = vm.snapshot();

        /// @dev single leg, liquidation through decrease in collateral, no-cross collateral

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;
            TokenId tokenId = TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(0, 1, asset, 0, tokenType, 0, 0, 2);
            //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
            } else {
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

            vm.startPrank(Swapper);

            if (tokenType == 0) {
                editCollateral(ct0, Bob, ct0.convertToShares(550));
            } else {
                editCollateral(ct1, Bob, ct1.convertToShares(550));
            }
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");

            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }
            console2.log("");
            console2.log("no cross collateral", i);

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev single leg, liquidation through decrease in collateral, with cross collateral

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;
            TokenId tokenId = TokenId
                .wrap(0)
                .addPoolId(PanopticMath.getPoolId(address(uniPool)))
                .addLeg(0, 1, asset, 0, tokenType, 0, 0, 2);
            //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 7);
                ct0.deposit(7, Bob);
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            } else {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
                token1.approve(address(ct1), 7);
                ct1.deposit(7, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

            vm.startPrank(Swapper);

            if (tokenType == 0) {
                editCollateral(ct1, Bob, ct1.convertToShares(550));
            } else {
                editCollateral(ct0, Bob, ct0.convertToShares(550));
            }

            (, currentTick, , , , , ) = uniPool.slot0();
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");

            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            console2.log("");
            console2.log("cross collateral", i);

            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
        console2.log("");
        console2.log("");

        /// @dev strangles, liquidation through decrease in collateral, no-cross collateral

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = (i / 2);
            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct0, Bob, ct0.convertToShares(250));
            editCollateral(ct1, Bob, ct1.convertToShares(250));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev strangles, liquidation through decrease in collateral, with cross collateral (token0)

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = (i / 2);
            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 15);
            ct1.deposit(15, Bob);

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct0, Bob, ct0.convertToShares(250));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev strangles, liquidation through decrease in collateral, with cross collateral (token1)

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = (i / 2);
            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 15);
            ct0.deposit(15, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);

            pp.mintOptions(
                posIdList,
                3000,
                0,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct1, Bob, ct1.convertToShares(250));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);
            vm.revertTo(snapshot);
        }

        /// @dev spreads, liquidation through decrease in collateral, no-cross collateral

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);
            TokenId tokenId;
            TokenId[] memory posIdList = new TokenId[](1);

            {
                // sell long leg
                vm.startPrank(Charlie);

                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
                posIdList[0] = tokenId;

                pp.mintOptions(
                    posIdList,
                    1_000_000,
                    0,
                    Constants.MAX_V3POOL_TICK,
                    Constants.MIN_V3POOL_TICK
                );

                // create spread tokenId
                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    i < 3 ? int24(-100) : int24(100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    1,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                10_000,
                2 ** 30,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct0, Bob, ct0.convertToShares(250));
            editCollateral(ct1, Bob, ct1.convertToShares(250));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev spreads, liquidation through decrease in collateral, with cross collateral (token0)

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);
            TokenId tokenId;
            TokenId[] memory posIdList = new TokenId[](1);

            {
                // sell long leg
                vm.startPrank(Charlie);

                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
                posIdList[0] = tokenId;

                pp.mintOptions(
                    posIdList,
                    1_000_000,
                    0,
                    Constants.MAX_V3POOL_TICK,
                    Constants.MIN_V3POOL_TICK
                );

                // create spread tokenId
                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    i < 3 ? int24(-100) : int24(100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    1,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 2500);
            ct0.deposit(2500, Bob);
            token1.approve(address(ct1), 150);
            ct1.deposit(150, Bob);
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                10_000,
                2 ** 30,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct0, Bob, ct0.convertToShares(250));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev spreads, liquidation through decrease in collateral, with cross collateral (token1)

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);
            TokenId tokenId;
            TokenId[] memory posIdList = new TokenId[](1);

            {
                // sell long leg
                vm.startPrank(Charlie);

                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
                posIdList[0] = tokenId;

                pp.mintOptions(
                    posIdList,
                    1_000_000,
                    0,
                    Constants.MAX_V3POOL_TICK,
                    Constants.MIN_V3POOL_TICK
                );

                // create spread tokenId
                tokenId = TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(uniPool)));
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    i < 3 ? int24(-100) : int24(100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    1,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 150);
            ct0.deposit(150, Bob);
            token1.approve(address(ct1), 2500);
            ct1.deposit(2500, Bob);
            // mint 1 liquidity unit of wideish centered position

            pp.mintOptions(
                posIdList,
                10_000,
                2 ** 30,
                Constants.MAX_V3POOL_TICK,
                Constants.MIN_V3POOL_TICK
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct1, Bob, ct1.convertToShares(250));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            pp.liquidate(new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
    }
}
