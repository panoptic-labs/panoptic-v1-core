/**
 * Test Liquidity.
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

describe("Liquidity", async function () {
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
      SFPMdeployment.address
    )) as SemiFungiblePositionManager;

    const uniPoolAddress = await pool.univ3pool();
    poolId = BigInt(uniPoolAddress.slice(0, 18).toLowerCase());

    uniPool = IUniswapV3Pool__factory.connect(uniPoolAddress, deployer);
    ({ sqrtPriceX96, tick } = await uniPool.slot0());

    //approvals
    await IERC20__factory.connect(WETH_ADDRESS, deployer).approve(
      pool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, deployer).approve(
      pool.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, swapper).approve(
      pool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, swapper).approve(
      pool.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, swapper).approve(
      uniPool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, swapper).approve(
      uniPool.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionWriter).approve(
      pool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionWriter).approve(
      pool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(WETH_ADDRESS, optionWriter).approve(
      uniPool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionWriter).approve(
      uniPool.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionBuyer).approve(
      pool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionBuyer).approve(
      pool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(WETH_ADDRESS, optionBuyer).approve(
      uniPool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionBuyer).approve(
      uniPool.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, liquidityProvider).approve(
      pool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidityProvider).approve(
      pool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(WETH_ADDRESS, liquidityProvider).approve(
      uniPool.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidityProvider).approve(
      uniPool.address,
      ethers.constants.MaxUint256
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
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, deployer).approve(
      collatToken0.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, deployer).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, deployer).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionWriter).approve(
      collatToken0.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionWriter).approve(
      collatToken0.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionWriter).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionWriter).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionBuyer).approve(
      collatToken0.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionBuyer).approve(
      collatToken0.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, optionBuyer).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, optionBuyer).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, liquidityProvider).approve(
      collatToken0.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidityProvider).approve(
      collatToken0.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, liquidityProvider).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, liquidityProvider).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, swapper).approve(
      collatToken0.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, swapper).approve(
      collatToken0.address,
      ethers.constants.MaxUint256
    );

    await IERC20__factory.connect(WETH_ADDRESS, swapper).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );
    await IERC20__factory.connect(USDC_ADDRESS, swapper).approve(
      collatToken1.address,
      ethers.constants.MaxUint256
    );
  });

  xit("should not withdraw token without any previous deposit", async function () {
    const amount = ethers.utils.parseUnits("10000000", "6");

    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
        "withdraw(uint256,address,address)"
      ](amount, depositor, depositor)
    ).to.be.revertedWith(revertReason("zero balance"));
    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
        "withdraw(uint256,address,address)"
      ](amount, depositor, depositor)
    ).to.be.revertedWith(revertReason("zero balance"));
  });

  it("should deposit token 0", async function () {
    const amount = ethers.utils.parseUnits("10000000", "6");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount,
      depositor
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(amount.toString());
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("0");
  });

  it("should deposit token 1", async function () {
    const amount = ethers.utils.parseEther("1");
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount,
      depositor
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(amount.toString());
  });

  it("should deposit 2 tokens", async function () {
    const amount0 = ethers.utils.parseUnits("10000000", "6");
    const amount1 = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseUnits("10000000", "6").toString()
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("1").toString()
    );
  });

  it("should withdraw token 0", async function () {
    const depositAmount = ethers.utils.parseUnits("20000000", "6");
    const amount = ethers.utils.parseUnits("10000000", "6");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      depositAmount,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount, depositor, depositor);
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseUnits("10000000", "6").toString()
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("0").toString()
    );
  });

  it("should withdraw token 1", async function () {
    const depositAmount = ethers.utils.parseEther("2");
    const amount = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      depositAmount,
      depositor
    );

    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount, depositor, depositor);
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("1").toString()
    );
  });

  it("should withdraw both tokens", async function () {
    const amount0 = ethers.utils.parseUnits("10000000", "6");
    const amount1 = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount0, depositor, depositor);
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount1, depositor, depositor);
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("0");
  });

  it("should calculate correct recipient token amount", async function () {
    const amount1 = ethers.utils.parseEther("1");
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("1")
    );

    const amount2 = ethers.utils.parseEther("1.25");
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount2,
      depositor
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("2.25")
    );

    const amount3 = ethers.utils.parseEther("1.75");
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount3, depositor, depositor);
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("0.5")
    );
  });

  it("should burn correct recipient token amount", async function () {
    const amount1 = ethers.utils.parseEther("1");
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount1, depositor, depositor);
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      ethers.utils.parseEther("1")
    );
  });

  it("should withdraw using recipient token", async function () {
    const amount0 = ethers.utils.parseUnits("100000000", 6);
    const amount1 = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );
  });

  it("should not mint 0 shares due to rounding", async function () {
    const amount0 = ethers.utils.parseUnits("100000", 6);
    const amount1 = ethers.utils.parseEther("10");

    const samount0 = ethers.utils.parseUnits("1", 0);
    const samount1 = ethers.utils.parseUnits("1", 0);

    // Correct tracking:
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(10),
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(10),
      depositor
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("1000000000000000000");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount0.div(10), depositor, depositor);
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount1.div(10), depositor, depositor);

    // the minimum initial shares check is a way to prevent attacks where:
    // 1. an attacker deposits a very small amount of assets, frontrunning a deposit
    // 2. the attacker donates tokens to the Panoptic Pool or otherwise increases the total assets to greater than the frontran deposit
    // 3. convertToShares(frontranDepositAssets) == 0 when the frontran deposit is processed
    // so the depositor gets no shares and forfeits their tokens to the attacker
    //);
    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider
    ).deposit(ethers.utils.parseUnits("1000000", 0), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider
    ).deposit(
      ethers.utils.parseUnits("10000000000000000", 0),
      await liquidityProvider.getAddress()
    );

    expect((await collatToken0.balanceOf(providor)).toString()).to.equal("1000000");
    expect((await collatToken1.balanceOf(providor)).toString()).to.equal("10000000000000000");

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("4396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("11000004428773891");

    // totalBalance: unchanged, contains balance of two depositors
    expect((await pool.poolData(0))[1].toString()).to.equal("4396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("11000004428773891");

    await usdc.connect(liquidityProvider).transfer(pool.address, amount0.mul(10));
    await weth.connect(liquidityProvider).transfer(pool.address, amount1.div(10));

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1000004396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("1011000004428773891");

    // totalBalance: unchanged, contains balance of two depositors
    expect((await pool.poolData(0))[1].toString()).to.equal("1000004396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("1011000004428773891");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.div(10),
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.div(10),
      depositor
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("43961");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10880320851223946");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), liquidityProvider)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidityProvider
      ).maxWithdraw(await liquidityProvider.getAddress()),
      await liquidityProvider.getAddress(),
      await liquidityProvider.getAddress()
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), liquidityProvider)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(
        await pool.collateralToken1(),
        liquidityProvider
      ).maxWithdraw(await liquidityProvider.getAddress()),
      await liquidityProvider.getAddress(),
      await liquidityProvider.getAddress()
    );

    expect(await usdc.balanceOf(providor)).to.equal("99227472856640"); // lost 700k?
    expect(await weth.balanceOf(providor)).to.equal("999999909090543076685325"); // gained 0

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).maxWithdraw(
        await deployer.getAddress()
      ),
      depositor,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).maxWithdraw(
        await deployer.getAddress()
      ),
      depositor,
      depositor
    );

    expect(await usdc.balanceOf(depositor)).to.equal("99999999975304"); // lost 0.024 USDC?
    expect(await weth.balanceOf(depositor)).to.equal("999999999999999999999884"); // loss a tiny amount
  });

  it.skip("should delegate", async function () {
    const amount0 = ethers.utils.parseUnits("100000000", 6);
    const amount1 = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    await expect(pool.delegate(token0, deployer.getAddress(), amount0.div(10))).to.be.revertedWith(
      revertReason("cannot self-delegate")
    );
    await expect(pool.delegate(token1, deployer.getAddress(), amount1.div(10))).to.be.revertedWith(
      revertReason("cannot self-delegate")
    );

    await expect(
      pool.delegate(token0, optionWriter.getAddress(), amount0.mul(10))
    ).to.be.revertedWith(revertReason("delegator must have enough funds"));
    await expect(pool.delegate(token0, optionWriter.getAddress(), 0)).to.be.revertedWith(
      revertReason("must delegate non-zero amount")
    );
    pool.delegate(token0, optionWriter.getAddress(), amount0.div(10));

    await expect(
      pool.delegate(token1, optionWriter.getAddress(), amount1.mul(10))
    ).to.be.revertedWith(revertReason("delegator must have enough funds"));
    await expect(pool.delegate(token1, optionWriter.getAddress(), 0)).to.be.revertedWith(
      revertReason("must delegate non-zero amount")
    );
    pool.delegate(token1, optionWriter.getAddress(), amount1.div(10));
  });

  it.skip("should fail if withdrawing delegated funds", async function () {
    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress()
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress()
    );

    expect((await collatToken0.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "1000000000000"
    );
    expect((await collatToken1.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "1000000000000000000000"
    );

    await expect(
      pool.connect(optionWriter).delegate(token0, depositor, amount0.mul(200))
    ).to.be.revertedWith(revertReason("delegator must have enough funds"));
    await pool.connect(optionWriter).delegate(token0, depositor, amount0);

    await expect(
      pool.connect(optionWriter).delegate(token1, depositor, amount1.mul(200))
    ).to.be.revertedWith(revertReason("delegator must have enough funds"));
    await pool.connect(optionWriter).delegate(token1, depositor, amount1);

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("20000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("20000000000000000000");

    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
        "withdraw(uint256,address,address)"
      ](amount0.mul(10), depositor, depositor)
    ).to.be.revertedWith(revertReason("Cannot remove delegated tokens, revoke tokens first"));
    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
        "withdraw(uint256,address,address)"
      ](amount1.mul(10), depositor, depositor)
    ).to.be.revertedWith(revertReason("Cannot remove delegated tokens, revoke tokens first"));

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount0, depositor, depositor);
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
      "withdraw(uint256,address,address)"
    ](amount1, depositor, depositor);

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
        "withdraw(uint256,address,address)"
      ](1, depositor, depositor)
    ).to.be.revertedWith(revertReason("Cannot remove delegated tokens, revoke tokens first"));
    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken1(), deployer)[
        "withdraw(uint256,address,address)"
      ](1, depositor, depositor)
    ).to.be.revertedWith(revertReason("Cannot remove delegated tokens, revoke tokens first"));
  });

  it.skip("should fail if co-delegating funds", async function () {
    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress()
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress()
    );

    expect((await collatToken0.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "1000000000000"
    );
    expect((await collatToken1.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "1000000000000000000000"
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), swapper).deposit(
      amount0.mul(20),
      await swapper.getAddress()
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), swapper).deposit(
      amount1.mul(20),
      await swapper.getAddress()
    );

    expect((await collatToken0.balanceOf(swapper.getAddress())).toString()).to.equal(
      "200000000000"
    );
    expect((await collatToken1.balanceOf(swapper.getAddress())).toString()).to.equal(
      "200000000000000000000"
    );

    // writer delegates to depositor
    await pool.connect(optionWriter).delegate(token0, depositor, amount0);
    await pool.connect(optionWriter).delegate(token1, depositor, amount1);

    await pool.connect(optionWriter).delegate(token0, depositor, amount0.div(10));
    await pool.connect(optionWriter).delegate(token1, depositor, amount1.div(10));

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("21000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("21000000000000000000");

    await expect(
      pool.connect(deployer).delegate(token0, swapper.getAddress(), amount0.div(10))
    ).to.be.revertedWith(revertReason("account who received delegated funds cannot delegate"));
    await expect(
      pool.connect(deployer).delegate(token1, swapper.getAddress(), amount1.div(10))
    ).to.be.revertedWith(revertReason("account who received delegated funds cannot delegate"));

    // swapper delegates to writer
    await expect(
      pool.connect(swapper).delegate(token0, optionWriter.getAddress(), amount0.div(2))
    ).to.be.revertedWith(revertReason("account who delegated funds cannot be delegated to"));
    await expect(
      pool.connect(swapper).delegate(token1, optionWriter.getAddress(), amount1.div(2))
    ).to.be.revertedWith(revertReason("account who delegated funds cannot be delegated to"));

    expect((await collatToken0.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "989000000000"
    );
    expect((await collatToken1.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "989000000000000000000"
    );
  });

  it.skip("should revoke", async function () {
    const amount0 = ethers.utils.parseUnits("100000000", 6);
    const amount1 = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    pool.delegate(token0, optionWriter.getAddress(), amount0.div(10));

    pool.revoke(token0, optionWriter.getAddress(), []);

    await expect(pool.revoke(token0, optionWriter.getAddress(), [])).to.be.revertedWith(
      revertReason("must have funds delegated")
    );

    pool.delegate(token1, optionWriter.getAddress(), amount1.div(10));

    pool.revoke(token1, optionWriter.getAddress(), []);

    await expect(pool.revoke(token1, optionWriter.getAddress(), [])).to.be.revertedWith(
      revertReason("must have funds delegated")
    );
  });

  it("should return pool balances", async function () {
    const amount0 = ethers.utils.parseUnits("100000000", 6);
    const amount1 = ethers.utils.parseEther("1");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor
    );

    expect((await pool.poolData(0))[0].toString()).to.equal("100000003396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("1001000004428773891");

    expect((await pool.poolData(0))[1].toString()).to.equal("100000003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("1001000004428773891");

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("0");
  });
});
