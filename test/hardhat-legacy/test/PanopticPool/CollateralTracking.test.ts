/**
 * Test Collateral Tracking.
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
  CollateralTracker,
  CollateralTracker__factory,
  PanopticPool,
  ERC20,
  SemiFungiblePositionManager,
  ISwapRouter,
} from "../../typechain";

import * as OptionEncoding from "../Libraries/OptionEncoding";
import * as UniswapV3 from "../Libraries/UniswapV3";

import { BigNumber, Signer } from "ethers";
import { maxLiquidityForAmounts, TickMath } from "@uniswap/v3-sdk";
import JSBI from "jsbi";
import { token } from "../../types/@openzeppelin/contracts";

const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_SLOT = 9;
const token0 = USDC_ADDRESS;

const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const WETH_SLOT = 3;
const token1 = WETH_ADDRESS;

const SWAP_ROUTER_ADDRESS = "0xE592427A0AEce92De3Edee1F18E0157C05861564";
const decimalUSDC = 6;
const decimalWETH = 18;

describe("Collateral Tracking", async function () {
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

  it("should not allow to write undercollateralized call USDC option, asset = 1", async function () {
    const width = 2;
    let strike = tick + 1;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396114535);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize = ethers.utils.parseEther("1");

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      "0", //
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "0", //
    );

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal(
      "3396114535", //
    );
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "1000000000000000000", //
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(1000),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(1000),
      await optionWriter.getAddress(),
    );

    const shortTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 200,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 200,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    // cannot mint, not enough collateral
    await expect(
      pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId],
          positionSize.div(10).mul(46),
          5000000000,
          0,
          0,
        ),
    ).to.be.revertedWith(revertCustom("NotEnoughCollateral()"));
    // can mint, barely enough collateral
    await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId],
        positionSize.div(10).mul(45),
        5000000000,
        0,
        0,
      );

    let slot0_ = await uniPool.slot0();

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot0_.tick, 1, [shortTokenId])
      ).toString(),
    ).to.equal("1946561868980687344,1782709127967229971");

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), slot0_.tick, 0, [shortTokenId])
      ).toString(),
    ).to.equal("6610805612,6054338007");

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 200,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 200,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    // write mints a lot of options
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId],
        positionSize.mul(100),
        5000000000,
        0,
        0,
      );

    await expect(
      pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId, tokenId2],
          positionSize.div(100).mul(75),
          5000000000,
          0,
          0,
        ),
    ).to.be.revertedWith(revertCustom("NotEnoughCollateral()"));

    //cannot mint either, no enough collateral
    //can mint, barely has enough collateral
    await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId, tokenId2],
        positionSize.div(100).mul(74),
        5000000000,
        0,
        0,
      );
  });

  it("should allow ATM put options, asset = 0 and collateral accurately tracked", async function () {
    // Structure of these tests:
    // 1) mint short option
    // 2) check short option minter's collateral
    // 3) mint long option
    // 4) checl long option minter's collateral
    // 5) burn long and short options
    // 6) withdraw + deposit collateral
    // 7) repeat at a different strike
    //
    const width = 24;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396e6);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize0 = BigNumber.from(1000e6);
    const positionSize1 = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0");

    // MOST ITM option
    let shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 32840, //+26x above strike
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        0,
        5000000000,
        193000,
        197000,
      ),
    ).to.be.reverted;
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 29833 at price=3396, collateral requirement = more than ~20% of strike = ~32256
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("25859313753,25861906956"); // still solvent

    // Deposited shares = 1ETH + 3396 -swap + itm = 2.185 ETH at price=3396, collateral requirement = more than 20% of strike = 0.246
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    // Balance - required = 1.93
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("7614314663403196671,7615078236020423719");

    // MOST ITM option
    let longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 32840, //+26x above strike
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap -itm = 4715  at price=3396, collateral requirement = more than ~10% of strike = ~266
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("4715356042,266619069");

    // Deposited shares = 1ETH + 3396 -swap + itm = 1.338 ETH at price=3396, collateral requirement = more than 20% of strike = 0.246
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    // Balance - required = 1.93
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1388443830956641318,78506394650910346");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("3395999999,0");

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // OTM Put option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        0,
        0,
      );

    // Deposited shares = 1ETH + 3396 = 6786 at price=3396, collateral requirement = 20% of strike = ~194
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6786746676,194945229");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 20% of 1000/strike = 0.057
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1998367985768526947,57401922426559085");

    // mint long OTM put
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 250,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 10% of 1000/strike = 0.0287
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "2000090272224972786,0",
    );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      0,
      0,
    );

    // Deposited shares = 1ETH + 3396 = 6786 at price=3396, collateral requirement = 10% of strike = ~9.7
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6792056089,9747261");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 10% of 1000/strike = 0.0287
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1999931350370829910,2870096121318516");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);

    // Deposited shares = 1ETH + 3396 = 6786 at price=3396, collateral requirement = 10% of strike = ~9.7
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 0, [])).toString()).to.equal(
      "6792056089,0",
    );

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 10% of 1000/strike = 0.0287
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "1999931350370829910,0",
    );

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Barely ATM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 110,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId0],
          positionSize0,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap +itm = 6785 at price=3396, collateral requirement = slightly more than ~20% of strike  = ~197
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6785753076,197792365");

    // Deposited shares = 1ETH + 3396 - swap = 1.998ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.058
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1998075418537389821,58240265907936432");

    // Barely ATM long option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 110,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // Deposited shares = 1ETH + 3396 - swap = 1.999ETH at price=3396, collateral requirement = slightly less than 10% of strike = 0.00291
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "2000114584933994391,0",
    );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 - swap +itm = 6792 at price=3396, collateral requirement = slightly less than ~10% of strike  = ~9.88
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6792129914,9884675");

    // Deposited shares = 1ETH + 3396 - swap = 1.999ETH at price=3396, collateral requirement = slightly less than 10% of strike = 0.00291
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1999953088435854223,2910558016385325");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);

    // Deposited shares = 1ETH + 3396 - swap = 1.999ETH at price=3396, collateral requirement = slightly less than 10% of strike = 0.00291
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "1999979803620509883,0",
    );

    await expect(
      pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 196000, 197000),
    ).to.be.revertedWith("PriceBoundFail()");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Exactly at the strike ATM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 0,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6778 at price=3396, collateral requirement = slightly more than ~20% of strike = ~204
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6788155715,204377342");

    // Deposited shares = 1ETH + 3396 -swap = 1.998 ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.0601
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1998782879308359314,60179222619808134");

    // Exactly at the strike ATM option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 0,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenId0],
        positionSize0.div(10),
        10,
        193000,
        197000,
      ),
    ).to.be.revertedWith("EffectiveLiquidityAboveThreshold(477218588, 10, 1286639861544607)");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6792 at price=3396, collateral requirement = slightly more than ~10% of strike = ~9.9
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6791836701,9994002");

    // Deposited shares = 1ETH + 3396 -swap = 1.9999 ETH at price=3396, collateral requirement = slightly more than 10% of 1ETH = 0.029
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1999866751223774517,2942749272359235");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Almost ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 110,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap +itm= 6795 at price=3396, collateral requirement = slightly more than ~20% of strike = ~211
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6795658004,211083786");

    // Deposited shares = 1ETH + 3396 - swap +itm = 2.001ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.0621
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("2000991939943727823,62153945326081436");

    // Almost ITM long option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 110,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 - swap +itm= 6792 at price=3396, collateral requirement = slightly more than ~10% of strike = ~10.1
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6791033239,10104537");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Barely ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 130,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6797 at price=3396, collateral requirement = slightly more than ~20% of strike = ~212
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6797581166,212476571");

    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 130,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6792 at price=3396, collateral requirement = slightly more than ~20% of strike = ~10.1
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6790832776,10124765");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Very ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 500,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6835 at price=3396, collateral requirement = slightly more than ~20% of strike = ~251
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6835493299,250637928");

    // Very ITM long option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 500,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap -itm = 6786 at price=3396, collateral requirement = slightly more than ~20% of strike = ~10.5
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6787015588,10506379");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // DEEP ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 5000, //+64% above strike
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 7420 at price=3396, collateral requirement = more than ~20% of strike = ~847
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("7421037850,847691194");

    // DEEP ITM option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 5000, //+64% above strike
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6727 at price=3396, collateral requirement = more than ~20% of strike = ~16.47
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6727850643,16476911");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // MOST ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 32960, //+26x above strike
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 29833 at price=3396, collateral requirement = more than ~20% of strike = ~32256
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("26245080808,26183761009"); // still solvent

    // MOST ITM option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 32960, //+26x above strike
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "2160452989861515583,0",
    );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 4620  at price=3396, collateral requirement = more than ~20% of strike = ~266
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("4630916610,269837610"); // still solvent

    // Deposited shares = 1ETH + 3396 -swap + itm = 1.36 ETH at price=3396, collateral requirement = more than 20% of strike = 0.078
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    // Balance - required = 1.93
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1363580510707591032,79454098855675552");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "2101831896101573150,0",
    );

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("3395999999,0");

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Too much ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 590000, //getting close to  MAX_TICK
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId0],
          positionSize0,
          5000000000,
          193000,
          197000,
        ),
    ).to.be.revertedWith("NotEnoughCollateral()");

    let shortTokenIdOTM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 5000,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdOTM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdOTM])
      ).toString(),
    ).to.be.equal("0,0");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdOTM, 0, 0);

    let shortTokenIdATM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdATM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdATM])
      ).toString(),
    ).to.be.equal("-796946206940930,-2706544");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdATM, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0,
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1,
      await optionBuyer.getAddress(),
    );
    let shortTokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 10000, //getting close to  MAX_TICK
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdITM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    let longTokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 10000, //getting close to  MAX_TICK
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionBuyer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenIdITM],
        positionSize0.div(10),
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionBuyer.getAddress(), tick + 100, [longTokenIdITM])
      ).toString(),
    ).to.be.equal("50247152302550681,168948718");

    await pool.connect(optionBuyer)["burnOptions(uint256,int24,int24)"](longTokenIdITM, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdITM, 0, 0);

    shortTokenIdOTM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 5000, //getting close to  MAX_TICK
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdOTM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdOTM])
      ).toString(),
    ).to.be.equal("0,0");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdOTM, 0, 0);

    shortTokenIdATM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike, //getting close to  MAX_TICK
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdATM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdATM])
      ).toString(),
    ).to.be.equal("-973555015955098,-3306333");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdATM, 0, 0);

    shortTokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 10000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdITM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    //await pool.connect(optionWriter)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortTokenIdITM], positionSize0, 5000000000, 0, 0);
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdITM])
      ).toString(),
    ).to.be.equal("-186188427603597409,-632322826");
    const resolved = await pool
      .connect(optionWriter)
      ["burnOptions(uint256,int24,int24)"](shortTokenIdITM, 0, 0);
    const receipt = await resolved.wait();
  });

  it("should allow ATM put options, asset = 0 and collateral accurately tracked", async function () {
    // Structure of these tests:
    // 1) mint short option
    // 2) check short option minter's collateral
    // 3) mint long option
    // 4) checl long option minter's collateral
    // 5) burn long and short options
    // 6) withdraw + deposit collateral
    // 7) repeat at a different strike
    //
    const width = 24;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396e6);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize0 = BigNumber.from(1000e6);
    const positionSize1 = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0");

    // MOST ITM option
    let shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 32840, //+26x above strike
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        0,
        5000000000,
        193000,
        197000,
      ),
    ).to.be.reverted;
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 29833 at price=3396, collateral requirement = more than ~20% of strike = ~32256
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("25859313753,25861906956"); // still solvent

    // Deposited shares = 1ETH + 3396 -swap + itm = 2.185 ETH at price=3396, collateral requirement = more than 20% of strike = 0.246
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    // Balance - required = 1.93
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("7614314663403196671,7615078236020423719");

    // MOST ITM option
    let longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 32840, //+26x above strike
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap -itm = 4715  at price=3396, collateral requirement = more than ~10% of strike = ~266
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("4715356042,266619069");

    // Deposited shares = 1ETH + 3396 -swap + itm = 1.338 ETH at price=3396, collateral requirement = more than 20% of strike = 0.246
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    // Balance - required = 1.93
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1388443830956641318,78506394650910346");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("3395999999,0");

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // OTM Put option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        0,
        0,
      );

    // Deposited shares = 1ETH + 3396 = 6786 at price=3396, collateral requirement = 20% of strike = ~194
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6786746676,194945229");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 20% of 1000/strike = 0.057
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1998367985768526947,57401922426559085");

    // mint long OTM put
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 250,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 10% of 1000/strike = 0.0287
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "2000090272224972786,0",
    );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      0,
      0,
    );

    // Deposited shares = 1ETH + 3396 = 6786 at price=3396, collateral requirement = 10% of strike = ~9.7
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6792056089,9747261");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 10% of 1000/strike = 0.0287
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1999931350370829910,2870096121318516");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);

    // Deposited shares = 1ETH + 3396 = 6786 at price=3396, collateral requirement = 10% of strike = ~9.7
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 0, [])).toString()).to.equal(
      "6792056089,0",
    );

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 10% of 1000/strike = 0.0287
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "1999931350370829910,0",
    );

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Barely ATM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 110,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId0],
          positionSize0,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap +itm = 6785 at price=3396, collateral requirement = slightly more than ~20% of strike  = ~197
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6785753076,197792365");

    // Deposited shares = 1ETH + 3396 - swap = 1.998ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.058
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1998075418537389821,58240265907936432");

    // Barely ATM long option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 110,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // Deposited shares = 1ETH + 3396 - swap = 1.999ETH at price=3396, collateral requirement = slightly less than 10% of strike = 0.00291
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "2000114584933994391,0",
    );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 - swap +itm = 6792 at price=3396, collateral requirement = slightly less than ~10% of strike  = ~9.88
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6792129914,9884675");

    // Deposited shares = 1ETH + 3396 - swap = 1.999ETH at price=3396, collateral requirement = slightly less than 10% of strike = 0.00291
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1999953088435854223,2910558016385325");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);

    // Deposited shares = 1ETH + 3396 - swap = 1.999ETH at price=3396, collateral requirement = slightly less than 10% of strike = 0.00291
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "1999979803620509883,0",
    );

    await expect(
      pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 196000, 197000),
    ).to.be.revertedWith("PriceBoundFail()");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Exactly at the strike ATM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 0,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6778 at price=3396, collateral requirement = slightly more than ~20% of strike = ~204
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6788155715,204377342");

    // Deposited shares = 1ETH + 3396 -swap = 1.998 ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.0601
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1998782879308359314,60179222619808134");

    // Exactly at the strike ATM option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 0,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenId0],
        positionSize0.div(10),
        10,
        193000,
        197000,
      ),
    ).to.be.revertedWith("EffectiveLiquidityAboveThreshold(477218588, 10, 1286639861544607)");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6792 at price=3396, collateral requirement = slightly more than ~10% of strike = ~9.9
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6791836701,9994002");

    // Deposited shares = 1ETH + 3396 -swap = 1.9999 ETH at price=3396, collateral requirement = slightly more than 10% of 1ETH = 0.029
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1999866751223774517,2942749272359235");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Almost ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 110,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap +itm= 6795 at price=3396, collateral requirement = slightly more than ~20% of strike = ~211
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6795658004,211083786");

    // Deposited shares = 1ETH + 3396 - swap +itm = 2.001ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.0621
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("2000991939943727823,62153945326081436");

    // Almost ITM long option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 110,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 - swap +itm= 6792 at price=3396, collateral requirement = slightly more than ~10% of strike = ~10.1
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6791033239,10104537");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Barely ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 130,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6797 at price=3396, collateral requirement = slightly more than ~20% of strike = ~212
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6797581165,212476571");

    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 130,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6792 at price=3396, collateral requirement = slightly more than ~20% of strike = ~10.1
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6790832776,10124765");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Very ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 500,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6835 at price=3396, collateral requirement = slightly more than ~20% of strike = ~251
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6835493299,250637928");

    // Very ITM long option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 500,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap -itm = 6786 at price=3396, collateral requirement = slightly more than ~20% of strike = ~10.5
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6787015588,10506379");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // DEEP ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 5000, //+64% above strike
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 7420 at price=3396, collateral requirement = more than ~20% of strike = ~847
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("7421037850,847691194");

    // DEEP ITM option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 5000, //+64% above strike
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6727 at price=3396, collateral requirement = more than ~20% of strike = ~16.47
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6727850643,16476911");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // MOST ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 32960, //+26x above strike
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 29833 at price=3396, collateral requirement = more than ~20% of strike = ~32256
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("26245080808,26183761009"); // still solvent

    // MOST ITM option
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 32960, //+26x above strike
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "2160452989861515583,0",
    );

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId0],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 4620  at price=3396, collateral requirement = more than ~20% of strike = ~266
    // Balance - required = 6572
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("4630916610,269837610"); // still solvent

    // Deposited shares = 1ETH + 3396 -swap + itm = 1.36 ETH at price=3396, collateral requirement = more than 20% of strike = 0.078
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    // Balance - required = 1.93
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1363580510707591032,79454098855675552");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    expect((await pool.checkCollateral(deployer.getAddress(), tick, 1, [])).toString()).to.equal(
      "2101831896101573150,0",
    );

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("3395999999,0");

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Too much ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 590000, //getting close to  MAX_TICK
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId0],
          positionSize0,
          5000000000,
          193000,
          197000,
        ),
    ).to.be.revertedWith("NotEnoughCollateral()");

    let shortTokenIdOTM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 5000,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdOTM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdOTM])
      ).toString(),
    ).to.be.equal("0,0");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdOTM, 0, 0);

    let shortTokenIdATM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdATM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdATM])
      ).toString(),
    ).to.be.equal("-796946206940930,-2706544");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdATM, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0,
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1,
      await optionBuyer.getAddress(),
    );
    let shortTokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 10000, //getting close to  MAX_TICK
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdITM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    let longTokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 10000, //getting close to  MAX_TICK
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionBuyer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenIdITM],
        positionSize0.div(10),
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionBuyer.getAddress(), tick + 100, [longTokenIdITM])
      ).toString(),
    ).to.be.equal("50247152302550681,168948718");

    await pool.connect(optionBuyer)["burnOptions(uint256,int24,int24)"](longTokenIdITM, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdITM, 0, 0);

    shortTokenIdOTM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 5000, //getting close to  MAX_TICK
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdOTM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdOTM])
      ).toString(),
    ).to.be.equal("0,0");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdOTM, 0, 0);

    shortTokenIdATM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike, //getting close to  MAX_TICK
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdATM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdATM])
      ).toString(),
    ).to.be.equal("-973555015955098,-3306333");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenIdATM, 0, 0);

    shortTokenIdITM = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 10000, //getting close to  MAX_TICK
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenIdITM],
        positionSize0,
        5000000000,
        0,
        0,
      );
    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [shortTokenIdITM])
      ).toString(),
    ).to.be.equal("-186188427603597409,-632322826");
    const resolved = await pool
      .connect(optionWriter)
      ["burnOptions(uint256,int24,int24)"](shortTokenIdITM, 0, 0);
    const receipt = await resolved.wait();
  });

  it("should allow ATM call options, asset = 0 and collateral accurately tracked", async function () {
    // Structure of these tests:
    // 1) mint short option
    // 2) check short option minter's collateral
    // 3) mint long option
    // 4) checl long option minter's collateral
    // 5) burn long and short options
    // 6) withdraw + deposit collateral
    // 7) repeat at a different strike
    //
    const width = 24;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396e6);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize0 = BigNumber.from(1000e6);
    const positionSize1 = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    //

    // OTM Call option
    let shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize0,
        5000000000,
        0,
        0,
      );

    // Deposited shares = 1ETH + 3396 = 6786 at price=3396, collateral requirement = 20% of 1000 = ~200
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6786643764,199999999");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 20% of 1000 = 0.058
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId1])).toString(),
    ).to.equal("1998337683087219633,58890307267944458");

    // OTM Call option
    let longTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 250,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId1],
      positionSize0.div(10),
      5000000000,
      0,
      0,
    );

    // Deposited shares = 1ETH + 3396 = 6786 at price=3396, collateral requirement = 10% of 100 = ~20
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId1])).toString(),
    ).to.equal("6792094643,9999999");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 10% of 100 = 0.0294
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId1])).toString(),
    ).to.equal("1999942702783164157,2944515363380921");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId1, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Barely ATM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 110,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        0,
        5000000000,
        193000,
        197000,
      ),
    ).to.be.reverted;
    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId1],
          positionSize0,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap +itm = 6785 at price=3396, collateral requirement = slightly more than ~20% of 1000 = ~200.6
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6785747249,200599999");

    // Deposited shares = 1ETH + 3396 - swap = 1.993ETH at price=3396, collateral requirement = slightly more than 20% of 1000 = 0.059
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId1])).toString(),
    ).to.equal("1998073703162566590,59066978189750402");

    // Barely ATM option
    longTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 110,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId1],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 - swap -itm = 6792 at price=3396, collateral requirement = slightly more than ~10% of 100 = ~10
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId1])).toString(),
    ).to.equal("6792169121,10000000");

    // Deposited shares = 1ETH + 3396 - swap = 1.99999ETH at price=3396, collateral requirement = slightly more than 10% of 100 = 0.0294
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId1])).toString(),
    ).to.equal("1999964632944687366,2944515368014010");

    await expect(
      pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 196000, 197000),
    ).to.be.revertedWith("PriceBoundFail()");
    await pool["burnOptions(uint256,int24,int24)"](longTokenId1, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Exactly at the strike ATM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 0,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6788 at price=3396, collateral requirement = slightly more than ~20% of 1000 = ~205
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6788779071,204999999");

    // Deposited shares = 1ETH + 3396 -swap = 1.998 ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.06036
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId1])).toString(),
    ).to.equal("1998966427513930315,60362564949643498");

    // Exactly at the strike ATM option
    longTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 0,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId1],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6791 at price=3396, collateral requirement = slightly more than ~10% of 100 = ~10
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId1])).toString(),
    ).to.equal("6791820215,10000000");

    // Deposited shares = 1ETH + 3396 -swap = 1.998 ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.06036
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId1])).toString(),
    ).to.equal("1999861905576050071,2944515399295943");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId1, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Almost ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 110,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6796 at price=3396, collateral requirement = slightly more than ~20% of 1000 = ~209
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6796794867,209299999");

    // Deposited shares = 1ETH + 3396 - swap +itm = 2.0013ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.0616
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId1])).toString(),
    ).to.equal("2001326690961109374,61628706555910850");

    // Almost ITM option
    longTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 110,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId1],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6791 at price=3396, collateral requirement = slightly more than ~10% of 100 = ~10
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId1])).toString(),
    ).to.equal("6790973733,10000000");

    // Deposited shares = 1ETH + 3396 -swap = 1.998 ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.06036
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId1])).toString(),
    ).to.equal("1999612649111577025,2944515429719897");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId1, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // Barely ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 130,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6798 at price=3396, collateral requirement = slightly more than ~20% of strike = ~210
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6792324676,210805812");

    // Deposited shares = 1ETH + 3396 -swap +itm = 2.0019 ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.06207
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId1])).toString(),
    ).to.equal("2000010436419746868,62072095507199270");

    // Barely ITM option
    longTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 130,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId1],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6791 at price=3396, collateral requirement = slightly more than ~10% of 100 = ~10
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId1])).toString(),
    ).to.equal("6790775728,9999999");

    // Deposited shares = 1ETH + 3396 -swap = 1.998 ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.06036
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [longTokenId1])).toString(),
    ).to.equal("1999554346235115163,2944515363380921");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId1, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // Very ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 500,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm= 6834 at price=3396, collateral requirement = slightly more than ~20% of strike = ~239
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6821715130,239470988");

    // Deposited shares = 1ETH + 3396 -swap + itm = 2.012 ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.0705
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId1])).toString(),
    ).to.equal("2008664500753772536,70512600619848209");

    // Very ITM option
    longTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 500,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId1],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6791 at price=3396, collateral requirement = slightly more than ~10% of 100 = ~10
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId1])).toString(),
    ).to.equal("6787194281,9999999");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId1, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // DEEP ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 5000, //+64% above strike
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 7176 at price=3396, collateral requirement = more than ~20% of 3396 = ~515
    // Balance - required = 5983
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("7156908330,515054381");

    // DEEP ITM option
    longTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 5000,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [longTokenId1],
      positionSize0.div(10),
      5000000000,
      193000,
      197000,
    );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6791 at price=3396, collateral requirement = slightly more than ~10% of 100 = ~10
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [longTokenId1])).toString(),
    ).to.equal("6752996214,9999999");

    await pool["burnOptions(uint256,int24,int24)"](longTokenId1, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // Most ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 50000, //+64% above strike
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize0,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 7765 at price=3396, collateral requirement = more than ~100% of 1000 = ~999.99....
    // Balance - required = 5983
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("7726734682,994611527");

    longTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 50000,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenId1],
        positionSize0.mul(1000),
        5000000000,
        193000,
        197000,
      ),
    ).to.be.revertedWith("NotEnoughLiquidity()");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);

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
    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // Too much ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 400000, //+64% above strike
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId1],
          positionSize0,
          20000,
          193000,
          197000,
        ),
    ).to.be.revertedWith("NotEnoughLiquidity()");

    // Too much ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 600000, //+64% above strike
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId1],
          positionSize0,
          20000,
          193000,
          197000,
        ),
    ).to.be.revertedWith("NotEnoughLiquidity()");

    //
  });

  it("should allow ATM options, asset = 1 and collateral accurately tracked", async function () {
    const width = 24;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396e6);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize0 = BigNumber.from(1000e6);
    const positionSize1 = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0");

    // OTM Put option
    let shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        0,
        0,
      );

    // Deposited shares = 1ETH + 3396 = 6773 at price=3396, collateral requirement = 20% of 3396 = ~679
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6773456336,679228923");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 20% of 1ETH = 0.2
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1994454624579272374,199999999999998016");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Barely ATM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 110,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        0,
        5000000000,
        193000,
        197000,
      ),
    ).to.be.reverted;
    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId0],
          positionSize1,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6770 at price=3396, collateral requirement = slightly more than ~20% of 3396 = ~679
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6770321907,679568537");

    // Deposited shares = 1ETH + 3396 - swap = 1.993ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.2
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1993531687172342197,200099999999995209");

    await expect(
      pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 196000, 197000),
    ).to.be.revertedWith("PriceBoundFail()");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Exactly at the strike ATM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 0,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap = 6778 at price=3396, collateral requirement = slightly more than ~20% of 3396 = ~694
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6778730112,694511574");

    // Deposited shares = 1ETH + 3396 -swap = 1.996 ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.2045
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1996007496097358344,204499999999991837");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Almost ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 110,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6804 at price=3396, collateral requirement = slightly more than ~20% of 3396 = ~709
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6804091971,709454610");

    // Deposited shares = 1ETH + 3396 - swap = 1.982ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.2089
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("2003475511523187244,208899999999988464");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Barely ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 130,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap = 6810 at price=3396, collateral requirement = slightly more than ~20% of 3396 = ~712
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6810515822,712708998");

    // Deposited shares = 1ETH + 3396 -swap +itm = 2.0053 ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.2098
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("2005366847094988547,209858259575331692");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    //

    // Very ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 500,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6932 at price=3396, collateral requirement = slightly more than ~20% of 3396 = ~810
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6932103227,810176966");

    // Deposited shares = 1ETH + 3396 -swap + itm = 2.041 ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.238
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("2041168445363046323,238557852636817611");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    //

    // DEEP ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 5000, //+64% above strike
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 8069 at price=3396, collateral requirement = more than ~20% of 3396 = ~1747
    // Balance - required = 6166
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("8069267292,1747221746");

    // Deposited shares = 1ETH + 3396 -swap + itm = 2.37 ETH at price=3396, collateral requirement = more than 20% of 1ETH = 0.5114
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    // Balance - required = 1.81
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("2376008151494170009,514472127483890827");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    //

    // MOST ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 190000, //getting close to  MAX_TICK
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 9650 at price=3396, collateral requirement = close to ~100% of 3396 = 3396
    // Balance - required = 6294
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("9950672865,3396144601");

    // Deposited shares = 1ETH + 3396 -swap + itm = 2.85 ETH at price=3396, collateral requirement = close to 100% of 1ETH = 0.99999...
    // Collateral and balance will increase in consort the more ITM the position is when it is minted
    // Balance - required = 1.81
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("2929990912958118333,999999995510801046");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // Too much ITM option
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 590000, //getting close to  MAX_TICK
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId0],
          positionSize1,
          5000000000,
          193000,
          197000,
        ),
    ).to.be.revertedWith("NotEnoughLiquidity()");

    //

    // OTM Call option
    let shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize1,
        5000000000,
        0,
        0,
      );

    // Deposited shares = 1ETH + 3396 = 6773 at price=3396, collateral requirement = 20% of 3396 = ~662
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6773907008,662857103");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 20% of 1ETH = 0.2
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId1])).toString(),
    ).to.equal("1994587325715032566,195179292646520498");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Barely ATM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 110,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId1],
          positionSize1,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6770 at price=3396, collateral requirement = slightly more than ~20% of strike = ~674
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6770633680,674218501");

    // Deposited shares = 1ETH + 3396 - swap = 1.993ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.198
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId1])).toString(),
    ).to.equal("1993623489550940688,198524673742584261");

    await expect(
      pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 196000, 197000),
    ).to.be.revertedWith("PriceBoundFail()");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Exactly at the strike ATM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 0,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap = 6780 at price=3396, collateral requirement = slightly more than ~20% of strike = ~697
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6780702643,696627475");

    // Deposited shares = 1ETH + 3396 -swap = 1.995 ETH at price=3396, collateral requirement = slightly more than 20% of strike = 0.2045
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId1])).toString(),
    ).to.equal("1996588310881181090,205123030564681229");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Almost ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 110,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6808 at price=3396, collateral requirement = slightly more than ~20% of strike = ~719
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6808112435,719106090");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // Barely ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 130,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 6814 at price=3396, collateral requirement = slightly more than ~20% of strike = ~725
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6814907460,725729652");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    //

    // Very ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 500,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm= 6943 at price=3396, collateral requirement = slightly more than ~20% of strike = ~855
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("6943460096,855486746");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    //

    // DEEP ITM option
    shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 5000, //+64% above strike
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId1],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 -swap +itm = 8868 at price=3396, collateral requirement = more than ~20% of 3396 = ~2885
    // Balance - required = 5983
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId1])).toString(),
    ).to.equal("8869070288,2885600535");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId1, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    //
  });

  it.only("should allow cross-collateral options, 1 leg tokentype = 1, asset = 1 and collateral=token0", async function () {
    const width = 24;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396e6);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize0 = BigNumber.from(1000e6);
    const positionSize1 = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0.mul(5), depositor);
    await collateraltoken1.deposit(amount1.div(100), depositor);

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(100), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(100), await liquidityProvider.getAddress());

    expect((await pool.checkCollateral(depositor, tick, 0, [])).toString()).to.equal(
      "17030175632,0",
    );

    // OTM Put option
    let shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("1");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortTokenId0],
      positionSize1.div(27),
      5000000000,
      0,
      0,
    );
    console.log("2");

    // Deposited shares = 1ETH + 3396 = 6773 at price=3396, collateral requirement = 20% of 3396 = ~679
    expect((await pool.checkCollateral(depositor, tick, 0, [shortTokenId0])).toString()).to.equal(
      "17030049861,25156626",
    );
    console.log("3");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 20% of 1ETH = 0.2
    expect((await pool.checkCollateral(depositor, tick, 1, [shortTokenId0])).toString()).to.equal(
      "5014524345795000525,7407407407407333",
    );
    console.log("4");

    await pool["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    console.log("5");
  });

  it.only("should allow cross-collateral options, 2 legs tokentype = 0+1 , asset = 1 and collateral=token0", async function () {
    const width = 24;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396e6);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize0 = BigNumber.from(1000e6);
    const positionSize1 = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0.mul(5), depositor);
    await collateraltoken1.deposit(amount1.div(100), depositor);

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(100), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(100), await liquidityProvider.getAddress());

    expect((await pool.checkCollateral(depositor, tick, 0, [])).toString()).to.equal(
      "17030175632,0",
    );

    // OTM Put option
    let shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 10,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    console.log("1");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortTokenId0],
      positionSize1,
      5000000000,
      0,
      0,
    );
    console.log("2");

    // Deposited shares = 1ETH + 3396 = 6773 at price=3396, collateral requirement = 20% of 3396 = ~679
    expect((await pool.checkCollateral(depositor, tick, 0, [shortTokenId0])).toString()).to.equal(
      "17026662892,703779186",
    );
    console.log("3");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 20% of 1ETH = 0.2
    expect((await pool.checkCollateral(depositor, tick, 1, [shortTokenId0])).toString()).to.equal(
      "5014524345795000525,7407407407407333",
    );
    console.log("4");

    await pool["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    console.log("5");
  });

  it("should allow short 2-legged ATM options, asset = 1 and collateral accurately tracked", async function () {
    const width = 24;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396e6);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize0 = BigNumber.from(1000e6);
    const positionSize1 = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6794408848,0");

    // OTM strangle, no capital efficiency
    let shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        0,
        0,
      );

    // Deposited shares = 1ETH + 3396 = 6773 at price=3396, collateral requirement = 20% of 3396 times 2 = ~1342
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6788257301,1342086027");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 20% of 1ETH times 2 = 0.4
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1998812791398870060,395179292646518515");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

    // OTM strangle
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        0,
        0,
      );

    // Deposited shares = 1ETH + 3396 = 6773 at price=3396, collateral requirement = 10% of 3396 times 2 = ~671
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6782105247,671043013");

    // Deposited shares = 1ETH + 3396 = 2ETH at price=3396, collateral requirement = 20% of 1ETH times 2 = 0.2
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1997001309610225746,197589646323242097");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6785917894,0"); // lost commission 18 USDC

    // Barely ITM strangle, put side
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 110,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        0,
        5000000000,
        193000,
        197000,
      ),
    ).to.be.reverted;
    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId0],
          positionSize1,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6770 at price=3396, collateral requirement = slightly more than ~20% of 3396 = ~679
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6779748598,671382628");

    // Deposited shares = 1ETH + 3396 - swap = 1.993ETH at price=3396, collateral requirement = slightly more than 20% of 1ETH = 0.2
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [shortTokenId0])).toString(),
    ).to.equal("1996307390951514734,197689646323239291");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6785917809,0"); // lost commission 18 USDC

    // Barely ITM strangle, call side
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 110,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6779791411,678068115");

    await expect(
      pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 196000, 197000),
    ).to.be.revertedWith("PriceBoundFail()");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6785917721,0"); // lost commission 18 USDC

    // ITM straddle, call side
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 240,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId0])).toString(),
    ).to.equal("6862297679,763805882");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6785917632,0"); // lost commission 18 USDC
  });

  it("Single positions, collateral output", async function () {
    const width = 6;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396e6);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize0 = BigNumber.from(1000e6);
    const positionSize1 = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.div(200),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(10), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(10), await liquidityProvider.getAddress());

    // OTM strangle, no capital efficiency
    let shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 200,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 200,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        0,
        0,
      );

    for (let i = 0; i < 200000; i = i + 1000) {
      // Deposited shares = 1ETH + 3396 = 6773 at price=3396, collateral requirement = 10% of 3396 times 2 = ~671
      console.log(
        1.0001 ** (95000 + i),
        ",",
        (await pool.checkCollateral(writor, 95000 + i, 0, [shortTokenId0])).toString(),
        ",",
        (await pool.checkCollateral(writor, 95000 + i, 1, [shortTokenId0])).toString(),
      );
    }
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);

    // OTM strangle, no capital efficiency
    shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 200,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
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

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1,
        5000000000,
        0,
        0,
      );

    for (let i = 0; i < 200000; i = i + 1000) {
      // Deposited shares = 1ETH + 3396 = 6773 at price=3396, collateral requirement = 10% of 3396 times 2 = ~671
      console.log(
        1.0001 ** (95000 + i),
        ",",
        (await pool.checkCollateral(writor, 95000 + i, 0, [shortTokenId0])).toString(),
        ",",
        (await pool.checkCollateral(writor, 95000 + i, 1, [shortTokenId0])).toString(),
      );
    }
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](shortTokenId0, 0, 0);
  });

  it("should allow long 2-legged ATM options, asset = 1 and collateral accurately tracked", async function () {
    const width = 24;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(3396e6);
    const amount1 = ethers.utils.parseEther("1");
    const positionSize0 = BigNumber.from(1000e6);
    const positionSize1 = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(
      await pool.collateralToken0(),
      liquidityProvider,
    ).deposit(amount0.mul(1000), await liquidityProvider.getAddress());
    await CollateralTracker__factory.connect(
      await pool.collateralToken1(),
      liquidityProvider,
    ).deposit(amount1.mul(1000), await liquidityProvider.getAddress());

    // mint short strangles
    let shortTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(liquidityProvider)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        positionSize1.mul(10),
        5000000000,
        0,
        0,
      );

    let shortTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 110,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 110,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0],
        0,
        5000000000,
        193000,
        197000,
      ),
    ).to.be.reverted;
    await pool
      .connect(liquidityProvider)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0, shortTokenId1],
        positionSize1.mul(10),
        5000000000,
        0,
        0,
      );

    // quasi-straddle
    let shortTokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 0,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 10,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(liquidityProvider)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0, shortTokenId1, shortTokenId2],
        positionSize1.mul(10),
        5000000000,
        0,
        0,
      );

    //inverted
    let shortTokenId3 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 110,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 110,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(liquidityProvider)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0, shortTokenId1, shortTokenId2, shortTokenId3],
        positionSize1.mul(10),
        5000000000,
        0,
        0,
      );

    //very inverted
    let shortTokenId4 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 240,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await pool
      .connect(liquidityProvider)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId0, shortTokenId1, shortTokenId2, shortTokenId3, shortTokenId4],
        positionSize1.mul(10),
        5000000000,
        0,
        0,
      );

    // OTM long strangle
    let longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [longTokenId0],
          positionSize1,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6770 at price=3396, collateral requirement = slightly more than ~10% of 3396 = ~335
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6789613626,335521506");

    // Deposited shares = 1ETH + 3396 - swap = 1.993ETH at price=3396, collateral requirement = slightly less than 10% of 1ETH = 0.1
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1999212163352262945,98794823161603889");

    await expect(
      pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](longTokenId0, 196000, 197000),
    ).to.be.revertedWith("PriceBoundFail()");
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // ITM long strangle, put side
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 110,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [longTokenId0],
          positionSize1,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6770 at price=3396, collateral requirement = slightly more than ~10% of 3396 = ~335
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("3355832233,335521511");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // ITM long strangle, call side
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 110,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [longTokenId0],
          positionSize1,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6770 at price=3396, collateral requirement = slightly more than ~10% of 3396 = ~335
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6751373781,337857721");

    // Deposited shares = 1ETH + 3396 - swap = 1.993ETH at price=3396, collateral requirement = slightly less than 10% of 1ETH = 0.1
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1987952382408729693,99482725149474255");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // ITM long strangle, both sides
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 110,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 110,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [longTokenId0],
          positionSize1,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6752 at price=3396, collateral requirement = slightly more than ~10% of 3396 = ~335
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6751377197,337857738");

    // Deposited shares = 1ETH + 3396 - swap = 1.988ETH at price=3396, collateral requirement = slightly less than 10% of 1ETH = 0.1
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [longTokenId0])).toString(),
    ).to.equal("1987953388215896546,99482730102727248");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // ITM long straddle
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 0,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 10,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [longTokenId0],
          positionSize1,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6751 at price=3396, collateral requirement = slightly more than ~10% of 3396 = ~335
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6741318910,339546809");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC

    // ITM long straddle
    longTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 240,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [longTokenId0],
          positionSize1,
          5000000000,
          196000,
          197000,
        ),
    ).to.be.revertedWith("PriceBoundFail()'");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longTokenId0],
        positionSize1,
        5000000000,
        193000,
        197000,
      );

    // Deposited shares = 1ETH + 3396 - swap = 6751 at price=3396, collateral requirement = slightly more than ~10% of 3396 = ~335
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [longTokenId0])).toString(),
    ).to.equal("6664929011,343843308");

    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](longTokenId0, 0, 0);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken0.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "withdraw(uint256,address,address)"
    ](
      await collateraltoken1.maxWithdraw(await optionWriter.getAddress()),
      await optionWriter.getAddress(),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("6792144616,0"); // lost commission 18 USDC
  });

  it.only("should allow to mint 2-leg long call spread USDC option, asset = 1", async function () {
    const width = 2;
    let strike = tick + 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    const shortTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 50,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 150,
        long: false,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 350,
        long: false,
        tokenType: 0,
        riskPartner: 3,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId],
        positionSize.mul(10),
        5000000000,
        0,
        0,
      );

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    console.log("spread1");
    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      5000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();

    console.log("Gas used = ", receipt.gasUsed.toNumber());

    // Deposited shares, defined risk collateral requirement = 3364 - 3347 = 17 * 10**6
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [tokenId])).toString(),
    ).to.equal("440020454157,33558076");

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("967267668763"); // 1_100_000 - 33640 - 33470  - 33140 - 32160 +  3364 - 3347 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1100000000000000010000");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100000009995");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100000000000000010000");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("132732341232"); // 33640 + 33470 + 33140 + 32160 + 3364 - 3347 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("1206"); // 1,100,000 USDC deposited, 133256 moved  = 12.06% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); //
  });

  it.only("should allow to mint 2-leg long call spread USDC option, asset = 0", async function () {
    const width = 2;
    let strike = tick + 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = BigNumber.from(3_396e6);

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    const shortTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike,
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
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 150,
        long: false,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 350,
        long: false,
        tokenType: 0,
        riskPartner: 3,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId],
        positionSize.mul(10),
        5000000000,
        0,
        0,
      );

    // Deposited shares, collateral requirement = 20% of 132410 = ~26428
    //expect(
    //  (
    //    await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId])
    //  ).toString()
    //).to.equal("4395732235621,27167999999");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 50,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    console.log("spread0");
    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      5000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();

    console.log("Gas used = ", receipt.gasUsed.toNumber());

    // Deposited shares, defined risk collateral requirement = 3364 - 3347 = 17 * 10**6
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [tokenId])).toString(),
    ).to.equal("440020662718,30571086");

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("964160009999"); // 1_100_000 - 33640 - 33470  - 33140 - 32160 +  3364 - 3347 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1100000000000000010000");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100000009999");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100000000000000010000");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("135840000000"); // 33640 + 33470 + 33140 + 32160 + 3364 - 3347 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("1234"); // 1,100,000 USDC deposited, 133256 moved  = 12.06% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); //
  });

  it.only("should allow to mint 2-leg long put spread USDC option, asset = 1", async function () {
    const width = 2;
    let strike = tick + 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    const shortTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 50,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 150,
        long: false,
        tokenType: 1,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 350,
        long: false,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId],
        positionSize.mul(10),
        5000000000,
        0,
        0,
      );

    const tokenId = OptionEncoding.encodeID(poolId, [
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
        strike: strike + 50,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("spread1");
    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      5000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();

    console.log("Gas used = ", receipt.gasUsed.toNumber());

    // Deposited shares, defined risk collateral requirement = 3364 - 3347 = 17 * 10**6
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [tokenId])).toString(),
    ).to.equal("129569834358737909235,9002087409912966");

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1100000010000"); // 1_100_000 - 33640 - 33470  - 33140 - 32160 +  3364 - 3347 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1060893991574045071529");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100000010000");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100893991574045071529");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); // 33640 + 33470 + 33140 + 32160 + 3364 - 3347 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("40000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); // 1,100,000 USDC deposited, 133256 moved  = 12.06% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("363"); //
  });

  it.only("should allow to mint 2-leg long put spread USDC option, asset = 0", async function () {
    const width = 2;
    let strike = tick + 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = BigNumber.from(3_396e6);

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    const shortTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 50,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 150,
        long: false,
        tokenType: 1,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 350,
        long: false,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId],
        positionSize.mul(10),
        5000000000,
        0,
        0,
      );

    // Deposited shares, collateral requirement = 20% of 132410 = ~26428
    //expect(
    //  (
    //    await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId])
    //  ).toString()
    //).to.equal("4395732235621,27167999999");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 50,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("spread0");
    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      5000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();

    console.log("Gas used = ", receipt.gasUsed.toNumber());

    // Deposited shares, defined risk collateral requirement = 3364 - 3347 = 17 * 10**6
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [tokenId])).toString(),
    ).to.equal("129570024834772311155,10118778532267570");

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1100000009999"); // 1_100_000 - 33640 - 33470  - 33140 - 32160 +  3364 - 3347 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1059978340072703645791");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100000009999");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100922098813341685393");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); // 33640 + 33470 + 33140 + 32160 + 3364 - 3347 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("40943758740638039602");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); // 1,100,000 USDC deposited, 133256 moved  = 12.06% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("371"); //
  });

  it.only("should allow to a calendar spread, asset = 0", async function () {
    const width = 10;
    let strike = tick + 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = BigNumber.from(3_396e6);

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    const shortTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 50,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 150,
        long: false,
        tokenType: 1,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 350,
        long: false,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId],
        positionSize.mul(10),
        5000000000,
        0,
        0,
      );

    // Deposited shares, collateral requirement = 20% of 132410 = ~26428
    //expect(
    //  (
    //    await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId])
    //  ).toString()
    //).to.equal("4395732235621,27167999999");

    let tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width: 10 * width,
        ratio: 1,
        asset: 0,
        strike: strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("calendar-spread0");
    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      5000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();

    console.log("Gas used = ", receipt.gasUsed.toNumber());

    // Deposited shares, defined risk collateral requirement = 3364 - 3347 = 17 * 10**6
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [tokenId])).toString(),
    ).to.equal("129573104888180532934,18169215473079226");

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1100000010000"); // 1_100_000 - 33640 - 33470  - 33140 - 32160 +  3364 - 3347 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1059986477737636762486");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100000010000");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100925177089008667248");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); // 33640 + 33470 + 33140 + 32160 + 3364 - 3347 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("40938699351371904762");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); // 1,100,000 USDC deposited, 133256 moved  = 12.06% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("371"); //

    await pool["burnOptions(uint256[],int24,int24)"]([tokenId], 0, 0);

    tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike,
        long: true,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width: 50 * width,
        ratio: 1,
        asset: 0,
        strike: strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    console.log("calendar-spread0");
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      5000000000,
      0,
      0,
    );

    // Deposited shares, defined risk collateral requirement = 3364 - 3347 = 17 * 10**6
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 1, [tokenId])).toString(),
    ).to.equal("129620561922474632398,98416583812555378");
  });

  it.only("should allow to mint synthetic longs/shorts, asset = 1", async function () {
    const width = 2;
    let strike = tick + 100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    const shortTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 50,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 150,
        long: false,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 350,
        long: false,
        tokenType: 0,
        riskPartner: 3,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId],
        positionSize.mul(10),
        5000000000,
        0,
        0,
      );

    // Deposited shares, collateral requirement = 20% of 132410 = ~26428
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [shortTokenId])).toString(),
    ).to.equal("4395732522921,26549824051");

    const lowCapSynLong = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: 4,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [lowCapSynLong],
      positionSize,
      5000000000,
      0,
      0,
    );

    // Deposited shares, collateral requirement = 20% of 132410 = ~26428
    expect((await pool.checkCollateral(depositor, tick, 0, [lowCapSynLong])).toString()).to.equal(
      "440020438904,1009311602",
    );

    await pool["burnOptions(uint256[],int24,int24)"]([lowCapSynLong], 0, 0);

    const highCapSynLong = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width: 4,
        ratio: 1,
        asset: 1,
        strike: strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [highCapSynLong],
        positionSize,
        5000000000,
        0,
        0,
      ),
    ).to.be.revertedWith("InvalidTokenIdParameter(5)");
  });

  it.only("should allow to mint 2-leg long ITM put spread USDC option, asset = 0", async function () {
    const width = 2;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = ethers.utils.parseEther("1");

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(500),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(500),
      await optionWriter.getAddress(),
    );

    const shortTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 10,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 50,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 150,
        long: false,
        tokenType: 0,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 350,
        long: false,
        tokenType: 0,
        riskPartner: 3,
      },
    ]);

    console.log("here?");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortTokenId],
        positionSize.mul(250),
        5000000000,
        0,
        0,
      );

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 150,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 350,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    for (let i = 0; i++; i < 5) {
      console.log("here2?");
      console.log(i / 10);
      await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize.mul(i + 1).div(10),
        5000000000,
        0,
        0,
      );
      await pool["burnOptions(uint256[],int24,int24)"]([tokenId], 0, 0);
    }
    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize.mul(155),
      8294967295,
      0,
      0,
    );
    //console.log("Gas used = ", receipt.gasUsed.toNumber());

    // Deposited shares, defined risk collateral requirement = 3364 - 3347 = 17 * 10**6
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [tokenId])).toString(),
    ).to.equal("449770689677,21601343915");

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("46697066493170"); // 1_100_000 - 33640 - 33470  - 33140 - 32160 +  3364 - 3347 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("50100000000000000010001");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("50154255681608");
    expect((await pool.poolData(1))[1].toString()).to.equal("50100000000000000010001");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("3457189188438"); // 33640 + 33470 + 33140 + 32160 + 3364 - 3347 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("689"); // 1,100,000 USDC deposited, 133256 moved  = 12.06% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); //

    const tokenId3 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 3,
        asset: 1,
        strike: strike - 150,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 3,
        asset: 1,
        strike: strike - 350,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId, tokenId3],
      positionSize.mul(25),
      190930818885,
      0,
      0,
    );

    // Deposited shares, defined risk collateral requirement = 3364 - 3347 = 17 * 10**6
    expect(
      (await pool.checkCollateral(deployer.getAddress(), tick, 0, [tokenId, tokenId3])).toString(),
    ).to.equal("421329411262,32402015874");
  });

  it("should allow to mint strangle with co-collateral, asset = 0", async function () {
    const width = 2;
    let strike = tick + 5;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = BigNumber.from(1000e6);

    // Deposit amounts
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // create tokenId for short strangle, no cross collateralization
    const strangleTokenId = OptionEncoding.encodeID(poolId, [
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
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    console.log("strike = ", strike - 100);
    console.log("strike = ", strike + 100);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [strangleTokenId],
        positionSize,
        5000000000,
        0,
        0,
      );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1099003396129"); // 1_100_000 - 1_000  USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1099709361537848626864"); // 1100 - 1000/3428 ETH (3428 = strike - 100)

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100001000004428773895");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("1000000000"); // 3361 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("291638466580147031"); // 1000/3428 = 0.29164

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("9"); // 1,100,000 USDC deposited, 1000 moved  = 0.909% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("2"); // 1_100 ETH deposited, 0.3 ETH moved: 0.265i% (rounded down)

    // Deposited shares, collateral requirement = 20% of 1000 = ~200 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [strangleTokenId])
      ).toString(),
    ).to.equal("4396143530910,398089281");

    // Deposited shares, collateral requirement = 20% of 0.29164ETH = 0.538ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [strangleTokenId])
      ).toString(),
    ).to.equal("1294451216646578046437,117218000583967294");

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

    // console.log("upperTick", strike + 5);
    // console.log("lowerTick", strike - 5);

    const slot0_ = await uniPool.slot0();

    const pc = UniswapV3.priceFromTick(tick);
    // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    // newPrice = 3122, strike = 3361, collateral requirement = 1000*(1-0.8*3122/3361) = ~256 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [strangleTokenId])
      ).toString(),
    ).to.equal("4121909169135,439005121");

    // Deposited shares, collateral requirement = 20% of 0.29164ETH = 0.0583ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 1, [strangleTokenId])
      ).toString(),
    ).to.equal("1320316373706511503519,140620675053739330");

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    // Deposited shares, collateral requirement = 20% of 3361 = ~672 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [strangleTokenId])
      ).toString(),
    ).to.equal("5445209996047,696394592");

    // new price = 192325 = 4444, strike = 3429 , collateral requirement = 1ETH*(1-0.8*(3429/4444)) = 0.3827ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 1, [strangleTokenId])
      ).toString(),
    ).to.equal("1224960905445341192758,156661754240168333");

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;
    console.log("newprice = ", currentTick);

    // Burn the position
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](strangleTokenId, 0, 0);

    // Deposited shares + fees, collateral requirement = 0
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("4396145532357,0");

    // Deposited shares, collateral requirement = 0
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [])).toString(),
    ).to.equal("1294451805975877056400,0");

    const efficientStrangleTokenId = OptionEncoding.encodeID(poolId, [
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
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const resolved = await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [efficientStrangleTokenId],
        positionSize,
        5000000000,
        0,
        0,
      );
    const receipt = await resolved.wait();

    console.log("Gas used = ", receipt.gasUsed.toNumber());

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1099004396628"); // 1_100_000 -1000 + fees  USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1099709656269276079883"); // 1100 -0.29164 + fees

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100004396626"); //1_100_000 + fees
    expect((await pool.poolData(1))[1].toString()).to.equal("1100001294735856226912"); // 1100 ETH + fees

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("1000000000"); // 1000 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("291638466580147031"); // 0.29164 ETH

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("2");
    expect((await pool.poolData(1))[3].toString()).to.equal("2");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("9"); // 1,100,000 USDC deposited, 3361 moved  = 30.05% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("2"); // 1_100 ETH deposited, 1 ETH moved: 9.09% (rounded down)

    // Deposited shares, collateral requirement = 1/2 of 20% of 1000 = ~100 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [efficientStrangleTokenId])
      ).toString(),
    ).to.equal("4396144446630,198746073");

    // Deposited shares, collateral requirement = 1/2 of 20% of .29164ETH = 0.029164ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [efficientStrangleTokenId])
      ).toString(),
    ).to.equal("1294451486281899525928,58521086791538610");

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [efficientStrangleTokenId],
        0,
        5000000000,
        193000,
        197000,
      ),
    ).to.be.reverted;
    await pool
      .connect(optionWriter)
      ["burnOptions(uint256,int24,int24)"](efficientStrangleTokenId, -800000, 800000);

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1100004896877"); // 1_100_000 + fees  USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1099947445342297429161"); // 1100 - swapFees (?)

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100004896874"); //1_100_000 + fees
    expect((await pool.poolData(1))[1].toString()).to.equal("1099947445342297429159"); // 1100 ETH - swapFees(?)

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("0"); // 0 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("0"); // 0 ETH

    expect((await collatToken0.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "999988500779", // 1_000_000 deposited - 10.5 USDC from swap TODO: check
    );
    expect((await collatToken1.balanceOf(optionWriter.getAddress())).toString()).to.equal(
      "999942705413609330529", // check! 1000 ETH deposited + 0.2344ETH from swap
    );
  });

  it("should allow to mint strangle with co-collateral, asset = 1", async function () {
    const width = 2;
    let strike = tick + 5;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = ethers.utils.parseEther("1");

    // Deposit amounts
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // create tokenId for short strangle, no cross collateralization
    const strangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 100,
        long: false,
        tokenType: 1,
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

    console.log("strike = ", strike - 100);
    console.log("strike = ", strike + 100);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [strangleTokenId],
        positionSize,
        5000000000,
        0,
        0,
      );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1096642386640"); // 1_100_000 - 3361  USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1099001000004428773898"); // 1100 - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100003396128");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100001000004428773898");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("3361009488"); // 3361 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("30"); // 1,100,000 USDC deposited, 3361 moved  = 30.05% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("9"); // 1_100 ETH deposited, 1 ETH moved: 9.09% (rounded down)

    // Deposited shares, collateral requirement = 20% of 3361 = ~672 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [strangleTokenId])
      ).toString(),
    ).to.equal("4396140930795,1351430820");

    // Deposited shares, collateral requirement = 20% of 1ETH = 0.2ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [strangleTokenId])
      ).toString(),
    ).to.equal("1294450451038958118657,397930881302143742");

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

    // console.log("upperTick", strike + 5);
    // console.log("lowerTick", strike - 5);

    const slot0_ = await uniPool.slot0();

    const pc = UniswapV3.priceFromTick(tick);
    // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
    console.log("initial tick", slot0_.tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    // newPrice = 3122, strike = 3361, collateral requirement = 3361*(1-0.8*3122/3361) = ~863 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [strangleTokenId])
      ).toString(),
    ).to.equal("4121906674981,1487863360");

    // Deposited shares, collateral requirement = 20% of 1ETH = 0.2ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 1, [strangleTokenId])
      ).toString(),
    ).to.equal("1320315574787292822754,476587492776831014");

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    // Deposited shares, collateral requirement = 20% of 3361 = ~672 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [strangleTokenId])
      ).toString(),
    ).to.equal("5444762514154,2373846304");

    // new price = 192325 = 4444, strike = 3429 , collateral requirement = 1ETH*(1-0.8*(3429/4444)) = 0.3827ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 1, [strangleTokenId])
      ).toString(),
    ).to.equal("1224982725411404569625,534076685311691469");

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;
    console.log("newprice = ", currentTick);

    // Burn the position
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](strangleTokenId, 0, 0);

    // Deposited shares, collateral requirement = 0
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("4396147725290,0");

    // Deposited shares, collateral requirement = 0
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [])).toString(),
    ).to.equal("1294452451688230882753,0");

    const efficientStrangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 100,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const resolved = await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [efficientStrangleTokenId],
        positionSize,
        5000000000,
        0,
        0,
      );
    const receipt = await resolved.wait();

    console.log("Gas used = ", receipt.gasUsed.toNumber());

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1096645783293"); // 1_100_000 + fees - 3361  USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1099002000504678898959"); // 1100 + fees - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100006792779"); //1_100_000 + fees
    expect((await pool.poolData(1))[1].toString()).to.equal("1100002000504678898957"); // 1100 ETH + fees

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("3361009488"); // 3361 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000"); // 1 ETH

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("2");
    expect((await pool.poolData(1))[3].toString()).to.equal("2");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("30"); // 1,100,000 USDC deposited, 3361 moved  = 30.05% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("9"); // 1_100 ETH deposited, 1 ETH moved: 9.09% (rounded down)

    var slotd_ = await uniPool.slot0();

    var currentTick = slotd_.tick;

    // Deposited shares, collateral requirement = 1/2 of 20% of 3361 = ~336 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [
          efficientStrangleTokenId,
        ])
      ).toString(),
    ).to.equal("4381910855570,673280654");

    // Deposited shares, collateral requirement = 1/2 of 20% of 1ETH = 0.1ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 1, [
          efficientStrangleTokenId,
        ])
      ).toString(),
    ).to.equal("1295690601105929797489,199082876081216383");

    for (let j = 0; j < 10; j++) {
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsS);
      await swapRouter.connect(swapper).exactInputSingle(paramsB);
    }

    slotd_ = await uniPool.slot0();

    var currentTick = slotd_.tick;

    // Deposited shares, collateral requirement = 1/2 of 20% of 3361 = ~336 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [
          efficientStrangleTokenId,
        ])
      ).toString(),
    ).to.equal("4364371436682,671529343");

    // Deposited shares, collateral requirement = 1/2 of 20% of 1ETH = 0.1ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 1, [
          efficientStrangleTokenId,
        ])
      ).toString(),
    ).to.equal("1297232120103249227535,199600205060518428");

    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), currentTick, [
          efficientStrangleTokenId,
        ])
      ).toString(),
    ).to.be.equal("0,0");
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(optionWriter.getAddress(), [
          efficientStrangleTokenId,
        ])
      ).toString(),
    ).to.be.equal("33927417,10005002501250622");
  });

  it.only("should allow to mint ITM strangle with co-collateral, asset = 1", async function () {
    const width = 2;
    let strike = tick + 5;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = ethers.utils.parseEther("1");

    // Deposit amounts
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // create tokenId for short strangle, no cross collateralization
    const gutsTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 100,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
    ]);

    console.log("strike = ", strike - 100);
    console.log("strike = ", strike + 100);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [gutsTokenId],
        positionSize,
        5000000000,
        0,
        0,
      );

    // Panoptic Pool Balance:
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [gutsTokenId])).toString(),
    ).to.equal("4396608190138,1419324287");

    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), tick, [gutsTokenId])
      ).toString(),
    ).to.be.equal("-19991335665585259,-67893467");
    //expect((await pool.calculateAccumulatedFeesBatch(optionWriter.getAddress(), [gutsTokenId])).toString()).to.be.equal("0,0");

    // Burn the position
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](gutsTokenId, 0, 0);
    // create tokenId for short strangle, no cross collateralization
    const strangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 100,
        long: false,
        tokenType: 1,
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

    console.log("strike = ", strike - 100);
    console.log("strike = ", strike + 100);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [strangleTokenId],
        positionSize,
        5000000000,
        0,
        0,
      );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1096635616138"); // 1_100_000 - 3361  USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1098999006380984815813"); // 1100 - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1099996625626");
    expect((await pool.poolData(1))[1].toString()).to.equal("1099999006380984815813");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("3361009488"); // 3361 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("30"); // 1,100,000 USDC deposited, 3361 moved  = 30.05% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("9"); // 1_100 ETH deposited, 1 ETH moved: 9.09% (rounded down)

    // Deposited shares, collateral requirement = 20% of 3361 = ~672 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [strangleTokenId])
      ).toString(),
    ).to.equal("4396536303919,1351430820");

    // Burn the position
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](strangleTokenId, 0, 0);

    // Deposited shares, collateral requirement = 0
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("4396536303919,0");

    const efficientGutsTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const resolved = await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [efficientGutsTokenId],
        positionSize,
        5000000000,
        0,
        0,
      );
    const receipt = await resolved.wait();

    console.log("Gas used = ", receipt.gasUsed.toNumber());

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1096598818418"); // 1_100_000 + fees - 3361  USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1099008846292054454028"); // 1100 + fees - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100027721373"); //1_100_000 + fees
    expect((await pool.poolData(1))[1].toString()).to.equal("1100008846292054454028"); // 1100 ETH + fees

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("3428902955"); // 3361 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000"); // 1 ETH

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("31"); // 1,100,000 USDC deposited, 3361 moved  = 30.05% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("9"); // 1_100 ETH deposited, 1 ETH moved: 9.09% (rounded down)

    var slotd_ = await uniPool.slot0();

    var currentTick = slotd_.tick;

    // Deposited shares, collateral requirement = 1/2 of 20% of 3361 = ~336 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [
          efficientGutsTokenId,
        ])
      ).toString(),
    ).to.equal("4396600191585,735795774");

    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), currentTick, [
          efficientGutsTokenId,
        ])
      ).toString(),
    ).to.be.equal("-19991335665585259,-67893467");
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(optionWriter.getAddress(), [efficientGutsTokenId])
      ).toString(),
    ).to.be.equal(
      "0,0,717769336303573713979969254828460583970566126,56493915618480126885070858183418090112286811830561125171200",
    );

    // Burn the position
    await pool
      .connect(optionWriter)
      ["burnOptions(uint256,int24,int24)"](efficientGutsTokenId, 0, 0);

    const efficientStrangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 100,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 100,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [efficientStrangleTokenId],
        positionSize,
        5000000000,
        0,
        0,
      );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1096632231764"); // 1_100_000 + fees - 3361  USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1098998012761969627050"); // 1100 + fees - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1099993241252"); //1_100_000 + fees
    expect((await pool.poolData(1))[1].toString()).to.equal("1099998012761969627050"); // 1100 ETH + fees

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("3361009488"); // 3361 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000"); // 1 ETH

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("30"); // 1,100,000 USDC deposited, 3361 moved  = 30.05% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("9"); // 1_100 ETH deposited, 1 ETH moved: 9.09% (rounded down)

    var slotd_ = await uniPool.slot0();

    var currentTick = slotd_.tick;

    // Deposited shares, collateral requirement = 1/2 of 20% of 3361 = ~336 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [
          efficientStrangleTokenId,
        ])
      ).toString(),
    ).to.equal("4396528305362,674701837");

    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), currentTick, [
          efficientStrangleTokenId,
        ])
      ).toString(),
    ).to.be.equal("0,0");
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(optionWriter.getAddress(), [
          efficientStrangleTokenId,
        ])
      ).toString(),
    ).to.be.equal(
      "0,0,717773589833160225695650974265870616389382126,56493915618480126884730575816497151648823437223129356959744",
    );

    // Burn the position
    await pool
      .connect(optionWriter)
      ["burnOptions(uint256,int24,int24)"](efficientStrangleTokenId, 0, 0);
  });

  it("multiple positions collateral tracking", async function () {
    const width = 10;
    let strike = tick + 5;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = ethers.utils.parseEther("1");

    // Deposit amounts
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(10),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(10),
      await optionWriter.getAddress(),
    );

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // create tokenId for short strangles
    const strangleTokenId0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 500,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 500,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const strangleTokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 1000,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 1000,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const strangleTokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 200,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const strangleTokenId3 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 800,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 200,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [strangleTokenId0],
        positionSize,
        5000000000,
        0,
        0,
      );
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [strangleTokenId0, strangleTokenId1],
        positionSize,
        5000000000,
        0,
        0,
      );
    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [strangleTokenId0, strangleTokenId1, strangleTokenId2],
        0,
        5000000000,
        0,
        0,
      ),
    ).to.be.reverted;
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [strangleTokenId0, strangleTokenId1, strangleTokenId2],
        positionSize,
        5000000000,
        0,
        0,
      );
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [strangleTokenId0, strangleTokenId1, strangleTokenId2, strangleTokenId3],
        positionSize,
        5000000000,
        0,
        0,
      );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1086977040535"); // 1_100_000 - 3361  USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1096002183048710357790"); // 1100 - 1 ETH

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100068945441");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100002183048710357790");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("13091904906"); // 3361 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("4000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("119");
    expect((await pool.poolData(1))[4].toString()).to.equal("36");

    // Deposited shares, collateral requirement = 20% of 3361 = ~672 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.equal("4396198403518,2703211705");

    // Deposited shares, collateral requirement = 20% of 1ETH = 0.2ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.equal("1294467373970297002999,795964839826030518");

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    expect(
      (
        await pool.calculatePortfolioValue(writor, currentTick, [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.be.equal("-21249976717983720,-72167994");
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(writor, [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.be.equal("636,100861700611"); //TODO: what?

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

    // console.log("upperTick", strike + 5);
    // console.log("lowerTick", strike - 5);

    const slot0_ = await uniPool.slot0();

    const pc = UniswapV3.priceFromTick(tick);
    // console.log("initial price=", 10 ** (decimalWETH - decimalUSDC) / pc);
    console.log("initial tick", slot0_.tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    // newPrice = 3122, strike = 3361, collateral requirement = 3361*(1-0.8*3122/3361) = ~863 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.equal("4121964321863,3057197259");

    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), currentTick, [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.be.equal("-209624563492972159,-654429065");
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(optionWriter.getAddress(), [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.be.equal("636,1270690281275953");

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    // Deposited shares, collateral requirement = 20% of 3361 = ~672 (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 0, [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.equal("5446060952324,5769874336");

    // new price = 192325 = 4444, strike = 3429 , collateral requirement = 1ETH*(1-0.8*(3429/4444)) = 0.3827ETH (second value)
    expect(
      (
        await pool.checkCollateral(optionWriter.getAddress(), currentTick, 1, [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.equal("1225029834596224700938,1297867994085972157");

    expect(
      (
        await pool.calculatePortfolioValue(optionWriter.getAddress(), currentTick, [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.be.equal("-762472534909170712,-3389690424");
    expect(
      (
        await pool.calculateAccumulatedFeesBatch(optionWriter.getAddress(), [
          strangleTokenId0,
          strangleTokenId1,
          strangleTokenId2,
          strangleTokenId3,
        ])
      ).toString(),
    ).to.be.equal("12213281,1270690281275953");

    await swapRouter.connect(swapper).exactInputSingle(paramsS);
    await swapRouter.connect(swapper).exactInputSingle(paramsS);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;
    console.log("newprice = ", currentTick);

    // Burn the position
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](strangleTokenId0, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](strangleTokenId1, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](strangleTokenId2, 0, 0);
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](strangleTokenId3, 0, 0);

    // Deposited shares, collateral requirement = 0
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 0, [])).toString(),
    ).to.equal("4396139929046,0");

    // Deposited shares, collateral requirement = 0
    expect(
      (await pool.checkCollateral(optionWriter.getAddress(), tick, 1, [])).toString(),
    ).to.equal("1294450156072284287886,0");
  });

  it("long options value tracking", async function () {
    const width = 10;
    let strike = tick + 5;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");
    const positionSize = ethers.utils.parseEther("1");

    // Deposit amounts
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(100),
      await optionBuyer.getAddress(),
    );

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // create tokenId for short strangles
    const shortStrangle = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 500,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 500,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const longPut = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 500,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    const longCall = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 500,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortStrangle],
        positionSize.mul(3),
        5000000000,
        0,
        0,
      );

    await expect(
      pool
        .connect(optionBuyer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"]([longPut], positionSize, 10490, 0, 0),
    ).to.be.revertedWith("EffectiveLiquidityAboveThreshold(2147483647, 10490, 23897050709029204)");
    await pool
      .connect(optionBuyer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longPut],
        positionSize,
        21474836470,
        0,
        0,
      );

    // Deposited shares, collateral requirement = 20% of 3361 = ~672 (second value)
    expect(
      (await pool.checkCollateral(optionBuyer.getAddress(), tick, 0, [longPut])).toString(),
    ).to.equal("43961495259033,339614461");

    // Deposited shares, collateral requirement = 20% of 1ETH = 0.2ETH (second value)
    expect(
      (await pool.checkCollateral(optionBuyer.getAddress(), tick, 1, [longPut])).toString(),
    ).to.equal("12944529818815272871562,99999999999990428");

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    expect(
      (await pool.calculatePortfolioValue(buyor, currentTick, [longPut])).toString(),
    ).to.be.equal("0,0");
    expect((await pool.calculateAccumulatedFeesBatch(buyor, [longPut])).toString()).to.be.equal(
      "0,0",
    );

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
    console.log("initial tick", slot0_.tick);

    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);
    await swapRouter.connect(swapper).exactInputSingle(paramsB);

    const slot1_ = await uniPool.slot0();
    const newPrice = Math.pow(1.0001, slot1_.tick);
    // console.log("new price =", 10 ** (decimalWETH - decimalUSDC) / newPrice);

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    expect(
      (await pool.calculatePortfolioValue(buyor, currentTick, [longPut])).toString(),
    ).to.be.equal("998228773795379872,2011324575000");

    // premium: effective liquidity factor - 1.05, amount deposited = 1 ETH / 1.0001**(strike-500)=3570, premia = 0.0005*3570*1.05=1.87USDC
    expect((await pool.calculateAccumulatedFeesBatch(buyor, [longPut])).toString()).to.be.equal(
      "-1896890,0",
    );

    // newPrice = 3122, strike = 3361, collateral requirement = 3361*(1-0.8*3122/3361) = ~863 (second value)
    expect((await pool.checkCollateral(buyor, currentTick, 0, [longPut])).toString()).to.equal(
      "20158946068032418,201491237590",
    );
  });

  it("iron condor value tracking", async function () {
    const width = 20;
    let strike = tick + 5;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(100_000e6);
    const amount1 = ethers.utils.parseEther("100");

    const positionSize0 = BigNumber.from(3396e6);
    const positionSize1 = ethers.utils.parseEther("1");

    // Deposit amounts
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress(),
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0.mul(100),
      await optionBuyer.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionBuyer).deposit(
      amount1.mul(100),
      await optionBuyer.getAddress(),
    );

    await collateraltoken0.deposit(amount0, depositor);
    await collateraltoken1.deposit(amount1, depositor);

    // create tokenId for short strangles
    const shortStrangleGuts = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const shortStrangleWings = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 750,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 750,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const shortIC0 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 750,
        long: true,
        tokenType: 1,
        riskPartner: 3,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 750,
        long: true,
        tokenType: 0,
        riskPartner: 2,
      },
    ]);

    const shortIC1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 250,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 250,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 750,
        long: true,
        tokenType: 1,
        riskPartner: 3,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 750,
        long: true,
        tokenType: 0,
        riskPartner: 2,
      },
    ]);

    console.log("p0");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortStrangleGuts],
        positionSize1.mul(10),
        5000000000,
        0,
        0,
      );
    console.log("p1");
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortStrangleGuts, shortStrangleWings],
        positionSize1.mul(10),
        5000000000,
        0,
        0,
      );
    console.log("p2");
    await pool
      .connect(optionBuyer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortIC0],
        positionSize0,
        5000000000,
        0,
        0,
      );

    var slotc_ = await uniPool.slot0();

    var currentTick = slotc_.tick;

    /*
     let v0 = 0;
     let v1 = 0;
     for (let t=strike-1250; t < strike + 1250; t = t+5) {
         [v0, v1] = await pool.calculatePortfolioValue(buyor, t, [shortIC0]);
         console.log(t, "\t", v0.toString(), "\t", v1.toString());
     }
    
     await pool.connect(optionBuyer)["burnOptions(uint256,int24,int24)"](shortIC0);

     console.log('');
     await pool.connect(optionBuyer)["mintOptions(uint256[],uint128,uint64,int24,int24)"]([shortIC1], positionSize1, 5000000000,0,0);

     v0 = 0;
     v1 = 0;
     for (let t=strike-1250; t < strike + 1250; t = t+5) {
         [v0, v1] = await pool.calculatePortfolioValue(buyor, t, [shortIC1]);
         console.log(t, "\t", v0.toString(), "\t", v1.toString());
     }
     */
  });
});
