// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

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
import {Errors} from "@libraries/Errors.sol";
// Panoptic Interfaces
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
// Uniswap
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {PoolAddress} from "v3-periphery/libraries/PoolAddress.sol";
import {CallbackValidation} from "v3-periphery/libraries/CallbackValidation.sol";
import {TransferHelper} from "v3-periphery/libraries/TransferHelper.sol";

contract PanopticFactoryHarness is PanopticFactory {
    constructor(
        address _WETH9,
        SemiFungiblePositionManager _SFPM,
        IUniswapV3Factory _univ3Factory,
        address poolReference,
        address collateralReference
    ) PanopticFactory(_WETH9, _SFPM, _univ3Factory, poolReference, collateralReference) {}

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
    SemiFungiblePositionManager sfpm = new SemiFungiblePositionManager(V3FACTORY);

    // store a few different mainnet pairs - the pool used is part of the fuzz

    // 0.01% pools
    IUniswapV3Pool constant DAI_USDC_1 = IUniswapV3Pool(0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168);
    IUniswapV3Pool constant USDC_USDT_1 =
        IUniswapV3Pool(0x3416cF6C708Da44DB2624D63ea0AAef7113527C6);

    // 0.05% pools
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IUniswapV3Pool constant FRAX_USDT_5 =
        IUniswapV3Pool(0xc2A856c3afF2110c1171B8f942256d40E980C726);
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
    IUniswapV3Pool[6] public pools = [
        // currently unsupported
        // DAI_USDC_1,
        // USDC_USDT_1,
        USDC_WETH_5,
        FRAX_USDT_5,
        WBTC_ETH_30,
        MATIC_ETH_30,
        INCH_USDC_100,
        ETH_USDT_5
    ];

    // granted token amounts
    uint256 constant INITIAL_MOCK_TOKENS = type(uint256).max;

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

    // Define the struct needed when minting a Uni v3 LP position
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
        assertEq(IERC20Partial(token0).balanceOf(address(this)), INITIAL_MOCK_TOKENS);
        assertEq(IERC20Partial(token1).balanceOf(address(this)), INITIAL_MOCK_TOKENS);

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
        // Deploy factory
        panopticFactory = new PanopticFactoryHarness(
            address(_WETH),
            sfpm,
            V3FACTORY,
            address(new PanopticPool(sfpm)),
            address(new CollateralTracker())
        );
    }

    /*//////////////////////////////////////////////////////////////
                        CONTRACT OWNER TESTS
    //////////////////////////////////////////////////////////////*/

    // When the owner, successfully change the owner
    function test_Success_setOwner(address newOwner) public {
        // Owner can't be changed to zero address -
        // or current owner
        vm.assume(newOwner != address(0) && address(this) != newOwner);

        // Change the factory owner
        panopticFactory.setOwner(newOwner);
        assertEq(newOwner, panopticFactory.factoryOwner());
    }

    // Expect failure when changing owner, while not the current owner
    function test_Fail_unauthorizedOwner(address unauthorizedOwner) public {
        // Owner can't be changed to zero address -
        // or current owner
        vm.assume(unauthorizedOwner != address(0));
        vm.assume(unauthorizedOwner != panopticFactory.factoryOwner());

        // begin impersonating transactions from fuzzed address
        vm.prank(unauthorizedOwner);

        // Attempt to change the factory owner from an unauthorized address
        vm.expectRevert(Errors.NotOwner.selector);
        panopticFactory.setOwner(unauthorizedOwner);
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
        bytes32 _salt = _getSalt(address(pool), address(this), salt);
        address preComputedPool = predictDeterministicAddress(
            poolReference,
            _salt,
            address(panopticFactory)
        );

        // Amount of liquidity currently in the univ3 pool
        uint128 liquidityBefore = pool.liquidity();

        // amount of assets held before mint
        uint256 balance0Before = IERC20Partial(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20Partial(token1).balanceOf(address(this));

        // Compute amount of liquidity to deploy
        (uint128 fullRangeLiquidity, uint256 amount0, uint256 amount1) = computeFullRangeLiquidity(
            address(panopticFactory)
        );

        {
            // Deploy pool
            // links the uni v3 pool to the Panoptic pool
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

        /* Liquidity checks */
        // Amount of liquidity in univ3 pool after Panoptic Pool deployment
        uint128 liquidityAfter = pool.liquidity();
        // ensure liquidity in pool now is sum of liquidity before and user deployed amount
        assertEq(liquidityAfter - liquidityBefore, fullRangeLiquidity);

        /* Shares checks */
        // check factory receives appropriate amount of shares
        // As this is the first deposit supply will be equal to zero
        // shares = supply == 0 ? assets : mulDiv(assets, supply, totalAssets());
        CollateralTracker collateralToken0 = PanopticPool(preComputedPool).collateralToken0();
        CollateralTracker collateralToken1 = PanopticPool(preComputedPool).collateralToken1();
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
        panopticFactory.deployNewPool(token0, token1, fee, salt);
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
        panopticFactory.deployNewPool(token0, token1, fee, salt);
    }

    function test_Fail_deployNewPool_UnsupportedPool() public {
        // tickSpacing on 1bps pools is 1, equal to the fee in bps
        // Panoptic only supports pools where TS is 2x the fee in bps
        _initalizeWorldState(USDC_USDT_1);

        vm.expectRevert(Errors.UniswapPoolNotSupported.selector);
        panopticFactory.deployNewPool(token0, token1, fee, 0);
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
        panopticFactory.deployNewPool(token0, token1, fee, salt + 1);
    }

    /*//////////////////////////////////////////////////////////////
                    MINE POOL ADDRESS TESTS
    //////////////////////////////////////////////////////////////*/

    // Successfully reach or surpass target rarity and deploy a Panoptic pool with the mined 'bestSalt'
    function test_Success_mineTargetRarity(uint256 x, uint96 salt, uint256 minTargetRarity) public {
        // limit minTargetRarity to 1-2 leading zeroes for test efficiency
        minTargetRarity = bound(minTargetRarity, 1, 2);

        // fuzz a random uniswap pool
        _initWorld(x);

        // mine pool address
        (uint96 bestSalt, uint256 highestRarity) = panopticFactory.minePoolAddress(
            token0,
            token1,
            fee,
            salt,
            address(this), // test contract is deployer
            50_000, // set cap on loops
            minTargetRarity
        );

        // check highestRarity address was reached or surpassed
        assertGe(highestRarity, minTargetRarity);

        // deploy pool
        panopticFactory.deployNewPool(token0, token1, fee, bestSalt);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC1155 RECEIVER HOOK
    //////////////////////////////////////////////////////////////*/
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
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

    // Replicated from PanopticFactory.sol
    function _getSalt(
        address v3Pool,
        address deployer,
        uint96 nonce
    ) internal pure returns (bytes32) {
        return
            bytes32(
                abi.encodePacked(PanopticMath.getPoolId(v3Pool), uint64(uint160(deployer)), nonce)
            );
    }

    /*//////////////////////////////////////////////////////////////
                COMPUTE FULL RANGE LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// Replicated logic from _mintFullRange in Panoptic Factory
    function computeFullRangeLiquidity(
        address panopticFactory
    ) internal returns (uint128 fullRangeLiquidity, uint256 amount0, uint256 amount1) {
        // get current tick
        (uint160 currentSqrtPriceX96, , , , , , ) = pool.slot0();

        // build callback data
        bytes memory mintdata = abi.encode(
            CallbackData({ // compute by reading values from univ3pool every time
                univ3poolKey: PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee}),
                payer: address(this)
            })
        );

        // For full range: L = Δx * sqrt(P) = Δy / sqrt(P)
        // We start with fixed delta amounts and apply this equation to calculate the liquidity
        unchecked {
            // Since we know one of the tokens is WETH, we simply add 0.1 ETH + worth in tokens
            if (token0 == _WETH) {
                fullRangeLiquidity = uint128(
                    (FULL_RANGE_LIQUIDITY_AMOUNT_WETH * currentSqrtPriceX96) / Constants.FP96
                );
            } else if (token1 == _WETH) {
                fullRangeLiquidity = uint128(
                    (FULL_RANGE_LIQUIDITY_AMOUNT_WETH * Constants.FP96) / currentSqrtPriceX96
                );
            } else {
                // Find the resulting liquidity for providing 1e6 of both tokens
                uint128 liquidity0 = uint128(
                    (FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN * currentSqrtPriceX96) / Constants.FP96
                );
                uint128 liquidity1 = uint128(
                    (FULL_RANGE_LIQUIDITY_AMOUNT_TOKEN * Constants.FP96) / currentSqrtPriceX96
                );

                // Pick the greater of the liquidities - i.e the more "expensive" option
                // This ensures that the liquidity added is sufficiently large
                fullRangeLiquidity = liquidity0 > liquidity1 ? liquidity0 : liquidity1;
            }

            // simulate the amounts minted in the uniswap pool
            uint256 snapshot = vm.snapshot();
            (amount0, amount1) = IUniswapV3Pool(pool).mint(
                address(this),
                (TickMath.MIN_TICK / tickSpacing) * tickSpacing,
                (TickMath.MAX_TICK / tickSpacing) * tickSpacing,
                fullRangeLiquidity,
                mintdata
            );

            // revert state
            vm.revertTo(snapshot);
        }
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        // Decode the mint callback data
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));
        // Validate caller to ensure we got called from the AMM pool
        CallbackLib.validateCallback(msg.sender, address(V3FACTORY), decoded.poolFeatures);

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
}
