/**
 * Test General Functions of the PanopticPool.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { deployments, ethers, hardhatArguments, network } from "hardhat";
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

const DAI_ADDRESS = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
const token2 = DAI_ADDRESS;

describe("General", async function () {
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

  describe("General tests", async function () {
    it("Should fail as expected on withdraw", async () => {
      await expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
          "redeem(uint256,address,address,uint256[])"
        ](200, depositor, depositor, [1, 2]),
      ).to.be.revertedWith(revertCustom(`InputListFail()`));
    });
    it("Should return expected name", async () => {
      await expect(
        await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).name(),
      ).to.be.equal("POPT-V1 USDC LP on USDC/WETH 5bps");
    });
    it("Should return expected symbol", async () => {
      await expect(
        await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).symbol(),
      ).to.be.equal("poUSDC");
    });
    it("Should return expected decimals", async () => {
      await expect(
        await CollateralTracker__factory.connect(
          await pool.collateralToken0(),
          deployer,
        ).decimals(),
      ).to.be.equal(6);
    });
    it("should return correct asset", async () => {
      await expect(
        await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).asset(),
      ).to.be.equal(USDC_ADDRESS);
    });
    it("should transfer correctly", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        "100000000",
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).transfer(
        await liquidityProvider.getAddress(),
        100,
      );
      await expect(
        await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).balanceOf(
          await liquidityProvider.getAddress(),
        ),
      ).to.be.equal(100);
      await expect(
        await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).balanceOf(
          depositor,
        ),
      ).to.be.equal(99999900);
    });
    it("should fail transfer if insufficient balance", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        "100000000",
        depositor,
      );
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).transfer(
          await liquidityProvider.getAddress(),
          100000001,
        ),
      ).to.be.reverted;
    });
    it("should fail transfer with open positions", async () => {
      const width = 2;
      let strike = tick + 1;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(3396114535);
      const amount1 = ethers.utils.parseEther("1");
      const positionSize = ethers.utils.parseEther("1");

      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        amount0,
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1,
        depositor,
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
      ]);
      await pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId],
          positionSize.div(10),
          20000,
          0,
          0,
        );
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).transfer(
          await liquidityProvider.getAddress(),
          100,
        ),
      ).to.be.reverted;
    });

    it("should transferFrom correctly", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        "100000000",
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).approve(
        await liquidityProvider.getAddress(),
        100,
      );
      await CollateralTracker__factory.connect(
        await pool.collateralToken0(),
        liquidityProvider,
      ).transferFrom(depositor, await liquidityProvider.getAddress(), 100);
      await expect(
        await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).balanceOf(
          await liquidityProvider.getAddress(),
        ),
      ).to.be.equal(100);
      await expect(
        await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).balanceOf(
          depositor,
        ),
      ).to.be.equal(99999900);
    });

    it("should fail transferFrom if insufficient balance", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        "100000000",
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).approve(
        await liquidityProvider.getAddress(),
        100000001,
      );
      expect(
        CollateralTracker__factory.connect(
          await pool.collateralToken0(),
          liquidityProvider,
        ).transferFrom(depositor, await liquidityProvider.getAddress(), 100000001),
      ).to.be.reverted;
    });

    it("should fail transferFrom if insufficient allowance", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        "100000000",
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).approve(
        await liquidityProvider.getAddress(),
        99,
      );
      expect(
        CollateralTracker__factory.connect(
          await pool.collateralToken0(),
          liquidityProvider,
        ).transferFrom(depositor, await liquidityProvider.getAddress(), 100),
      ).to.be.reverted;
    });

    it("should fail transferFrom with open positions", async () => {
      const width = 2;
      let strike = tick + 1;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(3396114535);
      const amount1 = ethers.utils.parseEther("1");
      const positionSize = ethers.utils.parseEther("1");

      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        amount0,
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1,
        depositor,
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
      ]);
      await pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId],
          positionSize.div(10),
          20000,
          0,
          0,
        );
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).approve(
        await liquidityProvider.getAddress(),
        100,
      );
      expect(
        CollateralTracker__factory.connect(
          await pool.collateralToken0(),
          liquidityProvider,
        ).transferFrom(depositor, await liquidityProvider.getAddress(), 100),
      ).to.be.reverted;
    });

    it("should mint shares correctly", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).mint(
        100000000,
        depositor,
      );
      expect(await collatToken0.balanceOf(depositor)).to.be.equal(100000000);
    });
    it("should fail mint shares if insufficient balance", async () => {
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).mint(
          10000000000000000000000000000,
          depositor,
        ),
      ).to.be.reverted;
    });
    it("should fail mint shares if below minimum initial", async () => {
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).mint(
          999999,
          depositor,
        ),
      ).to.be.reverted;
    });
    it("should deposit assets correctly", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        100000000,
        depositor,
      );
      expect(await collatToken0.balanceOf(depositor)).to.be.equal(100000000);
    });
    it("should fail deposit assets if insufficient balance", async () => {
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
          10000000000000000000000000000,
          depositor,
        ),
      ).to.be.reverted;
    });
    it("should fail deposit assets if below minimum initial", async () => {
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
          999999,
          depositor,
        ),
      ).to.be.reverted;
    });
    it("should withdraw assets correctly", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        100000000,
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).withdraw(
        100000000,
        depositor,
        depositor,
      );
      expect(await collatToken0.balanceOf(depositor)).to.be.equal(0);
    });
    it("should fail withdraw assets if insufficient balance", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        100000000,
        depositor,
      );
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).withdraw(
          100000001,
          depositor,
          depositor,
        ),
      ).to.be.reverted;
    });
    it("should fail withdraw assets if insufficient allowance", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        100000000,
        depositor,
      );

      expect(
        CollateralTracker__factory.connect(
          await pool.collateralToken0(),
          liquidityProvider,
        ).withdraw(100000000, await liquidityProvider.getAddress(), depositor),
      ).to.be.reverted;
    });
    it("should fail withdraw assets with open positions", async () => {
      const width = 2;
      let strike = tick + 1;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(3396114535);
      const amount1 = ethers.utils.parseEther("1");
      const positionSize = ethers.utils.parseEther("1");

      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        amount0,
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1,
        depositor,
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
      ]);
      await pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId],
          positionSize.div(10),
          20000,
          0,
          0,
        );
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).withdraw(
          1000,
          depositor,
          depositor,
        ),
      ).to.be.reverted;
    });
    it("should redeem shares correctly", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        100000000,
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
        "redeem(uint256,address,address)"
      ](100000000, depositor, depositor);
      expect(await collatToken0.balanceOf(depositor)).to.be.equal(0);
    });
    it("should fail redeem shares if insufficient balance", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        100000000,
        depositor,
      );
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
          "redeem(uint256,address,address)"
        ](100000001, depositor, depositor),
      ).to.be.reverted;
    });
    it("should fail redeem shares if insufficient allowance", async () => {
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        100000000,
        depositor,
      );

      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), liquidityProvider)[
          "redeem(uint256,address,address)"
        ](100000000, await liquidityProvider.getAddress(), depositor),
      ).to.be.reverted;
    });
    it("should fail redeem shares with open positions", async () => {
      const width = 2;
      let strike = tick + 1;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(3396114535);
      const amount1 = ethers.utils.parseEther("1");
      const positionSize = ethers.utils.parseEther("1");

      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        amount0,
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1,
        depositor,
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
      ]);
      await pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId],
          positionSize.div(10),
          20000,
          0,
          0,
        );
      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
          "redeem(uint256,address,address)"
        ](1000, depositor, depositor),
      ).to.be.reverted;
    });
    it("should redeem shares with open positions correctly", async () => {
      const width = 2;
      let strike = tick + 1;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(3396114535);
      const amount1 = ethers.utils.parseEther("1");
      const positionSize = ethers.utils.parseEther("1");

      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        amount0,
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1,
        depositor,
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
      ]);
      await pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId],
          positionSize.div(10),
          20000,
          0,
          0,
        );
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
        "redeem(uint256,address,address,uint256[])"
      ](100000000, depositor, depositor, [shortTokenId]);
      expect(await collatToken0.balanceOf(depositor)).to.be.equal(3294115997);
    });
    it("should fail redeem shares with open positions if insufficient available balance", async () => {
      const width = 2;
      let strike = tick + 1;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(3396114535);
      const amount1 = ethers.utils.parseEther("1");
      const positionSize = ethers.utils.parseEther("1");

      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        amount0,
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1,
        depositor,
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
      ]);
      await pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId],
          positionSize.div(10),
          20000,
          0,
          0,
        );

      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer)[
          "redeem(uint256,address,address,uint256[])"
        ](3396114535, depositor, depositor, [shortTokenId]),
      ).to.be.reverted;
    });
    it("should fail redeem shares with open positions if insufficient allowance", async () => {
      const width = 2;
      let strike = tick + 1;
      strike = strike - (strike % 10);

      const amount0 = BigNumber.from(3396114535);
      const amount1 = ethers.utils.parseEther("1");
      const positionSize = ethers.utils.parseEther("1");

      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        amount0,
        depositor,
      );
      await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
        amount1,
        depositor,
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
      ]);
      await pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortTokenId],
          positionSize.div(10),
          20000,
          0,
          0,
        );

      expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), liquidityProvider)[
          "redeem(uint256,address,address,uint256[])"
        ](100000000, await liquidityProvider.getAddress(), depositor, [shortTokenId]),
      ).to.be.reverted;
    });

    it("Should fail when using the wrong offset in OptionPositionBalanceBatch", async () => {
      // tokens0 and 1 should not revert
      await expect(pool.optionPositionBalanceBatch((await deployer.getAddress()).toString(), [])).to
        .not.be.reverted;
    });
  });
});
