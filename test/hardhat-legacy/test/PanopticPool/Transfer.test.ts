/**
 * Test General Functions of the PanopticPool.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { deployments, ethers, hardhatArguments, network } from "hardhat";
import { assert, expect } from "chai";
import { grantTokens, revertCustom, revertReason } from "../utils";
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
import { CollateralTracker } from "../../types";

const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_SLOT = 9;
const token0 = USDC_ADDRESS;

const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const WETH_SLOT = 3;
const token1 = WETH_ADDRESS;

const DAI_ADDRESS = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
const token2 = DAI_ADDRESS;

describe("Transfer", async function () {
  this.timeout(1000000);

  const contractName = "PanopticPool";
  const deploymentName = "PanopticPool-ETH-USDC";

  let uniPool: IUniswapV3Pool;
  let pool: PanopticPool;
  let collateralTracker: CollateralTracker;

  let usdc: ERC20;
  let weth: ERC20;

  let collatToken0: ERC20;
  let collatToken1: ERC20;

  let deployer: Signer;
  let optionWriter: Signer;
  let optionBuyer: Signer;
  let liquidityProvider: Signer;
  let swapper: Signer;
  let someoneElse: Signer;

  let depositor: address;
  let writor: address;
  let providor: address;
  let buyor: address;
  let someone: address;

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
      "CollateralTracker",
      "Math",
      "PanopticMath",
      "InteractionHelper",
      "SemiFungiblePositionManager",
    ]);
    const { address } = await deployments.get(deploymentName);
    [deployer, optionWriter, optionBuyer, liquidityProvider, swapper, someoneElse] =
      await ethers.getSigners();

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
    someone = await someoneElse.getAddress();

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

  describe("Transfers", async function () {
    xit("Should transfer shares of token0", async function () {
      // the shares of deployer is 0, so should fail
      await expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).transfer(
          someone,
          100,
        ),
      ).to.be.revertedWith("0x11");
      await expect(
        CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).transfer(
          someone,
          100,
        ),
      ).to.be.revertedWith("0x11");

      let address = await pool.collateralToken0();
      expect(await IERC20__factory.connect(address, deployer).balanceOf(pool.address)).to.equal(0);

      // we deposit token0 into the Panoptic Pool.
      // This gives us shares in return - and the shares are tracked via the CollateralTracker (an ERC20)
      await CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).deposit(
        10 ** 6,
        depositor,
      );

      // let's connect to the CollateralTracker token0 inside the Panoptic Pool and get the balance of various accounts holding it
      expect(await IERC20__factory.connect(address, deployer).balanceOf(pool.address)).to.equal(0); // the pool doesn't hold any
      expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(
        10 ** 6,
      ); // but the user who deposited does

      await expect(
        CollateralTracker__factory.connect(await pool.collateralToken0(), deployer).transfer(
          someone,
          100,
        ),
      ); // we can transfer the shares to other users

      expect(await IERC20__factory.connect(address, deployer).balanceOf(pool.address)).to.equal(0);
      expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(
        10 ** 6 - 100,
      );
      expect(await IERC20__factory.connect(address, deployer).balanceOf(someone)).to.equal(100); // and they will receive it
    });
  });

  xit("Should transfer shares of token1", async function () {
    let address = await pool.collateralToken1();
    expect(await IERC20__factory.connect(address, deployer).balanceOf(pool.address)).to.equal(0);

    // we deposit token1 into the Panoptic Pool.
    // This gives us shares in return - and the shares are tracked via the CollateralTracker (an ERC20)
    await CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).deposit(
      10 ** 9,
      depositor,
    );

    // let's connect to the CollateralTracker token0 inside the Panoptic Pool and get the balance of various accounts holding it
    expect(await IERC20__factory.connect(address, deployer).balanceOf(pool.address)).to.equal(0); // the pool doesn't hold any
    expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(10 ** 9); // but the user who deposited does
    expect(await IERC20__factory.connect(address, deployer).balanceOf(someone)).to.equal(0);

    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken1(), deployer).transfer(
        someone,
        100,
      ),
    ); // we can transfer the shares to other users

    expect(await IERC20__factory.connect(address, deployer).balanceOf(pool.address)).to.equal(0);
    expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(
      10 ** 9 - 100,
    );
    expect(await IERC20__factory.connect(address, deployer).balanceOf(someone)).to.equal(100); // and they will receive it
  });

  xit("Should fail if transferring from a sender with an active position", async () => {
    // find out how to test the block number thing
    // we can just manipulate the left slot i guess via setStorageAt

    let width = 10;
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
    let address = await pool.collateralToken0();
    expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(amount0);
    expect(await IERC20__factory.connect(address, deployer).balanceOf(writor)).to.equal(0);
    expect(await IERC20__factory.connect(address, deployer).balanceOf(someone)).to.equal(0);

    address = await pool.collateralToken1();
    expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(0);
    expect(await IERC20__factory.connect(address, deployer).balanceOf(writor)).to.equal(0);
    expect(await IERC20__factory.connect(address, deployer).balanceOf(someone)).to.equal(0);

    // the option writer user now creates a position
    await CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).deposit(
      amount0.mul(100),
      await optionWriter.getAddress(),
    );
    await CollateralTracker__factory.connect(await pool.collateralToken1(), optionWriter).deposit(
      amount1.mul(100),
      await optionWriter.getAddress(),
    );
    expect(
      await IERC20__factory.connect(await pool.collateralToken0(), deployer).balanceOf(writor),
    ).to.equal(BigNumber.from("1000000000000"));
    expect(
      await IERC20__factory.connect(await pool.collateralToken1(), deployer).balanceOf(writor),
    ).to.equal(BigNumber.from("1000000000000000000000"));

    let tokenId = OptionEncoding.encodeID(poolId, [
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
    await expect(pool.connect(optionWriter).mintOptions([tokenId], positionSize, 20000))
      .to.emit(pool, "OptionMinted")
      .withArgs(
        writor,
        positionSize,
        tokenId,
        BigNumber.from("20416942015256307807802476445906092687420"), // rates
        0, // pool utilization
        1, // number of positions of this user
      );

    // mint another position, slightly different:
    let tokenIdtwo = OptionEncoding.encodeID(poolId, [
      {
        width: width + 1,
        ratio: 1,
        asset: 1,
        strike,
        long: false,
        tokenType: 0,
        riskPartner: 0,
      },
    ]);
    await expect(pool.connect(optionWriter).mintOptions([tokenIdtwo], positionSize, 20000))
      .to.emit(pool, "OptionMinted")
      .withArgs(
        writor,
        positionSize,
        tokenId,
        BigNumber.from("20416942015256307807802476445906092687420"), // rates
        0, // pool utilization
        2, // number of positions of this user
      );

    address = await pool.collateralToken0();
    expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(amount0);
    expect(await IERC20__factory.connect(address, deployer).balanceOf(writor)).to.equal(
      999999994000,
    );
    expect(await IERC20__factory.connect(address, deployer).balanceOf(someone)).to.equal(0);

    address = await pool.collateralToken1();
    expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(0);
    expect(await IERC20__factory.connect(address, deployer).balanceOf(writor)).to.equal(
      BigNumber.from("1000000000000000000000"),
    );
    expect(await IERC20__factory.connect(address, deployer).balanceOf(someone)).to.equal(0);

    // now let's ensure that they cannot transfer shares since they have a position
    await expect(
      CollateralTracker__factory.connect(await pool.collateralToken0(), optionWriter).transfer(
        someone,
        100,
      ),
    );
    await network.provider.send("hardhat_mine", ["0x1"]);

    address = await pool.collateralToken0();
    expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(amount0);
    expect(await IERC20__factory.connect(address, deployer).balanceOf(writor)).to.equal(
      999999994000,
    );
    expect(await IERC20__factory.connect(address, deployer).balanceOf(someone)).to.equal(0);

    address = await pool.collateralToken1();
    expect(await IERC20__factory.connect(address, deployer).balanceOf(depositor)).to.equal(0);
    expect(await IERC20__factory.connect(address, deployer).balanceOf(writor)).to.equal(
      BigNumber.from("1000000000000000000000"),
    );
    expect(await IERC20__factory.connect(address, deployer).balanceOf(someone)).to.equal(0);
  });
});
