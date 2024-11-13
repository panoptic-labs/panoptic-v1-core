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
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {Constants} from "@libraries/Constants.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
import {Errors} from "@libraries/Errors.sol";
// Panoptic Types
import {Pointer, PointerLibrary} from "@types/Pointer.sol";
// Panoptic Interfaces
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

contract PanopticFactoryHarness is PanopticFactory {
    constructor(
        SemiFungiblePositionManager _SFPM,
        IUniswapV3Factory _univ3Factory,
        address poolReference,
        address collateralReference,
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    )
        PanopticFactory(
            _SFPM,
            _univ3Factory,
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
}

contract PanopticFactoryTest is Test {
    // the instance of the Panoptic Factory we are testing
    PanopticFactoryHarness panopticFactory;

    // Mainnet WETH smart contract address
    address _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Mainnet factory address
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    // deploy the semiFungiblePositionManager
    SemiFungiblePositionManager sfpm = new SemiFungiblePositionManager(V3FACTORY, 10 ** 13, 0);

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

        // give test contract a sufficient amount of tokens to deploy a new pool
        deal(token0, address(this), INITIAL_MOCK_TOKENS);
        deal(token1, address(this), INITIAL_MOCK_TOKENS);
        assertEq(IERC20Partial(token0).balanceOf(address(this)), INITIAL_MOCK_TOKENS, "token0");
        assertEq(IERC20Partial(token1).balanceOf(address(this)), INITIAL_MOCK_TOKENS, "token1");

        // approve factory to move tokens, on behalf of the test contract
        IERC20Partial(token0).approve(address(panopticFactory), INITIAL_MOCK_TOKENS);
        IERC20Partial(token1).approve(address(panopticFactory), INITIAL_MOCK_TOKENS);

        // approve sfpm to move tokens, on behalf of the test contract
        IERC20Partial(token0).approve(address(sfpm), INITIAL_MOCK_TOKENS);
        IERC20Partial(token1).approve(address(sfpm), INITIAL_MOCK_TOKENS);

        // approve self
        IERC20Partial(token0).approve(address(this), INITIAL_MOCK_TOKENS);
        IERC20Partial(token1).approve(address(this), INITIAL_MOCK_TOKENS);
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
            sfpm,
            V3FACTORY,
            address(new PanopticPool(sfpm)),
            address(new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20_000)),
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
        address poolReference = panopticFactory.getPoolReference();
        address preComputedPool = predictDeterministicAddress(
            poolReference,
            bytes32(
                abi.encodePacked(
                    uint80(uint160(address(this)) >> 80),
                    uint80(uint160(address(pool)) >> 80),
                    salt
                )
            ),
            address(panopticFactory)
        );

        {
            // Deploy pool
            // links the Uniswap V3 pool to the Panoptic pool
            PanopticPool deployedPool = panopticFactory.deployNewPool(token0, token1, fee, salt);

            // see if pool exists at the precomputed address
            uint256 size;
            assembly ("memory-safe") {
                size := extcodesize(preComputedPool)
            }
            // check if bytecode is greater than 0
            assertGt(size, 0);

            // check if pool is linked to the correct panoptic pool in factory
            assertEq(address(panopticFactory.getPanopticPool(pool)), address(deployedPool));
            // see if correct pool was linked in the panopticPool
            IUniswapV3Pool linkedPool = PanopticPool(preComputedPool).univ3pool();
            address linkedPoolAddress = address(PanopticPool(preComputedPool).univ3pool());
            assertEq(address(pool), linkedPoolAddress);

            // check the pool has the correct parameters
            assertEq(token0, linkedPool.token0());
            assertEq(token1, linkedPool.token1());
            assertEq(fee, linkedPool.fee());
        }
    }

    // Revert if trying to deploy a Panoptic Pool ontop of an invalid Uniswap Pool
    function test_Fail_deployinvalidPool() public {
        // generate a not so random salt
        uint96 salt = uint96(block.timestamp);

        // Deploy invalid pool (uninitalized tokens and fee)
        vm.expectRevert(Errors.UniswapPoolNotInitialized.selector);
        panopticFactory.deployNewPool(token0, token1, fee, salt);
    }

    // Revert if deploying a Panoptic Pool that has already been initalized
    function test_Fail_deployExistingPool() public {
        // No need to fuzz as we are testing for a specific condition
        // use pool[0] -> DAI_USDC_1
        _initalizeWorldState(pools[0]);

        // generate a not so random salt
        uint96 salt = uint96(block.timestamp);

        // Deploy pool
        panopticFactory.deployNewPool(token0, token1, fee, salt);

        // Attempt to deploy pool again
        vm.expectRevert(Errors.PoolAlreadyInitialized.selector);
        unchecked {
            panopticFactory.deployNewPool(token0, token1, fee, salt + 1);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          NFT TOKEN URI TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_tokenURI_decodes() public {
        _initalizeWorldState(pools[1]);
        uint96 salt = uint96(block.timestamp);
        PanopticPool deployedPool = panopticFactory.deployNewPool(token0, token1, fee, salt);
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
            nonce,
            50_000,
            minTargetRarity
        );

        assertEq(
            highestRarity,
            PanopticMath.numberOfLeadingHexZeros(
                predictDeterministicAddress(
                    panopticFactory.getPoolReference(),
                    bytes32(
                        abi.encodePacked(
                            uint80(uint160(randomAddress) >> 80),
                            uint80(uint160(address(pool)) >> 80),
                            bestSalt
                        )
                    ),
                    address(panopticFactory)
                )
            )
        );

        // check highestRarity address was reached or surpassed
        assertGe(highestRarity, minTargetRarity);
    }

    /*//////////////////////////////////////////////////////////////
                    PRECOMPUTE CLONE ADDRESS
    //////////////////////////////////////////////////////////////*/

    /* Internal functions used in base contract logic replicated for redundancy
       If a change is made to the logic makeup of these functions in the core contracts,
       Then they will have to be equally changed in the tests 
    */

    /// Computes the address of a clone deployed using {Clones-cloneDeterministic}.
    /// Replicated from the Clones library in OZ (internal as it cannot be called directly)
    function predictDeterministicAddress(
        address implementation,
        bytes32 salt,
        address deployer
    ) internal pure returns (address predicted) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), deployer)
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), implementation)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), salt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            predicted := keccak256(add(ptr, 0x43), 0x55)
        }
    }
}
