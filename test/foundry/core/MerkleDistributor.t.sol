pragma solidity ^0.8.0;

// Foundry
import "forge-std/Test.sol";
// OpenZeppelin
import {Strings} from "@openzeppelin/contracts/utils/strings.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
// Panoptic Core
import {MerkleDistributor} from "@contracts/MerkleDistributor.sol";
import {GatedFactory} from "@contracts/GatedFactory.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
// Panoptic Libraries
import {PanopticMath} from "@contracts/libraries/PanopticMath.sol";
import {Math} from "@contracts/libraries/PanopticMath.sol";
import {Errors} from "@contracts/libraries/Errors.sol";
import {LeftRight} from "@contracts/types/LeftRight.sol";
import {TokenId} from "@contracts/types/TokenId.sol";
import {LiquidityChunk} from "@contracts/types/LiquidityChunk.sol";
// Panoptic Interfaces
import {IERC20Partial} from "@contracts/tokens/interfaces/IERC20Partial.sol";
// Uniswap - Panoptic's version 0.8
import {FullMath} from "v3-core/libraries/FullMath.sol";
// Uniswap Libraries
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {FixedPoint96} from "univ3-core/libraries/FixedPoint96.sol";
// Solidity Merkle Tree Implementation
import {Merkle} from "@contracts/murky/Merkle.sol";
// test utils
import "../testUtils/PositionUtils.sol";

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

contract MerkleDistributorTest is Test, PositionUtils {
    using TokenId for uint256;
    using LiquidityChunk for uint256;
    using LeftRight for uint256;

    // Merkle contract
    Merkle m;

    // the instance of the Panoptic Factory we are testing
    GatedFactory panopticFactory;

    // the instance of the Panoptic Factory we are testing
    PanopticPool panopticPool;

    CollateralTracker collateralToken0;
    CollateralTracker collateralToken1;

    MerkleDistributor merkleDistributor;
    address merkleDistributorAddr;

    address deployer = address(0x10);
    address Bob = address(0x20);

    uint128 positionSize0;
    uint256[] positionIdList1;
    uint256[] positionIdList;
    uint256 tokenId;
    uint256 tokenId1;

    address underlyingToken0;
    address underlyingToken1;
    address deployedPoolAddress;

    uint256 sharesToken0;
    uint256 sharesToken1;
    uint256 poolBalanceBefore0;
    uint256 poolBalanceBefore1;
    uint256 poolBalanceAfter0;
    uint256 poolBalanceAfter1;

    // Positional details
    int24 width;
    int24 strike;
    int24 width1;
    int24 strike1;
    int24 legLowerTick;
    int24 legUpperTick;
    uint160 sqrtRatioAX96;
    uint160 sqrtRatioBX96;
    uint256 tokenType;

    // liquidity
    uint256 liquidityChunk;
    uint256 liquidity;

    bytes32 nodeUser;
    bytes32[] data;
    bytes32 rootHash;
    bytes32[] proof;
    bool verified;

    // Mainnet WETH smart contract address
    address _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Mainnet factory address
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    // deploy the semiFungiblePositionManager
    SemiFungiblePositionManager sfpm = new SemiFungiblePositionManager(V3FACTORY);

    // store a few different mainnet pairs - the pool used is part of the fuzz
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    IUniswapV3Pool constant WBTC_ETH_30 =
        IUniswapV3Pool(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);

    IUniswapV3Pool constant MATIC_ETH_30 =
        IUniswapV3Pool(0x290A6a7460B308ee3F19023D2D00dE604bcf5B42);

    IUniswapV3Pool[3] public pools = [USDC_WETH_5, WBTC_ETH_30, MATIC_ETH_30];

    // granted token amounts
    uint256 constant initialMockTokens = type(uint256).max;

    // store some data about the pool we are testing
    IUniswapV3Pool pool;
    uint64 poolId;
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
    int24 currentTick;

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
        (, currentTick, , , , , ) = _pool.slot0();
        poolId = PanopticMath.getPoolId(address(_pool));

        // give test deployer a sufficient amount of tokens to deploy a new pool
        deal(token0, deployer, initialMockTokens);
        deal(token1, deployer, initialMockTokens);
        assertEq(IERC20Partial(token0).balanceOf(deployer), initialMockTokens);
        assertEq(IERC20Partial(token1).balanceOf(deployer), initialMockTokens);

        // approve factory to move tokens, on behalf of the test contract
        IERC20Partial(token0).approve(address(panopticFactory), initialMockTokens);
        IERC20Partial(token1).approve(address(panopticFactory), initialMockTokens);

        // approve sfpm to move tokens, on behalf of the test contract
        IERC20Partial(token0).approve(address(sfpm), initialMockTokens);
        IERC20Partial(token1).approve(address(sfpm), initialMockTokens);
    }

    function _grantTokens(address recipient) internal {
        // give sender the max amount of underlying tokens
        deal(token0, recipient, initialMockTokens);
        deal(token1, recipient, initialMockTokens);
        assertEq(IERC20Partial(token0).balanceOf(recipient), initialMockTokens);
        assertEq(IERC20Partial(token1).balanceOf(recipient), initialMockTokens);
    }

    function _murkyTreeGeneration(
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree
    ) internal {
        /* INITALIZE MERKLE TREE */

        // user's node in the tree
        nodeUser = keccak256(abi.encodePacked(claimIndex, Bob, maxDeposit0, maxDeposit1));

        // fill in the tree with the appropriate nodes
        data = new bytes32[](totalNodes);
        for (uint256 i; i < totalNodes; i++) {
            // if this is user Bob's node then fill with his generated hash data
            if (i == locInTree) {
                data[i] = nodeUser;
                continue;
            }

            data[i] = bytes32(i); // mock data
        }

        /* Get Root, Proof, and Verify */
        rootHash = m.getRoot(data);
        proof = m.getProof(data, locInTree); // get proof for Bob's node
        verified = m.verifyProof(rootHash, proof, data[locInTree]); // verify the node
        assertTrue(verified, "Initial Merkle tree generation failed!");
    }

    function _deploymentSetup(uint96 salt) internal {
        changePrank(deployer);

        IUniswapV3Pool mockPool = IUniswapV3Pool(
            address(new MockUniswapPool(token0, token1, tickSpacing, currentTick, fee))
        );

        IUniswapV3Factory mockFactory = IUniswapV3Factory(
            address(new MockUniswapFactory(address(mockPool)))
        );
        SemiFungiblePositionManager sfpm = new SemiFungiblePositionManager(mockFactory);

        address poolReference = address(new PanopticPool(sfpm));
        address collateralReference = address(new CollateralTracker());

        panopticFactory = new GatedFactory(deployer);

        PanopticPool newPoolContract = panopticFactory.deployNewPool(
            IUniswapV3Pool(mockPool),
            sfpm,
            poolReference,
            collateralReference,
            bytes32(0)
        );
        deployedPoolAddress = address(panopticPool);

        collateralToken0 = CollateralTracker(newPoolContract.collateralToken0());
        collateralToken1 = CollateralTracker(newPoolContract.collateralToken1());

        // token0 and token1 of the Uniswap pool
        underlyingToken0 = collateralToken0.asset();
        underlyingToken1 = collateralToken1.asset();

        assertEq(address(newPoolContract.univ3pool()), address(mockPool));

        assertEq(sfpm.getPoolId(address(mockPool)), PanopticMath.getPoolId(address(mockPool)));

        // initialize new merkle tree
        m = new Merkle();

        // Get the MerkleDistributor
        merkleDistributor = panopticPool.merkleDistributor();
        merkleDistributorAddr = address(merkleDistributor);
    }

    function setUp() public {}

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    // initial factory owner set
    function test_Success_factoryOwner(uint256 x, uint96 salt) public {
        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        /* Check correct owner is set on factory contract  */
        assertEq(deployer, panopticFactory.factoryOwner());

        /* Check correct owner is set on merkle distributor */
        assertEq(address(panopticFactory), address(merkleDistributor.factory()));
    }

    // initial gating status
    function test_Success_gatingStatus(uint256 x, uint96 salt) public {
        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        (bool closeOnly, bool paused) = panopticPool.viewGateStatus();

        /* Check correct initial gating statuses are set  */
        assertEq(false, closeOnly);
        assertEq(false, paused);
    }

    // changing gating status
    function test_Success_changeGatingStatus(uint256 x, uint96 salt) public {
        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        {
            panopticPool.setGateStatus(true, false);

            (bool closeOnly, bool paused) = panopticPool.viewGateStatus();

            /* Check correct initial gating statuses are set  */
            assertEq(true, closeOnly);
            assertEq(false, paused);
        }

        {
            panopticPool.setGateStatus(false, true);

            (bool closeOnly, bool paused) = panopticPool.viewGateStatus();

            /* Check correct initial gating statuses are set  */
            assertEq(false, closeOnly);
            assertEq(true, paused);
        }

        {
            panopticPool.setGateStatus(true, false);

            (bool closeOnly, bool paused) = panopticPool.viewGateStatus();

            /* Check correct initial gating statuses are set  */
            assertEq(true, closeOnly);
            assertEq(false, paused);
        }

        {
            panopticPool.setGateStatus(true, true);

            (bool closeOnly, bool paused) = panopticPool.viewGateStatus();

            /* Check correct initial gating statuses are set  */
            assertEq(true, closeOnly);
            assertEq(true, paused);
        }
    }

    // fail change as non-owner
    function test_Fail_changeGatingStatus(uint256 x, uint96 salt) public {
        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        changePrank(Bob);
        vm.expectRevert(Errors.NotOwner.selector);
        panopticPool.setGateStatus(true, false);
    }

    // changing factory owner
    function test_Success_changeGatingStatus_NewOwner(uint256 x, uint96 salt) public {
        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        {
            panopticFactory.setOwner(Bob);

            changePrank(Bob);
            panopticPool.setGateStatus(true, true);

            (bool closeOnly, bool paused) = panopticPool.viewGateStatus();

            /* Check correct initial gating statuses are set  */
            assertEq(true, closeOnly);
            assertEq(true, paused);
        }
    }

    // fail deposit outside of merkle distributor
    function test_Fail_directDeposit(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1
    ) public {
        {
            maxDeposit0 = bound(maxDeposit0, 1, type(uint104).max);
            maxDeposit1 = bound(maxDeposit1, 1, type(uint104).max);
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), maxDeposit0);
        IERC20Partial(token1).approve(address(collateralToken1), maxDeposit1);

        // should fail as only deposits via the merkleDistributor are allowed
        vm.expectRevert(Errors.unauthorizedDepositor.selector);
        collateralToken0.deposit(maxDeposit0, Bob);

        vm.expectRevert(Errors.unauthorizedDepositor.selector);
        collateralToken1.deposit(maxDeposit1, Bob);
    }

    // fail deposit mint outside of merkle distributor
    function test_Fail_directMint(
        uint256 x,
        uint96 salt,
        uint256 maxMint0,
        uint256 maxMint1
    ) public {
        {
            maxMint0 = bound(maxMint0, 1, type(uint104).max);
            maxMint1 = bound(maxMint1, 1, type(uint104).max);
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        maxMint0 = uint104(bound(maxMint0, 0, (uint256(type(uint104).max) * 1000) / 1001));
        maxMint1 = uint104(bound(maxMint1, 0, (uint256(type(uint104).max) * 1000) / 1001));

        // the amount of assets that would be deposited
        uint256 assetsToken0 = convertToAssets(maxMint0, collateralToken0);
        uint256 assetsToken1 = convertToAssets(maxMint1, collateralToken1);

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), assetsToken0);
        IERC20Partial(token1).approve(address(collateralToken1), assetsToken1);

        // should fail as only deposits via the merkleDistributor are allowed
        vm.expectRevert(Errors.unauthorizedDepositor.selector);
        collateralToken0.mint(maxMint0, Bob);

        vm.expectRevert(Errors.unauthorizedDepositor.selector);
        collateralToken1.mint(maxMint1, Bob);
    }

    /*//////////////////////////////////////////////////////////////
                        DISTRIBUTOR DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/
    // fuzz for a random pool, asset amounts to deposit , and claim at a random index
    // Mock amount of nodes in the tree
    // Mock the location in the tree (node index) where the user we are testing for is located
    function test_Success_claim(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree
    ) public {
        {
            maxDeposit0 = bound(maxDeposit0, 1, type(uint104).max);
            maxDeposit1 = bound(maxDeposit1, 1, type(uint104).max);
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(maxDeposit0, maxDeposit1, claimIndex, totalNodes, locInTree);

        // set the initial root (root must not be initalized as null)
        merkleDistributor.updateRoot(rootHash);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve the MerkleDistributor to move tokens on the Bob's behalf
        IERC20Partial(token0).approve(merkleDistributorAddr, maxDeposit0);
        IERC20Partial(token1).approve(merkleDistributorAddr, maxDeposit1);

        // hardcoded for now
        uint256 mevTax0 = FullMath.mulDiv(maxDeposit0, uint128(10), 10_000);
        uint256 mevTax1 = FullMath.mulDiv(maxDeposit1, uint128(10), 10_000);

        // // the amount of shares that can be minted
        // // supply == 0 ? assets : FullMath.mulDiv(assets, supply, totalAssets());
        sharesToken0 = convertToShares(maxDeposit0 - mevTax0, collateralToken0);
        sharesToken1 = convertToShares(maxDeposit1 - mevTax1, collateralToken1);

        // balance of panoptic pool before
        poolBalanceBefore0 = IERC20Partial(underlyingToken0).balanceOf(deployedPoolAddress);
        poolBalanceBefore1 = IERC20Partial(underlyingToken1).balanceOf(deployedPoolAddress);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);

        // balance of panoptic pool after
        poolBalanceAfter0 = IERC20Partial(underlyingToken0).balanceOf(deployedPoolAddress);
        poolBalanceAfter1 = IERC20Partial(underlyingToken1).balanceOf(deployedPoolAddress);

        /* VERIFY STATE CHANGES */

        // check if receiver got the shares
        assertEq(sharesToken0, collateralToken0.balanceOf(Bob), "shares given to Bob 0");
        assertEq(sharesToken1, collateralToken1.balanceOf(Bob), "shares given to Bob 1");

        // check if the panoptic pool got transferred the correct underlying assets
        assertEq(maxDeposit0, poolBalanceAfter0 - poolBalanceBefore0, "assets given to Pool 0");
        assertEq(maxDeposit1, poolBalanceAfter1 - poolBalanceBefore1, "assets given to Pool 1");

        // ensure the bitmap index was claimed/flipped correctly
        assertTrue(merkleDistributor.isClaimed(claimIndex), "Index in bitmap was claimed");
    }

    function test_Fail_dualDeposit(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree
    ) public {
        {
            maxDeposit0 = bound(maxDeposit0, 1, type(uint104).max);
            maxDeposit1 = bound(maxDeposit1, 1, type(uint104).max);
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(maxDeposit0, maxDeposit1, claimIndex, totalNodes, locInTree);

        /* DEPLOYMENT PROCESS */

        {
            // Deploy pool
            // links the uni v3 pool to the Panoptic pool
            panopticPool = panopticFactory.deployNewPool(
                deployer,
                token0,
                token1,
                currentTick,
                fee
            );
            deployedPoolAddress = address(panopticPool);

            // get the Collateral Tokens
            collateralToken0 = panopticPool.collateralToken0();
            collateralToken1 = panopticPool.collateralToken1();

            // token0 and token1 of the Uniswap pool
            underlyingToken0 = collateralToken0.asset();
            underlyingToken1 = collateralToken1.asset();

            // Get the MerkleDistributor
            merkleDistributor = panopticPool.merkleDistributor();
            merkleDistributorAddr = address(merkleDistributor);

            // set the initial root (root must not be initalized as null)
            merkleDistributor.updateRoot(rootHash);
        }

        {
            /* INVOKE CLAIM ON DISTRIBUTOR  */

            // Invoke all interactions with the Collateral Tracker from user Bob
            changePrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve the MerkleDistributor to move tokens on the Bob's behalf
            IERC20Partial(token0).approve(merkleDistributorAddr, maxDeposit0);
            IERC20Partial(token1).approve(merkleDistributorAddr, maxDeposit1);

            // deposit a number of assets determined via fuzzing
            // equal deposits for both collateral token pairs for testing purposes
            merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);

            // fails as the user has already claimed
            vm.expectRevert(Errors.InvalidClaim.selector);
            merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);
        }
    }

    function test_Fail_invalidProof(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree,
        bytes32[] calldata proof
    ) public {
        {
            maxDeposit0 = bound(maxDeposit0, 1, type(uint104).max);
            maxDeposit1 = bound(maxDeposit1, 1, type(uint104).max);
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(maxDeposit0, maxDeposit1, claimIndex, totalNodes, locInTree);

        /* DEPLOYMENT PROCESS */

        {
            // Deploy pool
            // links the uni v3 pool to the Panoptic pool
            panopticPool = panopticFactory.deployNewPool(token0, token1, fee, salt);
            deployedPoolAddress = address(panopticPool);

            // get the Collateral Tokens
            collateralToken0 = panopticPool.collateralToken0();
            collateralToken1 = panopticPool.collateralToken1();

            // token0 and token1 of the Uniswap pool
            underlyingToken0 = collateralToken0.asset();
            underlyingToken1 = collateralToken1.asset();

            // Get the MerkleDistributor
            merkleDistributor = panopticPool.merkleDistributor();
            merkleDistributorAddr = address(merkleDistributor);

            // set the initial root (root must not be initalized as null)
            merkleDistributor.updateRoot(rootHash);
        }

        {
            /* INVOKE CLAIM ON DISTRIBUTOR  */

            // Invoke all interactions with the Collateral Tracker from user Bob
            changePrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve the MerkleDistributor to move tokens on the Bob's behalf
            IERC20Partial(token0).approve(merkleDistributorAddr, maxDeposit0);
            IERC20Partial(token1).approve(merkleDistributorAddr, maxDeposit1);

            // fails as the proof is invalid
            vm.expectRevert(Errors.InvalidProof.selector);
            merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ROOT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_generatedRoot(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree
    ) public {
        {
            maxDeposit0 = bound(maxDeposit0, 1, type(uint104).max);
            maxDeposit1 = bound(maxDeposit1, 1, type(uint104).max);
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(maxDeposit0, maxDeposit1, claimIndex, totalNodes, locInTree);

        // set the initial root (root must not be initalized as null)
        merkleDistributor.updateRoot(rootHash);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve the MerkleDistributor to move tokens on the Bob's behalf
        IERC20Partial(token0).approve(merkleDistributorAddr, maxDeposit0);
        IERC20Partial(token1).approve(merkleDistributorAddr, maxDeposit1);

        uint256 mevTax0 = FullMath.mulDiv(maxDeposit0, uint128(10), 10_000);
        uint256 mevTax1 = FullMath.mulDiv(maxDeposit1, uint128(10), 10_000);

        // // the amount of shares that can be minted
        // // supply == 0 ? assets : FullMath.mulDiv(assets, supply, totalAssets());
        sharesToken0 = convertToShares(maxDeposit0 - mevTax0, collateralToken0);
        sharesToken1 = convertToShares(maxDeposit1 - mevTax1, collateralToken1);

        // balance of panoptic pool before
        poolBalanceBefore0 = IERC20Partial(underlyingToken0).balanceOf(deployedPoolAddress);
        poolBalanceBefore1 = IERC20Partial(underlyingToken1).balanceOf(deployedPoolAddress);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);

        // balance of panoptic pool after
        poolBalanceAfter0 = IERC20Partial(underlyingToken0).balanceOf(deployedPoolAddress);
        poolBalanceAfter1 = IERC20Partial(underlyingToken1).balanceOf(deployedPoolAddress);

        /* VERIFY STATE CHANGES */

        // check if receiver got the shares
        assertApproxEqAbs(sharesToken0, collateralToken0.balanceOf(Bob), 1, "shares given to Bob");
        assertApproxEqAbs(sharesToken1, collateralToken1.balanceOf(Bob), 1, "shares given to Bob");

        // check if the panoptic pool got transferred the correct underlying assets
        assertEq(maxDeposit0, (poolBalanceAfter0 - poolBalanceBefore0), "assets given to Pool 0");
        assertEq(maxDeposit1, poolBalanceAfter1 - poolBalanceBefore1, "assets given to Pool 1");

        // ensure the bitmap index was claimed/flipped correctly
        assertTrue(merkleDistributor.isClaimed(claimIndex), "Index in bitmap was claimed");
    }

    function test_Success_multipleRootChange(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree
    ) public {
        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);
        _deploymentSetup(salt);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        for (uint256 i = 0; i < 5; i++) {
            {
                maxDeposit0 = bound(maxDeposit0, 1, type(uint32).max) + block.timestamp;
                maxDeposit1 = bound(maxDeposit1, 1, type(uint32).max) + block.timestamp;
                totalNodes = uint8(bound(totalNodes, 10, type(uint128).max)); // must be more than 1 node in tree
                locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
                claimIndex = i;
            }

            /// The following actions are executed by the deployment account
            changePrank(deployer);
            _murkyTreeGeneration(maxDeposit0, maxDeposit1, claimIndex, totalNodes, locInTree);

            // set the initial root (root must not be initalized as null)
            merkleDistributor.updateRoot(rootHash);

            /* INVOKE CLAIM ON DISTRIBUTOR  */

            // Invoke all interactions with the Collateral Tracker from user Bob
            changePrank(Bob);

            // approve the MerkleDistributor to move tokens on the Bob's behalf
            IERC20Partial(token0).approve(merkleDistributorAddr, maxDeposit0);
            IERC20Partial(token1).approve(merkleDistributorAddr, maxDeposit1);

            // deposit a number of assets determined via fuzzing
            // equal deposits for both collateral token pairs for testing purposes
            merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);

            /* VERIFY STATE CHANGES */

            // ensure the bitmap index was claimed/flipped correctly
            assertTrue(merkleDistributor.isClaimed(claimIndex), "Index in bitmap was claimed");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        GENERAL ACTIVITY TESTS
    //////////////////////////////////////////////////////////////*/
    function test_Success_mintAfterDeposit(
        uint256 x,
        uint96 salt,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree,
        uint128 positionSizeSeed,
        int256 strikeSeed,
        uint256 widthSeed
    ) public {
        uint256 deposit = type(uint104).max;
        {
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(deposit, deposit, claimIndex, totalNodes, locInTree);

        // Deploy pool
        // links the uni v3 pool to the Panoptic pool
        panopticPool = panopticFactory.deployNewPool(token0, token1, fee, salt);
        deployedPoolAddress = address(panopticPool);

        // get the Collateral Tokens
        collateralToken0 = panopticPool.collateralToken0();
        collateralToken1 = panopticPool.collateralToken1();

        // Get the MerkleDistributor
        merkleDistributor = panopticPool.merkleDistributor();
        merkleDistributorAddr = address(merkleDistributor);

        // set the initial root (root must not be initalized as null)
        merkleDistributor.updateRoot(rootHash);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve the MerkleDistributor to move tokens on the Bob's behalf
        IERC20Partial(token0).approve(merkleDistributorAddr, deposit);
        IERC20Partial(token1).approve(merkleDistributorAddr, deposit);

        // equal deposits for both collateral token pairs for testing purposes
        merkleDistributor.claim(claimIndex, deposit, deposit, proof);

        // mint an option
        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            1
        );

        // sell as Bob
        tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
        positionIdList.push(tokenId);

        positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 18));
        _assumePositionValidity(Bob, tokenId, positionSize0);

        changePrank(Bob);
        panopticPool.mintOptions(positionIdList, positionSize0, 0, 0, 0);
    }

    function test_Success_mintRollAfterDeposit(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree,
        uint128 positionSizeSeed,
        int256 strikeSeed,
        uint256 widthSeed,
        int256 strikeSeed1,
        uint256 widthSeed1
    ) public {
        {
            maxDeposit0 = type(uint104).max;
            maxDeposit1 = type(uint104).max;
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /* DEPLOYMENT PROCESS */
        _initWorld(x);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(maxDeposit0, maxDeposit1, claimIndex, totalNodes, locInTree);

        // Deploy pool
        // links the uni v3 pool to the Panoptic pool
        panopticPool = panopticFactory.deployNewPool(token0, token1, fee, salt);
        deployedPoolAddress = address(panopticPool);

        // get the Collateral Tokens
        collateralToken0 = panopticPool.collateralToken0();
        collateralToken1 = panopticPool.collateralToken1();

        // Get the MerkleDistributor
        merkleDistributor = panopticPool.merkleDistributor();
        merkleDistributorAddr = address(merkleDistributor);

        // set the initial root (root must not be initalized as null)
        merkleDistributor.updateRoot(rootHash);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve the MerkleDistributor to move tokens on the Bob's behalf
        IERC20Partial(token0).approve(merkleDistributorAddr, maxDeposit0);
        IERC20Partial(token1).approve(merkleDistributorAddr, maxDeposit1);

        // equal deposits for both collateral token pairs for testing purposes
        merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);

        // mint an option
        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        // mint an option
        (width1, strike1) = PositionUtils.getOTMSW(
            widthSeed1,
            strikeSeed1,
            uint24(tickSpacing),
            currentTick,
            0
        );

        vm.assume(width1 != width || strike1 != strike);

        // sell as Bob
        positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 18));

        changePrank(Bob);

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);

        // leg 2
        tokenId = tokenId.addLeg(1, 1, 1, 0, 0, 1, strike1, width1);
        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            _assumePositionValidity(Bob, tokenId, positionSize0);
            panopticPool.mintOptions(posIdList, positionSize0, 0, 0, 0);
        }
        // fully roll leg 2 to the same as leg 1
        uint256 newTokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            1,
            0,
            0,
            0,
            strike,
            width
        );
        newTokenId = newTokenId.addLeg(1, 1, 1, 0, 0, 1, strike, width);

        panopticPool.rollOptions(tokenId, newTokenId, new uint256[](0), 0, 0, 0);

        assertEq(sfpm.balanceOf(address(panopticPool), tokenId), 0);
        assertEq(sfpm.balanceOf(address(panopticPool), newTokenId), positionSize0);
    }

    /* fail gating closed */

    function test_Fail_mintWhenClosed(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree,
        uint128 positionSizeSeed,
        int256 strikeSeed,
        uint256 widthSeed
    ) public {
        {
            maxDeposit0 = bound(maxDeposit0, 1, type(uint104).max);
            maxDeposit1 = bound(maxDeposit1, 1, type(uint104).max);
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(maxDeposit0, maxDeposit1, claimIndex, totalNodes, locInTree);

        // Deploy pool
        // links the uni v3 pool to the Panoptic pool
        panopticPool = panopticFactory.deployNewPool(token0, token1, fee, salt);
        deployedPoolAddress = address(panopticPool);

        /* set pool status to closed */
        panopticPool.setGateStatus(true, false);

        // get the Collateral Tokens
        collateralToken0 = panopticPool.collateralToken0();
        collateralToken1 = panopticPool.collateralToken1();

        // Get the MerkleDistributor
        merkleDistributor = panopticPool.merkleDistributor();
        merkleDistributorAddr = address(merkleDistributor);

        // set the initial root (root must not be initalized as null)
        merkleDistributor.updateRoot(rootHash);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve the MerkleDistributor to move tokens on the Bob's behalf
        IERC20Partial(token0).approve(merkleDistributorAddr, maxDeposit0);
        IERC20Partial(token1).approve(merkleDistributorAddr, maxDeposit1);

        // equal deposits for both collateral token pairs for testing purposes
        merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);

        // mint an option
        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            1
        );

        // sell as Bob
        tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
        positionIdList.push(tokenId);
        positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 18));

        changePrank(Bob);
        vm.expectRevert(Errors.NotOpen.selector);
        panopticPool.mintOptions(positionIdList, positionSize0, 0, 0, 0);
    }

    function test_Fail_mintWhenClosedv2(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree,
        uint128 positionSizeSeed,
        int256 strikeSeed,
        uint256 widthSeed
    ) public {
        {
            maxDeposit0 = type(uint104).max;
            maxDeposit1 = type(uint104).max;
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(maxDeposit0, maxDeposit1, claimIndex, totalNodes, locInTree);

        // Deploy pool
        // links the uni v3 pool to the Panoptic pool
        panopticPool = panopticFactory.deployNewPool(token0, token1, fee, salt);
        deployedPoolAddress = address(panopticPool);

        // get the Collateral Tokens
        collateralToken0 = panopticPool.collateralToken0();
        collateralToken1 = panopticPool.collateralToken1();

        // Get the MerkleDistributor
        merkleDistributor = panopticPool.merkleDistributor();
        merkleDistributorAddr = address(merkleDistributor);

        // set the initial root (root must not be initalized as null)
        merkleDistributor.updateRoot(rootHash);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve the MerkleDistributor to move tokens on the Bob's behalf
        IERC20Partial(token0).approve(merkleDistributorAddr, maxDeposit0);
        IERC20Partial(token1).approve(merkleDistributorAddr, maxDeposit1);

        // equal deposits for both collateral token pairs for testing purposes
        merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);

        // mint an option
        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            1
        );

        // sell as Bob
        tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
        positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 18));

        _assumePositionValidity(Bob, tokenId, positionSize0);

        changePrank(Bob);
        positionIdList.push(tokenId);
        panopticPool.mintOptions(positionIdList, positionSize0, 0, 0, 0);

        /* set pool status to closed */
        changePrank(deployer);
        panopticPool.setGateStatus(true, false);

        // attempt to mint again after gating status has been closed
        changePrank(Bob);
        positionIdList.push(tokenId);
        vm.expectRevert(Errors.NotOpen.selector);
        panopticPool.mintOptions(positionIdList, positionSize0, 0, 0, 0);
    }

    // test_Fail_rollWhenClosed
    function test_Fail_rollWhenClosed(
        uint256 x,
        uint96 salt,
        uint256 maxDeposit0,
        uint256 maxDeposit1,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree,
        uint128 positionSizeSeed,
        int256 strikeSeed,
        uint256 widthSeed,
        int256 strikeSeed1,
        uint256 widthSeed1
    ) public {
        {
            maxDeposit0 = type(uint104).max;
            maxDeposit1 = type(uint104).max;
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(maxDeposit0, maxDeposit1, claimIndex, totalNodes, locInTree);

        // Deploy pool
        // links the uni v3 pool to the Panoptic pool
        panopticPool = panopticFactory.deployNewPool(token0, token1, fee, salt);
        deployedPoolAddress = address(panopticPool);

        /* set pool status to closed */
        //panopticPool.setGateStatus(true, false);

        // get the Collateral Tokens
        collateralToken0 = panopticPool.collateralToken0();
        collateralToken1 = panopticPool.collateralToken1();

        // Get the MerkleDistributor
        merkleDistributor = panopticPool.merkleDistributor();
        merkleDistributorAddr = address(merkleDistributor);

        // set the initial root (root must not be initalized as null)
        merkleDistributor.updateRoot(rootHash);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve the MerkleDistributor to move tokens on the Bob's behalf
        IERC20Partial(token0).approve(merkleDistributorAddr, maxDeposit0);
        IERC20Partial(token1).approve(merkleDistributorAddr, maxDeposit1);

        // equal deposits for both collateral token pairs for testing purposes
        merkleDistributor.claim(claimIndex, maxDeposit0, maxDeposit1, proof);

        // mint an option
        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        // mint an option
        (width1, strike1) = PositionUtils.getOTMSW(
            widthSeed1,
            strikeSeed1,
            uint24(tickSpacing),
            currentTick,
            0
        );

        vm.assume(width1 != width || strike1 != strike);

        // sell as Bob
        positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 18));

        changePrank(Bob);

        // leg 1
        uint256 tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);

        // leg 2
        tokenId = tokenId.addLeg(1, 1, 1, 0, 0, 1, strike1, width1);
        {
            uint256[] memory posIdList = new uint256[](1);
            posIdList[0] = tokenId;

            _assumePositionValidity(Bob, tokenId, positionSize0);
            panopticPool.mintOptions(posIdList, positionSize0, 0, 0, 0);
        }
        // fully roll leg 2 to the same as leg 1
        uint256 newTokenId = uint256(0).addUniv3pool(poolId).addLeg(
            0,
            1,
            1,
            0,
            0,
            0,
            strike,
            width
        );
        newTokenId = newTokenId.addLeg(1, 1, 1, 0, 0, 1, strike, width);

        /* set pool status to closed */
        changePrank(deployer);
        panopticPool.setGateStatus(true, false);

        // attempt to mint again after gating status has been closed
        changePrank(Bob);
        positionIdList.push(tokenId);
        vm.expectRevert(Errors.NotOpen.selector);
        panopticPool.rollOptions(tokenId, newTokenId, new uint256[](0), 0, 0, 0);
    }

    /* pause tests */
    // - liquidate fail
    // - force exercise fail
    // - roll fail
    // - mint fail
    // - deposit fail
    // - burn fail
    // - withdraw fail

    /* withdrawal tests */
    // - deposit and withdraw
    function test_Success_depositWithdraw(
        uint256 x,
        uint96 salt,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree,
        uint128 positionSizeSeed,
        int256 strikeSeed,
        uint256 widthSeed
    ) public {
        uint256 deposit = type(uint104).max;
        {
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(deposit, deposit, claimIndex, totalNodes, locInTree);

        // Deploy pool
        // links the uni v3 pool to the Panoptic pool
        panopticPool = panopticFactory.deployNewPool(token0, token1, fee, salt);
        deployedPoolAddress = address(panopticPool);

        // get the Collateral Tokens
        collateralToken0 = panopticPool.collateralToken0();
        collateralToken1 = panopticPool.collateralToken1();

        // Get the MerkleDistributor
        merkleDistributor = panopticPool.merkleDistributor();
        merkleDistributorAddr = address(merkleDistributor);

        // set the initial root (root must not be initalized as null)
        merkleDistributor.updateRoot(rootHash);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve the MerkleDistributor to move tokens on the Bob's behalf
        IERC20Partial(token0).approve(merkleDistributorAddr, deposit);
        IERC20Partial(token1).approve(merkleDistributorAddr, deposit);

        // equal deposits for both collateral token pairs for testing purposes
        merkleDistributor.claim(claimIndex, deposit, deposit, proof);

        uint256 maxWithdraw0 = collateralToken0.maxWithdraw(Bob);
        uint256 maxWithdraw1 = collateralToken1.maxWithdraw(Bob);

        // bob's token balance before withdraw
        uint256 balanceBefore0 = IERC20Partial(token0).balanceOf(Bob);
        uint256 balanceBefore1 = IERC20Partial(token1).balanceOf(Bob);

        // withdraw
        changePrank(Bob);
        collateralToken0.withdraw(maxWithdraw0, Bob, Bob);
        collateralToken1.withdraw(maxWithdraw1, Bob, Bob);

        // bob's token balance after withdraw
        uint256 balanceAfter0 = IERC20Partial(token0).balanceOf(Bob);
        uint256 balanceAfter1 = IERC20Partial(token1).balanceOf(Bob);

        // ensure underlying tokens were received back
        assertEq(maxWithdraw0, balanceAfter0 - balanceBefore0);
        assertEq(maxWithdraw1, balanceAfter1 - balanceBefore1);
    }

    // - deposit mint and then burn
    function test_Success_mintBurnAfterDeposit(
        uint256 x,
        uint96 salt,
        uint256 claimIndex,
        uint8 totalNodes,
        uint8 locInTree,
        uint128 positionSizeSeed,
        int256 strikeSeed,
        uint256 widthSeed
    ) public {
        uint256 deposit = type(uint104).max;
        {
            totalNodes = uint8(bound(totalNodes, 2, type(uint128).max)); // must be more than 1 node in tree
            locInTree = uint8(bound(locInTree, 0, totalNodes - 1)); // index of nodes [0, len - 1]
        }

        /// The following actions are executed by the deployment account

        /* DEPLOYMENT PROCESS */
        _initWorld(x);

        /// The following actions are executed by the deployment account
        _murkyTreeGeneration(deposit, deposit, claimIndex, totalNodes, locInTree);

        // Deploy pool
        // links the uni v3 pool to the Panoptic pool
        panopticPool = panopticFactory.deployNewPool(token0, token1, fee, salt);
        deployedPoolAddress = address(panopticPool);

        // get the Collateral Tokens
        collateralToken0 = panopticPool.collateralToken0();
        collateralToken1 = panopticPool.collateralToken1();

        // Get the MerkleDistributor
        merkleDistributor = panopticPool.merkleDistributor();
        merkleDistributorAddr = address(merkleDistributor);

        // set the initial root (root must not be initalized as null)
        merkleDistributor.updateRoot(rootHash);

        /* INVOKE CLAIM ON DISTRIBUTOR  */

        // Invoke all interactions with the Collateral Tracker from user Bob
        changePrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve the MerkleDistributor to move tokens on the Bob's behalf
        IERC20Partial(token0).approve(merkleDistributorAddr, deposit);
        IERC20Partial(token1).approve(merkleDistributorAddr, deposit);

        // equal deposits for both collateral token pairs for testing purposes
        merkleDistributor.claim(claimIndex, deposit, deposit, proof);

        // mint an option
        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            1
        );

        // sell as Bob
        tokenId = uint256(0).addUniv3pool(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
        positionIdList.push(tokenId);

        positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 18));
        _assumePositionValidity(Bob, tokenId, positionSize0);

        changePrank(Bob);
        panopticPool.mintOptions(positionIdList, positionSize0, 0, 0, 0);
        panopticPool.burnOptions(positionIdList, 0, 0);

        // ensure bob's position was liquidated
        (uint128 bobPositionBal, , ) = panopticPool.optionPositionBalance(Bob, tokenId);
        assertEq(0, bobPositionBal);
    }

    /* simulate multiple random epochs of new users and changing the root */

    /*//////////////////////////////////////////////////////////////
                        CROSS REFERENCE
    //////////////////////////////////////////////////////////////*/

    // @note dynamically read in from csv file
    bytes32[] tree = [
        bytes32(0xedf04969ea0ce2b31b005f602e258eb9168ffb1ca1b4ec31564267b8f0ea744f),
        bytes32(0xab6eca0ecfa10993f87aa33a7a1963f74ea5cb2c49bce6a1fc0c4200f345a204),
        bytes32(0xdf694a5cf0d90a6c4a53c63fc1ab281687b5f128dfd6d0bada0e060e746121f2),
        bytes32(0x4a9f2809ecb04e3be1530ff2d91570ba36fb552d5d7a413bcaf76132d50d17cb),
        bytes32(0x2c87ef20d0bd853898ad3fadb24275eb94a55a9f859d7fe43bbd7264253a6de9),
        bytes32(0xd9650d69789b4e18d555b8afa0eaf26bacb31ea4ab8cc5f8e29f0861fff16669),
        bytes32(0xbaeca2ce66be1280d04e2f38ff7efbcfeb2b0d4c338eb610dc5566f7df582cd9),
        bytes32(0xcf6b78f35a354688b59ab70d367ddcb625db6d1f51de4329cfda03c1153646fb),
        bytes32(0xc8666ecb6182e7bf783e5b5bd62aa7258c6e5bdad86852292badcd1467008f95),
        bytes32(0xf4c83235af034c3d720076648d7a94e3c39d6aaa50627c25946be8ef3df636eb),
        bytes32(0xaa3ac3e57b1bb3c4c32afa884b9a6c52b09562e1a440e5574a5daea6553cb2b6),
        bytes32(0xfdb6a106298d42e4826d10298761bf85719daa272cbb2104b7b45eb73a942d91),
        bytes32(0x534687cdfbbb97abffdfd686dec3d0e00b4f0e95b51835067212400d7cd136a3),
        bytes32(0xa10e5f938245119738c065e0c111a63bef5cb038fe30afb63cc2cc616b30f830),
        bytes32(0xe8171b20b097f884663cbb48e338c2908de01459ff5eb26b2e5c9c0baae61d7a),
        bytes32(0x5381510b27dc1b05fe214dee27b6bd1df5cfd3bb126a19c8b4f19394d5709366),
        bytes32(0xda9fdbb6cc267029aaed9de587ab15275bde8f3d9610324a260cce832759170e),
        bytes32(0x9f3bbdfdae5579f1f7b2901762b8998bcde2f8208945887352aba6fe831d3d8e),
        bytes32(0x818f8c178931845f62ab3a004006cedfecc45c00c1427d164cb58250f7f226e7),
        bytes32(0x4f1128bb0c71b81fd57af430e98b23a4e3a878aa79646c74e4b8ba5e1e9d5a1d),
        bytes32(0x31f8727515c86bc1843af3e15a2fe0d82710eae428781a6b8d7fcb936fc80bac),
        bytes32(0x9bc6ec18405148cdd4519518e240d80fbf71744b1a79dbb91ffb799a59369925),
        bytes32(0x57250c94d9ad8950b618436e249cf9ac68461c25299ba663d2faaf0f681ad968),
        bytes32(0x216d5b18f3838a41d060ca60bc89dc98f98d851221ab0e130e225dc628c7cc19),
        bytes32(0x614c6a0b59a10e3c9cb3553ba491f22eb0a50871261af81821ab92d16a7f993f),
        bytes32(0xa5ecddc4b6916d869c01ec0b13684609a5362a4aa5af69dbf3545f23c29efaf0),
        bytes32(0x0c3646e78048d0cde5725846baa7a7cf6eb80899e0cc64f1b835ff9fac8bcb4e),
        bytes32(0x7c4170464ddccbd1809f84fde46176b3928729b995f924f2f290e28c7794fca0),
        bytes32(0x38231a6db6d591655db8db0993a13a6c085a008324f5b2073f477880e19451d1),
        bytes32(0xdbfbccd952cbf51e0dd3cf3f13033be0065a221d9572af2d74f13748224bad8c),
        bytes32(0x3eff0c9a9c411cd4af3b9f003868eeaebdd50a37285f16a70211b0870e7a5571),
        bytes32(0x5b8cda9f1b1e6db720d8c4c2692bdee15c22cd305f1b11ac6b0cb8a9d94f1825),
        bytes32(0xf78f67dd553471e8c70aa641d031c1ccb5fbe757668d9857d416469ab0d5c0ee),
        bytes32(0xeb5fa9d56e26f88eaef942b6a04a1b5e7b3570f30a2baccee7dbee7e8b02c963),
        bytes32(0xe41312f418ba1790df9fe270bc71b499deec92a994fbeb87e4402c85e03207fa),
        bytes32(0xdccec0bbfd12300ad97603f560ae80f1c9b01b15f1784f5a9111e53b64e715ee),
        bytes32(0xd6a5ca596b688fddb39ed5e7b9d970e718646b522536814ac4fac28c8a972895),
        bytes32(0xcec59cfa15ab0b04b5bbfc960ebcee398f05d934e020a75566f279d73b0c50f0),
        bytes32(0xbfc858c1c9dfd6160c6763896b7342c1266cb3701f7d914590ca9d2951fa6443),
        bytes32(0xa0d3c326b47c82c19f6eaf7449614c48fd57974bc2771436e8e3b3b8d2e0b2d4),
        bytes32(0x96e6c7285a12969fb336ec1c1a7f6567db148b905e44adf0086dddaec2e6ddab),
        bytes32(0x936e14b670b19a28efcd6501df7e882f42a9561dd3127ba05b1d791dbc207422),
        bytes32(0x8fbb8f670652e0ad9fb8828a93b875ee879cbc35cd22169833de1ca588188025),
        bytes32(0x8bb7cb2b2766ae746f841a8583d49b2c4136c3b9f80d896f576f3c7d66a3db0b),
        bytes32(0x8bb0d65361aa83c69abfe906cc4fc82ae5e11c6f6929a6af5da7ec67ebd67a1e),
        bytes32(0x8797a957ec34f8136be4e48c63cafab67861ce2a9112c114b163b848bd9940f3),
        bytes32(0x773679dad5ab465eb4cd7808d96212ef6ee53d17fd9e0db8ccdc444280ffbfa3),
        bytes32(0x714191e0efca37c4ba7aca2afe3cd9e503d7ffc7c38cc3831dc220675023fbbe),
        bytes32(0x6a8a8880b3bc6759aa5172d3705daaada17356c68a6b6cc6e4e4d9f09d4e97f1),
        bytes32(0x68d9ce823211e71b77d3bc6840cd3d344b3b52ea415800281572ea9541a41aa7),
        bytes32(0x5c0d8a66ae88b726bb0e9c1524314e70a9b027eeffee29cab17ced2e9e945e33),
        bytes32(0x55795800d2219785a58b35f35a0bed1c4b0418ebaf55e64edaa05651be7eefe2),
        bytes32(0x4f3d1a2b2e9f46952e28f81688eca150daeeabb966b3e1fcfcf50d96a346de34),
        bytes32(0x47fe12016d1ab2199a12752b7d3f4740a6f1746b2668278b01f3cfa3191a46e2),
        bytes32(0x44f3944791b23527489eb55dcb9b2ccfa60659130f8bec8ec369b5de6a330233),
        bytes32(0x3ca45a75927c92b0530338c596f96e5b4e8ba359180686312ed59f3004a0ae45),
        bytes32(0x3c0a41364f303c9e16877a72d51a2b3525562e2dce6a1cdc37349af48caaacca),
        bytes32(0x39233be0493f6d436b1ed3387b070d8f3c8d5f01c21dba3d7d897fd162ea6413),
        bytes32(0x38c299ddc85b9bb7d784ad4d43d4c1081262e6e2a39fb99b73f7507085049d78),
        bytes32(0x38638af29e11d0b5de45743113876db2641850ef14144bc841b70c5da07d3121),
        bytes32(0x24f61541991aae60f13310e8769e561c17dfb59542f9cd997137245c5fb6de42),
        bytes32(0x1c0c720e934ffa8436d0ebe7df2cb27fa8a4d5a612160a8e1dc0583fac733107),
        bytes32(0x12bc3bab6cab62f9d8c74dbf159125db8969588ecddc69321eb12aa29287eedc),
        bytes32(0x061d467ec61a26970ce1d116625e420e09dd3d82df782b11498ce4a447b9acd3),
        bytes32(0x05f2afa137866791fa458dc2e11e32c4f4d561f091713437f6c3c43c4de0523a)
    ];

    // check if generated proofs are identical
    function test_Success_crossReference(uint32 node) public {
        // verify cross reference
        vm.assume(tree.length > 1);
        vm.assume(node < 32);
        bytes32 root = m.getRoot(tree);
        proof = m.getProof(tree, node);
        bytes32 valueToProve = proof[node];
        bool murkyVerified = m.verifyProof(root, proof, valueToProve);
        bool ozVerified = MerkleProof.verify(proof, root, valueToProve);
        assertTrue(murkyVerified == ozVerified);
    }

    // ensures enviornment is setup correctly
    // function test_Success_JSImplementationFuzzed(bytes32[] memory leaves) public {
    //     vm.assume(leaves.length > 1);
    //     bytes memory packed = abi.encodePacked(leaves);
    //     string[] memory runJsInputs = new string[](8);

    //     // build ffi command string
    //     runJsInputs[0] = 'npm';
    //     runJsInputs[1] = '--prefix';
    //     runJsInputs[2] = 'differential_testing/scripts/';
    //     runJsInputs[3] = '--silent';
    //     runJsInputs[4] = 'run';
    //     runJsInputs[5] = 'generate-root-cli';
    //     runJsInputs[6] = leaves.length.toString();
    //     runJsInputs[7] = packed.toHexString();

    //     // run and captures output
    //     bytes memory jsResult = vm.ffi(runJsInputs);
    //     bytes32 jsGeneratedRoot = abi.decode(jsResult, (bytes32));

    //     // Calculate root using Murky
    //     bytes32 murkyGeneratedRoot = m.getRoot(leaves);
    //     assertEq(murkyGeneratedRoot, jsGeneratedRoot);
    // }

    /*//////////////////////////////////////////////////////////////
                    REPLICATED FUNCTIONS (TEST HELPERS)
    //////////////////////////////////////////////////////////////*/

    function convertToShares(
        uint256 assets,
        CollateralTracker collateralToken
    ) public view returns (uint256 shares) {
        uint256 supply = collateralToken.totalSupply();
        return
            supply == 0
                ? assets
                : PanopticMath.mulDivDown(assets, supply, collateralToken.totalAssets());
    }

    function convertToAssets(
        uint256 shares,
        CollateralTracker collateralToken
    ) public view returns (uint256 assets) {
        uint256 supply = collateralToken.totalSupply();
        return
            supply == 0
                ? shares
                : PanopticMath.mulDivDown(shares, collateralToken.totalAssets(), supply);
    }

    /*//////////////////////////////////////////////////////////////
                    POSITION VALIDITY CHECKER
    //////////////////////////////////////////////////////////////*/

    struct CallbackData {
        PoolAddress.PoolKey univ3poolKey;
        address payer;
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
            TransferHelper.safeTransferFrom(
                decoded.univ3poolKey.token0,
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            TransferHelper.safeTransferFrom(
                decoded.univ3poolKey.token1,
                decoded.payer,
                msg.sender,
                amount1Owed
            );
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
            ? address(decoded.univ3poolKey.token0)
            : address(decoded.univ3poolKey.token1);

        // Transform the amount to pay to uint256 (take positive one from amount0 and amount1)
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        // Pay the required token from the payer to the caller of this contract
        TransferHelper.safeTransferFrom(token, decoded.payer, msg.sender, amountToPay);
    }

    function _swapITM(int128 itm0, int128 itm1) internal {
        // Initialize variables
        bool zeroForOne; // The direction of the swap, true for token0 to token1, false for token1 to token0
        int256 swapAmount; // The amount of token0 or token1 to swap
        bytes memory data;

        // construct the swap callback struct
        data = abi.encode(
            CallbackData({
                univ3poolKey: PoolAddress.PoolKey({
                    token0: pool.token0(),
                    token1: pool.token1(),
                    fee: pool.fee()
                }),
                payer: address(panopticPool)
            })
        );

        if ((itm0 != 0) && (itm1 != 0)) {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

            /// @dev we need to compare (deltaX = itm0 - itm1/price) to (deltaY =  itm1 - itm0 * price) to only swap the owed balance
            /// To reduce the number of computation steps, we do the following:
            ///    deltaX = (itm0*sqrtPrice - itm1/sqrtPrice)/sqrtPrice
            ///    deltaY = -(itm0*sqrtPrice - itm1/sqrtPrice)*sqrtPrice
            int256 net0 = itm0 + PanopticMath.convert1to0(itm1, sqrtPriceX96);

            int256 net1 = itm1 + PanopticMath.convert0to1(itm0, sqrtPriceX96);

            // if net1 is negative, then the protocol has a surplus of token0
            zeroForOne = net1 < net0;

            //compute the swap amount, set as positive (exact input)
            swapAmount = zeroForOne ? net0 : net1;
        } else if (itm0 != 0) {
            zeroForOne = itm0 < 0;
            swapAmount = -itm0;
        } else {
            zeroForOne = itm1 > 0;
            swapAmount = -itm1;
        }

        // assert the pool has enough funds to complete the swap for an ITM position (exchange tokens to token type)
        bytes memory callData = abi.encodeCall(
            pool.swap,
            (
                address(panopticPool),
                zeroForOne,
                swapAmount,
                zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                data
            )
        );
        (bool ok, ) = address(pool).call(callData);
        vm.assume(ok);
    }

    // Checks to see that a valid position is minted via simulation
    // asserts that the leg is sufficiently large enough to meet dust threshold requirement
    // also ensures that this is a valid mintable position in uniswap (i.e liquidity amount too much for pool, then fuzz a new positionSize)
    function _assumePositionValidity(
        address caller,
        uint256 tokenId,
        uint128 positionSize
    ) internal {
        // take a snapshot at this storage state
        uint256 snapshot = vm.snapshot();
        {
            IERC20Partial(token0).approve(address(sfpm), type(uint256).max);
            IERC20Partial(token1).approve(address(sfpm), type(uint256).max);

            // mock mints and burns from the SFPM
            changePrank(address(sfpm));
        }

        int128 itm0;
        int128 itm1;

        uint256 maxLoop = tokenId.countLegs();
        for (uint256 i; i < maxLoop; i++) {
            // basis
            uint256 numeraire = tokenId.numeraire(i);

            // token type we are transacting in
            tokenType = tokenId.tokenType(i);

            // position bounds
            (legLowerTick, legUpperTick) = tokenId.asTicks(i, tickSpacing);

            // sqrt price of bounds
            sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(legLowerTick);
            sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(legUpperTick);

            if (sqrtRatioAX96 > sqrtRatioBX96)
                (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

            /// get the liquidity
            if (numeraire == 0) {
                uint256 intermediate = PanopticMath.mulDiv96(sqrtRatioAX96, sqrtRatioBX96);
                liquidity = FullMath.mulDiv(
                    positionSize,
                    intermediate,
                    sqrtRatioBX96 - sqrtRatioAX96
                );
            } else {
                liquidity = FullMath.mulDiv(
                    positionSize,
                    FixedPoint96.Q96,
                    sqrtRatioBX96 - sqrtRatioAX96
                );
            }

            // liquidity should be less than 128 bits
            vm.assume(liquidity != 0 && liquidity < type(uint128).max);

            /// assert the notional value is valid
            uint128 contractSize = positionSize * uint128(tokenId.optionRatio(i));

            uint256 notional = numeraire == 0
                ? PanopticMath.convert0to1(
                    contractSize,
                    TickMath.getSqrtRatioAtTick((legUpperTick + legLowerTick) / 2)
                )
                : PanopticMath.convert1to0(
                    contractSize,
                    TickMath.getSqrtRatioAtTick((legUpperTick + legLowerTick) / 2)
                );
            vm.assume(notional != 0 && notional < type(uint128).max);

            uint256 amountsMoved = PanopticMath.getAmountsMoved(
                tokenId,
                positionSize,
                i,
                tickSpacing
            );
            amountsMoved = tokenType == 0 ? amountsMoved.rightSlot() : amountsMoved.leftSlot();

            /// simulate mint/burn
            // mint in pool if short
            if (tokenId.isLong(i) == 0) {
                try
                    pool.mint(
                        address(sfpm),
                        legLowerTick,
                        legUpperTick,
                        uint128(liquidity),
                        abi.encode(
                            CallbackData({
                                univ3poolKey: PoolAddress.PoolKey({
                                    token0: pool.token0(),
                                    token1: pool.token1(),
                                    fee: pool.fee()
                                }),
                                payer: address(panopticPool)
                            })
                        )
                    )
                returns (uint256 amount0, uint256 amount1) {
                    // assert that it meets the dust threshold requirement
                    vm.assume(
                        (amount0 > 50 && amount0 < uint128(type(int128).max)) ||
                            (amount1 > 50 && amount1 < uint128(type(int128).max))
                    );

                    if (tokenType == 1) {
                        itm0 += int128(uint128(amount0));
                    } else {
                        itm1 += int128(uint128(amount1));
                    }
                } catch {
                    vm.assume(false); // invalid position, discard
                }
            } else {
                pool.burn(legLowerTick, legUpperTick, uint128(liquidity));
            }
        }

        if (itm0 != 0 || itm1 != 0)
            // assert the pool has enough funds to complete the swap if ITM
            _swapITM(itm0, itm1);

        // rollback to the previous storage state
        vm.revertTo(snapshot);

        // revert back to original caller
        changePrank(caller);
    }
}
