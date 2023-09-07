/**
 * Test Minting Multiple Options.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { deployments, ethers, network } from "hardhat";
import { expect } from "chai";
import { grantTokens } from "../utils";
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

describe("PanopticPool", function () {
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

  it("should deploy the pool", async function () {
    await expect(pool.address).to.be.properAddress;
    await expect(pool.address).to.be.not.undefined;
  });

  describe("Mint N options - multiple options minting", async function () {
    it("should allow to mint N 1-leg short put ETH option", async function () {
      const width = 4;
      let strike = tick - 1100;
      strike = strike - (strike % 10);

      const amount1 = ethers.utils.parseEther("500");

      const positionSize = BigNumber.from(3396e6);

      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1,
        depositor,
      );

      const shortPutTokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 2,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      const Arr = Array(shortPutTokenId);

      const res = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        Arr,
        positionSize,
        20000,
        0,
        0,
      );
      const rec = await res.wait();

      console.log("First Mint. Gas used = " + rec.gasUsed.toNumber());

      for (let i = 0; i < 10; i++) {
        const tokenId = OptionEncoding.encodeID(poolId, [
          {
            width,
            ratio: 1,
            asset: 0,
            strike: strike - i * 100,
            long: false,
            tokenType: 1,
            riskPartner: 0,
          },
        ]);
        Arr.push(tokenId);
        const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          Arr,
          positionSize,
          20000,
          0,
          0,
        );
        const receipt = await resolved.wait();
        console.log(
          "Number of existing positions = " +
            i.toString() +
            ". Gas used = " +
            receipt.gasUsed.toNumber(),
        );
      }

      const tokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 12 * 100,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      Arr.push(tokenId);
      const tokenId3 = Arr[3];
      Arr[3] = shortPutTokenId;
      await expect(
        pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](Arr, positionSize, 20000, 0, 0),
      ).to.be.revertedWith("InputListFail()");
      Arr[3] = tokenId3;
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        Arr,
        positionSize,
        20000,
        0,
        0,
      );

      const resolved = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
      const receipt = await resolved.wait();
      console.log("Gas used = ", receipt.gasUsed.toNumber());

      Arr.pop();

      const tokenIdNew = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 1,
          asset: 0,
          strike: strike - 13 * 100,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);

      // Shiffle the order of the elements
      Arr.sort(() => Math.random() - 0.5);

      Arr.push(tokenIdNew);
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        Arr,
        positionSize,
        20000,
        0,
        0,
      );
    });

    it("should allow to mint N 1-leg short put ETH option, shortMint only", async function () {
      const width = 4;
      let strike = tick - 1100;
      strike = strike - (strike % 10);

      const amount1 = ethers.utils.parseEther("500");

      const positionSize = BigNumber.from(3396e6);

      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1,
        depositor,
      );

      const shortPutTokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 2,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      const Arr = Array(shortPutTokenId);

      const res = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        Arr,
        positionSize,
        0,
        0,
        0,
      );
      const rec = await res.wait();
      console.log("First Mint. Gas used = " + rec.gasUsed.toNumber());

      for (let i = 0; i < 31; i++) {
        const tokenId = OptionEncoding.encodeID(poolId, [
          {
            width,
            ratio: 1,
            asset: 0,
            strike: strike - i * 100,
            long: false,
            tokenType: 1,
            riskPartner: 0,
          },
        ]);
        Arr.push(tokenId);
        const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          Arr,
          positionSize,
          0,
          0,
          0,
        );
        const receipt = await resolved.wait();
        console.log(
          "Number of existing positions = " +
            i.toString() +
            ". Gas used = " +
            receipt.gasUsed.toNumber(),
        );
      }

      const tokenIdLast = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 100,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      Arr.push(tokenIdLast);

      await expect(
        pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](Arr, positionSize, 0, 0, 0),
      ).to.be.revertedWith("TooManyPositionsOpen()");

      Arr.pop();

      const burnT = await pool["burnOptions(uint256[],int24,int24)"](Arr, 0, 0);
      const recBurn = await burnT.wait();
      console.log("Gas used = ", recBurn.gasUsed.toNumber(), ". Npos = ", Arr.length);
    });

    it("test limits for 4-legged short put ETH option", async function () {
      const width = 4;
      let strike = tick - 1100;
      strike = strike - (strike % 10);

      const amount1 = ethers.utils.parseEther("500");

      const positionSize = BigNumber.from(3396e6);

      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1.mul(100),
        depositor,
      );

      const shortPutTokenId = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 2,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      const Arr = Array(shortPutTokenId);

      const res = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        Arr,
        positionSize,
        0,
        0,
        0,
      );
      const rec = await res.wait();
      console.log("First Mint. Gas used = " + rec.gasUsed.toNumber());

      for (let i = 0; i < 31; i++) {
        const tokenId = OptionEncoding.encodeID(poolId, [
          {
            width,
            ratio: 1,
            asset: 0,
            strike: strike + i * 10,
            long: false,
            tokenType: 1,
            riskPartner: 0,
          },
          {
            width,
            ratio: 2,
            asset: 0,
            strike: strike + i * 10,
            long: false,
            tokenType: 1,
            riskPartner: 1,
          },
          {
            width,
            ratio: 3,
            asset: 0,
            strike: strike + i * 10,
            long: false,
            tokenType: 1,
            riskPartner: 2,
          },
          {
            width,
            ratio: 4,
            asset: 0,
            strike: strike + i * 10,
            long: false,
            tokenType: 1,
            riskPartner: 3,
          },
        ]);
        Arr.push(tokenId);
        const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          Arr,
          positionSize,
          0,
          0,
          0,
        );
        const receipt = await resolved.wait();
        console.log(
          "Number of existing positions = " +
            i.toString() +
            ". Gas used = " +
            receipt.gasUsed.toNumber(),
        );
      }

      const tokenIdLast = OptionEncoding.encodeID(poolId, [
        {
          width,
          ratio: 100,
          asset: 0,
          strike,
          long: false,
          tokenType: 1,
          riskPartner: 0,
        },
      ]);
      Arr.push(tokenIdLast);

      await expect(
        pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](Arr, positionSize, 0, 0, 0),
      ).to.be.revertedWith("TooManyPositionsOpen()");

      Arr.pop();
      const burnT = await pool["burnOptions(uint256[],int24,int24)"](Arr, 0, 0);
      const recBurn = await burnT.wait();
      console.log("Gas used = ", recBurn.gasUsed.toNumber(), ". Npos = ", Arr.length);
    });
  });
});
