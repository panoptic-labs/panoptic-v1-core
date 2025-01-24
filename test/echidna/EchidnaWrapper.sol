// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";
import {PanopticPoolActions} from "./PanopticPoolActions.sol";
import {Pointer} from "@types/Pointer.sol";

// container that inherits all the actions contracts for the system and does necessary deployment/setup for a pool
// FuzzHelpers -> GeneralActions -> SFPMActions -> CollateralTrackerActions -> PanopticPoolActions -> EchidnaWrapper
contract EchidnaWrapper is PanopticPoolActions {
    constructor() {
        // Actors
        // We have 5 actors
        // The addresses need to be the same than in the echidna.yaml
        // See sender: ["0xa11ce", "0xb0b", "0xcafe", "0xda210", "0xedda"]
        actors = new address[](5);
        actors[0] = address(0xa11ce);
        actors[1] = address(0xb0b);
        actors[2] = address(0xcafe);
        actors[3] = address(0xda210);
        actors[4] = address(0xedda);

        pool_manipulator = address(0xfaded);

        deployer = IUniDeployer(address(0xde0001));

        USDC = IERC20(deployer.token0());
        WETH = IERC20(deployer.token1());

        pools = deployer.getPools();

        manager = new PoolManager(address(0));

        routerV4 = new V4RouterSimple(manager);

        swapperc = new SwapperC();
        emit LogAddress("Panoptic Swapper", address(swapperc));

        hevm.prank(pool_manipulator);
        IERC20(USDC).approve(address(swapperc), type(uint256).max);
        hevm.prank(pool_manipulator);
        IERC20(WETH).approve(address(swapperc), type(uint256).max);

        hevm.prank(pool_manipulator);
        IERC20(USDC).approve(address(routerV4), type(uint256).max);
        hevm.prank(pool_manipulator);
        IERC20(WETH).approve(address(routerV4), type(uint256).max);

        deal_USDC(pool_manipulator, type(uint240).max);
        deal_WETH(pool_manipulator, type(uint240).max);

        for (uint256 i = 0; i < pools.length; ++i) {
            poolKeys[i] = PoolKey(
                Currency.wrap(pools[i].token0()),
                Currency.wrap(pools[i].token1()),
                pools[i].fee(),
                pools[i].tickSpacing(),
                IHooks(address(0))
            );

            (uint160 sqrtPriceX96Pool, , , , , , ) = pools[i].slot0();

            manager.initialize(poolKeys[i], sqrtPriceX96Pool);

            hevm.prank(pool_manipulator);
            routerV4.modifyLiquidity(
                address(0),
                poolKeys[i],
                (-887272 / poolKeys[i].tickSpacing) * poolKeys[i].tickSpacing,
                (887272 / poolKeys[i].tickSpacing) * poolKeys[i].tickSpacing,
                1e18
            );
        }

        for (uint i = 0; i < actors.length; i++) {
            userPositions[actors[i]] = new TokenId[](0);
        }

        userPositions[pool_manipulator] = new TokenId[](0);

        univ3factory = IUniswapV3Factory(deployer.factory());
        emit LogAddress("UniV3 Factory", address(univ3factory));

        sfpm = new SemiFungiblePositionManager(manager, 500_000_000, 500_000_000, 0);
        emit LogAddress("Panoptic SFPM", address(sfpm));

        panopticHelper = new PanopticHelper(sfpm);
        emit LogAddress("Panoptic Helper", address(panopticHelper));

        // Import the Panoptic Pool reference (for cloning)
        poolReference = address(new PanopticPoolWrapper(sfpm, manager));
        emit LogAddress("Panoptic Pool reference", address(poolReference));

        // Import the Collateral Tracker reference (for cloning)
        collateralReference = address(
            new CollateralTrackerWrapper(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20, manager)
        );
        emit LogAddress("Panoptic Collateral reference", address(collateralReference));

        panopticFactory = new PanopticFactory(
            sfpm,
            manager,
            poolReference,
            collateralReference,
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );
        emit LogAddress("Panoptic Factory", address(panopticFactory));

        emit LogAddress("USDC Token", address(USDC));
        emit LogAddress("WETH Token", address(WETH));

        initialize();

        deal_USDC(pool_manipulator, type(uint240).max);
        deal_WETH(pool_manipulator, type(uint240).max);

        for (uint i; i < 4; i++) {
            hevm.prank(pool_manipulator);
            IERC20(USDC).approve(address(pools[i]), type(uint256).max);
            hevm.prank(pool_manipulator);
            IERC20(WETH).approve(address(pools[i]), type(uint256).max);
        }

        for (uint256 i; i < actors.length; ++i) {
            hevm.prank(actors[i]);
            manager.setOperator(address(sfpm), true);
        }

        for (uint i; i < pools.length; i++) {
            cyclingPool = pools[i];
            cyclingPoolKey = poolKeys[i];
            perform_swap_and_align_prices(uint256(keccak256(abi.encodePacked(i))));
        }

        cyclingPool = pool;
        cyclingPoolKey = poolKey;
    }

    function initialize() internal {
        // initalize current pool we are deploying
        pool = pools[0];
        poolKey = poolKeys[0];
        cyclingPool = pool;
        poolFee = pool.fee();
        poolTickSpacing = pool.tickSpacing();
        sfpmTickSpacing = poolTickSpacing;

        token0 = pool.token0();
        token1 = pool.token1();

        assert(pool.token0() == address(USDC));
        assert(pool.token1() == address(WETH));

        // give test contract a sufficient amount of tokens to deploy a new pool
        deal_USDC(address(this), 10000000 ether);
        deal_WETH(address(this), 10000 ether);

        // Check: Make sure the correct balance is set to the contract
        assert(USDC.balanceOf(address(this)) == 10000000 ether);
        assert(WETH.balanceOf(address(this)) == 10000 ether);

        // approve factory to move tokens, on behalf of the test contract
        USDC.approve(address(panopticFactory), type(uint256).max);
        WETH.approve(address(panopticFactory), type(uint256).max);

        // approve sfpm to move tokens, on behalf of the test contract
        USDC.approve(address(sfpm), type(uint256).max);
        WETH.approve(address(sfpm), type(uint256).max);

        // approve self
        USDC.approve(address(this), type(uint256).max);
        WETH.approve(address(this), type(uint256).max);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        for (uint256 i; i < poolKeys.length; i++) {
            sfpm.initializeAMMPool(poolKeys[i]);
        }
        poolId = sfpm.getPoolId(poolKeys[0].toId());
        sfpmPoolId = poolId;

        panopticPool = PanopticPoolWrapper(
            address(
                panopticFactory.deployNewPool(
                    IV3CompatibleOracle(address(pool)),
                    poolKey,
                    uint96(0)
                )
            )
        );

        collToken0 = CollateralTrackerWrapper(address(panopticPool.collateralToken0()));
        collToken1 = CollateralTrackerWrapper(address(panopticPool.collateralToken1()));

        hevm.prank(address(collToken0));
        IERC20(collToken0.asset()).approve(address(pool), type(uint256).max);
        hevm.prank(address(collToken0));
        IERC20(collToken1.asset()).approve(address(pool), type(uint256).max);

        hevm.prank(address(collToken1));
        IERC20(collToken0.asset()).approve(address(pool), type(uint256).max);
        hevm.prank(address(collToken1));
        IERC20(collToken1.asset()).approve(address(pool), type(uint256).max);
    }
}
