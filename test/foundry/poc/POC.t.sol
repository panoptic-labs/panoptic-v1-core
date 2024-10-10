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
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {PositionUtils} from "../testUtils/PositionUtils.sol";
import {Math} from "@libraries/Math.sol";
import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";
import {Errors} from "@libraries/Errors.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Constants} from "@libraries/Constants.sol";
import {Pointer} from "@types/Pointer.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {SwapperC} from "../core/Misc.t.sol";
import {ERC20S} from "../core/Misc.t.sol";
// V4 types
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {V4RouterSimple} from "../testUtils/V4RouterSimple.sol";

contract POC_Test is Test, PositionUtils {
    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Swapper = address(0x123456789);
    address Charlie = address(0x1234567891);
    address Seller = address(0x12345678912);
    address Eve = address(0x123456789123);

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

    IPoolManager manager;

    V4RouterSimple routerV4;

    PoolKey poolKey;

    IUniswapV3Pool uniPool;
    ERC20S token0;
    ERC20S token1;

    SwapperC swapperc;

    // creates a new PanopticPool with corresponding Uniswap pool on a mainnet fork
    // see test/foundry/misc.t.sol for example usage
    function setUp() public {
        vm.startPrank(Deployer);

        manager = IPoolManager(address(new PoolManager()));

        routerV4 = new V4RouterSimple(manager);

        sfpm = new SemiFungiblePositionManager(manager);

        ph = new PanopticHelper(sfpm);

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPool(sfpm, manager));
        collateralReference = address(
            new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20, manager)
        );
        token0 = new ERC20S("token0", "T0", 18);
        token1 = new ERC20S("token1", "T1", 18);
        uniPool = IUniswapV3Pool(V3FACTORY.createPool(address(token0), address(token1), 500));

        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            500,
            10,
            IHooks(address(0))
        );

        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint248).max);
        token1.mint(Swapper, type(uint248).max);
        token0.approve(address(swapperc), type(uint248).max);
        token1.approve(address(swapperc), type(uint248).max);
        token0.approve(address(routerV4), type(uint248).max);
        token1.approve(address(routerV4), type(uint248).max);

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

        manager.initialize(poolKey, 10 ** 17 * 2 ** 96);

        swapperc.burn(uniPool, -887270, 887270, 10 ** 18);
        vm.startPrank(Deployer);

        factory = new PanopticFactory(
            address(token1),
            sfpm,
            manager,
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
                    IV3CompatibleOracle(address(uniPool)),
                    poolKey,
                    uint96(block.timestamp),
                    type(uint256).max,
                    type(uint256).max
                )
            )
        );

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

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

        vm.stopPrank();
    }

    function test_POC() external {}
}
