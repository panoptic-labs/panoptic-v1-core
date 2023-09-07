/**
 * Test Minting In the Money Options.
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

describe("mint ITM", async function () {
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

  it("should allow to mint 1-leg short put ETH option that is ITM", async function () {
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

    const shortOtmPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 1100,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseUnits("10000", "6").toString(),
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("10").toString(),
    );

    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOtmPutTokenId],
      positionSize,
      0,
      0,
      0,
    );
    const receipt = await resolved.wait();

    // Amount of receipt token for user: less because user paid for commission = 6bps
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "9994000000000000001", // commission fee = 60bps
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("610003396129"); // 500_000+100_000+10_000
    expect((await pool.poolData(1))[0].toString()).to.equal("609001000004428773903"); // 500+100+10 ETH - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("610003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("610001000004428773903");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[4].toString()).to.equal("16"); // 1 / 61 = 0.16%

    await pool["burnOptions(uint256,int24,int24)"](shortOtmPutTokenId, 0, 0);

    // user balance: unchanged, did not pay swapFee
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "9994000000000000001", // commission fee = 0.006 ETH
    );

    //////////
    // MINT ITM
    //////////

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
      0,
      0,
    );

    const slot0_ = await uniPool.slot0();

    const pc = UniswapV3.priceFromTick(tick);

    const ps = UniswapV3.priceFromTick(strike + 1100);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("610003396129"); // 500_000+100_000+10_000
    expect((await pool.poolData(1))[0].toString()).to.equal("609104165441867311393"); // 500+100 ETH + 1 - 0.8968345626 (=3044/3396) ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("610003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("610104165441867311393");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[4].toString()).to.equal("16"); // 1 / 61 = 0.16%

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000"); // 10000 - swapFee?
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10090251377613898145", // balance + (1 - 3044/currentPrice) - commission*2 (receive amount not deposited in AMM)
    );

    await pool["burnOptions(uint256,int24,int24)"](shortItmPutTokenId, 0, 0);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("610003396129"); // 500_000+100_000+10_000
    expect((await pool.poolData(1))[0].toString()).to.equal("610000103394371469862"); // 500+100 ETH + 1 - swapFees (0.89ETH * 5bps * 2) ETH // MINTER MUST PAY!

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("610003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("610000103394371469862");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); // 1 / 61 = 0.16%

    // user balance
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000"); // 10_000
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "9987069852690746218", //
    );

    expect((await collatToken0.balanceOf(writor)).toString()).to.equal("100000000000"); // 100_000?
    expect((await collatToken1.balanceOf(writor)).toString()).to.equal("100000000000000000000"); // 10ETH?

    expect((await collatToken0.balanceOf(providor)).toString()).to.equal("500000000000"); // 10_000 - swapFee?
    expect((await collatToken1.balanceOf(providor)).toString()).to.equal("500000000000000000000"); // 10_000 - swapFee?

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

    expect((await usdc.balanceOf(depositor)).toString()).to.equal("100000000000000");
    expect((await weth.balanceOf(depositor)).toString()).to.equal("999999987266872572033943");

    expect((await usdc.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "100000000000000",
    );
    expect((await weth.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "1000000001972749607179764",
    );

    expect((await usdc.balanceOf(liquidityProvider.getAddress())).toString()).to.equal(
      "100000000000000",
    );
    expect((await weth.balanceOf(liquidityProvider.getAddress())).toString()).to.equal(
      "1000000009863748035898823",
    ); // combined gains = 0.0152
  });

  it("should allow to mint single 1-leg short put ETH option that is ITM", async function () {
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

    const shortOtmPutTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 1100,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseUnits("10000", "6").toString(),
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("10").toString(),
    );

    // user balance: unchanged, did not pay swapFee
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10000000000000000000", //
    );

    //////////
    // MINT ITM
    //////////

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
      0,
      0,
    );

    const slot0_ = await uniPool.slot0();

    const pc = UniswapV3.priceFromTick(tick);

    const ps = UniswapV3.priceFromTick(strike + 1100);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("610003396129"); // 500_000+100_000+10_000
    expect((await pool.poolData(1))[0].toString()).to.equal("609104165441867311394"); // 500+100 ETH + 1 - 0.8968345626 (=3044/3396) ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("610003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("610104165441867311394");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[4].toString()).to.equal("16"); // 1 / 61 = 0.16%

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000"); // 10000
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10096252324356520098", // TODO: check.  balance - 3044/currentPrice - commission (bought 0.89 ETH)
    );

    await pool["burnOptions(uint256,int24,int24)"](shortItmPutTokenId, 0, 0);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("610003396129"); // 500_000+100_000+10_000
    expect((await pool.poolData(1))[0].toString()).to.equal("610000103394371469863"); // 500+100+10 ETH  - swapFees (0.89ETH * 5bps * 2) ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("610003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("610000103394371469863");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); //
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); // 1 / 61 = 0.16%

    // user balance
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000"); // 10_000
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "9993069784524804110", //
    );

    expect((await collatToken0.balanceOf(writor)).toString()).to.equal("100000000000"); //
    expect((await collatToken1.balanceOf(writor)).toString()).to.equal("100000000000000000000"); //

    expect((await collatToken0.balanceOf(providor)).toString()).to.equal("500000000000"); //
    expect((await collatToken1.balanceOf(providor)).toString()).to.equal("500000000000000000000"); //

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

    expect((await usdc.balanceOf(depositor)).toString()).to.equal("100000000000000"); // 100_000_000
    expect((await weth.balanceOf(depositor)).toString()).to.equal("999999993168628502113825"); //

    expect((await usdc.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "100000000000000",
    );
    expect((await weth.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "1000000000989125258214293",
    );

    expect((await usdc.balanceOf(liquidityProvider.getAddress())).toString()).to.equal(
      "100000000000000",
    );
    expect((await weth.balanceOf(liquidityProvider.getAddress())).toString()).to.equal(
      "1000000004945626291071464",
    ); // combined gains = 0.009375494072
  });

  it("should allow to mint 1-leg short call USDC option that is ITM", async function () {
    const width = 4;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(33960e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize1 = BigNumber.from(3044e6);
    const positionSize2 = BigNumber.from(3791e6);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    const shortOtmCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 1100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseUnits("33960", "6").toString(),
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("10").toString(),
    );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOtmCallTokenId],
      positionSize1,
      0,
      0,
      0,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33941736000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10000000000000000000", // commission fee
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("3044000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await pool.poolData(0))[1].toString()).to.equal("33963396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("10001000004428773891");

    await pool["burnOptions(uint256,int24,int24)"](shortOtmCallTokenId, 0, 0);

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await pool.poolData(0))[1].toString()).to.equal("33963396128");
    expect((await pool.poolData(1))[1].toString()).to.equal("10001000004428773891");

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33941736000"); // commission fee
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const shortItmCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const slot0_ = await uniPool.slot0();

    const pc = UniswapV3.priceFromTick(tick);

    const ps = UniswapV3.priceFromTick(strike + 1100);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortItmCallTokenId],
      positionSize2,
      0,
      0,
      0,
    );

    expect((await pool.poolData(0))[1].toString()).to.equal("34358633031");
    expect((await pool.poolData(1))[1].toString()).to.equal("10001000004428773891");

    expect((await pool.poolData(0))[2].toString()).to.equal("3791000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("0"); // amount swapped to deposit 3044 Dai at 3044 strike

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      "34306763673", // balance - 3044/currentPrice TODO:
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10000000000000000000", // TODO: check this
    );
    await pool["burnOptions(uint256,int24,int24)"](shortItmCallTokenId, 0, 0);

    expect((await pool.poolData(0))[1].toString()).to.equal("33960001216"); // This misses the swap fees exactly
    expect((await pool.poolData(1))[1].toString()).to.equal("10001000004428773891");

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33907448947"); //
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10000000000000000000", // TODO: check! Shares are lower, amount of asset is the same
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

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("0");
  });

  it("should allow to mint 1-leg short call USDC option that is ATM", async function () {
    const width = 100;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(33960e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize1 = BigNumber.from(3044e6);
    const positionSize2 = BigNumber.from(3791e6);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0,
      buyor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1,
      buyor,
    );

    const shortAtmCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseUnits("33960", "6").toString(),
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("10").toString(),
    );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortAtmCallTokenId],
      positionSize1,
      0,
      0,
      0,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33976925266");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10000000000000000000", // commission fee
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("3044000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await pool.poolData(0))[1].toString()).to.equal("67961600710");
    expect((await pool.poolData(1))[1].toString()).to.equal("20001000004428773891");

    await pool["burnOptions(uint256,int24,int24)"](shortAtmCallTokenId, 0, 0);

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await pool.poolData(0))[1].toString()).to.equal("67921875211");
    expect((await pool.poolData(1))[1].toString()).to.equal("20001000004428773891");

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33940194069"); // commission fee
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const longAtmCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const slot0_ = await uniPool.slot0();

    const pc = UniswapV3.priceFromTick(tick);

    const ps = UniswapV3.priceFromTick(strike + 1100);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortAtmCallTokenId],
      positionSize1,
      0,
      0,
      0,
    );

    expect((await pool.poolData(0))[1].toString()).to.equal("67960079790");
    expect((await pool.poolData(1))[1].toString()).to.equal("20001000004428773891");

    expect((await pool.poolData(0))[2].toString()).to.equal("3044000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    await pool
      .connect(optionBuyer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longAtmCallTokenId],
        positionSize2.div(5),
        14246409150,
        0,
        0,
      );

    expect((await pool.poolData(0))[1].toString()).to.equal("67950185188");
    expect((await pool.poolData(1))[1].toString()).to.equal("20001000004428773891");

    expect((await pool.poolData(0))[2].toString()).to.equal("2285800000");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      "33957114776", // balance - 3044/currentPrice TODO:
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10000000000000000000", // TODO: check this
    );
    await pool.connect(optionBuyer)["burnOptions(uint256,int24,int24)"](longAtmCallTokenId, 0, 0);
    await pool["burnOptions(uint256,int24,int24)"](shortAtmCallTokenId, 0, 0);

    expect((await pool.poolData(0))[1].toString()).to.equal("67919975463");
    expect((await pool.poolData(1))[1].toString()).to.equal("20001000005834714781");

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33920395530"); //
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10000000001891627636", //
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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).maxWithdraw(
        await optionBuyer.getAddress(),
      ),
      buyor,
      buyor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).maxWithdraw(
        await optionBuyer.getAddress(),
      ),
      buyor,
      buyor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("0");

    expect((await collatToken0.balanceOf(buyor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(buyor)).toString()).to.equal("0");
  });

  it.only("ITM swap shenenigans", async function () {
    const width = 2;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(33960e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize1 = BigNumber.from(3044e6);
    const positionSize2 = BigNumber.from(3791e6);
    const positionSizeDust = BigNumber.from(289956333);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0,
      buyor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1,
      buyor,
    );

    console.log("1 otm leg");

    let shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);

    console.log("");

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    console.log("1 itm leg");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);

    console.log("");

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 1000,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    console.log("");
    console.log("short itm call, short itm put");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);

    console.log("");
    console.log("otm");

    const OTMTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 100,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 100,
        long: false,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: false,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);

    await pool
      .connect(optionBuyer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [OTMTokenId],
        positionSize1.mul(5),
        0,
        0,
        0,
      );

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 100,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    console.log("short itm call, long otm put");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    console.log("");
    console.log("short itm call, long otm call");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 1000,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: true,
        tokenType: 0,
        riskPartner: 2,
      },
    ]);

    console.log("");
    console.log("short itm call, short itm put, long otm call");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 1000,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: true,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 100,
        long: true,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);

    console.log("");
    console.log("short itm call, short itm put, long otm call, long otm put");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 1000,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 100,
        long: false,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);

    console.log("");
    console.log("short itm call, short itm put, short otm call, short otm put");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 1000,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 100,
        long: false,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: false,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33827297268"); // commission fee
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("9944835025593774416");

    console.log("");
    console.log("short itm call, short itm put, short otm call, short otm put");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33497099066"); // commission fee
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10229690264025360627");

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33817595664"); // commission fee
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("9934333330490539806");

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 1000,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 100,
        long: true,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: true,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);

    console.log("");
    console.log("short itm call, short itm put, long itm call, long itm put");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    console.log("burn");
    await pool["burnOptions(uint256,int24,int24)"](shortOTMCallTokenId, 0, 0);

    shortOTMCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: true,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 100,
        long: true,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);

    console.log("");
    console.log("BOX spread?");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortOTMCallTokenId],
      positionSize1,
      1023332224441,
      0,
      0,
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await pool.poolData(0))[1].toString()).to.equal("67921875211");
    expect((await pool.poolData(1))[1].toString()).to.equal("20001000004428773891");

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33940194069"); // commission fee
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const longAtmCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const slot0_ = await uniPool.slot0();

    const pc = UniswapV3.priceFromTick(tick);

    const ps = UniswapV3.priceFromTick(strike + 1100);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortAtmCallTokenId],
      positionSize1,
      0,
      0,
      0,
    );

    expect((await pool.poolData(0))[1].toString()).to.equal("67960079790");
    expect((await pool.poolData(1))[1].toString()).to.equal("20001000004428773891");

    expect((await pool.poolData(0))[2].toString()).to.equal("3044000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    await pool
      .connect(optionBuyer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longAtmCallTokenId],
        positionSize2.div(5),
        14246409150,
        0,
        0,
      );

    expect((await pool.poolData(0))[1].toString()).to.equal("67950185188");
    expect((await pool.poolData(1))[1].toString()).to.equal("20001000004428773891");

    expect((await pool.poolData(0))[2].toString()).to.equal("2285800000");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      "33957114776", // balance - 3044/currentPrice TODO:
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10000000000000000000", // TODO: check this
    );
    await pool.connect(optionBuyer)["burnOptions(uint256,int24,int24)"](longAtmCallTokenId, 0, 0);
    await pool["burnOptions(uint256,int24,int24)"](shortAtmCallTokenId, 0, 0);

    expect((await pool.poolData(0))[1].toString()).to.equal("67919975463");
    expect((await pool.poolData(1))[1].toString()).to.equal("20001000005834714781");

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("33920395530"); //
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "10000000001891627636", //
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

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).maxWithdraw(
        await optionBuyer.getAddress(),
      ),
      buyor,
      buyor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).maxWithdraw(
        await optionBuyer.getAddress(),
      ),
      buyor,
      buyor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("0");

    expect((await collatToken0.balanceOf(buyor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(buyor)).toString()).to.equal("0");
  });
});
