/**
 * Test Minting.
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

describe("Minting of Options", async function () {
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

  it("Should not allow minting of ITM put options using wrong tickLimits", async function () {
    const width = 10;
    let strike = tick + 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(10000000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 3,
        asset: 0,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        strike + 100,
        strike + 200,
      ),
    ).to.be.revertedWith(revertCustom("PriceBoundFail()"));

    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
  });

  it("Should not allow minting ITM call options using wrong tickLimits", async function () {
    const width = 10;
    let strike = tick - 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(10000000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 3,
        asset: 0,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        -800000,
        -700000,
      ),
    ).to.be.revertedWith(revertCustom("PriceBoundFail()"));

    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
  });

  it("Should not allow minting ITM put options with currentTick outside limits", async function () {
    const width = 10;
    let strike = tick + 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(10000000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 3,
        asset: 0,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        tick - 2222,
        tick - 2022,
      ),
    ).to.be.revertedWith(revertCustom("PriceBoundFail()"));

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        tick + 12323,
        tick + 12442,
      ),
    ).to.be.revertedWith(revertCustom("PriceBoundFail()"));

    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        strike - 12222,
        strike + 12442,
      ),
    ).to.emit(pool, "OptionMinted");
  });

  it("Should not allow minting ITM call options with currentTick outside tick limits", async function () {
    const width = 10;
    let strike = tick - 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(10000000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 3,
        asset: 0,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        tick - 2222,
        tick - 2022,
      ),
    ).to.be.revertedWith(revertCustom("PriceBoundFail()"));

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        tick + 12323,
        tick + 12442,
      ),
    ).to.be.revertedWith(revertCustom("PriceBoundFail()"));

    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        0,
        tick - 2222,
        tick + 12442,
      ),
    ).to.emit(pool, "OptionMinted");
  });

  it("Should not allow minting options with wrong poolId", async function () {
    const width = 10;
    let strike = tick - 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(10000000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const poolIdWrong = BigInt(depositor.slice(0, 22).toLowerCase());

    const tokenId = OptionEncoding.encodeID(poolIdWrong, [
      {
        width,
        ratio: 3,
        asset: 0,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        0,
        0,
      ),
    ).to.be.reverted;

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId2],
        positionSize,
        2000000000,
        0,
        0,
      ),
    ).to.emit(pool, "OptionMinted");

    await expect(pool["burnOptions(uint256,int24,int24)"](tokenId, 0, 0)).to.be.reverted;

    await expect(pool["burnOptions(uint256,int24,int24)"](tokenId2, 0, 0)).to.emit(
      pool,
      "OptionBurnt",
    );

    expect(await pool.positionsHash(depositor)).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
  });

  it("Should not allow minting options with no size or wrong positionIdList size", async function () {
    const width = 10;
    let strike = tick - 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(10000000e6);
    const amount1 = ethers.utils.parseEther("10");

    const positionSize = BigNumber.from(3396e6);
    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("10000000000000");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 3,
        asset: 0,
        strike,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"]([tokenId], 0, 0, 0, 0),
    ).to.be.revertedWith(revertCustom("OptionsBalanceZero()"));

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"]([], positionSize, 2000000000, 0, 0),
    ).to.be.reverted;

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId, tokenId],
        positionSize,
        2000000000,
        0,
        0,
      ),
    ).to.be.revertedWith(revertCustom("InputListFail()"));

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId, tokenId, tokenId],
        positionSize,
        2000000000,
        0,
        0,
      ),
    ).to.be.revertedWith(revertCustom("InputListFail()")); // incoming list is 3, stored is 1

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize,
        2000000000,
        0,
        0,
      ),
    ).to.emit(pool, "OptionMinted");

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 100,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId, tokenId],
        positionSize,
        2000000000,
        0,
        0,
      ),
    ).to.be.revertedWith(revertCustom("PositionAlreadyMinted()"));

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId2, tokenId],
        positionSize,
        2000000000,
        0,
        0,
      ),
    ).to.be.revertedWith(revertCustom("InputListFail()"));

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId],
        positionSize.mul(2),
        0,
        0,
        0,
      ),
    ).to.be.revertedWith(
      revertCustom("InputListFail()"), // this won't match what is stored, b/c the incoming list is empty (except the new position to mint)
    );

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId2],
        positionSize,
        2000000000,
        0,
        0,
      ),
    ).to.be.revertedWith(revertCustom("InputListFail()"));

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"]([tokenId, tokenId2], 0, 0, 0, 0),
    ).to.be.revertedWith(revertCustom("OptionsBalanceZero()"));

    await expect(
      pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId, tokenId2],
        positionSize,
        2000000000,
        0,
        0,
      ),
    ).to.emit(pool, "OptionMinted");
  });
  it("Should allow minting short call USDC option using token0 as asset", async function () {
    const width = 10;
    let strike = tick + 1200;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    // move 1 USDC to strike
    const positionSize = BigNumber.from(1e6);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress(),
    );

    const tokenId1 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId1],
      positionSize,
      2000000000,
      0,
      0,
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1010002396129"); // deposited balance - 1 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1010001000004428773891");

    // totalBalance: unchanged, contains balance of two depositors
    expect((await pool.poolData(0))[1].toString()).to.equal("1010003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("1010001000004428773891");

    // in AMM: about 1 ETH
    expect((await pool.poolData(0))[2].toString()).to.equal("1000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); // 1,010,000 USDC deposited, 1 moved  = 0.336% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); //

    // fees accumulation
    expect((await pool.calculateAccumulatedFeesBatch(depositor, [tokenId1])).toString()).to.equal(
      "0,0",
    );

    const tokenId2 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 2,
        asset: 0,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId2],
        positionSize,
        2000000000,
        0,
        0,
      );

    const tokenId3 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 800,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [tokenId1, tokenId3],
          positionSize,
          2000000000,
          0,
          0,
        ),
    ).to.be.revertedWith("InputListFail()");

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId2, tokenId3],
        positionSize,
        2000000000,
        0,
        0,
      );

    const tokenId4 = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 2,
        asset: 0,
        strike: strike - 1500,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    // wrong input list
    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [tokenId1, tokenId3, tokenId4],
          positionSize,
          2000000000,
          0,
          0,
        ),
    ).to.be.revertedWith("InputListFail()");
    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [tokenId2, tokenId2, tokenId4],
          positionSize,
          2000000000,
          0,
          0,
        ),
    ).to.be.revertedWith("InputListFail()");
    await expect(
      pool
        .connect(optionWriter)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [tokenId4, tokenId3, tokenId2],
          positionSize,
          2000000000,
          0,
          0,
        ),
    ).to.be.revertedWith("InputListFail()");

    // mint with correct list
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId2, tokenId3, tokenId4],
        positionSize,
        2000000000,
        0,
        0,
      );

    // burn tokenId4
    await pool.connect(optionWriter)["burnOptions(uint256,int24,int24)"](tokenId4, 0, 0);

    // mint with correct, but re-ordered list
    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [tokenId3, tokenId2, tokenId4],
        positionSize,
        2000000000,
        0,
        0,
      );

    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
        "redeem(uint256,address,address,uint256[])"
      ](amount0.div(100), await optionWriter.getAddress(), await optionWriter.getAddress(), [
        tokenId2,
        tokenId3,
      ]),
    ).to.be.revertedWith("InputListFail()");

    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
        "redeem(uint256,address,address,uint256[])"
      ](amount0.div(100), await optionWriter.getAddress(), await optionWriter.getAddress(), [
        tokenId2,
        tokenId1,
        tokenId3,
      ]),
    ).to.be.revertedWith("InputListFail()");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter)[
      "redeem(uint256,address,address,uint256[])"
    ](amount0.div(100), await optionWriter.getAddress(), await optionWriter.getAddress(), [
      tokenId2,
      tokenId3,
      tokenId4,
    ]);
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter)[
      "redeem(uint256,address,address,uint256[])"
    ](amount1.div(100), await optionWriter.getAddress(), await optionWriter.getAddress(), [
      tokenId2,
      tokenId3,
      tokenId4,
    ]);
  });

  it("Should allow minting short call USDC option using token1 as asset", async function () {
    const width = 10;
    let strike = tick + 1100;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    // move 1/3044 ETH to strike
    const positionSize = ethers.utils.parseEther("0.0003285151117");

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress(),
    );

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      2000000000,
      0,
      0,
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1010002396055"); // deposited balance - 1 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1000001000004428773891");

    // totalBalance: unchanged, contains balance of two depositors
    expect((await pool.poolData(0))[1].toString()).to.equal("1010003396128");
    expect((await pool.poolData(1))[1].toString()).to.equal("1000001000004428773891");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("1000073");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0"); // 1,010,000 USDC deposited, 1 moved  = 0.000099% (rounded to zero)
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); //
  });

  it("should allow to mint 2-leg short call USDC option, asset = 1", async function () {
    const width = 2;
    let strike = tick + 100;
    strike = strike - (strike % 10);

    const pa = UniswapV3.priceFromTick(strike);
    //console.log("strike1=", 10 ** (decimalWETH - decimalUSDC) / pa);
    const pa2 = UniswapV3.priceFromTick(strike + 50);
    //console.log("strike2=", 10 ** (decimalWETH - decimalUSDC) / pa2);

    const amount0 = BigNumber.from(100_000e6);
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

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
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
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      2000000000,
      0,
      0,
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("93291431144"); // deposited balance - 3364 - 3347 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("100001000004428773891");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("100003396127");
    expect((await pool.poolData(1))[1].toString()).to.equal("100001000004428773891");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("6711964983"); // 3364 + 3347 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("671"); // 100,000 USDC deposited, 6712 moved  = 6.71% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); //
  });

  it("should allow to mint 2-leg short call spread USDC option, asset = 1", async function () {
    const width = 2;
    let strike = tick + 100;
    strike = strike - (strike % 10);

    const pa = UniswapV3.priceFromTick(strike + 150);
    //console.log("strike1=", 10 ** (decimalWETH - decimalUSDC) / pa);
    const pa2 = UniswapV3.priceFromTick(strike + 250);
    //console.log("strike2=", 10 ** (decimalWETH - decimalUSDC) / pa2);

    const amount0 = BigNumber.from(100_000e6);
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
        strike: strike + 200,
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
        2000000000,
        0,
        0,
      );

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 50,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      2000000000,
      0,
      0,
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("966746549231"); // 1_100_000 - 33640 - 33470  - 33140 - 32810 -  3364 + 3347 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1100001000004428773891");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100003396124");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100001000004428773891");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("133256846893"); // 33640 + 33470 + 33140 + 32810 + 3364 - 3347 USDC
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("1211"); // 1,100,000 USDC deposited, 133256 moved  = 12.11% (rounded down)
    expect((await pool.poolData(1))[4].toString()).to.equal("0"); //
  });

  it("should allow to mint 2-leg long call spread USDC option, asset = 1", async function () {
    const width = 2;
    let strike = tick + 100;
    strike = strike - (strike % 10);

    const pa0 = UniswapV3.priceFromTick(strike);
    //console.log("strike1=", 10 ** (decimalWETH - decimalUSDC) / pa0);
    const pa1 = UniswapV3.priceFromTick(strike + 50);
    //console.log("strike2=", 10 ** (decimalWETH - decimalUSDC) / pa1);
    const pa2 = UniswapV3.priceFromTick(strike + 150);
    //console.log("strike1=", 10 ** (decimalWETH - decimalUSDC) / pa2);
    const pa3 = UniswapV3.priceFromTick(strike + 450);
    //console.log("strike2=", 10 ** (decimalWETH - decimalUSDC) / pa3);

    const amount0 = BigNumber.from(100_000e6);
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
        2000000000,
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

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      2000000000,
      0,
      0,
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("967271054892"); // 1_100_000 - 33640 - 33470  - 33140 - 32160 +  3364 - 3347 USDC
    expect((await pool.poolData(1))[0].toString()).to.equal("1100001000004428773891");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("1100003396124");
    expect((await pool.poolData(1))[1].toString()).to.equal("1100001000004428773891");

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

  it("should allow to mint 1 leg short put ETH option using token0 as asset", async function () {
    const width = 10;
    let strike = tick - 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    // Position size = deposit K token1 at strike K

    const positionSize = 1000000 * ((1 / 1.0001 ** strike) * 10 ** 12).toFixed(6);
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress(),
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

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

    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();

    // Amount of receipt token for user: less because user paid for commission = 60bps
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "9993999999999444412", // commission fee = 60bps
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1000003396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("1009001000004336175771"); // deposited balance - 1ETH

    // totalBalance: unchanged, contains balance of two depositors
    expect((await pool.poolData(0))[1].toString()).to.equal("1000003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("1010001000004428773945");

    // in AMM: about 1 ETH
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000092598174");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("9"); // 1010 ETH deposited, 1 moved  = 0.099% (rounded down)

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );
  });

  it("should allow to mint 1 leg short put ETH option using token1 as asset", async function () {
    const width = 10;
    let strike = tick - 1100;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(10000e6);
    const amount1 = ethers.utils.parseEther("10");

    //const positionSize = 1000000 * ((1 / 1.0001 ** strike) * 10 ** 12).toFixed(6);
    const positionSize = ethers.utils.parseEther("1");
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress(),
    );

    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal("10000000000000000000");

    const tokenId = OptionEncoding.encodeID(poolId, [
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

    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      2000000000,
      0,
      0,
    );

    const receipt = await resolved.wait();
    //console.log("Gas used = " + receipt.gasUsed.toNumber());

    // Amount of receipt token for user: less because user paid for commission = 6bps
    expect((await collatToken0.balanceOf(depositor)).toString()).to.equal("0");
    expect((await collatToken1.balanceOf(depositor)).toString()).to.equal(
      "9994000000000000001", // commission fee = 60bps
    );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("1000003396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("1009001000004428773918"); // deposited balance - 1ETH

    // totalBalance: unchanged, contains balance of two depositors
    expect((await pool.poolData(0))[1].toString()).to.equal("1000003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("1010001000004428773918");

    // in AMM: about 1 ETH
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("1000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("0");
    expect((await pool.poolData(1))[4].toString()).to.equal("9"); // 1010 ETH deposited, 1 moved  = 9.9% (rounded down)

    expect((await pool.optionPositionBalance(depositor, tokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );
  });

  it("should allow to mint 1 leg long put ETH option", async function () {
    const width = 10;
    let strike = tick - 1100;
    strike = strike - (strike % 10);

    const amount1 = ethers.utils.parseEther("50");

    //const positionSize = BigNumber.from(3396e6);
    const positionSize = 1000000 * ((1 / 1.0001 ** strike) * 10 ** 12).toFixed(6);

    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    // check deposited balance
    expect((await pool.poolData(0))[0].toString()).to.equal("3396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("50001000004428773891");

    // check total balance
    expect((await pool.poolData(0))[1].toString()).to.equal("3396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("50001000004428773891");

    // check AMM balance
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1,
      await optionWriter.getAddress(),
    );

    // check deposited balance
    expect((await pool.poolData(0))[0].toString()).to.equal("3396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("100001000004428773891");

    // check total balance
    expect((await pool.poolData(0))[1].toString()).to.equal("3396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("100001000004428773891");

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

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortPutTokenId],
        positionSize,
        2000000000,
        0,
        0,
      );

    // check deposited balance: total - amount moved to uniswap pool = 5ETH
    expect((await pool.poolData(0))[0].toString()).to.equal("3396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("95001000003965783051");

    // check total balance: Should be unchanged (included inAMM). Dust?
    expect((await pool.poolData(0))[1].toString()).to.equal("3396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("100001000004428773923");

    // check AMM balance: 5ETH moved to AMM
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("5000000000462990872");

    expect((await pool.optionPositionBalance(writor, shortPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );
    // check feesBase:
    //expect((await pool.options(writor, shortPutTokenId, 0, 0)).toString()).to.equal("0");
    // check baseLiquidity:
    //expect((await pool.options(writor, shortPutTokenId, 0, 1)).toString()).to.equal("0");

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

    const SFPMdeployment = await deployments.get(SFPMDeploymentName);

    const sfpm = (await ethers.getContractAt(
      SFPMContractName,
      SFPMdeployment.address,
    )) as SemiFungiblePositionManager;

    expect(
      (
        await sfpm.getAccountLiquidity(
          pool.univ3pool(),
          pool.address,
          1,
          strike - width * 5,
          strike + width * 5,
        )
      ).toString(),
    ).to.equal("0,61592755437886138");

    const resolved = await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longPutTokenId],
        positionSize,
        2000000000,
        0,
        0,
      );

    expect(
      (
        await sfpm.getAccountLiquidity(
          pool.univ3pool(),
          pool.address,
          1,
          strike - width * 5,
          strike + width * 5,
        )
      ).toString(),
    ).to.equal("12318551087577227,49274204350308911");

    const receipt = await resolved.wait();
    //console.log("Gas used = " + receipt.gasUsed.toNumber());

    // check deposited balance: total - amount moved to uniswap pool = 5ETH + amount moved back = 1ETH
    expect((await pool.poolData(0))[0].toString()).to.equal("3396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("96001000004058381170");

    // check total balance: Should be unchanged (included inAMM). Dust?
    expect((await pool.poolData(0))[1].toString()).to.equal("3396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("100001000004428773868");

    // check AMM balance: 5ETH moved to AMM, 1ETH moved out
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("4000000000370392698");

    expect((await pool.optionPositionBalance(depositor, longPutTokenId))[0].toString()).to.equal(
      positionSize.toString(),
    );

    // check baseLiquidity:
    //expect((await pool.options(depositor, longPutTokenId, 0, 1)).toString()).to.equal(
    //  "49274204350308911"
    //);
    //
    await pool.connect(deployer)["burnOptions(uint256,int24,int24)"](longPutTokenId, 0, 0);

    expect(
      (
        await sfpm.getAccountLiquidity(
          pool.univ3pool(),
          pool.address,
          1,
          strike - width * 5,
          strike + width * 5,
        )
      ).toString(),
    ).to.equal("0,61592755437886138");
  });

  it("should allow to mint 4 leg short put ETH option", async function () {
    const width = 10;
    let strike = tick - 1000;
    strike = strike - (strike % 10);

    const amount1 = ethers.utils.parseEther("10");
    const positionSize = BigNumber.from(3396e6);

    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1.mul(4),
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
        strike: strike - 200,
        long: false,
        tokenType: 1,
        riskPartner: 2,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 300,
        long: false,
        tokenType: 1,
        riskPartner: 3,
      },
    ]);

    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [tokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();
    //console.log("Gas used = " + receipt.gasUsed.toNumber());

    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("3563417477933176369");
  });

  it("should allow to mint 2-leg call USDC option with risk partner", async function () {
    const width = 10;
    let strike = tick + 150;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(1000000e6);
    //const positionSize = BigNumber.from(3396e6);

    const positionSize = 1000000 * ((1 / 1.0001 ** strike) * 10 ** 12).toFixed(6);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0.mul(2),
      depositor,
    );

    // check deposited balance
    expect((await pool.poolData(0))[0].toString()).to.equal("2000003396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("1000004428773891");

    // check total balance
    expect((await pool.poolData(0))[1].toString()).to.equal("2000003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("1000004428773891");

    // check AMM balance
    expect((await pool.poolData(0))[2].toString()).to.equal("0");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    const shortCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 5,
        asset: 0,
        strike: strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortCallTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();
    //console.log("Gas used = " + receipt.gasUsed.toNumber());

    // check deposited balance: total - amount moved to uniswap pool = 16737 USDC = 5x 3347 USDC
    expect((await pool.poolData(0))[0].toString()).to.equal("1983265431269");
    expect((await pool.poolData(1))[0].toString()).to.equal("1000004428773891");

    // check total balance: Should be unchanged (included inAMM). Dust?
    expect((await pool.poolData(0))[1].toString()).to.equal("2000003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("1000004428773891");

    // check AMM balance: 16737 moved to AMM
    expect((await pool.poolData(0))[2].toString()).to.equal("16737964860");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    const tokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 20,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
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

    await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortCallTokenId, tokenId],
      positionSize,
      2000000000,
      0,
      0,
    );

    // check deposited balance: total - amount moved to uniswap pool = ETH + amount moved back = net zero (dust = 1)
    expect((await pool.poolData(0))[0].toString()).to.equal("1983265431268");
    expect((await pool.poolData(1))[0].toString()).to.equal("1000004428773891");

    // check total balance: Should be unchanged (included inAMM). Dust?
    expect((await pool.poolData(0))[1].toString()).to.equal("2000003396128");
    expect((await pool.poolData(1))[1].toString()).to.equal("1000004428773891");

    // check AMM balance: 16737 moved to AMM, unchanged
    expect((await pool.poolData(0))[2].toString()).to.equal("16737964860");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");
  });

  it("should allow to mint long call USDC option", async function () {
    const width = 10;
    let strike = tick + 1000;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(50000e6);
    //const positionSize = BigNumber.from(3396e6);

    const positionSize = BigNumber.from(1000000 * ((1 / 1.0001 ** strike) * 10 ** 12).toFixed(6));

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0,
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionBuyer).deposit(
      amount0,
      await optionBuyer.getAddress(),
    );

    const shortCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 5,
        asset: 0,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortCallTokenId],
        positionSize,
        2000000000,
        0,
        0,
      );
    // inAMM: 5x 3074 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("15374091675");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");

    const longCallTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike,
        long: true,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);

    const resolved = await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longCallTokenId],
        positionSize,
        200000000000,
        0,
        0,
      );
    const receipt = await resolved.wait();
    console.log("Gas used = " + receipt.gasUsed.toNumber());

    await pool.connect(deployer)["burnOptions(uint256,int24,int24)"](longCallTokenId, 0, 0);

    await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longCallTokenId],
        positionSize.mul(4),
        20000000000000,
        0,
        0,
      );

    await pool.connect(deployer)["burnOptions(uint256,int24,int24)"](longCallTokenId, 0, 0);

    await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longCallTokenId],
        positionSize.mul(49).div(10),
        20000000000000,
        0,
        0,
      );

    await pool
      .connect(optionBuyer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [longCallTokenId],
        positionSize.mul(1).div(100),
        3301560736084503,
        0,
        0,
      );
    // panoptic pool balance
    expect((await pool.poolData(0))[0].toString()).to.equal("149726662474");
    expect((await pool.poolData(1))[0].toString()).to.equal("1000004428773891");

    // panoptic pool total balance
    expect((await pool.poolData(0))[1].toString()).to.equal("150003396125");
    expect((await pool.poolData(1))[1].toString()).to.equal("1000004428773891");

    // in AMM = 5x 3074 - 3074
    expect((await pool.poolData(0))[2].toString()).to.equal("276733651");
    expect((await pool.poolData(1))[2].toString()).to.equal("0");
  });

  it("should allow to mint short ETH-USDC ATM straddle", async function () {
    const width = 1;
    let strike = tick;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(50000e6);
    const amount1 = ethers.utils.parseEther("500");

    const positionSize = BigNumber.from(3396e6);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    const shortStrangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 15,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 5,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortStrangleTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();
    //console.log("Gas used = " + receipt.gasUsed.toNumber());

    expect((await pool.poolData(0))[2].toString()).to.equal("3396000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("998858123936669223");

    // Deposited shares, collateral requirement = 20% of 132410 = ~26428
    await expect(
      pool.checkCollateral(swapper.getAddress(), deployer.getAddress(), tick, [
        shortStrangleTokenId,
      ]),
    ).to.be.reverted;

    expect(
      (
        await pool.checkCollateral(deployer.getAddress(), tick, 0, [shortStrangleTokenId])
      ).toString(),
    ).to.equal("1748072306891,1357653328");
  });

  it("should allow to mint short ETH-USDC strangle", async function () {
    const width = 2;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(50000e6);
    const amount1 = ethers.utils.parseEther("500");

    const positionSize = BigNumber.from(3396e6);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    const shortStrangleTokenId = OptionEncoding.encodeID(poolId, [
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
    ]);

    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortStrangleTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();
    //console.log("Gas used = " + receipt.gasUsed.toNumber());

    expect((await pool.poolData(0))[2].toString()).to.equal("3396000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("989414372778182881");
  });

  it("should allow to mint short ETH-USDC iron condor, asset=0", async function () {
    const width = 2;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(50000e6);
    const amount1 = ethers.utils.parseEther("50");

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

    const shortStrangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 5,
        asset: 0,
        strike: strike + 300,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 5,
        asset: 0,
        strike: strike - 300,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortStrangleTokenId],
        positionSize,
        2000000000,
        0,
        0,
      );
    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("5033023396129");
    expect((await pool.poolData(1))[0].toString()).to.equal("5045151881877897270453");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("5050003396129");
    expect((await pool.poolData(1))[1].toString()).to.equal("5050001000004428773895");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("16980000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("4849118126531503442");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("33");
    expect((await pool.poolData(1))[4].toString()).to.equal("9");

    const longStrangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 300,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 300,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortStrangleTokenId, longStrangleTokenId],
        positionSize,
        2000000000,
        0,
        0,
      );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("5036419396128");
    expect((await pool.poolData(1))[0].toString()).to.equal("5046121705503203571133");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("5050003396128");
    expect((await pool.poolData(1))[1].toString()).to.equal("5050001000004428773887");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("13584000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("3879294501225202754");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("26");
    expect((await pool.poolData(1))[4].toString()).to.equal("7");

    const shortICTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 300,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 200,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 200,
        long: false,
        tokenType: 1,
        riskPartner: 3,
      },
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike - 300,
        long: true,
        tokenType: 1,
        riskPartner: 2,
      },
    ]);

    await expect(
      pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortICTokenId],
          positionSize,
          1000,
          0,
          0,
        ),
    ).to.be.revertedWith(
      revertCustom("EffectiveLiquidityAboveThreshold(2863311530, 1000, 177419501245784932)"),
    );
    const resolved = await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortICTokenId],
        positionSize,
        28633115300,
        0,
        0,
      );
    const receipt = await resolved.wait();
    //console.log("Gas used = " + receipt.gasUsed.toNumber());
    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("5036419396127");
    expect((await pool.poolData(1))[0].toString()).to.equal("5046111959103479554266");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("5050003396127");
    expect((await pool.poolData(1))[1].toString()).to.equal("5050001000004428773879");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("13584000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("3889040900949219613");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("26");
    expect((await pool.poolData(1))[4].toString()).to.equal("7");
  });

  it("should allow to mint short ETH-USDC iron condor, asset=1", async function () {
    const width = 2;
    let strike = tick;
    strike = strike - (strike % 10);

    const amount0 = BigNumber.from(50000e6);
    const amount1 = ethers.utils.parseEther("50");

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

    const shortStrangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 5,
        asset: 1,
        strike: strike + 300,
        long: false,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 5,
        asset: 1,
        strike: strike - 300,
        long: false,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortStrangleTokenId],
        positionSize,
        2000000000,
        0,
        0,
      );
    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("5033514614732");
    expect((await pool.poolData(1))[0].toString()).to.equal("5045001000004428773906");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("5050003396128");
    expect((await pool.poolData(1))[1].toString()).to.equal("5050001000004428773906");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("16488781396");
    expect((await pool.poolData(1))[2].toString()).to.equal("5000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("32");
    expect((await pool.poolData(1))[4].toString()).to.equal("9");

    const longStrangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 300,
        long: true,
        tokenType: 0,
        riskPartner: 1,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 300,
        long: true,
        tokenType: 1,
        riskPartner: 0,
      },
    ]);

    await pool
      .connect(optionWriter)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortStrangleTokenId, longStrangleTokenId],
        positionSize,
        2000000000,
        0,
        0,
      );

    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("5036812371011");
    expect((await pool.poolData(1))[0].toString()).to.equal("5046001000004428773899");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("5050003396128");
    expect((await pool.poolData(1))[1].toString()).to.equal("5050001000004428773899");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("13191025117");
    expect((await pool.poolData(1))[2].toString()).to.equal("4000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("26");
    expect((await pool.poolData(1))[4].toString()).to.equal("7");

    const shortICTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike + 300,
        long: true,
        tokenType: 0,
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
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 200,
        long: false,
        tokenType: 1,
        riskPartner: 3,
      },
      {
        width,
        ratio: 1,
        asset: 1,
        strike: strike - 300,
        long: true,
        tokenType: 1,
        riskPartner: 2,
      },
    ]);

    await expect(
      pool
        .connect(deployer)
        ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
          [shortICTokenId],
          positionSize,
          1000,
          0,
          0,
        ),
    ).to.be.revertedWith(
      revertCustom("EffectiveLiquidityAboveThreshold(2863311530, 1000, 172286888779630861)"),
    );
    const resolved = await pool
      .connect(deployer)
      ["mintOptions(uint256[],uint128,uint64,int24,int24)"](
        [shortICTokenId],
        positionSize,
        28633115300,
        0,
        0,
      );
    const receipt = await resolved.wait();
    //console.log("Gas used = " + receipt.gasUsed.toNumber());
    // Panoptic Pool Balance:
    expect((await pool.poolData(0))[0].toString()).to.equal("5036779229674");
    expect((await pool.poolData(1))[0].toString()).to.equal("5046001000004428773894");

    // totalBalance: unchanged, contains balance deposited
    expect((await pool.poolData(0))[1].toString()).to.equal("5050003396127");
    expect((await pool.poolData(1))[1].toString()).to.equal("5050001000004428773894");

    // in AMM: about 1 USDC
    expect((await pool.poolData(0))[2].toString()).to.equal("13224166453");
    expect((await pool.poolData(1))[2].toString()).to.equal("4000000000000000000");

    // totalCollected
    expect((await pool.poolData(0))[3].toString()).to.equal("0");
    expect((await pool.poolData(1))[3].toString()).to.equal("0");

    // poolUtilization:
    expect((await pool.poolData(0))[4].toString()).to.equal("26");
    expect((await pool.poolData(1))[4].toString()).to.equal("7");
  });

  it("should allow to mint short ETH-USDC ATM skewed straddle", async function () {
    const width = 1;
    let strike = tick;
    strike = strike - (strike % 10);
    const amount0 = BigNumber.from(50000e6);
    const amount1 = ethers.utils.parseEther("500");

    const positionSize = BigNumber.from(3396e6);

    await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
      amount0,
      depositor,
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      amount1,
      depositor,
    );

    const shortStrangleTokenId = OptionEncoding.encodeID(poolId, [
      {
        width,
        ratio: 1,
        asset: 0,
        strike: strike + 15,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
      {
        width: width * 2,
        ratio: 1,
        asset: 0,
        strike: strike - 10,
        long: false,
        tokenType: 1,
        riskPartner: 1,
      },
    ]);

    const resolved = await pool["mintOptions(uint256[],uint128,uint64,int24,int24)"](
      [shortStrangleTokenId],
      positionSize,
      2000000000,
      0,
      0,
    );
    const receipt = await resolved.wait();
    //console.log("Gas used = " + receipt.gasUsed.toNumber());

    expect((await pool.poolData(0))[2].toString()).to.equal("3396000000");
    expect((await pool.poolData(1))[2].toString()).to.equal("998358844668466435");
  });
});
