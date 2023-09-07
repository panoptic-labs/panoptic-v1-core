/**
 * Test Liquidations.
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

describe("Liquidations", async function () {
  this.timeout(1000000);

  const contractName = "PanopticPool";
  const deploymentName = "PanopticPool-ETH-USDC";
  const deploymentName100 = "PanopticPool-ETH-USDC-100";

  const SFPMContractName = "SemiFungiblePositionManager";
  const SFPMDeploymentName = "SemiFungiblePositionManager";

  let pool: PanopticPool;
  let pool100: PanopticPool;
  let uniPool: IUniswapV3Pool;

  let usdc: ERC20;
  let weth: ERC20;

  let collatToken0: ERC20;
  let collatToken1: ERC20;

  let deployer: Signer;
  let optionWriter: Signer;
  let optionBuyer: Signer;
  let liquidityProvider: Signer;
  let liquidator: Signer;
  let swapper: Signer;

  let depositor: address;
  let writor: address;
  let providor: address;
  let liquidateur: address;
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
      deploymentName100,
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
    const deployed5 = await deployments.get(deploymentName);
    const deployed100 = await deployments.get(deploymentName100);
    [deployer, optionWriter, optionBuyer, liquidityProvider, liquidator, swapper] =
      await ethers.getSigners();

    await grantTokens(WETH_ADDRESS, await deployer.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await deployer.getAddress(), USDC_SLOT, usdcBalance);

    await grantTokens(WETH_ADDRESS, await optionWriter.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await optionWriter.getAddress(), USDC_SLOT, usdcBalance);

    await grantTokens(WETH_ADDRESS, await optionBuyer.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await optionBuyer.getAddress(), USDC_SLOT, usdcBalance);

    await grantTokens(WETH_ADDRESS, await liquidityProvider.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await liquidityProvider.getAddress(), USDC_SLOT, usdcBalance);

    await grantTokens(WETH_ADDRESS, await liquidator.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await liquidator.getAddress(), USDC_SLOT, usdcBalance);

    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, usdcBalance);

    //pool = (await ethers.getContractAt(contractName, deployed5.address)) as PanopticPool;
    pool = (await ethers.getContractAt(contractName, deployed100.address)) as PanopticPool;

    usdc = await IERC20__factory.connect(USDC_ADDRESS, deployer);
    weth = await IERC20__factory.connect(WETH_ADDRESS, deployer);

    depositor = await deployer.getAddress();
    writor = await optionWriter.getAddress();
    buyor = await optionBuyer.getAddress();
    providor = await liquidityProvider.getAddress();
    liquidateur = await liquidator.getAddress();

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

    await IERC20__factory.connect(WETH_ADDRESS, liquidator).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidator).approve(
      pool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(WETH_ADDRESS, liquidator).approve(
      uniPool.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidator).approve(
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

    await collatToken0.connect(liquidator).approve(pool.address, ethers.constants.MaxUint256);
    await collatToken1.connect(liquidator).approve(pool.address, ethers.constants.MaxUint256);

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

    await IERC20__factory.connect(WETH_ADDRESS, liquidator).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidator).approve(
      collatToken0.address,
      ethers.constants.MaxUint256,
    );

    await IERC20__factory.connect(WETH_ADDRESS, liquidator).approve(
      collatToken1.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidator).approve(
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

  it("100bps: should NOT liquidate account: short put (OTM)", async function () {
    const width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 200);

    const amount0 = BigNumber.from(3396144616);
    const amount1 = ethers.utils.parseEther("1");

    const positionSize = BigNumber.from(3396144616);

    // deployer only deposits >100% of required
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
    ).deposit(amount0.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator).deposit(
      amount0.mul(10),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator).deposit(
      amount1.mul(10),
      await liquidator.getAddress(),
    );

    const shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      4772185880,
      0,
      0,
    );
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize,
        4772185880,
        0,
        0,
      );

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1957265332168641534");

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 500);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 500);

    // console.log("amountW to swap", amountW.toString());
    // console.log("amountU to swap", amountU.toString());

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

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);
    // console.log("new tick", slot1_.tick);

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(depositor, [shortPutTokenId]);
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    ///////// Liquidate
    await expect(
      pool
        .connect(liquidator)
        .liquidateAccount(depositor, 0, 0, [shortPutTokenId], [shortPutTokenId]),
    ).to.be.reverted;

    await expect(
      pool.connect(liquidator).liquidateAccount(depositor, 0, 0, [shortPutTokenId], []),
    ).to.be.revertedWith(revertCustom("NotMarginCalled()"));

    await pool["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("100000028888388"); // gained USDC
    expect(await weth.balanceOf(depositor)).to.equal("1000000002583969335906680"); // gained collateral ETH (premium?)

    expect(await usdc.balanceOf(writor)).to.equal("100000028888747"); // gained 28 USDC
    expect(await weth.balanceOf(writor)).to.equal("1000000003536631967133720"); // gained 0.00353 ETH

    expect(await usdc.balanceOf(providor)).to.equal("100000000003588"); // gained 0.00358 USDC
    expect(await weth.balanceOf(providor)).to.equal("1000000009523519886511527"); // gained ETH

    expect(await usdc.balanceOf(liquidateur)).to.equal("100000000000397"); // lost 4.96USDC? Why?
    expect(await weth.balanceOf(liquidateur)).to.equal("1000000001058168876279058"); // gained 0.00105
  });

  it("100bps: should NOT liquidate account: short put (OTM), close to maintenance margin", async function () {
    const width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 200);
    // console.log("currentTick", tick);
    // console.log("strike", strike);
    // console.log("lower", strike - (width * 100) / 2);
    // console.log("upper", strike + (width * 100) / 2);

    const amount0 = BigNumber.from(3396144616);
    const amount1 = ethers.utils.parseEther("1");

    const positionSize = BigNumber.from(3396144616);

    // deployer only deposits >100% of required
    // await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(amount0, depositor);
    // await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(amount1, depositor);
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
    ).deposit(amount0.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator).deposit(
      amount0.mul(10),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator).deposit(
      amount1.mul(10),
      await liquidator.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    const shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      4772185880,
      0,
      0,
    );
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize,
        4772185880,
        0,
        0,
      );

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1957265332168641534");

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 500);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 500);

    // console.log("amountW to swap", amountW.toString());
    // console.log("amountU to swap", amountU.toString());

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

    //await swapRouter.connect(swapper).exactInputSingle(paramsS);
    //await swapRouter.connect(swapper).exactInputSingle(paramsB);
    //await swapRouter.connect(swapper).exactInputSingle(paramsB);
    //await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(depositor, [shortPutTokenId]);
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);
    expect(
      (await pool.checkCollateral(depositor, slot1_.tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("825625350,661863613");

    ///////// Liquidate
    await expect(
      pool
        .connect(liquidator)
        .liquidateAccount(depositor, 0, 0, [shortPutTokenId], [shortPutTokenId]),
    ).to.be.reverted;

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }

    await mineBlocks(250);

    await expect(
      pool.connect(liquidator).liquidateAccount(depositor, 0, 0, [shortPutTokenId], []),
    ).to.be.revertedWith(revertCustom("NotMarginCalled()"));

    await pool["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);

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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("100000000000000"); // gained USDC
    expect(await weth.balanceOf(depositor)).to.equal("999999994154209854419208"); // lost collateral ETH (premium?)

    expect(await usdc.balanceOf(writor)).to.equal("100000000000000"); // gained USDC
    expect(await weth.balanceOf(writor)).to.equal("999999995193145114334068"); // gained ETH

    expect(await usdc.balanceOf(providor)).to.equal("100000000000000"); // gained
    expect(await weth.balanceOf(providor)).to.equal("1000000009587284651585624"); // gained

    expect(await usdc.balanceOf(liquidateur)).to.equal("100000000000000"); //
    expect(await weth.balanceOf(liquidateur)).to.equal("1000000001065253850176180"); // gained
  });

  it("100bps: should NOT liquidate account: long put (OTM), close to maintenance margin", async function () {
    const width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 200);
    // console.log("currentTick", tick);
    // console.log("strike", strike);
    // console.log("lower", strike - (width * 100) / 2);
    // console.log("upper", strike + (width * 100) / 2);

    const amount0 = BigNumber.from(3396144616);
    const amount1 = ethers.utils.parseEther("1");

    const positionSize = BigNumber.from(3396144616);

    // deployer only deposits >100% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(6),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(6),
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
    ).deposit(amount0.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator).deposit(
      amount0.mul(10),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator).deposit(
      amount1.mul(10),
      await liquidator.getAddress(),
    );

    const shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0
    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        0,
        4772185880,
        0,
        0,
      ),
    ).to.be.reverted;
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize.mul(10),
        4772185880,
        0,
        0,
      );
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longPutTokenId],
      positionSize,
      4772185880,
      0,
      0,
    );

    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      "33961446160",
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("8807693994758886912");

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 500);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 500);

    // console.log("amountW to swap", amountW.toString());
    // console.log("amountU to swap", amountU.toString());

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

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);
    // console.log("new tick", slot1_.tick);

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(depositor, [shortPutTokenId]);
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    ///////// Liquidate
    await expect(
      pool
        .connect(liquidator)
        .liquidateAccount(depositor, 0, 0, [shortPutTokenId], [shortPutTokenId]),
    ).to.be.reverted;

    await expect(
      pool.connect(liquidator).liquidateAccount(depositor, 0, 0, [longPutTokenId], []),
    ).to.be.revertedWith(revertCustom("NotMarginCalled()"));

    await pool["burnOptions(uint256,int24,int24)"](longPutTokenId, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999972507422"); // lost USDC
    expect(await weth.balanceOf(depositor)).to.equal("999999986270389707281406"); // lost collateral ETH (premium?)

    expect(await usdc.balanceOf(writor)).to.equal("100000271340433"); // gained 270 USDC
    expect(await weth.balanceOf(writor)).to.equal("1000000025629757490250569"); // gained 0.025 ETH

    expect(await usdc.balanceOf(providor)).to.equal("100000000162413"); // gained 0.16 USDC
    expect(await weth.balanceOf(providor)).to.equal("1000000052840341793788462"); // gained 0.00952

    expect(await usdc.balanceOf(liquidateur)).to.equal("100000000018045"); // gained 0.018
    expect(await weth.balanceOf(liquidateur)).to.equal("1000000005871149088198718"); // gained 0.00105
  });

  it("100bps: should liquidate account: long put (OTM), below maintenance margin - 0", async function () {
    const width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 200);
    // console.log("currentTick", tick);
    // console.log("strike", strike);
    // console.log("lower", strike - (width * 100) / 2);
    // console.log("upper", strike + (width * 100) / 2);

    const amount0 = BigNumber.from(3396144616);
    const amount1 = ethers.utils.parseEther("1");

    const positionSize = BigNumber.from(3396144616);

    // deployer only deposits >100% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(18),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(18),
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
    ).deposit(amount0.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator).deposit(
      amount0.mul(10),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator).deposit(
      amount1.mul(10),
      await liquidator.getAddress(),
    );

    const shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0
    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        0,
        4772185880,
        0,
        0,
      ),
    ).to.be.reverted;
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize.mul(10),
        4772185880,
        0,
        0,
      );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longPutTokenId],
      positionSize,
      4772185880,
      0,
      0,
    );

    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      "33961446160",
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("8807693994758886912");

    await expect(
      pool.connect(liquidator).liquidateAccount(depositor, 0, 0, [longPutTokenId], []),
    ).to.be.revertedWith(revertCustom("NotMarginCalled()"));

    const slot0_ = await uniPool.slot0();

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 500);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 500);

    // console.log("amountW to swap", amountW.toString());
    // console.log("amountU to swap", amountU.toString());

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

    const pc = UniswapV3.priceFromTick(tick);
    // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
    // console.log("initial tick", slot0_.tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);
    // console.log("new tick", slot1_.tick);

    ///////// Liquidate
    await expect(
      pool
        .connect(liquidator)
        .liquidateAccount(depositor, 0, 0, [shortPutTokenId], [shortPutTokenId]),
    ).to.be.reverted;

    await pool.connect(liquidator).liquidateAccount(depositor, 0, 0, [longPutTokenId], []);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);

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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999811325300"); // lost 188 USDC
    expect(await weth.balanceOf(depositor)).to.equal("999999990125668072866750"); // lost 0.0106 collateral ETH (premium?)

    expect(await usdc.balanceOf(liquidateur)).to.equal("100000161232042"); // gained 158
    expect(await weth.balanceOf(liquidateur)).to.equal("1000000001956603580687269"); // gained 0.0196

    expect(await usdc.balanceOf(writor)).to.equal("100000271337068"); // gained 270 USDC
    expect(await weth.balanceOf(writor)).to.equal("1000000025635602003583627"); // gained 0.025 ETH

    expect(await usdc.balanceOf(providor)).to.equal("100000000133903"); //gained 0.133 USDC
    expect(await weth.balanceOf(providor)).to.equal("1000000052893763828780497"); // gained 0.00952
  });

  it("100bps: should liquidate account: long put (OTM), below maintenance margin - 1", async function () {
    const width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 200);
    // console.log("currentTick", tick);
    // console.log("strike", strike);
    // console.log("lower", strike - (width * 100) / 2);
    // console.log("upper", strike + (width * 100) / 2);

    const amount0 = BigNumber.from(3396144616);
    const amount1 = ethers.utils.parseEther("1");

    const positionSize = BigNumber.from(3396144616);

    // deployer only deposits >100% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(18),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(18),
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
    ).deposit(amount0.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator).deposit(
      amount0.mul(10),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator).deposit(
      amount1.mul(10),
      await liquidator.getAddress(),
    );

    const shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0
    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        0,
        4772185880,
        0,
        0,
      ),
    ).to.be.reverted;
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize.mul(10),
        4772185880,
        0,
        0,
      );
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longPutTokenId],
      positionSize,
      4772185880,
      0,
      0,
    );

    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      "33961446160",
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("8807693994758886912");

    await expect(
      pool.connect(liquidator).liquidateAccount(depositor, 0, 0, [longPutTokenId], []),
    ).to.be.revertedWith(revertCustom("NotMarginCalled()"));

    const slot0_ = await uniPool.slot0();

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 500);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 500);

    // console.log("amountW to swap", amountW.toString());
    // console.log("amountU to swap", amountU.toString());

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

    const pc = UniswapV3.priceFromTick(tick);
    // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
    // console.log("initial tick", slot0_.tick);

    for (let i = 0; i < 10; i++) {
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
    }
    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);
    // console.log("new tick", slot1_.tick);

    ///////// Liquidate
    await expect(
      pool
        .connect(liquidator)
        .liquidateAccount(depositor, 0, 0, [shortPutTokenId], [shortPutTokenId]),
    ).to.be.reverted;

    await pool.connect(liquidator).liquidateAccount(depositor, 0, 0, [longPutTokenId], []);

    await expect(pool["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0)).to.be.reverted;
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);

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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionWriter,
      ).maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidator)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        liquidator,
      ).maxWithdraw(await liquidator.getAddress()),
      await liquidator.getAddress(),
      await liquidator.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999811325300"); // lost 188 USDC
    expect(await weth.balanceOf(depositor)).to.equal("999999944444444444444445"); // lost 0.05555 collateral ETH (premium?)

    expect(await usdc.balanceOf(liquidateur)).to.equal("99999995216189"); //
    expect(await weth.balanceOf(liquidateur)).to.equal("999999998703588771499331"); // lost 0.002

    expect(await usdc.balanceOf(writor)).to.equal("100002210146657"); // gained 2240 USDC
    expect(await weth.balanceOf(writor)).to.equal("1000000588467159369677138"); // gained 0.586 ETH

    expect(await usdc.balanceOf(providor)).to.equal("99999983141063"); //lost 61 USDC
    expect(await weth.balanceOf(providor)).to.equal("1000000048585515523506478"); // gained 0.04
  });
});
