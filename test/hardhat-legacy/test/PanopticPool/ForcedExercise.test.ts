/**
 * Test Forced Exercise.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { deployments, ethers, network, mine } from "hardhat";
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

import { BigNumber, Signer, Typed } from "ethers";
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

describe("forced exercise", async function () {
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

  it("should allow to force exercise 1 leg long OTM put ETH option 0 ", async function () {
    const width = 10;
    let strike = tick - 1100;
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
        ratio: 2,
        asset: 0,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        0,
        20000,
        -800000,
        800000,
      ),
    ).to.be.revertedWith(revertCustom("OptionsBalanceZero()"));
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize.mul(5),
        20000,
        0,
        0,
      );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.mul(5).toString(),
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("8952636224408034954");

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

    const resolved = await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longPutTokenId],
        positionSize,
        20000000000,
        0,
        0,
      );
    const receipt = await resolved.wait();
    // console.log("Gas used = " + receipt.gasUsed.toNumber());

    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("8057372601967231459");
    //expect((await pool.options(depositor, longPutTokenId, 0)).baseLiquidity.toString()).to.equal("18966480458");

    await expect(
      pool
        .connect(optionWriter)
        .forceExercise(depositor, strike - 100000, strike + 100000, [shortPutTokenId]),
    ).to.be.revertedWith(revertCustom("NoLegsExercisable()")); // cannot force exercise short options

    const longPutTokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 3,
        asset: 0,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        .forceExercise(depositor, strike - 100000, strike + 100000, [longPutTokenId2]),
    ).to.be.revertedWith(revertCustom("OptionsBalanceZero()")); // depositor does not own option

    await expect(pool.connect(optionWriter).forceExercise(depositor, 0, 0, [])).to.be.revertedWith(
      revertCustom("InputListFail()"),
    ); // no positionId

    const resolvedFE = await pool
      .connect(optionWriter)
      .forceExercise(depositor, -700000, 700000, [longPutTokenId]);

    const receiptFE = await resolvedFE.wait();
    // console.log("Gas used = " + receiptFE.gasUsed.toNumber());
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // writor/liquidator balance
    expect((await collatToken0.balanceOf(writor)).toString()).to.equal("3396000000000"); // 33960000
    expect((await collatToken1.balanceOf(writor)).toString()).to.equal("999945304630170661795"); // 1_000 -0.05917 ETH -> Cost to force exercise option = 60bps

    // depositor/liquidatee balance: gets bonus
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("339600000000"); // 33960
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "99995607999316450598", // 100 +0.000089ETH : bonus to the user = 1/1024 * 0.89 - commission?
    );

    // LP balance: stays same
    expect((await collatToken0.balanceOf(providor)).toString()).to.equal("30564000000000"); // 3396*9
    expect((await collatToken1.balanceOf(providor)).toString()).to.equal("9000000000000000000000");

    // option does not exist
    await expect(
      pool["burnOptions(uint256,int24,int24)"](longPutTokenId, -800000, 800000),
    ).to.be.revertedWith(revertCustom("OptionsBalanceZero()"));

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      await deployer.getAddress(),
      await deployer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      await deployer.getAddress(),
      await deployer.getAddress(),
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

    expect(await usdc.balanceOf(depositor)).to.equal("100000000000000"); //
    expect(await weth.balanceOf(depositor)).to.equal("999999996193000457113221"); // gained 0.000669 ETH (net positive)

    expect(await usdc.balanceOf(writor)).to.equal("100000000000000"); //
    expect(await weth.balanceOf(writor)).to.equal("999999951154578538522941"); // lost 0.0488 ETH (61bps of 0.89ETH)

    expect(await usdc.balanceOf(providor)).to.equal("100000000000000"); //
    expect(await weth.balanceOf(providor)).to.equal("1000000052652415154069576"); // gained 0.052ETH (60bps paid as commission)
  });

  it("should allow to force exercise 1 leg long OTM put ETH option 0, close to ATM ", async function () {
    const width = 2;
    let strike = tick - 30;
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
        ratio: 2,
        asset: 0,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        0,
        20000,
        -800000,
        800000,
      ),
    ).to.be.revertedWith("OptionsBalanceZero()");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize.mul(5),
        20000,
        0,
        0,
      );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.mul(5).toString(),
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("9963642219961143086");

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

    const resolved = await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longPutTokenId],
        positionSize,
        20000000000,
        0,
        0,
      );
    const receipt = await resolved.wait();
    // console.log("Gas used = " + receipt.gasUsed.toNumber());

    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("8967277997965028778");
    //expect((await pool.options(depositor, longPutTokenId, 0)).baseLiquidity.toString()).to.equal("18966480458");

    await expect(pool.connect(optionWriter).forceExercise(depositor, 0, 0, [])).to.be.revertedWith(
      revertCustom("InputListFail()"),
    ); // no positionId

    const resolvedFE = await pool
      .connect(optionWriter)
      .forceExercise(depositor, -800000, 800000, [longPutTokenId]);

    const receiptFE = await resolvedFE.wait();
    // console.log("Gas used = " + receiptFE.gasUsed.toNumber());
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // writor/liquidator balance
    expect((await collatToken0.balanceOf(writor)).toString()).to.equal("3396000000000"); // 33960000
    expect((await collatToken1.balanceOf(writor)).toString()).to.equal("999936039904166463941"); // 1_000 -0.0689 ETH

    // depositor/liquidatee balance: gets bonus
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("339600000000"); // 33960
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "99998200092566640363", // 100 +0.0000938ETH =
    );

    // LP balance: stays same
    expect((await collatToken0.balanceOf(providor)).toString()).to.equal("30564000000000"); // 3396*9
    expect((await collatToken1.balanceOf(providor)).toString()).to.equal("9000000000000000000000");

    // option does not exist
    await expect(
      pool["burnOptions(uint256,int24,int24)"](longPutTokenId, -800000, 800000),
    ).to.be.revertedWith(revertCustom("OptionsBalanceZero()"));

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      await deployer.getAddress(),
      await deployer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      await deployer.getAddress(),
      await deployer.getAddress(),
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

    expect(await usdc.balanceOf(depositor)).to.equal("100000000000000"); //
    expect(await weth.balanceOf(depositor)).to.equal("999999998851174163552673"); // gained 0.000074 ETH (net positive)

    expect(await usdc.balanceOf(writor)).to.equal("100000000000000"); //
    expect(await weth.balanceOf(writor)).to.equal("999999942550420886448094"); // lost 0.059 ETH (61bps of 0.89ETH)

    expect(await usdc.balanceOf(providor)).to.equal("100000000000000"); //
    expect(await weth.balanceOf(providor)).to.equal("1000000058598398439037235"); // gained 0.058ETH (60bps paid as commission)
  });

  it("should allow to force exercise 1 leg long DEEP ITM put ETH option", async function () {
    const width = 22;
    let strike = tick + 100;
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
        ratio: 5,
        asset: 0,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        0,
        0,
        -800000,
        800000,
      ),
    ).to.be.revertedWith("OptionsBalanceZero()");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize,
        20000000000,
        -80000,
        800000,
      );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("5047004298079791882");

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

    const resolved = await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longPutTokenId],
        positionSize,
        20000000000,
        0,
        0,
      );
    const receipt = await resolved.wait();
    // console.log("Gas used = " + receipt.gasUsed.toNumber());

    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //TODO: check amounts here, they changed
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("4037603438463833506");
    //expect((await pool.options(depositor, longPutTokenId, 0)).baseLiquidity.toString()).to.equal("18966480458");

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 150);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 150);

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

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);
    console.log("old tick", tick);
    console.log("new tick", slot1_.tick);

    ///////// FORCE EXERSICE

    // TWAP not updated to OTM yet
    await expect(
      pool.connect(optionWriter).forceExercise(depositor, -800000, 800000, [shortPutTokenId]),
    ).to.be.revertedWith(revertCustom("NoLegsExercisable()")); // cannot force exercise short options

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
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
    await swapRouter.connect(swapper).exactInputSingle(paramsU);

    await mineBlocks(25);
    await pool.pokeMedian();
    /*
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    */
    // TWAP tick = 19499
    const resolvedFE = await pool
      .connect(optionWriter)
      .forceExercise(depositor, -800000, 800000, [longPutTokenId]);

    const receiptFE = await resolvedFE.wait();
    // console.log("Gas used = " + receiptFE.gasUsed.toNumber());
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // writor/liquidator balance
    expect((await collatToken0.balanceOf(writor)).toString()).to.equal("3396000000000");
    expect((await collatToken1.balanceOf(writor)).toString()).to.equal("1000008014151752141202"); // 0.0995  = 10.24% due to being close to being in range

    // depositor/liquidatee balance: gets bonus
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("339599869839");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("100037698709926192413");
    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);

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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      await deployer.getAddress(),
      await deployer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      await deployer.getAddress(),
      await deployer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999869839"); //
    expect(await weth.balanceOf(depositor)).to.equal("1000000038049152896899529"); // gained 0.037 ETH (net positive)

    expect(await usdc.balanceOf(writor)).to.equal("100000000635027"); //
    expect(await weth.balanceOf(writor)).to.equal("999999970718368076078614"); // lost 0.03 ETH: exercised ITM + bonus?

    expect(await usdc.balanceOf(providor)).to.equal("100000000000000"); //
    expect(await weth.balanceOf(providor)).to.equal("1000000031527981721265829"); // gained 0.032ETH (60bps paid as commission)
  });

  it.only("manipulating force exercise price 1 leg long DEEP ITM put ETH option", async function () {
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
        ratio: 5,
        asset: 0,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        0,
        0,
        -800000,
        800000,
      ),
    ).to.be.revertedWith("OptionsBalanceZero()");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize,
        20000000000,
        -80000,
        800000,
      );

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //expect((await pool.poolData(0))[2].toString()).to.equal("0");
    //expect((await pool.poolData(1))[2].toString()).to.equal("5047004298079791882");

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

    const resolved = await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longPutTokenId],
        positionSize,
        20000000000,
        0,
        0,
      );
    const receipt = await resolved.wait();
    // console.log("Gas used = " + receipt.gasUsed.toNumber());

    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    //TODO: check amounts here, they changed
    //expect((await pool.poolData(0))[2].toString()).to.equal("0");
    //expect((await pool.poolData(1))[2].toString()).to.equal("4037603438463833506");
    //expect((await pool.options(depositor, longPutTokenId, 0)).baseLiquidity.toString()).to.equal("18966480458");

    ///////// SWAP
    const liquidity = await uniPool.liquidity();

    let amountU = UniswapV3.getAmount0ForPriceRange(liquidity, tick, tick + 100);
    let amountW = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 100);
    let amount6W = UniswapV3.getAmount1ForPriceRange(liquidity, tick, tick + 600);

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

    const paramsS6: ISwapRouter.ExactInputSingleParamsStruct = {
      tokenIn: WETH_ADDRESS,
      tokenOut: USDC_ADDRESS,
      fee: await uniPool.fee(),
      recipient: await swapper.getAddress(),
      deadline: 1759448473,
      amountIn: amount6W,
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
    console.log("initial tick", slot0_.tick, "strike = ", strike);
    let slot1_ = await uniPool.slot0();
    console.log("new tick", slot1_.tick);

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
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    slot1_ = await uniPool.slot0();
    console.log("new tick", slot1_.tick);
    ///////// FORCE EXERSICE

    // TWAP not updated to OTM yet
    await expect(
      pool.connect(optionWriter).forceExercise(depositor, -800000, 800000, [shortPutTokenId]),
    ).to.be.revertedWith(revertCustom("NoLegsExercisable()")); // cannot force exercise short options

    async function mineBlocks(blockNumber) {
      while (blockNumber > 0) {
        blockNumber--;
        await hre.network.provider.request({
          method: "evm_mine",
          params: [],
        });
      }
    }
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

    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await swapRouter.connect(swapper).exactInputSingle(paramsS6);

    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    await mineBlocks(25);
    /*
    await pool.pokeMedian();
    await mineBlocks(25);
    await pool.pokeMedian();
    */
    // TWAP tick = 19499
    const resolvedFE = await pool
      .connect(optionWriter)
      .forceExercise(depositor, -800000, 800000, [longPutTokenId]);

    const receiptFE = await resolvedFE.wait();
    // console.log("Gas used = " + receiptFE.gasUsed.toNumber());
    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      "0",
    );

    // writor/liquidator balance
    expect((await collatToken0.balanceOf(writor)).toString()).to.equal("3396000000000");
    expect((await collatToken1.balanceOf(writor)).toString()).to.equal("1000008014151752141202"); // 0.0995  = 10.24% due to being close to being in range

    // depositor/liquidatee balance: gets bonus
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("339599869839");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("100037698709926192413");
    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortPutTokenId, 0, 0);

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
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      await deployer.getAddress(),
      await deployer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).maxWithdraw(
        await deployer.getAddress(),
      ),
      await deployer.getAddress(),
      await deployer.getAddress(),
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999869839"); //
    expect(await weth.balanceOf(depositor)).to.equal("1000000038049152896899530"); // gained 0.037 ETH (net positive)

    expect(await usdc.balanceOf(writor)).to.equal("100000000635027"); //
    expect(await weth.balanceOf(writor)).to.equal("999999970718368076078614"); // lost 0.03 ETH: exercised ITM + bonus?

    expect(await usdc.balanceOf(providor)).to.equal("100000000000000"); //
    expect(await weth.balanceOf(providor)).to.equal("1000000031527981721265829"); // gained 0.032ETH (60bps paid as commission)
  });
});
