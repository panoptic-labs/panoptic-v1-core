// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Foundry
import {Test, console2} from "forge-std/Test.sol";

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";

// Panoptic Gated Launch Periphery
import {GatedFactory} from "@contracts/GatedFactory.sol";

// Panoptic Libraries
import {PanopticMath} from "@contracts/libraries/PanopticMath.sol";

contract MockUniswapPool {
    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    Slot0 public slot0;
    address public token0;
    address public token1;
    int24 public tickSpacing;
    uint24 public fee;

    constructor(
        address _token0,
        address _token1,
        int24 _tickSpacing,
        int24 _currentTick,
        uint24 _fee
    ) {
        token0 = _token0;
        token1 = _token1;
        tickSpacing = _tickSpacing;
        slot0 = Slot0(0, _currentTick, 0, 0, 0, 0, false);
        fee = _fee;
    }

    function increaseObservationCardinalityNext(uint16 _observationCardinalityNext) external {
        require(_observationCardinalityNext == 100);
    }
}

contract MockUniswapFactory {
    address pool;

    constructor(address _pool) {
        pool = _pool;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

contract MockToken {
    function approve(address, uint256) external {}
}

contract GatedFactoryTest is Test {
    GatedFactory public factory;

    function test_success_Construct(address owner) public {
        vm.startPrank(owner);
        factory = new GatedFactory(owner);
        assertEq(factory.factoryOwner(), owner);
    }

    function test_success_setOwner(address oldOwner, address newOwner) public {
        vm.startPrank(oldOwner);
        factory = new GatedFactory(oldOwner);

        factory.setOwner(newOwner);
        assertEq(factory.factoryOwner(), newOwner);
    }

    function test_success_deployNewPool(
        address owner,
        address token0,
        address token1,
        int24 tickSpacing,
        int24 currentTick,
        uint24 fee
    ) public {
        vm.startPrank(owner);

        vm.assume(token0 > address(10));
        vm.assume(token1 > address(10));

        address mockToken = address(new MockToken());
        vm.etch(token0, mockToken.code);
        vm.etch(token1, mockToken.code);

        IUniswapV3Pool mockPool = IUniswapV3Pool(
            address(new MockUniswapPool(token0, token1, tickSpacing, currentTick, fee))
        );

        IUniswapV3Factory mockFactory = IUniswapV3Factory(
            address(new MockUniswapFactory(address(mockPool)))
        );
        SemiFungiblePositionManager sfpm = new SemiFungiblePositionManager(mockFactory);

        address poolReference = address(new PanopticPool(sfpm));
        address collateralReference = address(new CollateralTracker());

        factory = new GatedFactory(owner);

        PanopticPool newPoolContract = factory.deployNewPool(
            IUniswapV3Pool(mockPool),
            sfpm,
            poolReference,
            collateralReference,
            bytes32(0)
        );

        CollateralTracker ct0 = CollateralTracker(newPoolContract.collateralToken0());
        CollateralTracker ct1 = CollateralTracker(newPoolContract.collateralToken1());

        assertEq(address(newPoolContract.univ3pool()), address(mockPool));

        assertEq(sfpm.getPoolId(address(mockPool)), PanopticMath.getPoolId(address(mockPool)));

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
            bytes32(uint256(((2 * (fee / 100)) + (2_000 << 128))))
        ); // itm spread fee + sellCollateralRatio
        assertEq(
            vm.load(address(ct1), bytes32(uint256(10))),
            bytes32(uint256(((2 * (fee / 100)) + (2_000 << 128))))
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
}
