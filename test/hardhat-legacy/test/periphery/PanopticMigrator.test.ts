/**
 * Test PanopticMigrator.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { config, deployments, ethers, network, getNamedAccounts, network } from "hardhat";
import { expect } from "chai";
import { BigNumber, Signer } from "ethers";
import {
  ERC20,
  IERC20__factory,
  IUniswapV3Pool,
  SemiFungiblePositionManager,
  INonfungiblePositionManager,
  PanopticMigrator,
  SemiFungiblePositionManager__factory,
} from "../../typechain";
import * as OptionEncoding from "../Libraries/OptionEncoding";
import { grantTokens, revertReason } from "../utils";

const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_SLOT = 9;
const token0 = USDC_ADDRESS;

const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const WETH_SLOT = 3;
const token1 = WETH_ADDRESS;

const ETH_USDC_POOL_ADDRESS = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640";

describe("PanopticMigrator", function () {
  let positionManager: SemiFungiblePositionManager;
  let NonFungiblePositionManager: INonfungiblePositionManager;
  let migrator: PanopticMigrator;
  let pool: IUniswapV3Pool;
  let startingBlockNumber = 14822946;

  let deployer: Signer;
  let alice: Signer;

  let tick: number;
  let sqrtPriceX96: BigNumber;

  const SFPMContractName = "SemiFungiblePositionManager";
  const MigratorContractName = "PanopticMigrator";

  beforeEach(async () => {
    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.NODE_URL,
            blockNumber: 14487083,
          },
        },
      ],
    });

    [deployer, alice] = await ethers.getSigners();

    await deployments.fixture([
      "FeesCalc",
      "Math",
      "PanopticMath",
      "InteractionHelper",
      "LeftRight",
      "TokenId",
      SFPMContractName,
      MigratorContractName,
    ]);
    const { address: sfpmAddress } = await deployments.get(SFPMContractName);
    const { address: migratorAddress } = await deployments.get(MigratorContractName);
    positionManager = (await ethers.getContractAt(
      SFPMContractName,
      sfpmAddress,
    )) as SemiFungiblePositionManager;
    NonFungiblePositionManager = (await ethers.getContractAt(
      "INonfungiblePositionManager",
      "0xC36442b4a4522E871399CD717aBDD847Ab11FE88",
    )) as INonfungiblePositionManager;
    migrator = (await ethers.getContractAt(
      MigratorContractName,
      migratorAddress,
    )) as PanopticMigrator;
    const ETH_USDC_POOL_ADDRESS = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640";

    pool = (await ethers.getContractAt(
      "contracts/external/uniswapv3_core/contracts/interfaces/IUniswapV3Pool.sol:IUniswapV3Pool",
      ETH_USDC_POOL_ADDRESS,
    )) as IUniswapV3Pool;

    ({ sqrtPriceX96, tick } = await pool.slot0());
    tick = tick - (tick % 10);
    // initialize the pool
    // we need funds to do that due to the full-range deployment of funds
    const usdcBalance = ethers.utils.parseUnits("520000000", "6");
    const wethBalance = ethers.utils.parseEther("1000");

    await grantTokens(token1, await deployer.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(token0, await deployer.getAddress(), USDC_SLOT, usdcBalance);
    await IERC20__factory.connect(token1, deployer).approve(
      sfpmAddress,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(token0, deployer).approve(
      sfpmAddress,
      ethers.constants.MaxUint256,
    );

    let tx = await positionManager.initializeAMMPool(token0, token1, 500);
    await tx.wait();
  });

  it("migration of in-range NFPM position (to SFPM) succeeds", async () => {
    //get required tokens
    await grantTokens(token1, await alice.getAddress(), WETH_SLOT, ethers.utils.parseEther("100"));
    await grantTokens(
      token0,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("100000", "6"),
    );
    //approve NonFungiblePositionManager for tokens
    await IERC20__factory.connect(token1, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(token0, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    //create in-range position on NonFungiblePositionManager
    let res = await NonFungiblePositionManager.connect(alice).mint({
      token0: token0,
      token1: token1,
      fee: 500,
      tickLower: 195000,
      tickUpper: 195030,
      amount0Desired: ethers.utils.parseUnits("100000", "6"),
      amount1Desired: ethers.utils.parseEther("100"),
      amount0Min: 0,
      amount1Min: 0,
      recipient: await alice.getAddress(),
      deadline: 4825814790,
    });
    let NFTokenId = (await res.wait()).events[3].args.tokenId.toNumber();
    let initliq = (await NonFungiblePositionManager.positions(NFTokenId)).liquidity;
    await NonFungiblePositionManager.connect(alice).approve(migrator.address, NFTokenId);
    //migrate position to SemiFungiblePositionManager
    await migrator.connect(alice).migrateToPanoptic(NFTokenId);
    const tokenId = OptionEncoding.encodeID(
      BigInt(ETH_USDC_POOL_ADDRESS.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 3,
          strike: 195015,
          riskPartner: 0,
          ratio: 1,
          tokenType: 0,
          asset: 0,
          long: false,
        },
      ],
    );

    expect(await positionManager.balanceOf(await alice.getAddress(), tokenId)).to.equal(
      215736925815,
    );
    expect(
      initliq -
        (
          await positionManager.getAccountLiquidity(
            pool.address,
            await alice.getAddress(),
            0,
            195000,
            195030,
          )
        )[1],
    ).to.be.lessThanOrEqual(68638464);
  });

  it("migration of below-range NFPM position (to SFPM) succeeds", async () => {
    //get required tokens
    await grantTokens(token1, await alice.getAddress(), WETH_SLOT, ethers.utils.parseEther("100"));
    await grantTokens(
      token0,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("100000", "6"),
    );
    //approve NonFungiblePositionManager for tokens
    await IERC20__factory.connect(token1, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(token0, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    //create in-range position on NonFungiblePositionManager
    let res = await NonFungiblePositionManager.connect(alice).mint({
      token0: token0,
      token1: token1,
      fee: 500,
      tickLower: 0,
      tickUpper: 30,
      amount0Desired: ethers.utils.parseUnits("100000", "6"),
      amount1Desired: ethers.utils.parseEther("100"),
      amount0Min: 0,
      amount1Min: 0,
      recipient: await alice.getAddress(),
      deadline: 4825814790,
    });
    let NFTokenId = (await res.wait()).events[3].args.tokenId.toNumber();
    let initliq = (await NonFungiblePositionManager.positions(NFTokenId)).liquidity;
    await NonFungiblePositionManager.connect(alice).approve(migrator.address, NFTokenId);
    //migrate position to SemiFungiblePositionManager
    await migrator.connect(alice).migrateToPanoptic(NFTokenId);
    expect(
      initliq -
        (
          await positionManager.getAccountLiquidity(
            pool.address,
            await alice.getAddress(),
            0,
            0,
            30,
          )
        )[1],
    ).to.be.lessThanOrEqual(0);
  });
  it("migration of above-range NFPM position (to SFPM) succeeds", async () => {
    //get required tokens
    await grantTokens(token1, await alice.getAddress(), WETH_SLOT, ethers.utils.parseEther("100"));
    await grantTokens(
      token0,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("100000", "6"),
    );
    //approve NonFungiblePositionManager for tokens
    await IERC20__factory.connect(token1, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(token0, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    //create in-range position on NonFungiblePositionManager
    let res = await NonFungiblePositionManager.connect(alice).mint({
      token0: token0,
      token1: token1,
      fee: 500,
      tickLower: 500000,
      tickUpper: 500030,
      amount0Desired: ethers.utils.parseUnits("100000", "6"),
      amount1Desired: ethers.utils.parseEther("100"),
      amount0Min: 0,
      amount1Min: 0,
      recipient: await alice.getAddress(),
      deadline: 4825814790,
    });
    let NFTokenId = (await res.wait()).events[3].args.tokenId.toNumber();
    let initliq = (await NonFungiblePositionManager.positions(NFTokenId)).liquidity;
    await NonFungiblePositionManager.connect(alice).approve(migrator.address, NFTokenId);
    //migrate position to SemiFungiblePositionManager
    await migrator.connect(alice).migrateToPanoptic(NFTokenId);
    expect(
      initliq -
        (
          await positionManager.getAccountLiquidity(
            pool.address,
            await alice.getAddress(),
            0,
            500000,
            500030,
          )
        )[1],
    ).to.be.lessThanOrEqual(287890047238144);
  });

  //  it("migration of NFPM position wider than 4094 ticks (to SFPM) fails", async () => {
  //   //get required tokens
  //   await grantTokens(token1, await alice.getAddress(), WETH_SLOT, ethers.utils.parseEther("100"));
  //   await grantTokens(token0, await alice.getAddress(), USDC_SLOT, ethers.utils.parseUnits("100000", "6"));
  //   //approve NonFungiblePositionManager for tokens
  //   await IERC20__factory.connect(token1, alice).approve(NonFungiblePositionManager.address, ethers.constants.MaxUint256);
  //   await IERC20__factory.connect(token0, alice).approve(NonFungiblePositionManager.address, ethers.constants.MaxUint256);
  //   //create in-range position on NonFungiblePositionManager
  //   let res = await NonFungiblePositionManager.connect(alice).mint({
  //       token0: token0,
  //       token1: token1,
  //       fee: 500,
  //       tickLower: 0,
  //       tickUpper: 4100,
  //       amount0Desired: ethers.utils.parseUnits("100000", "6"),
  //       amount1Desired: ethers.utils.parseEther("100"),
  //       amount0Min: 0,
  //       amount1Min: 0,
  //       recipient: await alice.getAddress(),
  //       deadline: 4825814790
  //   })
  //   let NFTokenId = (await res.wait()).events[3].args.tokenId.toNumber()
  //   await NonFungiblePositionManager.connect(alice).approve(migrator.address, NFTokenId);
  //   //migrate position to SemiFungiblePositionManager
  //   //await expect(migrator.connect(alice).migrateToPanoptic(NFTokenId)).to.be.revertedWith("RangeTooWide");
  //   await migrator.connect(alice).migrateToPanoptic(NFTokenId);
  //  });

  it("migration of Full-Range NFPM position success", async () => {
    //get required tokens
    await grantTokens(token1, await alice.getAddress(), WETH_SLOT, ethers.utils.parseEther("100"));
    await grantTokens(
      token0,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("100000", "6"),
    );
    //approve NonFungiblePositionManager for tokens
    await IERC20__factory.connect(token1, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(token0, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    //create in-range position on NonFungiblePositionManager
    let res = await NonFungiblePositionManager.connect(alice).mint({
      token0: token0,
      token1: token1,
      fee: 500,
      tickLower: -887270,
      tickUpper: 887270,
      amount0Desired: ethers.utils.parseUnits("1000", "6"),
      amount1Desired: ethers.utils.parseEther("1"),
      amount0Min: 0,
      amount1Min: 0,
      recipient: await alice.getAddress(),
      deadline: 4825814790,
    });
    let NFTokenId = (await res.wait()).events[3].args.tokenId.toNumber();
    await NonFungiblePositionManager.connect(alice).approve(migrator.address, NFTokenId);
    //migrate position to SemiFungiblePositionManager
    //await expect(migrator.connect(alice).migrateToPanoptic(NFTokenId)).to.be.revertedWith("RangeTooWide");
    await migrator.connect(alice).migrateToPanoptic(NFTokenId);
  });
  it("migration of 5-wei (below dust threshold) position underflows", async () => {
    //get required tokens
    await grantTokens(token1, await alice.getAddress(), WETH_SLOT, ethers.utils.parseEther("100"));
    await grantTokens(
      token0,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("100000", "6"),
    );
    //approve NonFungiblePositionManager for tokens
    await IERC20__factory.connect(token1, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(token0, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    //create in-range position on NonFungiblePositionManager
    let res = await NonFungiblePositionManager.connect(alice).mint({
      token0: token0,
      token1: token1,
      fee: 500,
      tickLower: 0,
      tickUpper: 30,
      amount0Desired: 0,
      amount1Desired: 5,
      amount0Min: 0,
      amount1Min: 0,
      recipient: await alice.getAddress(),
      deadline: 4825814790,
    });
    let NFTokenId = (await res.wait()).events[3].args.tokenId.toNumber();
    let initliq = (await NonFungiblePositionManager.positions(NFTokenId)).liquidity;
    await NonFungiblePositionManager.connect(alice).approve(migrator.address, NFTokenId);
    //migrate position to SemiFungiblePositionManager
    await expect(migrator.connect(alice).migrateToPanoptic(NFTokenId)).to.be.revertedWith("0x11");
  });
  it("migration of small (above 5 wei dust threshold and 10 wei sfpm threshold) NFPM position (to SFPM) succeeds", async () => {
    //get required tokens
    await grantTokens(token1, await alice.getAddress(), WETH_SLOT, ethers.utils.parseEther("100"));
    await grantTokens(
      token0,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("100000", "6"),
    );
    //approve NonFungiblePositionManager for tokens
    await IERC20__factory.connect(token1, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(token0, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    //create in-range position on NonFungiblePositionManager
    let res = await NonFungiblePositionManager.connect(alice).mint({
      token0: token0,
      token1: token1,
      fee: 500,
      tickLower: 0,
      tickUpper: 30,
      amount0Desired: 0,
      amount1Desired: 16,
      amount0Min: 0,
      amount1Min: 0,
      recipient: await alice.getAddress(),
      deadline: 4825814790,
    });
    let NFTokenId = (await res.wait()).events[3].args.tokenId.toNumber();
    let initliq = (await NonFungiblePositionManager.positions(NFTokenId)).liquidity;
    await NonFungiblePositionManager.connect(alice).approve(migrator.address, NFTokenId);
    //migrate position to SemiFungiblePositionManager
    await migrator.connect(alice).migrateToPanoptic(NFTokenId);
    await expect(
      initliq -
        (await positionManager.getAccountLiquidity(pool.address, alice.getAddress(), 0, 0, 30))[1],
    ).to.be.lessThanOrEqual(4000);
  });
  it("migration of extremely large NFPM position (to SFPM) succeeds (verify dust threshold high enough)", async () => {
    //get required tokens
    await grantTokens(
      token1,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("1000000000000"),
    );
    await grantTokens(
      token0,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("100000", "6"),
    );
    //approve NonFungiblePositionManager for tokens
    await IERC20__factory.connect(token1, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(token0, alice).approve(
      NonFungiblePositionManager.address,
      ethers.constants.MaxUint256,
    );
    //create in-range position on NonFungiblePositionManager
    let res = await NonFungiblePositionManager.connect(alice).mint({
      token0: token0,
      token1: token1,
      fee: 500,
      tickLower: 0,
      tickUpper: 30,
      amount0Desired: 0,
      amount1Desired: ethers.utils.parseEther("1000000000000"),
      amount0Min: 0,
      amount1Min: 0,
      recipient: await alice.getAddress(),
      deadline: 4825814790,
    });
    let NFTokenId = (await res.wait()).events[3].args.tokenId.toNumber();
    let initliq = (await NonFungiblePositionManager.positions(NFTokenId)).liquidity;
    await NonFungiblePositionManager.connect(alice).approve(migrator.address, NFTokenId);
    //migrate position to SemiFungiblePositionManager
    await migrator.connect(alice).migrateToPanoptic(NFTokenId);
    await expect(
      initliq -
        (await positionManager.getAccountLiquidity(pool.address, alice.getAddress(), 0, 0, 30))[1],
    ).to.be.lessThanOrEqual(4000);
  });
});
