// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import "forge-std/Test.sol";
// Panoptic Core
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Panoptic Libraries
import {Constants} from "@libraries/Constants.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
import {Errors} from "@libraries/Errors.sol";
// Panoptic Types
import {Pointer, PointerLibrary} from "@types/Pointer.sol";
// Panoptic Interfaces
import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
// Uniswap
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {PoolAddress} from "v3-periphery/libraries/PoolAddress.sol";
import {CallbackValidation} from "v3-periphery/libraries/CallbackValidation.sol";
import {TransferHelper} from "v3-periphery/libraries/TransferHelper.sol";
import {Base64} from "solady/utils/Base64.sol";
import {JSONParserLib} from "solady/utils/JSONParserLib.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
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

contract PanopticFactoryHarness is PanopticFactory {
    constructor(
        address _WETH9,
        SemiFungiblePositionManager _SFPM,
        IPoolManager manager,
        address poolReference,
        address collateralReference,
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    )
        PanopticFactory(
            _WETH9,
            _SFPM,
            manager,
            poolReference,
            collateralReference,
            properties,
            indices,
            pointers
        )
    {}

    function getPoolReference() external view returns (address) {
        return POOL_REFERENCE;
    }

    function create3Address(bytes32 salt) external view returns (address) {
        return ClonesWithImmutableArgs.addressOfClone3(salt);
    }
}

contract PanopticFactoryTest is Test {
    // the instance of the Panoptic Factory we are testing
    PanopticFactoryHarness panopticFactory;

    // Mainnet WETH smart contract address
    address _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Mainnet factory address
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    IPoolManager manager = IPoolManager(address(new PoolManager()));

    V4RouterSimple routerV4 = new V4RouterSimple(manager);

    // deploy the semiFungiblePositionManager
    SemiFungiblePositionManager sfpm = new SemiFungiblePositionManager(manager);

    address Deployer = makeAddr("Deployer");

    // store a few different mainnet pairs - the pool used is part of the fuzz

    // 0.01% pools
    IUniswapV3Pool constant DAI_USDC_1 = IUniswapV3Pool(0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168);
    IUniswapV3Pool constant USDC_USDT_1 =
        IUniswapV3Pool(0x3416cF6C708Da44DB2624D63ea0AAef7113527C6);

    // 0.05% pools
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IUniswapV3Pool constant ETH_USDT_5 = IUniswapV3Pool(0x11b815efB8f581194ae79006d24E0d814B7697F6);

    // 0.3% pools
    IUniswapV3Pool constant WBTC_ETH_30 =
        IUniswapV3Pool(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);
    IUniswapV3Pool constant MATIC_ETH_30 =
        IUniswapV3Pool(0x290A6a7460B308ee3F19023D2D00dE604bcf5B42);

    // 1% pools
    IUniswapV3Pool constant INCH_USDC_100 =
        IUniswapV3Pool(0x9feBc984504356225405e26833608b17719c82Ae);

    // store in fixed array
    IUniswapV3Pool[7] public pools = [
        DAI_USDC_1,
        USDC_USDT_1,
        USDC_WETH_5,
        WBTC_ETH_30,
        MATIC_ETH_30,
        INCH_USDC_100,
        ETH_USDT_5
    ];

    struct PointerInfo {
        uint256 codeIndex;
        uint256 end;
        uint256 start;
    }

    // granted token amounts
    uint256 constant INITIAL_MOCK_TOKENS = type(uint256).max / 2;

    // store some data about the pool we are testing
    IUniswapV3Pool pool;
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;

    PoolKey poolKey;

    // the amount that's deployed when initializing the SFPM against a new AMM pool.
    uint128 constant FULL_RANGE_LIQUIDITY_AMOUNT_WETH = 0.1 ether;
    uint128 constant FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN = 1e6;

    // Amount of initial assets to be deposited to the Collateral Tracker
    // These assets are used to mint 'dead shares' to the Panoptic Factory
    // Used as a mitigation technique for the ERC4626 share inflation attack
    uint256 constant INITIAL_DEPOSIT = 1e4;

    // Define the struct needed when minting a Uniswap V3 LP position
    struct CallbackData {
        PoolAddress.PoolKey univ3poolKey;
        address payer;
    }

    function _initWorld(uint256 seed) internal {
        // Pick a pool from the seed and cache initial state
        _initalizeWorldState(pools[bound(seed, 0, pools.length - 1)]);
    }

    function _initalizeWorldState(IUniswapV3Pool _pool) internal {
        // initalize current pool we are deploying
        pool = _pool;
        token0 = _pool.token0();
        token1 = _pool.token1();
        fee = _pool.fee();
        tickSpacing = _pool.tickSpacing();

        poolKey = PoolKey(
            Currency.wrap(token0),
            Currency.wrap(token1),
            fee,
            tickSpacing,
            IHooks(address(0))
        );

        (uint160 currentSqrtPriceX96, , , , , , ) = pool.slot0();
        manager.initialize(poolKey, currentSqrtPriceX96);

        // give test contract a sufficient amount of tokens to deploy a new pool
        deal(token0, address(this), INITIAL_MOCK_TOKENS);
        deal(token1, address(this), INITIAL_MOCK_TOKENS);
        assertEq(IERC20Partial(token0).balanceOf(address(this)), INITIAL_MOCK_TOKENS, "token0");
        assertEq(IERC20Partial(token1).balanceOf(address(this)), INITIAL_MOCK_TOKENS, "token1");

        // approve factory to move tokens, on behalf of the test contract
        IERC20Partial(token0).approve(address(panopticFactory), INITIAL_MOCK_TOKENS);
        IERC20Partial(token1).approve(address(panopticFactory), INITIAL_MOCK_TOKENS);

        IERC20Partial(token0).approve(address(routerV4), INITIAL_MOCK_TOKENS);
        IERC20Partial(token1).approve(address(routerV4), INITIAL_MOCK_TOKENS);
    }

    function setUp() public {
        string memory metadata = vm.readFile("./metadata/out/MetadataPackage.json");

        bytes[] memory bytecodes = vm.parseJsonBytesArray(metadata, ".bytecodes");
        address[] memory pointerAddresses = new address[](bytecodes.length);

        for (uint256 i = 0; i < bytecodes.length; i++) {
            bytes memory code = bytecodes[i];
            address pointer;
            // deploy code and store pointer
            assembly {
                pointer := create(0, add(code, 0x20), mload(code))
                if iszero(extcodesize(pointer)) {
                    revert(0, 0)
                }
            }
            pointerAddresses[i] = pointer;
        }

        PointerInfo[][] memory pointerInfo = abi.decode(
            vm.parseJson(metadata, ".pointers"),
            (PointerInfo[][])
        );
        Pointer[][] memory pointers = new Pointer[][](pointerInfo.length);

        for (uint256 i = 0; i < pointerInfo.length; i++) {
            pointers[i] = new Pointer[](pointerInfo[i].length);
            for (uint256 j = 0; j < pointerInfo[i].length; j++) {
                pointers[i][j] = PointerLibrary.createPointer(
                    pointerAddresses[pointerInfo[i][j].codeIndex],
                    uint48(pointerInfo[i][j].start),
                    uint48(pointerInfo[i][j].end)
                );
            }
        }

        string[] memory propsStr = vm.parseJsonStringArray(metadata, ".properties");
        bytes32[] memory props = new bytes32[](propsStr.length);
        for (uint256 i = 0; i < propsStr.length; i++) {
            props[i] = bytes32(bytes(propsStr[i]));
        }

        string[][] memory indicesStr = abi.decode(vm.parseJson(metadata, ".indices"), (string[][]));
        uint256[][] memory indices = new uint256[][](indicesStr.length);
        for (uint256 i = 0; i < indicesStr.length; i++) {
            indices[i] = new uint256[](indicesStr[i].length);
            for (uint256 j = 0; j < indicesStr[i].length; j++) {
                indices[i][j] = vm.parseUint(indicesStr[i][j]);
            }
        }

        // Deploy factory
        panopticFactory = new PanopticFactoryHarness(
            address(_WETH),
            sfpm,
            manager,
            address(new PanopticPool(sfpm, manager)),
            address(new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20, manager)),
            props,
            indices,
            pointers
        );
    }

    /*//////////////////////////////////////////////////////////////
                    DEPLOY NEW POOL TESTS
    //////////////////////////////////////////////////////////////*/

    // fuzz seed to deploy random pools
    // fuzz salt to generate a pool with a random address
    function test_Success_deployNewPool(uint256 x, uint96 salt) public {
        _initWorld(x);

        // Compute clone determinsitic Panoptic Factory address
        address preComputedPool = panopticFactory.create3Address(
            bytes32(
                abi.encodePacked(
                    uint80(uint160(address(this)) >> 80),
                    uint80(uint256(keccak256(abi.encode(poolKey, pool)))),
                    salt
                )
            )
        );

        // Amount of liquidity currently in the univ3 pool
        uint128 liquidityBefore = StateLibrary.getLiquidity(manager, poolKey.toId());

        // amount of assets held before mint
        // Compute amount of liquidity to deploy
        (uint128 fullRangeLiquidity, , ) = computeFullRangeLiquidity();

        {
            // Deploy pool
            // links the Uniswap V3 pool to the Panoptic pool
            PanopticPool deployedPool = panopticFactory.deployNewPool(
                IV3CompatibleOracle(address(pool)),
                poolKey,
                salt,
                type(uint256).max,
                type(uint256).max
            );

            // see if pool exists at the precomputed address
            uint256 size;
            assembly ("memory-safe") {
                size := extcodesize(preComputedPool)
            }
            // check if bytecode is greater than 0
            assertGt(size, 0);

            // check if pool is linked to the correct panoptic pool in factory
            assertEq(
                address(
                    panopticFactory.getPanopticPool(poolKey, IV3CompatibleOracle(address(pool)))
                ),
                address(deployedPool)
            );
            // see if correct pool was linked in the panopticPool
            IUniswapV3Pool linkedPool = IUniswapV3Pool(
                address(PanopticPool(preComputedPool).oracleContract())
            );
            address linkedPoolAddress = address(PanopticPool(preComputedPool).oracleContract());
            assertEq(address(pool), linkedPoolAddress);

            // check the pool has the correct parameters
            assertEq(token0, linkedPool.token0());
            assertEq(token1, linkedPool.token1());
            assertEq(fee, linkedPool.fee());
        }

        /* Liquidity checks */
        // Amount of liquidity in univ3 pool after Panoptic Pool deployment
        uint128 liquidityAfter = StateLibrary.getLiquidity(manager, poolKey.toId());
        // ensure liquidity in pool now is sum of liquidity before and user deployed amount
        assertEq(liquidityAfter - liquidityBefore, fullRangeLiquidity);
    }

    // deploy a pool with token0 as WETH
    function test_Success_deployNewPoolWETH0() public {
        // No need to fuzz as we are testing for a specific condition
        // use pool[7] -> ETH_USDT_5
        _initalizeWorldState(pools[5]);

        // generate a not so random salt
        uint96 salt = uint96(block.timestamp);

        // Deploy pool
        // links the uni v3 pool to the Panoptic pool
        panopticFactory.deployNewPool(
            IV3CompatibleOracle(address(pool)),
            poolKey,
            salt,
            type(uint256).max,
            type(uint256).max
        );
    }

    // deploy a pool with token1 as WETH
    function test_Success_deployNewPoolToken1() public {
        // No need to fuzz as we are testing for a specific condition
        // use pool[1] -> USDC_USDT_1
        _initalizeWorldState(pools[1]);

        // generate a not so random salt
        uint96 salt = uint96(block.timestamp);

        // Deploy pool
        // links the uni v3 pool to the Panoptic pool
        panopticFactory.deployNewPool(
            IV3CompatibleOracle(address(pool)),
            poolKey,
            salt,
            type(uint256).max,
            type(uint256).max
        );
    }

    function test_Success_deployNewPool_SlippagePass() public {
        _initWorld(0);

        uint256 salt = uint96(block.timestamp) + (uint256(uint160(address(this))) << 96);

        (, uint256 amount0, uint256 amount1) = computeFullRangeLiquidity();

        panopticFactory.deployNewPool(
            IV3CompatibleOracle(address(pool)),
            poolKey,
            uint96(salt),
            amount0,
            amount1
        );
    }

    function test_Fail_deployNewPool_Slippage0() public {
        _initWorld(0);

        uint256 salt = uint96(block.timestamp) + (uint256(uint160(address(this))) << 96);

        (, uint256 amount0, uint256 amount1) = computeFullRangeLiquidity();

        vm.expectRevert(Errors.PriceBoundFail.selector);
        panopticFactory.deployNewPool(
            IV3CompatibleOracle(address(pool)),
            poolKey,
            uint96(salt),
            amount0 - 1,
            amount1
        );
    }

    function test_Fail_deployNewPool_Slippage1() public {
        _initWorld(0);

        uint256 salt = uint96(block.timestamp) + (uint256(uint160(address(this))) << 96);

        (, uint256 amount0, uint256 amount1) = computeFullRangeLiquidity();

        vm.expectRevert(Errors.PriceBoundFail.selector);
        panopticFactory.deployNewPool(
            IV3CompatibleOracle(address(pool)),
            poolKey,
            uint96(salt),
            amount0,
            amount1 - 1
        );
    }

    function test_Fail_deployNewPool_Slippage0Both() public {
        _initWorld(0);

        uint256 salt = uint96(block.timestamp) + (uint256(uint160(address(this))) << 96);

        (, uint256 amount0, uint256 amount1) = computeFullRangeLiquidity();

        vm.expectRevert(Errors.PriceBoundFail.selector);
        panopticFactory.deployNewPool(
            IV3CompatibleOracle(address(pool)),
            poolKey,
            uint96(salt),
            amount0 - 1,
            amount1 - 1
        );
    }

    // Revert if trying to deploy a Panoptic Pool ontop of an invalid Uniswap Pool
    function test_Fail_deployinvalidPool() public {
        // generate a not so random salt
        uint96 salt = uint96(block.timestamp);

        // Deploy invalid pool (uninitalized tokens and fee)
        vm.expectRevert(Errors.UniswapPoolNotInitialized.selector);
        panopticFactory.deployNewPool(
            IV3CompatibleOracle(address(pool)),
            poolKey,
            salt,
            type(uint256).max,
            type(uint256).max
        );
    }

    // Revert if deploying a Panoptic Pool that has already been initalized
    function test_Fail_deployExistingPool() public {
        // No need to fuzz as we are testing for a specific condition
        // use pool[0] -> DAI_USDC_1
        _initalizeWorldState(pools[0]);

        // generate a not so random salt
        uint96 salt = uint96(block.timestamp);

        // Deploy pool
        panopticFactory.deployNewPool(
            IV3CompatibleOracle(address(pool)),
            poolKey,
            salt,
            type(uint256).max,
            type(uint256).max
        );

        // Attempt to deploy pool again
        vm.expectRevert(Errors.PoolAlreadyInitialized.selector);
        unchecked {
            panopticFactory.deployNewPool(
                IV3CompatibleOracle(address(pool)),
                poolKey,
                salt + 1,
                type(uint256).max,
                type(uint256).max
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                          NFT TOKEN URI TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_tokenURI_decodes() public {
        _initalizeWorldState(pools[1]);
        uint96 salt = uint96(block.timestamp);
        PanopticPool deployedPool = panopticFactory.deployNewPool(
            IV3CompatibleOracle(address(pool)),
            poolKey,
            salt,
            type(uint256).max,
            type(uint256).max
        );
        uint256 panopticPoolAddress = uint256(uint160(address(deployedPool)));
        bytes memory uri = bytes(panopticFactory.tokenURI(panopticPoolAddress));
        uint256 prefixLength = bytes("data:application/json;base64,").length;
        bytes memory encodedPartBytes = new bytes(uri.length - prefixLength);
        for (uint256 i = 0; i < encodedPartBytes.length; i++) {
            encodedPartBytes[i] = uri[i + prefixLength];
        }

        bytes memory tokenURIDecoded = Base64.decode(string(encodedPartBytes));

        // ensure the output URI is valid JSON
        JSONParserLib.parse(string(tokenURIDecoded));
    }

    /*//////////////////////////////////////////////////////////////
                    MINE POOL ADDRESS TESTS
    //////////////////////////////////////////////////////////////*/

    // Successfully reach or surpass target rarity and deploy a Panoptic pool with the mined 'bestSalt'
    function test_Success_mineTargetRarity(
        uint256 x,
        uint96 nonce,
        address randomAddress,
        uint256 minTargetRarity
    ) public {
        // limit minTargetRarity to 1-2 leading zeroes for test efficiency
        minTargetRarity = bound(minTargetRarity, 1, 2);

        nonce = uint96(bound(nonce, 0, type(uint96).max - 1001));

        // fuzz a random Uniswap pool
        _initWorld(x);

        randomAddress = address(uint160(uint256(keccak256(abi.encode(randomAddress)))));

        vm.startPrank(randomAddress);

        // mine pool address
        (uint96 bestSalt, uint256 highestRarity) = panopticFactory.minePoolAddress(
            randomAddress,
            address(pool),
            poolKey,
            nonce,
            50_000,
            minTargetRarity
        );

        assertEq(
            highestRarity,
            PanopticMath.numberOfLeadingHexZeros(
                panopticFactory.create3Address(
                    bytes32(
                        abi.encodePacked(
                            uint80(uint160(randomAddress) >> 80),
                            uint80(uint256(keccak256(abi.encode(poolKey, pool)))),
                            bestSalt
                        )
                    )
                )
            )
        );

        // check highestRarity address was reached or surpassed
        assertGe(highestRarity, minTargetRarity);
    }

    /*//////////////////////////////////////////////////////////////
                COMPUTE FULL RANGE LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// Replicated logic from _mintFullRange in Panoptic Factory
    function computeFullRangeLiquidity()
        internal
        returns (uint128 fullRangeLiquidity, uint256, uint256)
    {
        // get current tick
        (uint160 currentSqrtPriceX96, , , , , , ) = pool.slot0();

        // For full range: L = Δx * sqrt(P) = Δy / sqrt(P)
        // We start with fixed delta amounts and apply this equation to calculate the liquidity
        unchecked {
            // Since we know one of the tokens is WETH, we simply add 0.1 ETH + worth in tokens
            if (token0 == _WETH) {
                fullRangeLiquidity = uint128(
                    Math.mulDivRoundingUp(
                        FULL_RANGE_LIQUIDITY_AMOUNT_WETH,
                        currentSqrtPriceX96,
                        Constants.FP96
                    )
                );
            } else if (token1 == _WETH) {
                fullRangeLiquidity = uint128(
                    Math.mulDivRoundingUp(
                        FULL_RANGE_LIQUIDITY_AMOUNT_WETH,
                        Constants.FP96,
                        currentSqrtPriceX96
                    )
                );
            } else {
                // Find the resulting liquidity for providing 1e6 of both tokens
                uint128 liquidity0 = uint128(
                    Math.mulDivRoundingUp(
                        FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN,
                        currentSqrtPriceX96,
                        Constants.FP96
                    )
                );
                uint128 liquidity1 = uint128(
                    Math.mulDivRoundingUp(
                        FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN,
                        Constants.FP96,
                        currentSqrtPriceX96
                    )
                );

                // Pick the greater of the liquidities - i.e the more "expensive" option
                // This ensures that the liquidity added is sufficiently large
                fullRangeLiquidity = liquidity0 > liquidity1 ? liquidity0 : liquidity1;
            }

            // simulate the amounts minted in the Uniswap pool
            uint256 snapshot = vm.snapshot();
            (int256 amount0, int256 amount1) = routerV4.modifyLiquidity(
                address(0),
                poolKey,
                (TickMath.MIN_TICK / tickSpacing) * tickSpacing,
                (TickMath.MAX_TICK / tickSpacing) * tickSpacing,
                int256(uint256(fullRangeLiquidity))
            );

            // revert state
            vm.revertTo(snapshot);

            return (fullRangeLiquidity, uint256(-amount0), uint256(-amount1));
        }
    }
}
