/**
 * Test Rolling Options.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { deployments, ethers, network } from "hardhat";
import { expect } from "chai";
import { grantTokens, revertCustom } from "../utils";
import {
  IERC20__factory,
  IUniswapV3Pool,
  IUniswapV3Pool__factory,
  PanopticPool,
  ERC20,
  SemiFungiblePositionManager,
  ISwapRouter,
  CollateralTracker__factory,
} from "../../typechain";

import * as OptionEncoding from "../Libraries/OptionEncoding";
import * as UniswapV3 from "../Libraries/UniswapV3";

import { BigNumber, Signer } from "ethers";
import { maxLiquidityForAmounts, TickMath } from "@uniswap/v3-sdk";
import JSBI from "jsbi";
import { token } from "../../typechain/@openzeppelin/contracts";

const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_SLOT = 9;
const token0 = USDC_ADDRESS;

const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const WETH_SLOT = 3;
const token1 = WETH_ADDRESS;

const SWAP_ROUTER_ADDRESS = "0xE592427A0AEce92De3Edee1F18E0157C05861564";
const decimalUSDC = 6;
const decimalWETH = 18;

describe("Roll Positions", async function () {
  this.timeout(1000000);

  const contractName = "PanopticPool";
  const deploymentName = "PanopticPool-ETH-USDC";

  const SFPMContractName = "SemiFungiblePositionManager";
  const SFPMDeploymentName = "SemiFungiblePositionManager";

  let pool: PanopticPool;
  let uniPool: IUniswapV3Pool;

  let usdc: ERC20;
  let weth: ERC20;

  let collatToken0: ERC20;
  let collatToken1: ERC20;

  let deployer: Signer;
  let optionWriter: Signer;
  let optionBuyer: Signer;
  let liquidityProvider: Signer;
  let swapper: Signer;

  let depositor: address;
  let writor: address;
  let providor: address;
  let buyor: address;

  let poolId: bigint;
  let tick: number;
  let sqrtPriceX96: BigNumber;

  const usdcBalance = ethers.utils.parseUnits("100000000", "6");
  const wethBalance = ethers.utils.parseEther("1000000");

  const emptyPositionList: string[] = [];

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
    await deployments.fixture([
      deploymentName,
      "PanopticFactory",
      "CollateralTracker",
      "PanopticPool",
      "LeftRight",
      "TokenId",
      "FeesCalc",
      "OptionEncoding",
      "Math",
      "PanopticMath",
      "InteractionHelper",
      "SemiFungiblePositionManager",
    ]);
    const { address } = await deployments.get(deploymentName);
    [deployer, optionWriter, optionBuyer, liquidityProvider, swapper] = await ethers.getSigners();

    await grantTokens(WETH_ADDRESS, await deployer.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await deployer.getAddress(), USDC_SLOT, usdcBalance);

    await grantTokens(WETH_ADDRESS, await optionWriter.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await optionWriter.getAddress(), USDC_SLOT, usdcBalance);

    await grantTokens(WETH_ADDRESS, await optionBuyer.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await optionBuyer.getAddress(), USDC_SLOT, usdcBalance);

    await grantTokens(WETH_ADDRESS, await liquidityProvider.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await liquidityProvider.getAddress(), USDC_SLOT, usdcBalance);

    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, usdcBalance);

    pool = (await ethers.getContractAt(contractName, address)) as PanopticPool;

    usdc = await IERC20__factory.connect(USDC_ADDRESS, deployer);
    weth = await IERC20__factory.connect(WETH_ADDRESS, deployer);

    depositor = await deployer.getAddress();
    writor = await optionWriter.getAddress();
    buyor = await optionBuyer.getAddress();
    providor = await liquidityProvider.getAddress();

    collatToken0 = (await ethers.getContractAt("IERC20", await pool.collateralToken0())) as ERC20;
    collatToken1 = (await ethers.getContractAt("IERC20", await pool.collateralToken1())) as ERC20;

    const SFPMdeployment = await deployments.get(SFPMDeploymentName);

    const sfpm = (await ethers.getContractAt(
      SFPMContractName,
      SFPMdeployment.address,
    )) as SemiFungiblePositionManager;

    const uniPoolAddress = await pool.univ3pool();
    poolId = BigInt(uniPoolAddress.slice(0, 18).toLowerCase());

    uniPool = IUniswapV3Pool__factory.connect(uniPoolAddress, deployer);
    ({ sqrtPriceX96, tick } = await uniPool.slot0());

    //approvals
    await IERC20__factory.connect(WETH_ADDRESS, deployer).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, deployer).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, swapper).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, swapper).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, swapper).approve(
      uniPool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, swapper).approve(
      uniPool.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionWriter).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionWriter).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(WETH_ADDRESS, optionWriter).approve(
      uniPool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionWriter).approve(
      uniPool.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionBuyer).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionBuyer).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(WETH_ADDRESS, optionBuyer).approve(
      uniPool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionBuyer).approve(
      uniPool.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, liquidityProvider).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidityProvider).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(WETH_ADDRESS, liquidityProvider).approve(
      uniPool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidityProvider).approve(
      uniPool.address,
      ethers.constants.MaxUint256,
    );
    //approvals

    await collatToken0.approve(pool.address, ethers.constants.MaxUint256);
    await collatToken1.approve(pool.address, ethers.constants.MaxUint256);

    await collatToken0.connect(optionWriter).approve(pool.address, ethers.constants.MaxUint256);
    await collatToken1.connect(optionWriter).approve(pool.address, ethers.constants.MaxUint256);

    await collatToken0.connect(optionBuyer).approve(pool.address, ethers.constants.MaxUint256);
    await collatToken1.connect(optionBuyer).approve(pool.address, ethers.constants.MaxUint256);

    await collatToken0
      .connect(liquidityProvider)
      .approve(pool.address, ethers.constants.MaxUint256);
    await collatToken1
      .connect(liquidityProvider)
      .approve(pool.address, ethers.constants.MaxUint256);

    await collatToken0.connect(swapper).approve(pool.address, ethers.constants.MaxUint256);
    await collatToken1.connect(swapper).approve(pool.address, ethers.constants.MaxUint256);

    await IERC20__factory.connect(WETH_ADDRESS, deployer).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, deployer).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, deployer).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, deployer).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionWriter).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionWriter).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionWriter).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionWriter).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionBuyer).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionBuyer).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionBuyer).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionBuyer).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, liquidityProvider).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidityProvider).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, liquidityProvider).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidityProvider).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, swapper).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, swapper).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, swapper).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, swapper).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );
  });

  it.only("should allow to roll puts, no collateral checks", async function () {
    const width = 10;
    let strike = tick - 1100;
    strike = strike - (strike % 10);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("9980010000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 3,
        asset: 0,
        strike: strike + 1000,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [tokenId])).toString(),
    ).to.equal("33961446166,2016116577");

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 3,
        asset: 0,
        strike: strike + 300,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool.rollOptions(tokenId, tokenId2, [], 0, 0, 0);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [tokenId2])).toString(),
    ).to.equal("33961446166,1879821215");

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");
    expect((await pool.optionPositionBalance(depositor, tokenId2))[0].toString()).to.equal(
      positionSize.toString(),
    );

    await pool["burnOptions(uint256,int24,int24)"](tokenId2, 0, 0);

    //const resolved2 = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"]([tokenId], positionSize, 20000,0,0);
    //const receipt2 = await resolved2.wait();

    //const resolved3 = await pool["burnOptions(uint256,int24,int24)"](tokenId,0,0);

    //const resolved4 = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"]([tokenId2], positionSize, 20000,0,0);
  });

  it("Should fail when emptyList argument is not empty", async () => {
    const width = 2;
    let strike = tick + 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(339600e6);

    const positionSize = ethers.utils.parseEther("1");
    //const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("339600000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("0");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 7,
        asset: 1,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 3,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 7,
        asset: 1,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 3,
        asset: 1,
        strike: strike - 100,
        long: false,
        tokenType: 0,
        riskPartner: 1, //
      },
    ]);

    /// this should work fine:
    await pool.rollOptions(tokenId, tokenId2, [], 0, 0, 0);
    //
    /// but here the emptyList is not empty, so should revert:
    await expect(pool.rollOptions(tokenId, tokenId2, [1], 0, 0, 0)).to.be.revertedWith(
      revertCustom("InputListFail()"),
    );
  });

  it("should allow to roll one leg of a two-legged call", async function () {
    const width = 2;
    let strike = tick + 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(339600e6);

    const positionSize = ethers.utils.parseEther("1");
    //const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("339600000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("0");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 7,
        asset: 1,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 3,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 7,
        asset: 1,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 3,
        asset: 1,
        strike: strike - 100,
        long: false,
        tokenType: 0,
        riskPartner: 1, //
      },
    ]);

    await pool.rollOptions(tokenId, tokenId2, [], 0, 0, 0);

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");
    expect((await pool.optionPositionBalance(depositor, tokenId2))[0].toString()).to.equal(
      positionSize.toString(),
    );
  });

  it("Should not allow to roll one leg of an ITM two-legged call", async function () {
    const width = 2;
    let strike = tick + 12;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396114535);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize = ethers.utils.parseEther("1");

    //const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("3396114535");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("1000000000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 2000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize.div(100),
      20000,
      tick - 10000,
      tick + 10000,
    );

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.div(100).toString(),
    );

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 1200,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    await expect(
      pool.rollOptions(tokenId, tokenId2, [], 0, strike - 20000, strike + 2000),
    ).to.be.revertedWith(revertCustom("OptionsNotOTM()"));

    const tokenId3 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 1200,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    await pool.rollOptions(tokenId, tokenId3, [], 0, strike - 20000, strike + 20000);

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");
    expect((await pool.optionPositionBalance(depositor, tokenId3))[0].toString()).to.equal(
      positionSize.div(100).toString(),
    );
  });

  it("should allow to roll two legs of a strangle", async function () {
    const width = 2;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(339600e6);
    const amount1 = ethers.utils.parseEther("100");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("339600000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("100000000000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );
    await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 400,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 400,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId2],
      positionSize,
      20000,
      0,
      0,
    );

    expect((await pool.optionPositionBalance(depositor, tokenId2))[0].toString()).to.equal(
      "3396000000",
    );

    await pool["burnOptions(uint256,int24,int24)"](tokenId2, 0, 0);

    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, tokenId2))[0].toString()).to.equal("0");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId2],
      positionSize,
      20000,
      0,
      0,
    );

    expect((await pool.optionPositionBalance(depositor, tokenId2))[0].toString()).to.equal(
      "3396000000",
    );

    await pool.rollOptions(tokenId2, tokenId, [], 0, 0, 0);

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      "3396000000",
    );
    expect((await pool.optionPositionBalance(depositor, tokenId2))[0].toString()).to.equal("0");
  });

  it("should allow to roll two legs of a strangle, with fees", async function () {
    const width = 2;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(339600e6);
    const amount1 = ethers.utils.parseEther("100");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("339600000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("100000000000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 60,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 60,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );
    await pool
      .connect(liquidityProvider)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize.mul(3),
        20000,
        0,
        0,
      );

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 150);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 150);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    const swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    const paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    const paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    var slot0_ = await uniPool.slot0();

    for (let i = 0; i < 4; i++) {
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
    }

    var slot0_ = await uniPool.slot0();

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 40,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 40,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    await pool.rollOptions(tokenId, tokenId2, [], 0, 0, 0);

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");

    expect((await pool.optionPositionBalance(depositor, tokenId2))[0].toString()).to.equal(
      "3396000000",
    );

    expect(
      (await pool.optionPositionBalance(liquidityProvider.getAddress(), tokenId))[0].toString(),
    ).to.equal("10188000000");

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("3722073759308"); //amount0.mul(10) + amount0
    expect((await pool.poolData(1))[0].toString()).to.equal("1096041490335653882822"); // amount1.mul(10) + amount1 -

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("3735616986922");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100004999506738278520"); // amount1.mul(10) + amount1.div(4) +

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("13584000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("3975507678012909557");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("40772386");
    expect((await pool.poolData(1))[3].toString()).to.equal("11998506928513859");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("36");
    expect((await pool.poolData(1))[4].toString()).to.equal("36"); // pool utilization 0.9894 / 10.25 = 9.65%

    // check token balances for all
    expect(await collatToken0.balanceOf(depositor)).to.equal("339593214448"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("99998027190952965560"); // 0
    expect(await collatToken0.balanceOf(liquidityProvider.getAddress())).to.equal("3395938872334"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(liquidityProvider.getAddress())).to.equal(
      "999982119261251312696",
    ); // 0

    await pool.connect(liquidityProvider)["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("3732261759307"); //amount0.mul(10) + amount0
    expect((await pool.poolData(1))[0].toString()).to.equal("1099021629608111480989"); // amount1.mul(10) + amount1 -

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("3735657759305");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100016998013666792370"); // amount1.mul(10) + amount1.div(4) +

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("3396000000"); // token2 put
    expect((await pool.poolData(1))[2].toString()).to.equal("995368405555311383"); // token2 call

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("2");
    expect((await pool.poolData(1))[3].toString()).to.equal("2");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("9");
    expect((await pool.poolData(1))[4].toString()).to.equal("9"); // pool utilization 0.9894 / 10.25 = 9.65%

    expect(await collatToken0.balanceOf(depositor)).to.equal("339593214448"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("99998027190952965560"); // 0
    expect(await collatToken0.balanceOf(liquidityProvider.getAddress())).to.equal("3395979643383"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(liquidityProvider.getAddress())).to.equal(
      "999994117377126637153",
    ); // commission fee?

    await pool["burnOptions(uint256,int24,int24)"](tokenId2, 0, 0);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      depositor,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      depositor,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidityProvider)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidityProvider,
      ).maxWithdraw(await liquidityProvider.getAddress()),
      await liquidityProvider.getAddress(),
      await liquidityProvider.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidityProvider)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        liquidityProvider,
      ).maxWithdraw(await liquidityProvider.getAddress()),
      await liquidityProvider.getAddress(),
      await liquidityProvider.getAddress(),
    );
    expect(await usdc.balanceOf(depositor)).to.equal("100000000623923"); // gained 0.62USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("1000000000195656337796714"); //
    expect(await usdc.balanceOf(providor)).to.equal("100000053739177"); // gained 53USDC in premium
    expect(await weth.balanceOf(providor)).to.equal("1000000015802331215044065"); //
    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); // token2 put
    expect((await pool.poolData(1))[2].toString()).to.equal("0"); // token2 call
  });

  it.only("should allow to put option, ITM/OTM with fees", async function () {
    const width = 10;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(339600e6);
    const amount1 = ethers.utils.parseEther("100");

    const positionSize = ethers.utils.parseEther("1");
    //const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 200,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([tokenId], positionSize.mul(3), 20000,0,0);

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 150);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 150);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    const swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    const paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    const paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    var slot0_ = await uniPool.slot0();

    for (let i = 0; i < 4; i++) {
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
    }

    var slot0_ = await uniPool.slot0();

    console.log("old tick: ", tick, ", new tick: ", slot0_.tick);
    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(pool.rollOptions(tokenId, tokenId2, [], 0, 0, 0)).to.be.revertedWith(
      revertCustom("OptionsNotOTM()"),
    );

    await pool.rollOptions(tokenId, tokenId2, [tokenId], 0, 0, 0);

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");

    expect((await pool.optionPositionBalance(depositor, tokenId2))[0].toString()).to.equal(
      "1000000000000000000",
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("7131600010000"); //amount0.mul(10) + amount0
    expect((await pool.poolData(1))[0].toString()).to.equal("2099007857379142240946"); // amount1.mul(10) + amount1 -

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("7131600010000");
    expect((await pool.poolData(1))[1].toString()).to.equal("2100007857379142240946"); // amount1.mul(10) + amount1.div(4) +

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("4");

    // check token balances for all
    expect(await collatToken0.balanceOf(depositor)).to.equal("338921139600"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("99806904521431584902"); // 0
    expect(await collatToken0.balanceOf(liquidityProvider.getAddress())).to.equal("3385822184703"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(liquidityProvider.getAddress())).to.equal(
      "997002999000000000099",
    ); // 0

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("7131600010000"); //amount0.mul(10) + amount0
    expect((await pool.poolData(1))[0].toString()).to.equal("2099007857379142240946"); // amount1.mul(10) + amount1 -

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("7131600010000");
    expect((await pool.poolData(1))[1].toString()).to.equal("2100007857379142240946"); // amount1.mul(10) + amount1.div(4) +

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); // token2 put
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000"); // token2 call

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("4"); // pool utilization 0.9894 / 10.25 = 9.65%

    expect(await collatToken0.balanceOf(depositor)).to.equal("338921139600"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("99806904521431584902"); // 0
    expect(await collatToken0.balanceOf(liquidityProvider.getAddress())).to.equal("3385822184703"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(liquidityProvider.getAddress())).to.equal(
      "997002999000000000099",
    ); // commission fee?

    await pool["burnOptions(uint256,int24,int24)"](tokenId2, 0, 0);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      depositor,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      depositor,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidityProvider)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidityProvider,
      ).maxWithdraw(await liquidityProvider.getAddress()),
      await liquidityProvider.getAddress(),
      await liquidityProvider.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidityProvider)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        liquidityProvider,
      ).maxWithdraw(await liquidityProvider.getAddress()),
      await liquidityProvider.getAddress(),
      await liquidityProvider.getAddress(),
    );
    expect(await usdc.balanceOf(depositor)).to.equal("100000470946724"); // gained 0.62USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("1000000136706854370774188"); //
    expect(await usdc.balanceOf(providor)).to.equal("100001308757875"); // gained 53USDC in premium
    expect(await weth.balanceOf(providor)).to.equal("1000000385872754023829647"); //
    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); // token2 put
    expect((await pool.poolData(1))[2].toString()).to.equal("0"); // token2 call
  });

  it.only("roll with multiple positions", async function () {
    const width = 10;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(339600e6);
    const amount1 = ethers.utils.parseEther("100");

    const positionSize = ethers.utils.parseEther("1");
    //const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    let tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 127,
        asset: 1,
        strike: strike + 200,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("1");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );

    const Arr = Array(tokenId);

    expect((await pool.checkCollateral(deployer.getAddress(), tick, 0, Arr)).toString()).to.equal(
      "687702673076,92891168575",
    ); // collateral requirement = 92k USDC = 27 ETH

    let strikeRand = 0;
    for (let i = 0; i < 8; i++) {
      strikeRand = Math.floor(Math.random() * 20 + 2) * 100;
      tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 77,
          asset: 1,
          strike: strike - strikeRand - (strikeRand % 10) + i * 10,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      console.log("strike = ", strike - strikeRand - (strikeRand % 10) + i * 10);
      Arr.push(tokenId);
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        Arr,
        positionSize,
        20000,
        0,
        0,
      );
    }
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 0, Arr)).toString()).to.equal(
      "685712178055,511296185344",
    );

    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([tokenId], positionSize.mul(3), 20000,0,0);

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 150);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 150);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    const swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    const paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    const paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    var slot0_ = await uniPool.slot0();

    for (let i = 0; i < 4; i++) {
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
    }

    var slot0_ = await uniPool.slot0();

    console.log("old tick: ", tick, ", new tick: ", slot0_.tick);
    const tokenIdOTM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 77,
        asset: 1,
        strike: strike - 610,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), slot0_.tick, 0, Arr)).toString(),
    ).to.equal("685228643061,510107475533");

    console.log("aa");
    let oldToken = Arr[1];

    await pool.rollOptions(oldToken, tokenIdOTM, [], 0, 0, 0);

    //Arr[1] = tokenIdOTM;

    Arr[1] = tokenIdOTM;

    let tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 67,
        asset: 1,
        strike: strike - 300,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("ITM []");
    //await expect(pool.rollOptions(Arr[5], tokenIdITM, [], 0, 0, 0)).to.be.revertedWith(revertCustom("OptionsNotOTM()"));

    tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 10000,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("asset");
    await expect(pool.rollOptions(Arr[5], tokenIdITM, Arr, 0, 0, 0)).to.be.revertedWith(
      revertCustom("NotATokenRoll()"),
    );

    tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 10000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    console.log("tokenType");
    await expect(pool.rollOptions(Arr[5], tokenIdITM, Arr, 0, 0, 0)).to.be.revertedWith(
      revertCustom("NotATokenRoll()"),
    );

    tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 10000,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("long");
    await expect(pool.rollOptions(Arr[5], tokenIdITM, Arr, 0, 0, 0)).to.be.revertedWith(
      revertCustom("NotATokenRoll()"),
    );

    tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 77,
        asset: 1,
        strike: strike - 300,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("last roll");
    await pool.rollOptions(Arr[Arr.length - 1], tokenIdITM, Arr, 0, 0, 0);

    Arr[Arr.length - 1] = tokenIdITM;
    expect(
      (await pool.checkCollateral(deployer.getAddress(), slot0_.tick, 0, Arr)).toString(),
    ).to.equal("685228643061,510107475533");

    expect((await pool.optionPositionBalance(depositor, tokenIdITM))[0].toString()).to.equal(
      "1000000000000000000",
    );
  });

  it.only("roll with multiple ITM positions", async function () {
    const width = 10;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(339600e6);
    const amount1 = ethers.utils.parseEther("100");

    const positionSize = ethers.utils.parseEther("1");
    //const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    let tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 127,
        asset: 1,
        strike: strike + 200,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );

    const Arr = Array(tokenId);

    let strikeRand = 0;
    for (let i = 0; i < 8; i++) {
      strikeRand = Math.floor(Math.random() * 20 + 2) * 100;
      tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 67,
          asset: 1,
          strike: strike + strikeRand - (strikeRand % 10) + i * 10,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      console.log("strike = ", strike + strikeRand - (strikeRand % 10) + i * 10);
      Arr.push(tokenId);
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        Arr,
        positionSize,
        20000,
        0,
        0,
      );
    }

    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([tokenId], positionSize.mul(3), 20000,0,0);

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 150);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 150);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    const swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    const paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    const paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    var slot0_ = await uniPool.slot0();

    for (let i = 0; i < 4; i++) {
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
    }

    var slot0_ = await uniPool.slot0();

    console.log("old tick: ", tick, ", new tick: ", slot0_.tick);
    const tokenIdOTM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 67,
        asset: 1,
        strike: strike - 210,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool.rollOptions(Arr[1], tokenIdOTM, [], 0, 0, 0);

    Arr[1] = tokenIdOTM;

    let tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 55,
        asset: 1,
        strike: strike - 300,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("ITM []");
    //await expect(pool.rollOptions(Arr[5], tokenIdITM, [], 0, 0, 0)).to.be.revertedWith(revertCustom("OptionsNotOTM()"));

    tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 67,
        asset: 0,
        strike: strike + 10000,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("asset");
    await expect(pool.rollOptions(Arr[5], tokenIdITM, Arr, 0, 0, 0)).to.be.revertedWith(
      revertCustom("NotATokenRoll()"),
    );

    tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 10000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    console.log("tokenType");
    await expect(pool.rollOptions(Arr[5], tokenIdITM, Arr, 0, 0, 0)).to.be.revertedWith(
      revertCustom("NotATokenRoll()"),
    );

    tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 10000,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("long");
    await expect(pool.rollOptions(Arr[5], tokenIdITM, Arr, 0, 0, 0)).to.be.revertedWith(
      revertCustom("NotATokenRoll()"),
    );

    tokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 67,
        asset: 1,
        strike: strike + 2000,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool.rollOptions(Arr[Arr.length - 1], tokenIdITM, Arr, 0, 0, 0);
  });
});
