/**
 * Test Burning Mechanisms.
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
  ISwapRouter,
  CollateralTracker__factory,
  CollateralTracker,
  SemiFungiblePositionManager__factory,
} from "../../typechain";

import * as OptionEncoding from "../Libraries/OptionEncoding";
import * as UniswapV3 from "../Libraries/UniswapV3";

import { BigNumber, Signer } from "ethers";
import { ADDRESS_ZERO } from "@uniswap/v3-sdk";

const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_SLOT = 9;
const token0 = USDC_ADDRESS;

const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const WETH_SLOT = 3;
const token1 = WETH_ADDRESS;

const SWAP_ROUTER_ADDRESS = "0xE592427A0AEce92De3Edee1F18E0157C05861564";
const decimalUSDC = 6;
const decimalWETH = 18;

describe("Burning", async function () {
  this.timeout(1000000);

  const contractName = "PanopticPool";
  const deploymentName = "PanopticPool-ETH-USDC";

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

  let collateraltoken0: CollateralTracker;
  let collateraltoken1: CollateralTracker;

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
    collateraltoken0 = await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      deployer,
    );
    collateraltoken1 = await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      deployer,
    );

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

  describe("burn", async function () {
    it("should allow to mint+burn 1 leg short put ETH option", async function () {
      const width = 10;
      let strike = tick - 1100;
      strike = strike - (strike % 10);
      const amount1 = ethers.utils.parseEther("10");

      const positionSize = BigNumber.from(3396e6);
      await collateraltoken1.deposit(amount1, depositor);

      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 3,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
        positionSize.toString(),
      );

      await pool["burnOptions(uint256,int24,int24)"](tokenId, -800000, 800000);

      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize.mul(2),
        0,
        0,
        0,
      );
      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
        positionSize.mul(2).toString(),
      );

      await pool["burnOptions(uint256,int24,int24)"](tokenId, -800000, 800000);

      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");
    });

    it("should allow to mint+burn 1 leg long put ETH option", async function () {
      const width = 10;
      let strike = tick - 1100;
      strike = strike - (strike % 10);

      const amount1 = ethers.utils.parseEther("50");

      const positionSize = BigNumber.from(3396e6);

      await collateraltoken1.deposit(amount1, depositor);

      const shortPutTokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 7,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      // console.log(
      //  "pool utilizations " +
      //    (await pool.poolUtilization0()).toString() +
      //    " " +
      //    (await pool.poolUtilization1()).toString()
      //);

      const longPutTokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: true,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId, longPutTokenId],
        positionSize.div(2),
        2000000000,
        -800000,
        800000,
      );
      // console.log(
      //  "pool utilizations " +
      //    (await pool.poolUtilization0()).toString() +
      //    " " +
      //    (await pool.poolUtilization1()).toString()
      //);

      expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
        positionSize.div(2).toString(),
      );

      //expect((await pool.poolData()).inAMM0).to.equal("0");
      //expect(((await pool.poolData()).inAMM1).toString()).to.equal("4476318112204017477");

      const shortPutTokenId2 = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      await expect(
        pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [longPutTokenId, longPutTokenId, shortPutTokenId2],
          positionSize.div(6),
          2000000000,
          -800000,
          800000,
        ),
      ).to.be.revertedWith(revertCustom("InputListFail()"));

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId, longPutTokenId, shortPutTokenId2],
        positionSize.div(6),
        2000000000,
        -800000,
        800000,
      );
      expect(
        (await pool.optionPositionBalance(depositor, shortPutTokenId2))[0].toString(),
      ).to.equal(positionSize.div(6).toString());

      await pool["burnOptions(uint256,int24,int24)"](shortPutTokenId2, 0, 0);

      expect(
        (await pool.optionPositionBalance(depositor, shortPutTokenId2))[0].toString(),
      ).to.equal("0");

      await pool["burnOptions(uint256,int24,int24)"](longPutTokenId, 0, 0);
      // console.log(
      //  "pool utilizations " +
      //    (await pool.poolUtilization0()).toString() +
      //    " " +
      //    (await pool.poolUtilization1()).toString()
      //);

      expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
        "0",
      );

      await pool["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);
    });

    it("should allow to mint+burn 4 leg short put ETH option", async function () {
      const width = 10;
      let strike = tick - 1000;
      strike = strike - (strike % 10);

      const amount1 = ethers.utils.parseEther("50");

      const positionSize = BigNumber.from(3396e6);

      await collateraltoken1.deposit(amount1.mul(4), depositor);

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 100,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 200,
          long: false,
          tokenType: 1,
          riskPartner: 1,
        },
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 300,
          long: false,
          tokenType: 1,
          riskPartner: 2,
        },
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 400,
          long: false,
          tokenType: 1,
          riskPartner: 3,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      await pool["burnOptions(uint256,int24,int24)"](tokenId, -800000, 800000);

      expect(await pool.positionsHash(depositor)).to.equal(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
      );
      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");
    });

    it("should allow to mint+burn short call USDC option", async function () {
      const width = 10;
      let strike = tick + 100;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(100000e6);

      const positionSize = BigNumber.from(3396e6);

      await collateraltoken0.deposit(amount0, depositor);

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: false,
          tokenType: 0,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      await pool["burnOptions(uint256,int24,int24)"](tokenId, -800000, 800000);
    });

    it("should allow to mint+burn several USDC options in batch mode", async function () {
      const width = 10;
      let strike = tick;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(100000e6);
      const amount1 = ethers.utils.parseEther("10");

      const positionSize = BigNumber.from(3396e6);

      await collateraltoken0.deposit(amount0.mul(10), depositor);
      await collateraltoken1.deposit(amount1.mul(10), depositor);

      const tokenId1 = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike + 100,
          long: false,
          tokenType: 0,
          riskPartner: 0,
        },
      ]);

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
      ]);

      const tokenId3 = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 200,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);

      const tokenId4 = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 300,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId1],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId1, tokenId2],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId1, tokenId2, tokenId3],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId1, tokenId2, tokenId3, tokenId4],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      await pool["burnOptions(uint256,int24,int24)"](tokenId1, 0, 0);
      await pool["burnOptions(uint256,int24,int24)"](tokenId2, 0, 0);
      await pool["burnOptions(uint256,int24,int24)"](tokenId3, 0, 0);
      await pool["burnOptions(uint256,int24,int24)"](tokenId4, 0, 0);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId1],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId1, tokenId2],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId1, tokenId2, tokenId3],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId1, tokenId2, tokenId3, tokenId4],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      await pool["burnOptions(uint256[],int24,int24)"]([tokenId1, tokenId2], 0, 0);
      await expect(
        pool["burnOptions(uint256[],int24,int24)"]([tokenId3, tokenId4], 0, 10),
      ).to.be.revertedWith("PriceBoundFail()");
      await expect(
        pool["burnOptions(uint256[],int24,int24)"]([tokenId3, tokenId4], strike + 10, strike + 20),
      ).to.be.revertedWith("PriceBoundFail()");
      await pool["burnOptions(uint256[],int24,int24)"](
        [tokenId3, tokenId4],
        strike - 10,
        strike + 10,
      );
    });

    it("should allow to mint 2-leg short call USDC option", async function () {
      const width = 10;
      let strike = tick + 100;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(100000e6);
      const positionSize = BigNumber.from(3396e6);

      await collateraltoken0.deposit(amount0.mul(2), depositor);

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: false,
          tokenType: 0,
          riskPartner: 0,
        },
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike + 50,
          long: false,
          tokenType: 0,
          riskPartner: 1,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      await pool["burnOptions(uint256,int24,int24)"](tokenId, -800000, 800000);

      expect(await pool.positionsHash(depositor)).to.equal(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
      );
      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");
    });

    it("should allow to mint+burn 2-leg call USDC option with risk partner", async function () {
      const width = 10;
      let strike = tick + 100;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(100000e6);
      const positionSize = BigNumber.from(3396e6);

      await collateraltoken0.deposit(amount0.mul(2), depositor);
      const shortCallTokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 5,
          asset: 0,
          strike: strike + 50,
          long: false,
          tokenType: 0,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortCallTokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: false,
          tokenType: 0,
          riskPartner: 1,
        },
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike + 50,
          long: true,
          tokenType: 0,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortCallTokenId, tokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      await pool["burnOptions(uint256,int24,int24)"](tokenId, -800000, 800000);

      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");
    });

    it("should allow to mint+burn long call USDC option", async function () {
      const width = 10;
      let strike = tick + 1000;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(50000e6);
      const positionSize = BigNumber.from(3396e6);

      await collateraltoken0.deposit(amount0, depositor);

      const shortCallTokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 5,
          asset: 0,
          strike,
          long: false,
          tokenType: 0,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortCallTokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      const longCallTokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: true,
          tokenType: 0,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortCallTokenId, longCallTokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      await pool["burnOptions(uint256,int24,int24)"](longCallTokenId, 0, 0);

      expect((await pool.optionPositionBalance(depositor, longCallTokenId))[0].toString()).to.equal(
        "0",
      );
    });

    it("should allow to mint+burn 1 leg short put ETH option", async function () {
      const width = 10;
      let strike = tick - 1100;
      strike = strike - (strike % 10);
      const amount1 = ethers.utils.parseEther("10");

      const positionSize = BigNumber.from(3396e6);
      await collateraltoken1.deposit(amount1, depositor);

      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 3,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);

      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
        positionSize.toString(),
      );

      await pool["burnOptions(uint256,int24,int24)"](tokenId, -800000, 800000);

      expect(await pool.positionsHash(depositor)).to.equal(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
      );
      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");
    });
  });

  describe("burning ITM", async function () {
    it("should allow to mint+burn 1 leg short put ITM out-of-range option, overcollateralized", async function () {
      const width = 10;
      let strike = tick - 110;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(33960e6);
      const amount1 = ethers.utils.parseEther("10");

      const positionSize = BigNumber.from(3396e6);
      expect((await usdc.balanceOf(await pool.address)).toString()).to.equal("3396129");
      expect((await weth.balanceOf(await pool.address)).toString()).to.equal("1000004428773891");

      // deposit collateral
      await collateraltoken0.deposit(amount0, depositor);
      await collateraltoken1.deposit(amount1, depositor);

      // check balance in Panoptic pool
      expect((await usdc.balanceOf(await pool.address)).toString()).to.equal("33963396129");
      expect((await weth.balanceOf(await pool.address)).toString()).to.equal(
        "10001000004428773891",
      );

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);

      /////// MINT

      // check user receipt token balance before mint
      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33960000000");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

      const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        0,
        0,
      );
      const receipt = await resolved.wait();
      // console.log("Simple mint gas used = " + receipt.gasUsed.toNumber());

      // check user receipt token balance after mint (commission taken)
      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33960000000");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
        "9994069446985805746", // 10bps commission on 0.988425502365709212 ETH
      );

      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
        positionSize.toString(),
      );

      // check amount in AMM
      expect((await pool.poolData(0))[2].toString()).to.equal("0");
      expect((await pool.poolData(1))[2].toString()).to.equal("988425502365709288");

      // check balance in Panoptic pool: amounts moved
      expect((await usdc.balanceOf(await pool.address)).toString()).to.equal("33963396129");
      expect((await weth.balanceOf(await pool.address)).toString()).to.equal("9012574502063064679");

      const resolvedB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptB = await resolvedB.wait();
      // console.log("Simple burn gas used = " + receiptB.gasUsed.toNumber());

      // check user quantities
      expect(await pool.positionsHash(depositor)).to.equal(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
      );
      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");

      // check user receipt token balance after mint (commission taken)
      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33960000000");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
        "9994069446985805746", // 2x 10bps commission on 0.988425502365709212 ETH
      );

      // confirm that no amount in AMM left
      expect((await pool.poolData(0))[2].toString()).to.equal("0");
      expect((await pool.poolData(1))[2].toString()).to.equal("0");

      // check balance in Panoptic pool: back to initial amounts
      expect((await usdc.balanceOf(await pool.address)).toString()).to.equal("33963396129");
      expect((await weth.balanceOf(await pool.address)).toString()).to.equal(
        "10001000004428773890",
      );

      // check balance in Panoptic pool: amounts moved back
      expect((await usdc.balanceOf(await pool.address)).toString()).to.equal("33963396129");
      expect((await weth.balanceOf(await pool.address)).toString()).to.equal(
        "10001000004428773890",
      );

      // re-mint
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      ///////// SWAP
      const liquidity = await uniPool.liquidity();

      let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 400);
      let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 400);

      //console.log("amountW to swap", amountW.toString());
      //console.log("amountU to swap", amountU.toString());

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

      // console.log("");

      // console.log("upperTick", strike + (10 * width) / 2);
      // console.log("lowerTick", strike - (10 * width) / 2);
      // console.log(
      //  "strike price=",
      //  10 ** (decimalWETH - decimalUSDC) / UniswapV3.priceFromTick(strike)
      //);

      const slot0_ = await uniPool.slot0();

      const pc = UniswapV3.priceFromTick(tick);
      // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
      // console.log("initial tick", slot0_.tick);

      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);

      const slot1_ = await uniPool.slot0();
      const newPrice = Math.pow(1.0001, slot1_.tick);
      // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

      ////////////// burn ITM option
      //
      //

      // Panoptic Pool Balance:
      expect((await pool.poolData(0))[0].toString()).to.equal("33963396129"); //
      expect((await pool.poolData(1))[0].toString()).to.equal("9012574502063064678"); // 10 ETH - 0.988 ETH

      // totalBalance: unchanged, contains balance deposited
      expect((await pool.poolData(0))[1].toString()).to.equal("33963396129");
      expect((await pool.poolData(1))[1].toString()).to.equal("10001000004428773966");

      // in AMM: about 1 USDC
      expect((await pool.poolData(0))[2].toString()).to.equal("0"); //
      expect((await pool.poolData(1))[2].toString()).to.equal("988425502365709288");

      // totalCollected
      expect((await pool.poolData(0))[3].toString()).to.equal("0");
      expect((await pool.poolData(1))[3].toString()).to.equal("0");

      // poolUtilization:
      expect((await pool.poolData(0))[4].toString()).to.equal("0"); //
      expect((await pool.poolData(1))[4].toString()).to.equal("988"); //

      const resolvedBB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptBB = await resolvedBB.wait();
      // console.log("Complex burn gas used = " + receiptBB.gasUsed.toNumber());

      // Panoptic Pool Balance:
      expect((await pool.poolData(0))[0].toString()).to.equal("33965094978"); //  33960 + 1.7 USDC in fees
      expect((await pool.poolData(1))[0].toString()).to.equal("10001494464409947330"); // 10 ETH + 0.0004944 ETH

      // totalBalance: unchanged, contains balance deposited
      expect((await pool.poolData(0))[1].toString()).to.equal("33965094977");
      expect((await pool.poolData(1))[1].toString()).to.equal("10001494464409947329");

      // in AMM: about 1 USDC
      expect((await pool.poolData(0))[2].toString()).to.equal("0"); //
      expect((await pool.poolData(1))[2].toString()).to.equal("0");

      // totalCollected
      expect((await pool.poolData(0))[3].toString()).to.equal("1");
      expect((await pool.poolData(1))[3].toString()).to.equal("1");

      // poolUtilization:
      expect((await pool.poolData(0))[4].toString()).to.equal("0"); //
      expect((await pool.poolData(1))[4].toString()).to.equal("0"); //

      // check user quantities
      expect(await pool.positionsHash(depositor)).to.equal("0x00000000000000000000000000000000");
      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal("0");

      // check user receipt token balance after mint (commission taken on usdc and weth!)
      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33961698763");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
        "9988636260078869301", //
      );

      // confirm that no amount in AMM left
      expect((await pool.poolData(0))[2].toString()).to.equal("0");
      expect((await pool.poolData(0))[2].toString()).to.equal("0");

      // check balance in Panoptic pool: ?
      expect((await usdc.balanceOf(await pool.address)).toString()).to.equal("33965094978");
      expect((await weth.balanceOf(await pool.address)).toString()).to.equal(
        "10001494464409947330",
      );

      // withdraw entire balance
      await collateraltoken0["withdraw(uint256,address,address)"](
        await collateraltoken0.maxWithdraw(depositor),
        depositor,
        depositor,
      );
      await collateraltoken1["withdraw(uint256,address,address)"](
        await collateraltoken1.maxWithdraw(depositor),
        depositor,
        depositor,
      );

      // check collateral token balance = 0
      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("1");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("1");

      // check balance in Panoptic pool at the end: back to initial amounts plus fees??
      expect((await usdc.balanceOf(await pool.address)).toString()).to.equal("3396131");
      expect((await weth.balanceOf(await pool.address)).toString()).to.equal("1001191484248747");
    });

    it("should allow to mint+burn 1 leg short put ITM in-range option, overcollateralized", async function () {
      const width = 10;
      let strike = tick - 110;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(33960e6);
      const amount1 = ethers.utils.parseEther("10");

      const positionSize = BigNumber.from(3396e6);
      await collateraltoken0.deposit(amount0, depositor);
      await collateraltoken1.deposit(amount1, depositor);

      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33960000000");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        0,
        0,
      );
      const receipt = await resolved.wait();
      // console.log("Simple mint gas used = " + receipt.gasUsed.toNumber());

      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
        positionSize.toString(),
      );
      //expect((await pool.options(depositor, tokenId, 0))[2].toString()).to.equal("0");

      const resolvedB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptB = await resolvedB.wait();
      // console.log("Simple burn gas used = " + receiptB.gasUsed.toNumber());
      // re-mint
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        0,
        0,
      );

      ///////// SWAP
      const liquidity = await uniPool.liquidity();

      let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 120);
      let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 120);

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

      const slot0_ = await uniPool.slot0();

      const pc = UniswapV3.priceFromTick(tick);
      // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
      // console.log("initial tick", slot0_.tick);

      await swapRouter.connect(swapper).exactInputSingle(paramsB);

      const slot1_ = await uniPool.slot0();
      const newPrice = Math.pow(1.0001, slot1_.tick);
      // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

      ////////////// burn ITM option
      //
      //
      const resolvedBB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptBB = await resolvedBB.wait();
      // console.log("Complex burn gas used = " + receiptBB.gasUsed.toNumber());

      await collateraltoken0["withdraw(uint256,address,address)"](
        await collateraltoken0.maxWithdraw(depositor),
        depositor,
        depositor,
      );
      await collateraltoken1["withdraw(uint256,address,address)"](
        await collateraltoken1.maxWithdraw(depositor),
        depositor,
        depositor,
      );
    });

    it("should allow to mint+burn 1 leg short call ITM out-of-range option, overcollateralized", async function () {
      const width = 10;
      let strike = tick + 110;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(33960e6);
      const amount1 = ethers.utils.parseEther("10");

      const positionSize = BigNumber.from(3396e6);
      await collateraltoken0.deposit(amount0, depositor);
      await collateraltoken1.deposit(amount1, depositor);

      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33960000000");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: false,
          tokenType: 0,
          riskPartner: 0,
        },
      ]);

      const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );
      const receipt = await resolved.wait();
      // console.log("Simple mint gas used = " + receipt.gasUsed.toNumber());

      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
        positionSize.toString(),
      );

      const resolvedB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptB = await resolvedB.wait();
      // console.log("Simple strangle burn gas used = " + receiptB.gasUsed.toNumber());

      // re-mint
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        0,
        0,
      );

      ///////// SWAP
      const liquidity = await uniPool.liquidity();

      let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 400);
      let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 400);

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

      // console.log("");
      // console.log("upperTick", strike + (10 * width) / 2);
      // console.log("lowerTick", strike - (10 * width) / 2);

      // console.log(
      //  "strike price=",
      //  10 ** (decimalWETH - decimalUSDC) / UniswapV3.priceFromTick(strike)
      //);

      const slot0_ = await uniPool.slot0();

      const pc = UniswapV3.priceFromTick(tick);
      // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
      // console.log("initial tick", slot0_.tick);

      await swapRouter.connect(swapper).exactInputSingle(paramsS);

      const slot1_ = await uniPool.slot0();
      const newPrice = Math.pow(1.0001, slot1_.tick);
      // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

      ////////////// burn ITM option
      //
      //
      const resolvedBB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptBB = await resolvedBB.wait();
      // console.log("Complex strangle burn gas used = " + receiptBB.gasUsed.toNumber());

      await collateraltoken0["withdraw(uint256,address,address)"](
        await collateraltoken0.maxWithdraw(depositor),
        depositor,
        depositor,
      );
      await collateraltoken1["withdraw(uint256,address,address)"](
        await collateraltoken1.maxWithdraw(depositor),
        depositor,
        depositor,
      );
    });

    it("should allow to mint+burn 1 leg short call ITM in-range option, overcollateralized", async function () {
      const width = 10;
      let strike = tick + 110;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(33960e6);
      const amount1 = ethers.utils.parseEther("10");

      const positionSize = BigNumber.from(3396e6);
      await collateraltoken0.deposit(amount0, depositor);
      await collateraltoken1.deposit(amount1, depositor);

      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33960000000");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike,
          long: false,
          tokenType: 0,
          riskPartner: 0,
        },
      ]);

      const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        0,
        0,
      );
      const receipt = await resolved.wait();
      // console.log("Simple mint gas used = " + receipt.gasUsed.toNumber());

      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
        positionSize.toString(),
      );

      const resolvedB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptB = await resolvedB.wait();
      // console.log("Simple strangle burn gas used = " + receiptB.gasUsed.toNumber());

      // re-mint
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        0,
        0,
      );

      ///////// SWAP
      const liquidity = await uniPool.liquidity();

      let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 120);
      let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 120);

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

      // console.log("");
      // console.log("upperTick", strike + (10 * width) / 2);
      // console.log("lowerTick", strike - (10 * width) / 2);

      // console.log(
      //  "strike price=",
      //  10 ** (decimalWETH - decimalUSDC) / UniswapV3.priceFromTick(strike)
      //);

      const slot0_ = await uniPool.slot0();

      const pc = UniswapV3.priceFromTick(tick);
      // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
      // console.log("initial tick", slot0_.tick);

      await swapRouter.connect(swapper).exactInputSingle(paramsS);

      const slot1_ = await uniPool.slot0();
      const newPrice = Math.pow(1.0001, slot1_.tick);
      // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);
      // console.log("new tick", slot1_.tick);
      // console.log("");

      ////////////// burn ITM option
      //
      //
      const resolvedBB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptBB = await resolvedBB.wait();
      // console.log("Complex strangle burn gas used = " + receiptBB.gasUsed.toNumber());

      await collateraltoken0["withdraw(uint256,address,address)"](
        await collateraltoken0.maxWithdraw(depositor),
        depositor,
        depositor,
      );
      await collateraltoken1["withdraw(uint256,address,address)"](
        await collateraltoken1.maxWithdraw(depositor),
        depositor,
        depositor,
      );
    });

    it("should allow to mint+burn 2 leg short strangle ITM out-of-range options, overcollateralized", async function () {
      const width = 10;
      let strike = tick;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(33960e6);
      const amount1 = ethers.utils.parseEther("10");

      const positionSize = BigNumber.from(3396e6);
      await collateraltoken0.deposit(amount0, depositor);
      await collateraltoken1.deposit(amount1, depositor);

      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33960000000");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike + 110,
          long: false,
          tokenType: 0,
          riskPartner: 0,
        },
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 110,
          long: false,
          tokenType: 1,
          riskPartner: 1,
        },
      ]);

      const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        0,
        0,
      );
      const receipt = await resolved.wait();
      // console.log("Simple mint gas used = " + receipt.gasUsed.toNumber());

      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
        positionSize.toString(),
      );

      const resolvedB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptB = await resolvedB.wait();
      // console.log("Simple strangle burn gas used = " + receiptB.gasUsed.toNumber());

      // re-mint
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        0,
        0,
      );

      ///////// SWAP
      const liquidity = await uniPool.liquidity();

      let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 400);
      let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 400);

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

      // console.log("");
      // console.log("upperTick", strike + (10 * width) / 2);
      // console.log("lowerTick", strike - (10 * width) / 2);

      // console.log(
      //  "strike price=",
      //  10 ** (decimalWETH - decimalUSDC) / UniswapV3.priceFromTick(strike)
      //);

      const slot0_ = await uniPool.slot0();

      const pc = UniswapV3.priceFromTick(tick);
      // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
      // console.log("initial tick", slot0_.tick);

      await swapRouter.connect(swapper).exactInputSingle(paramsS);

      const slot1_ = await uniPool.slot0();
      const newPrice = Math.pow(1.0001, slot1_.tick);
      // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

      ////////////// burn ITM option
      //
      //
      const resolvedBB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptBB = await resolvedBB.wait();
      // console.log("Complex strangle burn gas used = " + receiptBB.gasUsed.toNumber());

      await collateraltoken0["withdraw(uint256,address,address)"](
        await collateraltoken0.maxWithdraw(depositor),
        depositor,
        depositor,
      );
      await collateraltoken1["withdraw(uint256,address,address)"](
        await collateraltoken1.maxWithdraw(depositor),
        depositor,
        depositor,
      );
    });

    it("should allow to mint+burn 2 leg short strangle ITM in-range options, overcollateralized", async function () {
      const width = 10;
      let strike = tick;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(33960e6);
      const amount1 = ethers.utils.parseEther("10");

      const positionSize = BigNumber.from(3396e6);
      await collateraltoken0.deposit(amount0, depositor);
      await collateraltoken1.deposit(amount1, depositor);

      expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33960000000");
      expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike + 110,
          long: false,
          tokenType: 0,
          riskPartner: 0,
        },
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 110,
          long: false,
          tokenType: 1,
          riskPartner: 1,
        },
      ]);

      const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        0,
        0,
      );
      const receipt = await resolved.wait();
      // console.log("Simple mint gas used = " + receipt.gasUsed.toNumber());

      expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
        positionSize.toString(),
      );

      const resolvedB = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receiptB = await resolvedB.wait();
      // console.log("Simple strangle burn gas used = " + receiptB.gasUsed.toNumber());

      // re-mint
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        -800000,
        800000,
      );

      ///////// SWAP
      const liquidity = await uniPool.liquidity();

      let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 120);
      let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 120);

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

      // console.log("");
      // console.log("upperTick", strike + (10 * width) / 2);
      // console.log("lowerTick", strike - (10 * width) / 2);

      // console.log(
      //  "strike price=",
      //  10 ** (decimalWETH - decimalUSDC) / UniswapV3.priceFromTick(strike)
      //);

      const slot0_ = await uniPool.slot0();

      const pc = UniswapV3.priceFromTick(tick);
      // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
      // console.log("initial tick", slot0_.tick);

      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);

      const slot1_ = await uniPool.slot0();
      const newPrice = Math.pow(1.0001, slot1_.tick);
      // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

      ////////////// burn ITM option
      //
      //
      const resolvedBB = await pool["burnOptions(uint256,int24,int24)"](tokenId, -800000, 800000);
      const receiptBB = await resolvedBB.wait();
      // console.log("Complex strangle burn gas used = " + receiptBB.gasUsed.toNumber());
      await collateraltoken0["withdraw(uint256,address,address)"](
        await collateraltoken0.maxWithdraw(depositor),
        depositor,
        depositor,
      );
      await collateraltoken1["withdraw(uint256,address,address)"](
        await collateraltoken1.maxWithdraw(depositor),
        depositor,
        depositor,
      );
    });
  });
});
