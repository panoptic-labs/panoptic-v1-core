/**
 * Test Swapping and Fees.
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

describe("Swapping and fees", async function () {
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

  it("should burn put with minimum range factor then collect fee ", async function () {
    const init_balance = await usdc.balanceOf(depositor);

    ///////// MINT OPTION
    const width = 2;
    let strike = tick - 100;
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

    // mint #1
    let resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );
    let receipt = await resolved.wait();
    let gas = receipt.gasUsed;

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("339603396129"); // 339600 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("99011585631650591018");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("339603396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("100001000004428773899");

    // in AMM: about 0.997 ETH
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989414372778182881");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); // 339600 USDC deposited,  moved  = 12.06% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("98"); // 100 ETH deposited, 0.895 ETH moved = 0.00895 (rounded down)

    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[0].toString(),
    ).to.equal("0");
    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[1].toString(),
    ).to.equal("0");

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    const pa = UniswapV3.priceFromTick(tick);
    //console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pa);
    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 350);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 350);

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

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

    ///////// BURN OPTIONS

    // 1.69 USDC
    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[0].toString(),
    ).to.equal("1698848");
    // 0.0005ETH
    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[1].toString(),
    ).to.equal("494954663720951");

    // Second user mints the same position, touches+collect fees
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    //console.log('MINT-TOUCH');
    // Create a second identical position to collect the accumulated fees
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"]([tokenId], positionSize, 20000, 0, 0);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("3735605094978"); // 3396000 + 339600 + collected fees
    expect((await pool.poolData(1))[0].toString()).to.equal("1098022666213536129096");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("3735603396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100001000004428773907");

    // in AMM: about 2x 1ETH
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1978828745556365762");

    // totalCollected: 1.69 USDC and 0.005ETH
    expect((await pool.poolData(0))[3].toString()).to.equal("1698849");
    expect((await pool.poolData(1))[3].toString()).to.equal("494954663720951");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); // 339600 USDC deposited,  moved  = 12.06% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("17"); // 1100 ETH deposited, 2*0.997 ETH moved = 0.0018 (rounded down)

    //console.log("BURN");
    //
    // burn #2
    resolved = await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
    receipt = await resolved.wait();
    gas = gas.add(receipt.gasUsed);
    //console.log(" Gas used = " + gas.toNumber());

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("3735605094978"); // 3396000 + 339600 + collected fees
    expect((await pool.poolData(1))[0].toString()).to.equal("1099012080586314311968");

    // totalBalance: contains collected fees
    expect((await pool.poolData(0))[1].toString()).to.equal("3735605094977");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100001494959092494848");

    // in AMM: about 9.97 ETH
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989414372778182881");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("1");
    expect((await pool.poolData(1))[3].toString()).to.equal("1");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("8"); // 1100 ETH deposited, 2*0.997 ETH moved = 0.0018 (rounded down)

    //
    // swap again to collect fees
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    //
    // burn from optionWriter
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("3735606793827"); // 3396000 + 339600 + 2x collected fees
    expect((await pool.poolData(1))[0].toString()).to.equal("1100001989913756215791");

    // totalBalance: contains collected fees
    expect((await pool.poolData(0))[1].toString()).to.equal("3735606793825");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100001989913756215789");

    // in AMM: about 9.97 ETH
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("2");
    expect((await pool.poolData(1))[3].toString()).to.equal("2");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");
  });

  it("should burn long put with minimum range factor then collect fee ", async function () {
    const init_balance = await usdc.balanceOf(depositor);

    ///////// MINT OPTION
    const width = 2;
    let strike = tick - 100;
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

    // mint #1
    console.log("mint1");
    let resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );
    let receipt = await resolved.wait();
    let gas = receipt.gasUsed;

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("339603396129"); // 339600 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("99011585631650591018");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("339603396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("100001000004428773899");

    // in AMM: about 0.997 ETH
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("989414372778182881");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); // 339600 USDC deposited,  moved  = 12.06% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("98"); // 100 ETH deposited, 0.895 ETH moved = 0.00895 (rounded down)

    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[0].toString(),
    ).to.equal("0");
    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[1].toString(),
    ).to.equal("0");

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    const pa = UniswapV3.priceFromTick(tick);
    //console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pa);
    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 350);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 350);

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

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

    ///////// BURN OPTIONS

    console.log("fees1");
    // 1.69 USDC
    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[0].toString(),
    ).to.equal("1698848");
    // 0.0005ETH
    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[1].toString(),
    ).to.equal("494954663720951");

    // Second user mints the same position, touches+collect fees
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress(),
    );

    const longtokenId = OptionEncoding.encodeID(poolId, [
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

    const SFPMdeployment = await deployments.get(SFPMDeploymentName);

    const sfpm = (await ethers.getContractAt(
      SFPMContractName,
      SFPMdeployment.address,
    )) as SemiFungiblePositionManager;

    //expect((await sfpm.getAccountActivity(pool.univ3pool(), pool.address, 1, strike - width*5, strike + width*5, slot1_.tick)).toString()).to.equal("540604750,157503605280186278");

    console.log("MINT-TOUCH");
    // Create a second identical position to collect the accumulated fees
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longtokenId],
        positionSize.mul(10).div(100),
        20000000000,
        0,
        0,
      );

    //expect((await sfpm.getAccountActivity(pool.univ3pool(), pool.address, 1, strike - width*5, strike + width*5, slot1_.tick)).toString()).to.equal("609014610,177434617059468749");

    // Panoptic Pool Balance:
    //expect((await pool.poolData(0))[0].toString()).to.equal("3735605094978"); // 3396000 + 339600 + collected fees
    //expect((await pool.poolData(1))[0].toString()).to.equal("1099111022023592130249");

    // totalBalance: unchanged, contains balance deposited
    //expect((await pool.poolData(0))[1].toString()).to.equal("3735603396129");
    //expect((await pool.poolData(1))[1].toString()).to.equal("1100001000004428773891");

    // in AMM: about 2x 1ETH
    //expect((await pool.poolData(0))[2].toString()).to.equal("0");
    //expect((await pool.poolData(1))[2].toString()).to.equal("890472935500364593");

    // totalCollected: 1.69 USDC and 0.005ETH
    //expect((await pool.poolData(0))[3].toString()).to.equal("1698849");
    //expect((await pool.poolData(1))[3].toString()).to.equal("494954663720951");

    // poolUtilization:
    //expect((await pool.poolData(0))[4].toString()).to.equal("0"); // 339600 USDC deposited,  moved  = 12.06% (rounded down)
    //expect((await pool.poolData(1))[4].toString()).to.equal("8"); // 1100 ETH deposited, 2*0.997 ETH moved = 0.0018 (rounded down)

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot2_ = await uniPool.slot0();

    //await expect((await sfpm.getAccountLiquidity(pool.univ3pool(), pool.address, 1, strike - width*5, strike + width*5)).toString()).to.equal("5796884454490613,52171960090415521");

    // Second user mints the same position, touches+collect fees
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    await pool
      .connect(liquidityProvider)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longtokenId],
        positionSize.mul(20).div(100),
        20000000000,
        0,
        0,
      );

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    //await expect((await sfpm.getAccountActivity(pool.univ3pool(), pool.address, 1, strike - width*5, strike + width*5, slot2_.tick)).toString()).to.equal("1823037901,531136758650330045");

    //await swapRouter.connect(swapper).exactInputSingle(paramsS);
    //await swapRouter.connect(swapper).exactInputSingle(paramsB);
    //await swapRouter.connect(swapper).exactInputSingle(paramsB);
    //:await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot3_ = await uniPool.slot0();

    // burn from optionWriter
    //await expect((await sfpm.getAccountActivity(pool.univ3pool(), pool.address, 1, strike - width*5, strike + width*5, slot3_.tick)).toString()).to.equal("2378168481,692872353322752056");
    console.log("");
    console.log("optionWriter BURN long");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](longtokenId, 0, 0);

    //await expect((await sfpm.getAccountActivity(pool.univ3pool(), pool.address, 1, strike - width*5, strike + width*5, slot3_.tick)).toString()).to.equal("2310098236,673040397469908654");
    //
    // burn from optionWriter
    //console.log('liquidityPrivider');
    //await pool.connect(liquidityProvider)["burnOptions(uint256,int24,int24)"](longtokenId);
    //await expect((await sfpm.getAccountActivity(pool.univ3pool(), pool.address, 1, strike - width*5, strike + width*5, slot3_.tick)).toString()).to.equal("2310098236,673040397469908654");

    // Panoptic Pool Balance:
    //expect((await pool.poolData(0))[0].toString()).to.equal("7131609551189"); // 3396000 + 339600 + 2x collected fees
    //expect((await pool.poolData(1))[0].toString()).to.equal("2099013378890470721328");

    // totalBalance: contains collected fees
    //expect((await pool.poolData(0))[1].toString()).to.equal("7131602743827");
    //expect((await pool.poolData(1))[1].toString()).to.equal("2100000809957996223002");

    // in AMM: about 9.97 ETH
    //expect((await pool.poolData(0))[2].toString()).to.equal("0");
    //expect((await pool.poolData(1))[2].toString()).to.equal("989414372778182881");

    // totalCollected
    //expect((await pool.poolData(0))[3].toString()).to.equal("6807362");
    //expect((await pool.poolData(1))[3].toString()).to.equal("1983305252681207");

    // poolUtilization:
    //expect((await pool.poolData(0))[4].toString()).to.equal("0");
    //expect((await pool.poolData(1))[4].toString()).to.equal("4");

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    await pool.connect(liquidityProvider)["burnOptions(uint256,int24,int24)"](longtokenId, 0, 0);

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    console.log("");
    console.log("deployer BURN");
    await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);
    //await expect((await sfpm.getAccountActivity(pool.univ3pool(), pool.address, 1, strike - width*5, strike + width*5, slot3_.tick)).toString()).to.equal("2310098236,673040397469908654");

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("37695610871064"); // 3396000 + 339600 + 2x collected fees
    expect((await pool.poolData(1))[0].toString()).to.equal("11100003177804949146073");

    // totalBalance: contains collected fees
    //expect((await pool.poolData(0))[1].toString()).to.equal("7131609551189");
    //expect((await pool.poolData(1))[1].toString()).to.equal("2100002793263248904200");

    // in AMM
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");
  });

  it("burn option with collected fees stored in s_positionsHash", async function () {
    const init_balance = await usdc.balanceOf(depositor);

    ///////// MINT OPTION
    const width = 2;
    let strike = tick - 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(339600e6);
    const amount1 = ethers.utils.parseEther("100");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.mul(10),
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.mul(10),
      depositor,
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

    // mint #1
    console.log("mint1");
    let resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      20000,
      0,
      0,
    );
    let receipt = await resolved.wait();
    let gas = receipt.gasUsed;

    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[0].toString(),
    ).to.equal("0");
    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[1].toString(),
    ).to.equal("0");

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    const pa = UniswapV3.priceFromTick(tick);
    //console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pa);
    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 350);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 350);

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

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

    ///////// BURN OPTIONS

    // Second user mints the same position, touches+collect fees
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress(),
    );

    const longtokenId = OptionEncoding.encodeID(poolId, [
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

    const SFPMdeployment = await deployments.get(SFPMDeploymentName);

    const sfpm = (await ethers.getContractAt(
      SFPMContractName,
      SFPMdeployment.address,
    )) as SemiFungiblePositionManager;

    // Second user mints the same position, touches+collect fees
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    console.log("MINT-TOUCH");
    // Create a second identical position to collect the accumulated fees
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longtokenId],
        positionSize.mul(999).div(1000),
        10038654705667,
        0,
        0,
      );

    await pool
      .connect(liquidityProvider)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize.mul(1).div(100),
        20000000000,
        0,
        0,
      );

    const slot2_ = await uniPool.slot0();

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot3_ = await uniPool.slot0();

    console.log("");
    console.log("optionWriter BURN short");

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    // 1.69 USDC
    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[0].toString(),
    ).to.equal("103873353");
    // 0.0005ETH
    expect(
      (await pool.calculateAccumulatedFeesBatch(deployer.getAddress(), [tokenId]))[1].toString(),
    ).to.equal("30263097426850004");

    // 1.69 USDC
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(optionWriter.getAddress(), [longtokenId])
      )[0].toString(),
    ).to.equal("-104818649");
    // 0.0005ETH
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(optionWriter.getAddress(), [longtokenId])
      )[1].toString(),
    ).to.equal("-30538505894613850");

    // 1.69 USDC
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(liquidityProvider.getAddress(), [tokenId])
      )[0].toString(),
    ).to.equal("1038733");
    // 0.0005ETH
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(liquidityProvider.getAddress(), [tokenId])
      )[1].toString(),
    ).to.equal("302630974268499");

    console.log("");
    console.log("provider BURN");

    await pool.connect(liquidityProvider)["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](longtokenId, 0, 0);

    await pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("40752003489565"); // 3396000 + 339600 + 2x collected fees
    expect((await pool.poolData(1))[0].toString()).to.equal("12000001027226935278540");

    // totalBalance: contains collected fees
    expect((await pool.poolData(0))[1].toString()).to.equal("40752002544279");
    expect((await pool.poolData(1))[1].toString()).to.equal("12000000751818467514694");

    // in AMM
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("945286");
    expect((await pool.poolData(1))[3].toString()).to.equal("275408467763846");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");
  });

  it("should mint short call with minimum width and collect fees ", async function () {
    const init_balance = await weth.balanceOf(depositor);

    // console.log("init  balance", init_balance.toString());

    ///////// MINT OPTION
    const width = 1;
    let strike = tick + 20;
    strike = strike - (strike % 10) - 5;

    // console.log(
    //   "init usdc balance=",
    //   (await usdc.balanceOf(depositor)).toString()
    // );

    const amount0 = BigNumber.from(339600e6);
    const amount1 = ethers.utils.parseEther("100");

    const positionSize = BigNumber.from(3396e6);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    const writor = await optionWriter.getAddress();

    const shortCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 6,
        asset: 0,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortCallTokenId], 0, 20000, 0, 0),
    ).to.be.reverted;
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortCallTokenId],
        positionSize,
        20000,
        0,
        0,
      );

    expect((await pool.optionPositionBalance(writor, shortCallTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );
    //expect((await pool.options(writor, shortPutTokenId, 0)).baseLiquidity.toString()).to.equal(
    //  "0"
    //);

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 20);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 20);

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

    for (let i = 0; i < 10; i++) {
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
    }

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);
    // console.log("new tick", slot1_.tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    const slot2_ = await uniPool.slot0();
    const newPrice2 = Math.pow(1.0001, slot2_.tick);
    // console.log("new price 2 =", 10 ** (decimalWETH - decimalUSDC) / newPrice2);
    // console.log("new tick 2", slot2_.tick);

    ///////// BURN OPTIONS

    // console.log(
    //  "beforeBurn: writor collateralToken0 balance",
    //  (await collatToken0.balanceOf(writor)).toString()
    //);
    // console.log(
    //  "beforeBurn: writor collateralToken1 balance",
    //  (await collatToken1.balanceOf(writor)).toString()
    //);

    const resolved = await pool
      .connect(optionWriter)
      ["burnOptions(uint256,int24,int24)"](shortCallTokenId, 0, 0);
    const receipt = await resolved.wait();
    //console.log("Gas used = ", receipt.gasUsed.toNumber());
  });

  it("should not mint long call with liquidity deposited as short put ", async function () {
    ///////// MINT OPTION
    const width = 2;
    let strike = tick;
    strike = strike - (strike % 10);

    console.log("start tick", tick);
    const amount0 = BigNumber.from(339600e6);
    const amount1 = ethers.utils.parseEther("100");

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
    ).deposit(amount0.mul(90), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(90), await liquidityProvider.getAddress());

    const shortPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 6,
        asset: 1,
        strike: strike - 30,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize,
        20000,
        0,
        0,
      );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 50);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 50);

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

    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    for (let i = 0; i < 10; i++) {
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
    }
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);

    ///////// MINT OPTIONS

    const longCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 30,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longCallTokenId],
        positionSize.div(10),
        1000000,
        0,
        0,
      ),
    ).to.be.revertedWith(revertCustom("NotEnoughLiquidity()"));

    const longPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 30,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log(strike - 30);
    console.log(slot1_.tick);
    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longPutTokenId],
        positionSize.div(10),
        1000000,
        195000,
        195016,
      ),
    ).to.be.revertedWith(revertCustom("PriceBoundFail()"));

    console.log("here?");
    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longPutTokenId],
        positionSize.div(10),
        10,
        0,
        0,
      ),
    ).to.be.reverted;

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longPutTokenId],
      positionSize.div(10),
      72796058,
      194900,
      195000,
    );
  });
});
