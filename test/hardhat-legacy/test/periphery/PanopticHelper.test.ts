/**
 * Test PanopticHelper.
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
  PanopticHelper,
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

describe("Panoptic Helper", async function () {
  this.timeout(1000000);

  const contractName = "PanopticPool";
  const deploymentName = "PanopticPool-ETH-USDC";

  const SFPMContractName = "SemiFungiblePositionManager";
  const SFPMDeploymentName = "SemiFungiblePositionManager";

  let helper: PanopticHelper;

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
  let uniPoolAddress: address;

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
      "PanopticHelper",
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
    helper = (await ethers.getContractAt(
      "PanopticHelper",
      (await deployments.get("PanopticHelper")).address,
    )) as PanopticHelper;
    uniPoolAddress = await pool.univ3pool();
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

  it("Should return correct downward LP within tolerance", async function () {
    const width = 4;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(20),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(20),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(50), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(50), await liquidityProvider.getAddress());

    const shortItmPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 1100,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortItmPutTokenId],
      positionSize,
      0,
      -800000,
      800000,
    );
    expect(
      await helper.findLiquidationPriceDown(pool.address, depositor, [shortItmPutTokenId]),
    ).to.be.equal(187404);
  });
  it("Should return min tick on downward LP below tolerance", async function () {
    const width = 4;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(50), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(50), await liquidityProvider.getAddress());

    const shortItmPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 1100,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortItmPutTokenId],
      positionSize,
      0,
      tick - 1000,
      tick + 1000,
    );
    expect(
      await helper.findLiquidationPriceDown(pool.address, depositor, [shortItmPutTokenId]),
    ).to.be.equal(-887272);
  });
  it("Should return correct upward LP within tolerance", async function () {
    const width = 4;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(20),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(20),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(50), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(50), await liquidityProvider.getAddress());

    const shortItmPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 1100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortItmPutTokenId],
      positionSize,
      0,
      tick - 10000,
      tick + 10000,
    );
    expect(
      await helper.findLiquidationPriceUp(pool.address, depositor, [shortItmPutTokenId]),
    ).to.be.equal(200457);
  });
  it("Should return max tick on upward LP above tolerance", async function () {
    const width = 4;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(50), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(50), await liquidityProvider.getAddress());

    const shortItmPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 1100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortItmPutTokenId],
      positionSize,
      0,
      tick - 40000,
      tick + 20000,
    );
    expect(
      await helper.findLiquidationPriceUp(pool.address, depositor, [shortItmPutTokenId]),
    ).to.be.equal(887272);
  });

  it("Should return correct strangle token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createStrangle(uniPoolAddress, 4, 50, -50, 0, 1, 1, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct straddle token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 0,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 0,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    expect(
      BigInt((await helper.createStraddle(uniPoolAddress, 4, 0, 0, 1, 1, 0)).toString()).toString(
        2,
      ),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct call spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createCallSpread(uniPoolAddress, 4, -50, 50, 0, 1, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct put spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createPutSpread(uniPoolAddress, 4, -50, 50, 0, 1, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct call diag spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 8,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createCallDiagonalSpread(uniPoolAddress, 4, 8, -50, 50, 0, 1, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct put diag spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width: 8,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createPutDiagonalSpread(uniPoolAddress, 4, 8, -50, 50, 0, 1, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct call cal spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 0,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 8,
        ratio: 1,
        asset: 0,
        strike: 0,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createCallCalendarSpread(uniPoolAddress, 4, 8, 0, 0, 1, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct put cal spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 0,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width: 8,
        ratio: 1,
        asset: 0,
        strike: 0,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createPutCalendarSpread(uniPoolAddress, 4, 8, 0, 0, 1, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct iron condor token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 100,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -100,
        long: true,
        tokenType: 1,
        riskPartner: 3,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: false,
        tokenType: 1,
        riskPartner: 2,
      },
    ]);

    expect(
      BigInt(
        (await helper.createIronCondor(uniPoolAddress, 4, 50, -50, 50, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct jade lizard token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 100,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    expect(
      BigInt(
        (await helper.createJadeLizard(uniPoolAddress, 4, 100, 50, -50, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct big lizard token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 100,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 1,
        riskPartner: 2,
      },
    ]);

    expect(
      BigInt((await helper.createBigLizard(uniPoolAddress, 4, 100, 50, 0)).toString()).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct super bull token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    expect(
      BigInt((await helper.createSuperBull(uniPoolAddress, 4, -50, 50, 50, 0)).toString()).toString(
        2,
      ),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct super bear token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: true,
        tokenType: 1,
        riskPartner: 2,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    expect(
      BigInt(
        (await helper.createSuperBear(uniPoolAddress, 4, 50, -50, -50, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct iron butterfly token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 0,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 0,
        long: true,
        tokenType: 1,
        riskPartner: 3,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: false,
        tokenType: 1,
        riskPartner: 2,
      },
    ]);

    expect(
      BigInt((await helper.createIronButterfly(uniPoolAddress, 4, 0, 50, 0)).toString()).toString(
        2,
      ),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct call ratio spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 2,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createCallRatioSpread(uniPoolAddress, 4, -50, 50, 0, 2, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct put ratio spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 2,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createPutRatioSpread(uniPoolAddress, 4, -50, 50, 0, 2, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct call ZEBRA spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 2,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createCallZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct put ZEBRA spread token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 2,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    expect(
      BigInt(
        (await helper.createPutZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0)).toString(),
      ).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct ZEEHBS token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 2,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 2,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 1,
        riskPartner: 3,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 1,
        riskPartner: 2,
      },
    ]);

    expect(
      BigInt((await helper.createZEEHBS(uniPoolAddress, 4, -50, 50, 0, 2)).toString()).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });

  it("Should return correct BATS(double ratio spread) token id", async function () {
    const expectedId = OptionEncoding.encodeID(poolId, [
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 2,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 1,
        asset: 0,
        strike: -50,
        long: true,
        tokenType: 1,
        riskPartner: 3,
      },
      {
        width: 4,
        ratio: 2,
        asset: 0,
        strike: 50,
        long: false,
        tokenType: 1,
        riskPartner: 2,
      },
    ]);

    expect(
      BigInt((await helper.createBATS(uniPoolAddress, 4, -50, 50, 0, 2)).toString()).toString(2),
    ).to.be.equal(expectedId.toString(2));
  });
});
