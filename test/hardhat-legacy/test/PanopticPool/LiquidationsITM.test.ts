/**
 * Test In the Money Liqudations.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { deployments, ethers, network } from "hardhat";
import { expect } from "chai";
import { grantTokens, revertReason, revertCustom } from "../utils";
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

describe("liquidations: ITMs", async function () {
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
  it("should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, bonus=12bps ", async function () {
    const dTick = 215;
    const width = 2;
    var strike = tick - 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396144616);
    const amount1 = ethers.utils.parseEther("1");

    const positionSize = BigNumber.from(3396144616);

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    await expect(
      pool.connect(optionWriter).liquidateAccount(depositor, 0, 0, [shortPutTokenId], []),
    ).to.be.revertedWith("NotMarginCalled()");

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);
    //await swapRouter.connect(swapper).exactInputSingle(paramsU);
    //await mineBlocks(50);

    ///////// Liquidate

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();

    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

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

    // NEW Price =  194302 = 3647
    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // lost 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999933615376857313980"); // lost 0.066ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001760440"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000004033859073134626"); // gained 0.004ETH

    expect(await usdc.balanceOf(providor)).to.equal("99999999972446"); // dust?
    expect(await weth.balanceOf(providor)).to.equal("1000000002604601336038452"); // gained 0.000260ETH
  });

  it("should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, bonus=2283 bps", async function () {
    const dTick = 320;

    const width = 2;
    var strike = tick - 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396144616);
    const amount1 = ethers.utils.parseEther("1");

    const positionSize = BigNumber.from(3396144616);

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000,0,0);

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("33964876250");
    expect((await pool.poolData(1))[0].toString()).to.equal("9261543498214509241");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("33964876250");
    expect((await pool.poolData(1))[1].toString()).to.equal("10251000004428773892");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989456506214264651");

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // commission 60bps
    expect(await collatToken0.balanceOf(writor)).to.equal("16980723080");
    expect(await collatToken1.balanceOf(writor)).to.equal("5000000000000000000");
    expect(await collatToken0.balanceOf(providor)).to.equal("16980723080");
    expect(await collatToken1.balanceOf(providor)).to.equal("5000000000000000000");

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    ///////// Liquidate
    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();

    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );
    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("33966575171");
    //expect((await pool.poolData(1))[0].toString()).to.equal("10123282515643929654");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("33966575170");
    //expect((await pool.poolData(1))[1].toString()).to.equal("10123282515643929654");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");
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

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost 0.1897ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001767046"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000083747825799070789"); // gained 0.0083ETH

    expect(await usdc.balanceOf(providor)).to.equal("99999999965841"); // TODO: check why!
    expect(await weth.balanceOf(providor)).to.equal("999999987232266229003849"); // lost 0.0004ETH
  });

  it("should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, bonus=3537 bps", async function () {
    const dTick = 320;

    const width = 2;
    var strike = tick - 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396144616);
    const amount1 = ethers.utils.parseEther("1");

    const positionSize = BigNumber.from(3396144616);

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // commission 60bps

    ///////// Liquidate
    //
    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();

    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

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

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001767046"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000083747825799070789"); // gained 0.083ETH

    expect(await usdc.balanceOf(providor)).to.equal("99999999965841"); // dust?
    expect(await weth.balanceOf(providor)).to.equal("999999987232266229003849"); // gaines 0.0004ETH
  });

  it("should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, swap to 193544 (price =3934) ", async function () {
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);

    let depositor = await deployer.getAddress();

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 280);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 280);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("960905048,1176294354");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(depositor, [shortPutTokenId]);
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    //await pool["burnOptions(uint256[],int24,int24)"](shortPutTokenId, -800000, 800000);
    ///////// Liquidate
    //
    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

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

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999810083236514137720"); // lost 0.189ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001763947"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000058194081250499214"); // gained 0.059ETH
    expect(await usdc.balanceOf(providor)).to.equal("99999999968939"); // dust?
    expect(await weth.balanceOf(providor)).to.equal("1000000004113266252504937"); // gained 0.004ETH
  });

  it("should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, swap to 193390 (price = 3995)", async function () {
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);

    let depositor = await deployer.getAddress();

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829388401,672067477");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 290);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 290);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("975816239,1236710780");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(depositor, [shortPutTokenId]);
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    //await pool["burnOptions(uint256[],int24,int24)"](shortPutTokenId, -800000, 800000);
    ///////// Liquidate
    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );
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

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999785991638658879892"); // lost all 0.21ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001764692"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000068939866118220197"); // gained 0.074ETH
    expect(await usdc.balanceOf(providor)).to.equal("99999999968195"); // dust?
    expect(await weth.balanceOf(providor)).to.equal("1000000003429332018135752"); // gained 0.074ETH
  });

  it("should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, swap to 192436 (price = 4395), close to losing funds", async function () {
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);
    let depositor = await deployer.getAddress();

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829388401,672067477");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 350);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 350);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("1073485760,1632443327");

    ///////// Liquidate

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
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

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001769582"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000079491023166782776"); // gained 0.0276ETH

    expect(await usdc.balanceOf(providor)).to.equal("99999999963306"); // dust?
    expect(await weth.balanceOf(providor)).to.equal("999999953258106913006927"); // gained 0.0276ETH
  });

  it("should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, swap to 191834 (price = 4668), almost losing funds now", async function () {
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);
    let depositor = await deployer.getAddress();
    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();
    let buyor = await optionBuyer.getAddress();
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829151153,672067477");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 350);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 350);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("1073178685,1632443327");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67926322410"); //2*amount0.mul(10) + amount0.div(100000)
    expect((await pool.poolData(1))[0].toString()).to.equal("19261543498214509241"); // 2*amount1.mul(10) + amount1.div(4) - 0.9894

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67926322410");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773892"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989456506214264651");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("488"); // pool utilization 0.9894 / 10.25 = 9.65%

    // check token balances for all
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0

    expect(await collatToken0.balanceOf(optionWriter.getAddress())).to.equal("33961446160");
    expect(await collatToken1.balanceOf(optionWriter.getAddress())).to.equal(
      "10000000000000000000",
    );

    expect(await collatToken0.balanceOf(optionBuyer.getAddress())).to.equal("33961446160");
    expect(await collatToken1.balanceOf(optionBuyer.getAddress())).to.equal("10000000000000000000");

    ///////// Liquidate
    // New price = 4668, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/4668) = -0.02ETH
    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67928021331"); // amount0.mul(10) - 1.73(IL?) =  33963179042: seller lost all and LP lost 1.732 (premium!)
    expect((await pool.poolData(1))[0].toString()).to.equal("20033739786088544342"); // amount1.mul(10) - 0.1236 (IL?) < 10 : seller lost all AND LP lost 0.1236 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67928021330"); // amount0.mul(10) + 1.732 (gain)
    expect((await pool.poolData(1))[1].toString()).to.equal("20033739786088544342"); // amount1.mul(10) - 0.1236ETH (IL)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); // pool utilization 0

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    // Withdraw optionWriter: should be ahead
    expect(await usdc.balanceOf(writor)).to.equal("99966038553840"); // 10^8 - 33910 USDC
    expect(await weth.balanceOf(writor)).to.equal("999990000000000000000000"); // 10^6 - 10ETH
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

    expect(await usdc.balanceOf(writor)).to.equal("100000001769565"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000079766616588129025"); // gained 0.0796ETH

    // Withdraw optionBuyer: should lose
    expect(await usdc.balanceOf(buyor)).to.equal("99966038553840"); // 10^8 - 33910 USDC
    expect(await weth.balanceOf(buyor)).to.equal("999990000000000000000000"); // 10^6 - 10ETH
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    expect(await usdc.balanceOf(buyor)).to.equal("99999999963319"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("999999952977867305735890"); // gained 0.044ETH
  });

  it("check: should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, swap to 191834 (price = 4668), not losing funds yet", async function () {
    let dTick = 305;

    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);
    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829151153,672067477");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67926322410"); //2*amount0.mul(10) + amount0.div(100000)
    expect((await pool.poolData(1))[0].toString()).to.equal("19261543498214509241"); // 2*amount1.mul(10) + amount1.div(4) - 0.9894

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67926322410");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773892"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989456506214264651");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("488"); // pool utilization 0.9894 / 10.25 = 9.65%

    // check token balances for all
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0

    expect(await collatToken0.balanceOf(optionWriter.getAddress())).to.equal("33961446160");
    expect(await collatToken1.balanceOf(optionWriter.getAddress())).to.equal(
      "10000000000000000000",
    );

    expect(await collatToken0.balanceOf(optionBuyer.getAddress())).to.equal("33961446160");
    expect(await collatToken1.balanceOf(optionBuyer.getAddress())).to.equal("10000000000000000000");

    ///////// Liquidate
    // New price = 4668, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/4668) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Withdraw depositor: should lose 0.25ETH (collateral)
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

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750556133629769707"); // lost 0.249ETH of collateral

    // Withdraw optionWriter: should be ahead
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

    // Withdraw optionBuyer: should lose
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // 10^8 - 33910 USDC
    expect(await weth.balanceOf(depositor)).to.equal("999999750556133629769707"); // 10^6 - 10ETH

    expect(await usdc.balanceOf(writor)).to.equal("100000001765858"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000084683371160337625"); // lost 0.0173

    expect(await usdc.balanceOf(buyor)).to.equal("99999999967025"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("1000000003982741503238895"); // lost 0.05011ETH
  });

  it("check: should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, swap to 191834 (price = 4668), not losing funds yet but no collateral", async function () {
    let dTick = 306;

    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829151153,672067477");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67926322410"); //2*amount0.mul(10) + amount0.div(100000)
    expect((await pool.poolData(1))[0].toString()).to.equal("19261543498214509241"); // 2*amount1.mul(10) + amount1.div(4) - 0.9894

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67926322410");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773892"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989456506214264651");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("488"); // pool utilization 0.9894 / 10.25 = 9.65%

    // check token balances for all
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0

    expect(await collatToken0.balanceOf(optionWriter.getAddress())).to.equal("33961446160");
    expect(await collatToken1.balanceOf(optionWriter.getAddress())).to.equal(
      "10000000000000000000",
    );

    expect(await collatToken0.balanceOf(optionBuyer.getAddress())).to.equal("33961446160");
    expect(await collatToken1.balanceOf(optionBuyer.getAddress())).to.equal("10000000000000000000");

    ///////// Liquidate
    // New price = 4668, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/4668) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Withdraw depositor: should lose 0.25ETH (collateral)
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
    // Withdraw optionWriter: should be ahead
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

    // Withdraw optionBuyer: should lose
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001765948"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000085636546075950814"); // lost 0.0173

    expect(await usdc.balanceOf(buyor)).to.equal("99999999966936"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("1000000002910719112370744"); // lost 0.05011ETH
  });

  it("check: should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, swap to 191834 (price = 4668), not losing funds yet", async function () {
    let dTick = 377;

    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829151153,672067477");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67926322410"); //2*amount0.mul(10) + amount0.div(100000)
    expect((await pool.poolData(1))[0].toString()).to.equal("19261543498214509241"); // 2*amount1.mul(10) + amount1.div(4) - 0.9894

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67926322410");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773892"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989456506214264651");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("488"); // pool utilization 0.9894 / 10.25 = 9.65%

    // check token balances for all
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0

    expect(await collatToken0.balanceOf(optionWriter.getAddress())).to.equal("33961446160");
    expect(await collatToken1.balanceOf(optionWriter.getAddress())).to.equal(
      "10000000000000000000",
    );

    expect(await collatToken0.balanceOf(optionBuyer.getAddress())).to.equal("33961446160");
    expect(await collatToken1.balanceOf(optionBuyer.getAddress())).to.equal("10000000000000000000");

    ///////// Liquidate
    // New price = 4668, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/4668) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Withdraw depositor: should lose 0.25ETH (collateral)
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

    // Withdraw optionWriter: should be ahead
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

    // Withdraw optionBuyer: should lose
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001772103"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000075960454996213147"); // lost 0.0173

    expect(await usdc.balanceOf(buyor)).to.equal("99999999960781"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("999999921878409233407592"); // lost 0.05011ETH
  });

  it("check: should liquidate account: short put (ITM), Large collateral=1, asset=0, liquidation tick = 194310, swap to 191834 (price = 4668), losing funds now", async function () {
    let dTick = 385;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829151153,672067477");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("1139762742,1902302520");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67926322410"); //2*amount0.mul(10) + amount0.div(100000)
    expect((await pool.poolData(1))[0].toString()).to.equal("19261543498214509241"); // 2*amount1.mul(10) + amount1.div(4) - 0.9894

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67926322410");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773892"); // 2*amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989456506214264651");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("488"); // pool utilization 0.9894 / 20.25 = 4.88%

    ///////// Liquidate
    // New price = 4668, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/4668) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67928021331"); // amount0.mul(10) - 1.73(IL?) =  33963179042: seller lost all and LP lost 1.732 (premium!)
    expect((await pool.poolData(1))[0].toString()).to.equal("19988615513303668992"); // amount1.mul(10) - 0.1236 (IL?) < 10 : seller lost all AND LP lost 0.1236 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67928021330"); // amount0.mul(10) + 1.732 (gain)
    expect((await pool.poolData(1))[1].toString()).to.equal("19988615513303668992"); // amount1.mul(10) - 0.1236ETH (IL)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); // pool utilization 0

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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // lost 0.033USDC (?) in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001772895"); //
    expect(await weth.balanceOf(writor)).to.equal("1000000074849368597724752"); // lost 0.017ETH

    expect(await usdc.balanceOf(buyor)).to.equal("99999999959990"); //
    expect(await weth.balanceOf(buyor)).to.equal("999999912774862829517437"); // gained 0.005ETH
  });

  it("check: should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, swap to 182875 (price = 11,435), losing LOTTTSSSS of funds now", async function () {
    let dTick = 585;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);
    let depositor = await deployer.getAddress();
    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829151153,672067477");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("2791719448,8597534430");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67926322410"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("19261543498214509241"); // amount1.mul(10) + amount1.div(4) - 0.9894

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67926322410");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773892"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989456506214264651");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("488"); // pool utilization 0.9894 / 10.25 = 9.65%

    ///////// Liquidate
    // New price = 4668, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.376ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67928021331"); // amount0.mul(10) - 1.732(IL?) =  33963179042: seller lost all and LP lost 1.732 (premium!)
    expect((await pool.poolData(1))[0].toString()).to.equal("19558325621845109783"); // amount1.mul(10) - 0.442 (IL?) < 10 : seller lost all AND LP lost 0.442 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67928021330"); // amount0.mul(10) + 1.732 (gain)
    expect((await pool.poolData(1))[1].toString()).to.equal("19558325621845109783"); // amount1.mul(10) - 0.442ETH (IL)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); // pool utilization 0.9894 / 10.25 = 9.65%

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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001855517"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000020884029391506548"); // lost 0.458ETH

    expect(await usdc.balanceOf(buyor)).to.equal("99999999877376"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("999999536487939436164737"); // gained 0.01ETH
  });

  it("check: should liquidate account: short put (ITM), collateral=1, asset=0, liquidation tick = 194310, swap to 4946 (price 10^11), losing ALL funds now", async function () {
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = BigNumber.from(3396144616);
    let depositor = await deployer.getAddress();
    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
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

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829151153,672067477");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244063260962714414"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 1085);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 1085);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("2107617711403614,8541982253453465");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67926322410"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("19261543498214509241"); // amount1.mul(10) + amount1.div(4) - 0.9894

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67926322410");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773892"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989456506214264651");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("488"); // pool utilization 0.9894 / 10.25 = 9.65%

    ///////// Liquidate
    // New price = 4668, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.376ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67928021331"); // amount0.mul(10) - 1.732(IL?) =  33963179042: seller lost all and LP lost 1.732 (premium!)
    expect((await pool.poolData(1))[0].toString()).to.equal("19261543891412196932"); // amount1.mul(10) - 0.442 (IL?) < 10 : seller lost all AND LP lost 0.442 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67928021330"); // amount0.mul(10) + 1.732 (gain)
    expect((await pool.poolData(1))[1].toString()).to.equal("19261543891412196932"); // amount1.mul(10) - 0.442ETH (IL)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); // pool utilization 0.9894 / 10.25 = 9.65%

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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100025687962623"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("999999976394207133875033"); // gained 0.02ETH

    expect(await usdc.balanceOf(buyor)).to.equal("99974316338612"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("999999284221258040746153"); // gained 0.029ETH
  });

  it("check: should liquidate account: short put (ITM), collateral=1, asset=1 liquidation tick = 194310, swap to 191834 (price = 4668), losing funds now", async function () {
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(5),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(5), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("829178553,679228923");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244000000000000000"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 385);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 385);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("1139800406,1922573158");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("33964876250"); //amount0.mul(10) + amount0.div(100000)
    expect((await pool.poolData(1))[0].toString()).to.equal("9251000004428773891"); // amount1.mul(10) + amount1.div(4) - 1ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("33964876250");
    expect((await pool.poolData(1))[1].toString()).to.equal("10251000004428773891"); // amount1.mul(10) + amount1.div(4)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("975"); // pool utilization 1 / 10.25 = 9.75%

    ///////// Liquidate
    // New price = 4668, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/4668) = -0.02ETH
    //
    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

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

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.71USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001791001"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000074884675906753274");

    expect(await usdc.balanceOf(providor)).to.equal("99999999959992"); // dust?
    expect(await weth.balanceOf(providor)).to.equal("999999909953044637639805"); // lost 0.022ETH
  });

  it("check: should liquidate account: short put (ITM), collateral=1, asset=1 , liquidation tick = 194310, swap to 182875 (price = 11,435), losing LOTTTSSSS of funds now", async function () {
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");
    let depositor = await deployer.getAddress();
    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("828938836,679228923");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244000000000000000"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 585);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 585);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("2791004567,8689148412");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67926322410"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("19251000004428773891"); // amount1.mul(10) + amount1.div(4) - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67926322410");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773891"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("493"); // pool utilization 1 / 20.25 = 9.75%

    ///////// Liquidate
    // New price = 11435, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.02ETH
    //
    //
    //

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67928039435"); // amount0.mul(10) - 1.732(IL?) =  33963179042: seller lost all and LP lost 1.732 (premium!)
    expect((await pool.poolData(1))[0].toString()).to.equal("19550944825529116422"); // amount1.mul(10) - 0.450 (IL?) < 10 : seller lost all AND LP lost 0.450 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67928039434"); // amount0.mul(10) + 1.732 (gain)
    expect((await pool.poolData(1))[1].toString()).to.equal("19550944825529116422"); // amount1.mul(10) - 0.450ETH (IL)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");

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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100000001873585"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("1000000020856394369570853"); // lost 0.45ETH

    expect(await usdc.balanceOf(buyor)).to.equal("99999999877412"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("999999529135513387968114"); // lost 0.0159ETH
  });

  it("check: should liquidate account: short put (ITM), collateral=1, asset=1 , liquidation tick = 194310, swap to 4946 (price ~ 10^11), losing ALL funds now", async function () {
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");
    let depositor = await deployer.getAddress();
    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100000),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
      depositor,
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("828938836,679228923");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244000000000000000"); // 0.25ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 10085);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 10085);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("148649226243321130,609037637430482354");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67926322410"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("19251000004428773891"); // amount1.mul(10) + amount1.div(4) - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67926322410");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773891"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("493"); // pool utilization 1 / 20.25 = 9.75%

    ///////// Liquidate
    // New price = 11435, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67928039435"); // amount0.mul(10) - 1.732(IL?) =  33963179042: seller lost all and LP lost 1.732 (premium!)
    expect((await pool.poolData(1))[0].toString()).to.equal("19251000010061584865"); // amount1.mul(10) - 0.450 (IL?) < 10 : seller lost all AND LP lost 0.450 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67928039434"); // amount0.mul(10) + 1.732 (gain)
    expect((await pool.poolData(1))[1].toString()).to.equal("19251000010061584865"); // amount1.mul(10) - 0.450ETH (IL)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("1");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");

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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999966039"); // gained 1.69USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999750000000000000000"); // lost all 0.25ETH of collateral

    expect(await usdc.balanceOf(writor)).to.equal("100033812105992"); // dust?
    expect(await weth.balanceOf(writor)).to.equal("999999975677229169462850"); // gains 0.083ETH

    expect(await usdc.balanceOf(buyor)).to.equal("99966193025674"); //
    expect(await weth.balanceOf(buyor)).to.equal("999999274395337250976924"); // gained 0.03ETH
  });

  it("should liquidate account: short put (ITM), both-collateral, asset=1 , liquidation tick = 194310", async function () {
    let dTick = 320;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");
    let depositor = await deployer.getAddress();

    // deployer only deposits 25% of required, split evenly between tokens
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(8),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(8),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();
    expect(await collatToken0.balanceOf(depositor)).to.equal("424518077");
    expect(await collatToken1.balanceOf(depositor)).to.equal("125000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("828779805,679228923");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect(await collatToken0.balanceOf(depositor)).to.equal("424518077"); // amount0 / 8
    expect(await collatToken1.balanceOf(depositor)).to.equal("119000000000000000"); // 0.125ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("923092078,1442581731"); // balance = amount0/8, required = 0

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 1, [shortPutTokenId])
      ).toString(),
    ).to.equal("220389981899532921,344419120206909513"); //balance = 0.125-commission+fees, required = 0.344ETH (notional value of call option)*(1-0.8*3430/4188)

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("68350806526"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("19126000004428773891"); // amount1.mul(10) + amount1.div(4) - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("68350806526");
    expect((await pool.poolData(1))[1].toString()).to.equal("20126000004428773891"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("496"); // pool utilization 1 / 20.25 = 9.75%

    ///////// Liquidate
    // New price = 4188, strike price = 3430, collateral = 0.119ETH + 424.5/4188 = 0.119 + 0.1013 -> excess = 0.22 - (1-3430/4188) = +0.039ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("68352523551"); //
    expect((await pool.poolData(1))[0].toString()).to.equal("19945070001433601338"); //

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("68352523550"); //
    expect((await pool.poolData(1))[1].toString()).to.equal("19945070001433601338"); //

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("1");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");

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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    // NEW PRICE = 4188
    expect(await usdc.balanceOf(depositor)).to.equal("99999575481923"); // lost  422USDC in premium
    expect(await weth.balanceOf(depositor)).to.equal("999999875000000000000000"); // lost 0.125 collateral. Net: 237 + 0.125*4188 = 760 USDC

    expect(await usdc.balanceOf(writor)).to.equal("100000426241048"); // gained 424 USDC
    expect(await weth.balanceOf(writor)).to.equal("1000000005377832756987166"); // lost 0.06 ETH. Net: 424-456

    expect(await usdc.balanceOf(buyor)).to.equal("99999999994053"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("999999938698294445544864"); //
  });

  it("should liquidate account: short put (ITM), cross-collateral, asset=1 , liquidation tick = 194310", async function () {
    let dTick = 320;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");
    let depositor = await deployer.getAddress();

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(4),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(100),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();
    expect(await collatToken0.balanceOf(depositor)).to.equal("849036154");
    expect(await collatToken1.balanceOf(depositor)).to.equal("10000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("862624806,679228923");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("849036154");
    expect(await collatToken1.balanceOf(depositor)).to.equal("4000000000000000"); // 0.01ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("865794972,1442581731");

    //expect(
    //  (
    //    await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 1, [shortPutTokenId])
    //  ).toString()
    //).to.equal("4001199760047990,586835935176824028"); //32% collateralization

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("68775324603"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("19011000004428773891"); // amount1.mul(10) + amount1.div(4) - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("68775324603");
    expect((await pool.poolData(1))[1].toString()).to.equal("20011000004428773891"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("499"); // pool utilization 1 / 20.25 = 9.75%

    ///////// Liquidate
    // New price = 11435, strike price = 3432, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );
    expect(await collatToken0.balanceOf(depositor)).to.equal("0"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("0"); // 0

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("68777041628"); // amount0.mul(10) - 1.732(IL?) =  33963179042: seller lost all and LP lost 1.732 (premium!)
    expect((await pool.poolData(1))[0].toString()).to.equal("19830070001433601338"); // amount1.mul(10) - 0.450 (IL?) < 10 : seller lost all AND LP lost 0.450 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("68777041627"); // amount0.mul(10) + 1.732 (gain)
    expect((await pool.poolData(1))[1].toString()).to.equal("19830070001433601338"); // amount1.mul(10) - 0.450ETH (IL)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");

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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    // price = 4188
    expect(await usdc.balanceOf(depositor)).to.equal("99999150963846"); // lost  847USDC in collateral
    expect(await weth.balanceOf(depositor)).to.equal("999999990000000000000000"); // lost all 0.01ETH of collateral. Net = 563 + 0.01*4188 = 605USDC

    expect(await usdc.balanceOf(writor)).to.equal("100000850777363"); // gained 849 USDC
    expect(await weth.balanceOf(writor)).to.equal("999999915907878639852046"); // lost 0.084ETH. Net = 847-0.084*4188 = 495 USDC

    expect(await usdc.balanceOf(buyor)).to.equal("99999999975817"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("999999913170801323297759"); // gained 0.086ETH. Net = -360 USDC
  });

  it("should liquidate account: short put (ITM), cross-collateral, asset=1 , liquidation tick = 194310, Barely undercollateralized", async function () {
    let dTick = 198;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");
    let depositor = await deployer.getAddress();

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(4),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(100),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();
    expect(await collatToken0.balanceOf(depositor)).to.equal("849036154");
    expect(await collatToken1.balanceOf(depositor)).to.equal("10000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("862624806,679228923");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("849036154");
    expect(await collatToken1.balanceOf(depositor)).to.equal("4000000000000000"); // 0.01ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("863483807,864963727");

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 1, [shortPutTokenId])
      ).toString(),
    ).to.equal("239137179082985906,239547034862356607");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // NEW PRICE = 3610
    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("68775324603"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("19011000004428773891"); // amount1.mul(10) + amount1.div(4) - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("68775324603");
    expect((await pool.poolData(1))[1].toString()).to.equal("20011000004428773891"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("499"); // pool utilization 1 / 20.25 = 9.75%

    // depositor balance
    expect(await collatToken0.balanceOf(depositor)).to.equal("849036154"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("4000000000000000"); // 0

    ///////// Liquidate
    // New price = 3436, strike price = 3430, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );
    expect(await collatToken0.balanceOf(depositor)).to.equal("0"); // collected fees = 1.73USDC = 0.0005*3432
    expect(await collatToken1.balanceOf(depositor)).to.equal("0"); // 0

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("68777041628"); // amount0.mul(10) - 1.732(IL?) =  33963179042: seller lost all and LP lost 1.732 (premium!)
    expect((await pool.poolData(1))[0].toString()).to.equal("19961096024175314765"); // amount1.mul(10) - 0.450 (IL?) < 10 : seller lost all AND LP lost 0.450 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("68777041627"); // amount0.mul(10) + 1.732 (gain)
    expect((await pool.poolData(1))[1].toString()).to.equal("19961096024175314765"); // amount1.mul(10) - 0.450ETH (IL)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("1");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");

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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    // new price = 3611
    expect(await usdc.balanceOf(depositor)).to.equal("99999150963846"); // lost 833 USDC
    expect(await weth.balanceOf(depositor)).to.equal("999999990000000000000000"); // lost 0.01 collateral ETH (all of it) : Net = -0.27 - 0.01*3611 = 36.4 USDC

    expect(await usdc.balanceOf(writor)).to.equal("100000850766745"); // gained 834 USDC
    expect(await weth.balanceOf(writor)).to.equal("999999980088265358404484"); // lost 0.04ETH : Net = 834 - 0.04*3611 = 761USDC

    expect(await usdc.balanceOf(buyor)).to.equal("99999999986434"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("999999980009753421647452"); // gained 0.0036
  });

  it("should liquidate account: short put (ITM), cross-collateral, asset=1 , liquidation tick = 194310, almost losing funds", async function () {
    let dTick = 200;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(4),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(100),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    expect(await collatToken0.balanceOf(depositor)).to.equal("849036154");
    expect(await collatToken1.balanceOf(depositor)).to.equal("10000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("862624806,679228923");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("849036154");
    expect(await collatToken1.balanceOf(depositor)).to.equal("4000000000000000"); // 0.01ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("863496815,868214775");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // NEW PRICE = 3610
    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("68775324603"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("19011000004428773891"); // amount1.mul(10) + amount1.div(4) - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("68775324603");
    expect((await pool.poolData(1))[1].toString()).to.equal("20011000004428773891"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("499"); // pool utilization 1 / 20.25 = 9.75%

    ///////// Liquidate
    // New price = 3436, strike price = 3430, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );
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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    // new price = 3610
    //expect(await usdc.balanceOf(depositor)).to.equal("99999932516898"); // lost 67 USDC
    //expect(await weth.balanceOf(depositor)).to.equal("999999990000000000000000"); // lost 0.01 collateral ETH (all of it) : Net = -0.01 - -67/3610 = -0.025ETH = -103USDC

    expect(await usdc.balanceOf(writor)).to.equal("100000850773061"); // gained 69 USDC
    expect(await weth.balanceOf(writor)).to.equal("999999979674217416047118"); // lost 0.04ETH : Net = 69 - 0.02*3680 = 87 = 0.21ETH

    expect(await usdc.balanceOf(buyor)).to.equal("99999999980118"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("999999979580578484536644"); // lost 0.002
  });

  it("should liquidate account: short put (ITM), cross-collateral, asset=1 , liquidation tick = 194310, almost losing funds", async function () {
    let dTick = 260;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");
    let depositor = await deployer.getAddress();
    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );

    let shortPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    let writor = await optionWriter.getAddress();
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961446");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortPutTokenId], positionSize, 2000000000);

    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortPutTokenId])).toString(),
    ).to.equal("862866321,679228923");

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //
    //expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
    //  positionSize.toString()
    //);

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961446");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244000000000000000"); // 0.01ETH - 0.0006 ETH in commission fees (60bps)

    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0, [shortPutTokenId])
      ).toString(),
    ).to.equal("967049415,1077131281");

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // NEW PRICE = 3822
    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("67960249895"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("19251000004428773891"); // amount1.mul(10) + amount1.div(4) - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67960249895");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773891"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("493"); // pool utilization 1 / 20.25 = 9.75%

    ///////// Liquidate
    // New price = 3436, strike price = 3430, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    const resolvedLA = await pool
      .connect(optionWriter)
      .liquidateAccount(depositor, 0, 0, [shortPutTokenId], []);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      "0",
    );
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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    // new price = 3822
    expect(await usdc.balanceOf(depositor)).to.equal("99999966038554"); // lost 32 USDC
    expect(await weth.balanceOf(depositor)).to.equal("999999862177965829655902"); // lost 0.13 collateral ETH (all of it) : Net = -0.01 - -67/3610 = -0.025ETH = -103USDC

    expect(await usdc.balanceOf(writor)).to.equal("100000035717797"); // gained 69 USDC
    expect(await weth.balanceOf(writor)).to.equal("1000000030647596648937797"); // lost 0.02ETH : Net = 69 - 0.02*3680 = 87 = 0.21ETH

    expect(await usdc.balanceOf(buyor)).to.equal("99999999960675"); // dust?
    expect(await weth.balanceOf(buyor)).to.equal("1000000003670947204009127"); // lost 0.002
  });

  it("should liquidate account: short put (ITM), cross-collateral, multiple positions, asset=1, LONG-SHORT leg order , liquidation tick = 194310", async function () {
    let dTick = 450;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");

    expect(await weth.balanceOf(depositor)).to.equal("1000000000000000000000000");
    expect(await usdc.balanceOf(depositor)).to.equal("100000000000000");

    expect(await weth.balanceOf(writor)).to.equal("1000000000000000000000000");
    expect(await usdc.balanceOf(writor)).to.equal("100000000000000");

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );

    let shortPutTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    let shortPutTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 200,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    let shortPutTokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 50,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    let shortPutTokenId3 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961446");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId0],
        positionSize.mul(5),
        2000000000,
        0,
        0,
      );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId0],
      positionSize.div(4),
      2000000000,
      0,
      0,
    );
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId0, shortPutTokenId1],
      positionSize.div(4),
      2000000000,
      0,
      0,
    );
    console.log("shortPutTokenId2");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId0, shortPutTokenId1, shortPutTokenId2],
      positionSize.div(4),
      2000000000,
      0,
      0,
    );
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId0, shortPutTokenId1, shortPutTokenId2, shortPutTokenId3],
      positionSize.div(4),
      2000000000,
      0,
      0,
    );

    /* 
    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), tick, 0,[
          shortPutTokenId0,
          shortPutTokenId1,
          shortPutTokenId2,
          shortPutTokenId3,
        ])
      ).toString()
    ).to.equal("865595727,424518077");

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961446");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244531752523997328"); // 0.01ETH - 0.0006 ETH in commission fees (60bps)
*/
    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // NEW PRICE = 3610
    // Panoptic Pool Balance:
    /*
    expect((await pool.poolData(0))[0].toString()).to.equal("67960249895"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("15001000004428773890"); // amount1.mul(10) + amount1.div(4) - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67960249895");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773890"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("5250000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("2592"); // pool utilization 1 / 20.25 = 9.75%
     */
    ///////// Liquidate
    // New price = 3436, strike price = 3430, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    /*
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961446");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244531752523997328"); // 0.01ETH - 0.0006 ETH in commission fees (60bps)

    var slot1_ = await uniPool.slot0();

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0,[
          shortPutTokenId0,
          shortPutTokenId1,
          shortPutTokenId2,
          shortPutTokenId3,
        ])
      ).toString()
    ).to.equal("1360687303,1457623495");
*/
    //await pool["burnOptions(uint256[],int24,int24)"]([shortPutTokenId0, shortPutTokenId1, shortPutTokenId2, shortPutTokenId3],-800000, 800000);

    console.log("liquidate");
    const resolvedLA = await pool
      .connect(optionBuyer)
      .liquidateAccount(depositor, -800000, 800000, [
        shortPutTokenId0,
        shortPutTokenId1,
        shortPutTokenId3,
        shortPutTokenId2,
      ]);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId0))[0].toString()).to.equal(
      "0",
    );

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

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId0, 0, 0);
    expect(await pool.positionsHash(writor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
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
    expect(await pool.positionsHash(buyor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
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

    // new price = 3610
    // LIQUIDATEE
    expect(await usdc.balanceOf(depositor)).to.equal("99999966038554"); // lost 33U SDC -> Needs to be swapped to ETH!!
    expect(await weth.balanceOf(depositor)).to.equal("999999885689049344414152"); // lost 0.11ETH? -> net = -83USDC

    // LIQUIDATOR
    expect(await usdc.balanceOf(buyor)).to.equal("100000034414665"); // gained 34 USDC
    expect(await weth.balanceOf(buyor)).to.equal("1000000030414824364007956"); // gained 0.032  -> net = +264USDC

    // OPTION WRITER
    expect(await usdc.balanceOf(writor)).to.equal("100000008583570"); // gained 8.56 USDC
    expect(await weth.balanceOf(writor)).to.equal("999999987001538802472604"); // lost 0.012 ETH -> commission

    // PASSIVE EXTERNAL INVESTOR
    expect(await usdc.balanceOf(providor)).to.equal("99999999988411"); // gained 8.56 USDC
    expect(await weth.balanceOf(providor)).to.equal("1000000011531631899780572"); // lost 0.0959 ETH -> net = +97USDC
  });

  it("should liquidate account: short put (ITM), cross-collateral, multiple positions, asset=1, SHORT-LONG leg order, liquidation tick = 194310", async function () {
    let dTick = 450;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");

    expect(await weth.balanceOf(depositor)).to.equal("1000000000000000000000000");
    expect(await usdc.balanceOf(depositor)).to.equal("100000000000000");

    expect(await weth.balanceOf(writor)).to.equal("1000000000000000000000000");
    expect(await usdc.balanceOf(writor)).to.equal("100000000000000");

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );

    let shortPutTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    let shortPutTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 200,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    let shortPutTokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 50,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    let shortPutTokenId3 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961446");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId0],
        positionSize.mul(5),
        2000000000,
        0,
        0,
      );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId0],
      positionSize.div(4),
      2000000000,
      0,
      0,
    );
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId0, shortPutTokenId1],
      positionSize.div(4),
      2000000000,
      0,
      0,
    );
    console.log("shortPutTokenId2");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId0, shortPutTokenId1, shortPutTokenId2],
      positionSize.div(4),
      2000000000,
      0,
      0,
    );
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId0, shortPutTokenId1, shortPutTokenId2, shortPutTokenId3],
      positionSize.div(4),
      2000000000,
      0,
      0,
    );

    /* 
    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), tick, 0,[
          shortPutTokenId0,
          shortPutTokenId1,
          shortPutTokenId2,
          shortPutTokenId3,
        ])
      ).toString()
    ).to.equal("865595727,424518077");

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961446");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244531752523997328"); // 0.01ETH - 0.0006 ETH in commission fees (60bps)
*/
    ///////// SWAP
    let liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + dTick);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + dTick);

    await grantTokens(USDC_ADDRESS, await swapper.getAddress(), USDC_SLOT, amountU.mul(100));
    await grantTokens(WETH_ADDRESS, await swapper.getAddress(), WETH_SLOT, amountW.mul(100));

    let swapRouter = (await ethers.getContractAt(
      "contracts/test/ISwapRouter.sol:ISwapRouter",
      SWAP_ROUTER_ADDRESS,
    )) as ISwapRouter;

    await usdc.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);
    await weth.connect(swapper).approve(swapRouter.address, ethers.constants.MaxUint256);

    let paramsS: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountW,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let paramsB: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    let slot0_ = await uniPool.slot0();

    let pc = UniswapV3.priceFromTick(tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slot1_ = await uniPool.slot0();
    var newPrice = Math.pow(1.0001, slot1_.tick);

    ///////// check health
    //await pool.calculateAccumulatedFeesBatch(writor, [shortPutTokenId]);

    // NEW PRICE = 3610
    // Panoptic Pool Balance:
    /*
    expect((await pool.poolData(0))[0].toString()).to.equal("67960249895"); //amount0.mul(10)  +
    expect((await pool.poolData(1))[0].toString()).to.equal("15001000004428773890"); // amount1.mul(10) + amount1.div(4) - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("67960249895");
    expect((await pool.poolData(1))[1].toString()).to.equal("20251000004428773890"); // amount1.mul(10) + amount1.div(4) + dust

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("5250000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("2592"); // pool utilization 1 / 20.25 = 9.75%
     */
    ///////// Liquidate
    // New price = 3436, strike price = 3430, collateral = 0.244ETH -> loss = 0.244 - (1-3432/11435) = -0.02ETH

    let paramsU: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amountU.div(10000),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    };

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsU);
    await mineBlocks(500);

    /*
    expect(await collatToken0.balanceOf(depositor)).to.equal("33961446");
    expect(await collatToken1.balanceOf(depositor)).to.equal("244531752523997328"); // 0.01ETH - 0.0006 ETH in commission fees (60bps)

    var slot1_ = await uniPool.slot0();

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot1_.tick, 0,[
          shortPutTokenId0,
          shortPutTokenId1,
          shortPutTokenId2,
          shortPutTokenId3,
        ])
      ).toString()
    ).to.equal("1360687303,1457623495");
*/
    //await pool["burnOptions(uint256[],int24,int24)"]([shortPutTokenId0, shortPutTokenId1, shortPutTokenId2, shortPutTokenId3],-800000, 800000);

    console.log("liquidate");
    const resolvedLA = await pool
      .connect(optionBuyer)
      .liquidateAccount(depositor, -800000, 800000, [
        shortPutTokenId0,
        shortPutTokenId1,
        shortPutTokenId3,
        shortPutTokenId2,
      ]);

    const receiptLA = await resolvedLA.wait();
    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId0))[0].toString()).to.equal(
      "0",
    );

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

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId0, 0, 0);
    expect(await pool.positionsHash(writor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
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
    expect(await pool.positionsHash(buyor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );

    //expect(await collatToken0.balanceOf(buyor)).to.equal("33995892661");
    //expect(await collatToken1.balanceOf(buyor)).to.equal("10017822584491209601");

    // Panoptic Pool Balance:
    //expect((await pool.poolData(0))[0].toString()).to.equal("33999261453");
    //expect((await pool.poolData(1))[0].toString()).to.equal("10033297092935336269");

    // totalBalance: unchanged, contains balance deposited
    //expect((await pool.poolData(0))[1].toString()).to.equal("33999261451");
    //expect((await pool.poolData(1))[1].toString()).to.equal("10033297092935336268");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // locked:
    expect((await pool.poolData(0))[3].toString()).to.equal("2");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
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

    // new price = 3610
    // LIQUIDATEE
    expect(await usdc.balanceOf(depositor)).to.equal("99999966038554"); // lost 33 USDC USDC
    expect(await weth.balanceOf(depositor)).to.equal("999999885689049344414152"); // lost 0.11ETH? -> net = -83USDC

    // LIQUIDATOR
    expect(await usdc.balanceOf(buyor)).to.equal("100000034414665"); // gained 34 USDC
    expect(await weth.balanceOf(buyor)).to.equal("1000000030414824364007956"); // gained 0.032ETH  -> net = +264USDC

    // OPTION WRITOR
    expect(await usdc.balanceOf(writor)).to.equal("100000008583570"); // gained 8.56 USDC
    expect(await weth.balanceOf(writor)).to.equal("999999987001538802472604"); // lost 0.013 ETH -> commission

    // PASSIVE EXTERNAL INVESTOR
    expect(await usdc.balanceOf(providor)).to.equal("99999999988411"); // gained 8.56 USDC
    expect(await weth.balanceOf(providor)).to.equal("1000000011531631899780572"); // lost 0.012 ETH -> net = +97USDC
  });

  it("NO liquidate account, user closes: short put (ITM), cross-collateral, multiple positions, asset=1, SHORT-LONG leg order, liquidation tick = 194310", async function () {
    let dTick = 450;
    let width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    let amount0 = BigNumber.from(3396144616);
    let amount1 = ethers.utils.parseEther("1");

    let positionSize = ethers.utils.parseEther("1");

    expect(await weth.balanceOf(depositor)).to.equal("1000000000000000000000000");
    expect(await usdc.balanceOf(depositor)).to.equal("100000000000000");

    expect(await weth.balanceOf(writor)).to.equal("1000000000000000000000000");
    expect(await usdc.balanceOf(writor)).to.equal("100000000000000");

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(100),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(10),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(10),
      await optionBuyer.getAddress(),
    );

    let shortPutTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    let shortPutTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 200,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    let shortPutTokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 50,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    let shortPutTokenId3 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // deployer: liquidation at 3622
    // optionWriter: liquidation at 0

    let collatToken0 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken0(),
    )) as ERC20;
    let collatToken1 = (await ethers.getContractAt(
      "IERC20",
      await pool.collateralToken1(),
    )) as ERC20;

    expect(await collatToken0.balanceOf(depositor)).to.equal("33961446");
    expect(await collatToken1.balanceOf(depositor)).to.equal("250000000000000000");

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId0],
        positionSize.mul(5),
        2000000000,
        0,
        0,
      );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortPutTokenId0],
      positionSize.div(4),
      2000000000,
      0,
      0,
    );
    await pool["burnOptions(uint256[],int24,int24)"]([shortPutTokenId0], -800000, 800000);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId0, 0, 0);

    console.log("NO liquidate, close account");
    //await pool["burnOptions(uint256[],int24,int24)"]([shortPutTokenId0],-800000,800000);

    // Position does not exist anymore
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, shortPutTokenId0))[0].toString()).to.equal(
      "0",
    );

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

    //await swapRouter.connect(swapper).exactInputSingle(paramsS);
    //await swapRouter.connect(swapper).exactInputSingle(paramsS);

    // await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId0,0,0);
    expect(await pool.positionsHash(writor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
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
    expect(await pool.positionsHash(buyor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        optionBuyer,
      ).maxWithdraw(await optionBuyer.getAddress()),
      await optionBuyer.getAddress(),
      await optionBuyer.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidityProvider)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidityProvider,
      ).maxWithdraw(providor),
      providor,
      providor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidityProvider)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        liquidityProvider,
      ).maxWithdraw(providor),
      providor,
      providor,
    );

    // new price = 3610
    // LIQUIDATEE
    //expect(await usdc.balanceOf(depositor)).to.equal("99999966038554"); // lost 33 USDC USDC
    //expect(await weth.balanceOf(depositor)).to.equal("999999888426089172972427"); // lost 0.11ETH? -> net = -83USDC

    // LIQUIDATOR
    //expect(await usdc.balanceOf(buyor)).to.equal("100000034419163"); // gained 34 USDC
    //expect(await weth.balanceOf(buyor)).to.equal("1000000032295643769120306"); // lost 0.032ETH  -> net = +264USDC

    // OPTION WRITOR
    //expect(await usdc.balanceOf(writor)).to.equal("100000008567485"); // gained 8.56 USDC
    //expect(await weth.balanceOf(writor)).to.equal("999999904058795090115562"); // lost 0.0959 ETH -> net = +97USDC

    // PASSIVE EXTERNAL INVESTOR
    expect(await usdc.balanceOf(providor)).to.equal("100000000000000"); // gained 8.56 USDC
    expect(await weth.balanceOf(providor)).to.equal("1000000009371710572281331"); // lost 0.0959 ETH -> net = +97USDC
  });

  it("should not liquidate account: short put (NOT YET UNDERWATER)", async function () {
    const width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396144616);
    const amount1 = ethers.utils.parseEther("1");

    const positionSize = BigNumber.from(3396144616);

    // deployer only deposits 25% of required
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(4),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(4),
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
      2000000000,
      0,
      0,
    );
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize,
        2000000000,
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
    expect((await pool.poolData(1))[2].toString()).to.equal("1978913012428529302");

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 75);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 75);

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

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);

    ///////// Liquidate
    await expect(
      pool.connect(optionWriter).liquidateAccount(depositor, 0, 0, [shortPutTokenId], []),
    ).to.be.revertedWith(revertCustom("NotMarginCalled()"));

    expect((await pool.optionPositionBalance(depositor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );
  });
});
