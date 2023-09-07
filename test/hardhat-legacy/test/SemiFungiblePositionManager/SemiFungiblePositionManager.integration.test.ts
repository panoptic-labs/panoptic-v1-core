/**
 * Test SemiFungiblePositionManager via Integration tests.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { config, deployments, ethers, network, getNamedAccounts } from "hardhat";
import { expect } from "chai";
import { BigNumber, Signer } from "ethers";
import {
  ERC20,
  IERC20__factory,
  IUniswapV3Pool,
  SemiFungiblePositionManager,
  ISwapRouter,
} from "../../typechain";
import * as OptionEncoding from "../Libraries/OptionEncoding";
import { grantTokens, revertReason } from "../utils";

const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_SLOT = 9;
const token0 = USDC_ADDRESS;

const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const WETH_SLOT = 3;
const token1 = WETH_ADDRESS;

describe("SemiFungiblePositionManager-integration", function () {
  let positionManager: SemiFungiblePositionManager;

  let pool: IUniswapV3Pool;
  let startingBlockNumber = 14822946;

  let deployer: Signer;
  let alice: Signer;
  let bob: Signer;

  let tick: number;
  let sqrtPriceX96: BigNumber;

  let weth: ERC20;

  const SFPMContractName = "SemiFungiblePositionManager";

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
    [deployer, alice, bob] = await ethers.getSigners();

    await deployments.fixture([
      "FeesCalc",
      "Math",
      "PanopticMath",
      "InteractionHelper",
      "LeftRight",
      "TokenId",
      SFPMContractName,
    ]);
    const { address: sfpmAddress } = await deployments.get(SFPMContractName);

    positionManager = (await ethers.getContractAt(
      SFPMContractName,
      sfpmAddress,
    )) as SemiFungiblePositionManager;

    const ETH_USDC_POOL_ADDRESS = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640";

    pool = (await ethers.getContractAt(
      "contracts/external/uniswapv3_core/contracts/interfaces/IUniswapV3Pool.sol:IUniswapV3Pool",
      ETH_USDC_POOL_ADDRESS,
    )) as IUniswapV3Pool;

    ({ sqrtPriceX96, tick } = await pool.slot0());
    tick = tick - (tick % 10);
    // initialize the pool
    // we need funds to do that due to the full-range deployment of funds
    const usdcBalance = ethers.utils.parseUnits("520000000", "6");
    const wethBalance = ethers.utils.parseEther("1000");

    await grantTokens(token1, await deployer.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(token0, await deployer.getAddress(), USDC_SLOT, usdcBalance);
    await IERC20__factory.connect(token1, deployer).approve(
      sfpmAddress,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(token0, deployer).approve(
      sfpmAddress,
      ethers.constants.MaxUint256,
    );

    let tx = await positionManager.initializeAMMPool(token0, token1, 500);
    await tx.wait();
  });

  it("pay with safeTransferFrom", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );
    const positionSize = 3;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 4000,
          strike: 10000,
          riskPartner: 0,
          ratio: 4,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          -800000,
          800000,
        ),
    ).to.emit(positionManager, "TokenizedPositionMinted");
  });

  it("fail: pay without approval", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    const positionSize = 3;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 40,
          strike: 10000,
          riskPartner: 0,
          ratio: 4,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          -800000,
          800000,
        ),
    ).to.be.revertedWith(revertReason("STF"));
    const ethBalance = await ethers.provider.getBalance(positionManager.address);
  });

  it("burn failed: insufficient position", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );
    const positionSize = 3;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 4000,
          strike: 10000,
          riskPartner: 0,
          ratio: 4,
          tokenType: 1,
          asset: 0,
          long: true,
        },
      ],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          -800000,
          800000,
        ),
    ).to.be.revertedWith("NotEnoughLiquidity()");
  });

  it("mint failed: too much liquidity", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100000000000000000000000000000"),
    );

    const positionSize = ethers.utils.parseEther("3000000000000000");

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 2,
          strike: -300000,
          riskPartner: 0,
          ratio: 1,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          -800000,
          800000,
        ),
    ).to.be.reverted;
  });

  it("mint successful: short OTM Put ", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );
    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 10,
          strike: tick - 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountLiquidity(pool.address, await alice.getAddress(), 1, tick - 650, tick - 550)
      ).toString(),
    ).to.be.equal("0,0");

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );

    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountLiquidity(pool.address, await alice.getAddress(), 0, tick - 650, tick - 550)
      ).toString(),
    ).to.be.equal("0,0");
    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountLiquidity(pool.address, await alice.getAddress(), 1, tick - 650, tick - 550)
      ).toString(),
    ).to.be.equal("0,11307520561765961");
    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountFeesBase(pool.address, await alice.getAddress(), 1, tick - 650, tick - 550)
      )[0].toString(),
    ).to.be.equal("21972463694");
    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountFeesBase(pool.address, await alice.getAddress(), 1, tick - 650, tick - 550)
      )[1].toString(),
    ).to.be.equal("8399715703320475827");

    await positionManager
      .connect(alice)
      .burnTokenizedPosition(tokenId.toString(), positionSize.div(2), -800000, 800000);

    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountLiquidity(pool.address, await alice.getAddress(), 0, tick - 650, tick - 550)
      ).toString(),
    ).to.be.equal("0,0");
    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountFeesBase(pool.address, await alice.getAddress(), 1, tick - 650, tick - 550)
      )[0].toString(),
    ).to.be.equal("10986231847");
    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountFeesBase(pool.address, await alice.getAddress(), 1, tick - 650, tick - 550)
      )[1].toString(),
    ).to.be.equal("4199857851660238285");

    await positionManager
      .connect(alice)
      .burnTokenizedPosition(
        tokenId.toString(),
        await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
        -800000,
        800000,
      );

    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountLiquidity(pool.address, await alice.getAddress(), 1, tick - 650, tick - 550)
      )[1],
    ).to.be.equal("0");
    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountFeesBase(pool.address, await alice.getAddress(), 1, tick - 650, tick - 550)
      )[0].toString(),
    ).to.be.equal("0");
    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountFeesBase(pool.address, await alice.getAddress(), 1, tick - 650, tick - 550)
      )[1].toString(),
    ).to.be.equal("0");
  });

  it("mint successful: short OTM Call ", async () => {
    // exchange for 100 weth
    await grantTokens(
      USDC_ADDRESS,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("10000000", "6"),
    );
    await IERC20__factory.connect(USDC_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseUnits("10000000", "6"),
    );
    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick + 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 0,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    const receipt = await resolved.wait();
  });

  it("mint successful: short ITM Put, no swap ", async () => {
    // exchange for 100 weth
    await grantTokens(
      USDC_ADDRESS,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("10000000", "6"),
    );
    await IERC20__factory.connect(USDC_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseUnits("10000000", "6"),
    );

    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick + 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    const receipt = await resolved.wait();
  });

  it("mint successful: short ITM Call, no swap ", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );

    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick - 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 0,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    const receipt = await resolved.wait();
  });

  it("mint successful: short ITM Put, swap! ", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await grantTokens(
      USDC_ADDRESS,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("10000000", "6"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(USDC_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseUnits("10000000", "6"),
    );

    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick + 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    /*
    const receipt = await resolved.wait();
    */
    weth = await IERC20__factory.connect(WETH_ADDRESS, deployer);

    //await positionManager
    //  .connect(alice)
    //  ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId.toString(), positionSize.div(2), -887270, 887270);
    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize.div(2),
        887270,
        -887270,
      );

    await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize.div(2),
        887270,
        -887270,
      );
  });

  it("mint successful: short ITM Call, swap! ", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );
    await grantTokens(
      USDC_ADDRESS,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("10000000", "6"),
    );
    await IERC20__factory.connect(USDC_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseUnits("10000000", "6"),
    );

    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick - 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 0,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        887270,
        -887270,
      );
    const receipt = await resolved.wait();
  });

  it("burn successfully after minting: OTM short put", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );
    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick - 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    await resolved.wait();

    // remove approval
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("0"),
    );

    await expect(
      positionManager
        .connect(alice)
        .burnTokenizedPosition(
          tokenId.toString(),
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        ),
    ).to.emit(positionManager, "TokenizedPositionBurnt");
  });

  it("burn successfully after minting: 2x OTM short put", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );
    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick - 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    const receipt = await resolved.wait();

    // remove approval
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("0"),
    );

    await expect(
      positionManager
        .connect(alice)
        .burnTokenizedPosition(tokenId.toString(), positionSize.div(2), -800000, 800000),
    ).to.emit(positionManager, "TokenizedPositionBurnt");
    await expect(
      positionManager
        .connect(alice)
        .burnTokenizedPosition(
          tokenId.toString(),
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        ),
    ).to.emit(positionManager, "TokenizedPositionBurnt");
  });

  it("burn successfully after minting: OTM short call", async () => {
    // exchange for 100 weth
    await grantTokens(
      USDC_ADDRESS,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("10000000", "6"),
    );
    await IERC20__factory.connect(USDC_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseUnits("10000000", "6"),
    );
    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick + 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 0,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    const receipt = await resolved.wait();

    // remove approval
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("0"),
    );

    await expect(
      positionManager
        .connect(alice)
        .burnTokenizedPosition(
          tokenId.toString(),
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        ),
    ).to.emit(positionManager, "TokenizedPositionBurnt");
  });

  it("burn successfully after minting: ITM short put, no swap", async () => {
    // exchange for 100 weth
    await grantTokens(
      USDC_ADDRESS,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("10000000", "6"),
    );
    await IERC20__factory.connect(USDC_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseUnits("10000000", "6"),
    );
    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick + 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    const receipt = await resolved.wait();

    // remove approval
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("0"),
    );

    await expect(
      positionManager
        .connect(alice)
        .burnTokenizedPosition(
          tokenId.toString(),
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        ),
    ).to.emit(positionManager, "TokenizedPositionBurnt");
  });

  it("burn successfully after minting: ITM short call, no swap", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );
    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick - 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 0,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    const receipt = await resolved.wait();

    // remove approval
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("0"),
    );

    await expect(
      positionManager
        .connect(alice)
        .burnTokenizedPosition(
          tokenId.toString(),
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        ),
    ).to.emit(positionManager, "TokenizedPositionBurnt");
  });

  it("burn successfully after minting: ITM short put, swap at burn!", async () => {
    // exchange for 100 weth
    await grantTokens(
      USDC_ADDRESS,
      await alice.getAddress(),
      USDC_SLOT,
      ethers.utils.parseUnits("10000000", "6"),
    );
    await IERC20__factory.connect(USDC_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseUnits("10000000", "6"),
    );
    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick + 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    const receipt = await resolved.wait();

    // DO NOT remove approval

    await expect(
      positionManager
        .connect(alice)
        .burnTokenizedPosition(
          tokenId.toString(),
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          887270,
          -887270,
        ),
    ).to.emit(positionManager, "TokenizedPositionBurnt");
  });

  it("burn successfully after minting: ITM short call, swap at burn!", async () => {
    // exchange for 100 weth
    await grantTokens(
      WETH_ADDRESS,
      await alice.getAddress(),
      WETH_SLOT,
      ethers.utils.parseEther("100"),
    );
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.utils.parseEther("100"),
    );

    const positionSize = BigNumber.from(3396e6);

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 100,
          strike: tick - 600,
          riskPartner: 0,
          ratio: 1,
          tokenType: 0,
          asset: 0,
          long: false,
        },
      ],
    );

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        -800000,
        800000,
      );
    const receipt = await resolved.wait();

    // DO NOT remove approval

    await expect(
      positionManager
        .connect(alice)
        .burnTokenizedPosition(
          tokenId.toString(),
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          887270,
          -887270,
        ),
    ).to.emit(positionManager, "TokenizedPositionBurnt");
  });

  describe("rollTokenizedPositions", async () => {
    const USDC_DAI_POOL_ADDRESS = "0x6c6Bc977E13Df9b0de53b251522280BB72383700";
    const DAI_ADDRESS = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
    const USDC_ADDRESS = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
    const DAI_SLOT = 2;

    let nToken0: ERC20;
    let nToken1: ERC20;
    let DAI: ERC20;
    let nPool: IUniswapV3Pool;

    beforeEach(async () => {
      nToken0 = (await ethers.getContractAt("IERC20", DAI_ADDRESS)) as ERC20;
      nToken1 = (await ethers.getContractAt("IERC20", USDC_ADDRESS)) as ERC20;
      DAI = nToken0;
      nPool = (await ethers.getContractAt(
        "contracts/external/uniswapv3_core/contracts/interfaces/IUniswapV3Pool.sol:IUniswapV3Pool",
        USDC_DAI_POOL_ADDRESS,
      )) as IUniswapV3Pool;
      // initialize the pool
      // we need funds to do that due to the full-range deployment of funds
      const usdcBalance = ethers.utils.parseUnits("100026581690881682", "6");
      const daiBalance = ethers.utils.parseUnits("100026581690881682", "6");

      await grantTokens(nToken0.address, await deployer.getAddress(), DAI_SLOT, daiBalance);
      await grantTokens(nToken1.address, await deployer.getAddress(), USDC_SLOT, usdcBalance);
      await IERC20__factory.connect(nToken1.address, deployer).approve(
        positionManager.address,
        ethers.constants.MaxUint256,
      );
      await IERC20__factory.connect(nToken0.address, deployer).approve(
        positionManager.address,
        ethers.constants.MaxUint256,
      );

      // now initialize
      let tx = await positionManager
        .connect(deployer)
        .initializeAMMPool(nToken0.address, nToken1.address, 500);
      await tx.wait();
    });

    it("fail: old tokenId does not exist", async () => {
      await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
        positionManager.address,
        ethers.utils.parseEther("100"),
      );
      const tokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 10,
            strike: tick - 600,
            riskPartner: 0,
            ratio: 4,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      await grantTokens(DAI.address, alice.address, DAI_SLOT, ethers.utils.parseEther("100"));
      await DAI.connect(alice).approve(positionManager.address, ethers.utils.parseEther("100"));

      const newTokenId = OptionEncoding.encodeID(
        BigInt(nPool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 10,
            strike: 90000,
            riskPartner: 0,
            ratio: 4,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      await expect(
        positionManager
          .connect(alice)
          .rollTokenizedPositions(
            tokenId,
            newTokenId,
            await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
            -800000,
            800000,
          ),
      ).to.be.revertedWith("OptionsBalanceZero()");
    });

    it("different pools", async () => {
      await grantTokens(
        WETH_ADDRESS,
        await alice.getAddress(),
        WETH_SLOT,
        ethers.utils.parseEther("100"),
      );
      await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
        positionManager.address,
        ethers.utils.parseEther("100"),
      );
      const positionSize = BigNumber.from(3396e6);

      const tokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 10,
            strike: tick - 600,
            riskPartner: 0,
            ratio: 4,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      await positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          -800000,
          800000,
        );

      await grantTokens(
        DAI.address,
        await alice.getAddress(),
        DAI_SLOT,
        ethers.utils.parseEther("100"),
      );
      await DAI.connect(alice).approve(positionManager.address, ethers.utils.parseEther("100"));

      const newTokenId = OptionEncoding.encodeID(
        BigInt(nPool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 10,
            strike: 90000,
            riskPartner: 0,
            ratio: 4,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      await positionManager
        .connect(alice)
        .rollTokenizedPositions(
          tokenId,
          newTokenId,
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        );
    });

    it("same pool, one leg", async () => {
      await grantTokens(
        WETH_ADDRESS,
        await alice.getAddress(),
        WETH_SLOT,
        ethers.utils.parseEther("100"),
      );
      await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
        positionManager.address,
        ethers.utils.parseEther("100"),
      );

      const tokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 10,
            strike: tick - 1000,
            riskPartner: 0,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );
      const positionSize = 1000000 * ((1 / 1.0001 ** (tick - 1000)) * 10 ** 12).toFixed(6);

      const newTokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 10,
            strike: tick - 600,
            riskPartner: 0,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      await positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          -800000,
          800000,
        );

      await positionManager
        .connect(alice)
        .rollTokenizedPositions(
          tokenId,
          newTokenId,
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        );
    });

    it("same pool, two legs: roll one", async () => {
      await grantTokens(
        WETH_ADDRESS,
        await alice.getAddress(),
        WETH_SLOT,
        ethers.utils.parseEther("100"),
      );
      await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
        positionManager.address,
        ethers.utils.parseEther("100"),
      );
      const positionSize = BigNumber.from(3396e6);

      const tokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 2,
            strike: tick - 600,
            riskPartner: 0,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
          {
            width: 2,
            strike: tick - 1200,
            riskPartner: 1,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      const newTokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 2,
            strike: tick - 600,
            riskPartner: 0,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
          {
            width: 2,
            strike: tick - 800,
            riskPartner: 1,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      await positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          -800000,
          800000,
        );

      await positionManager
        .connect(alice)
        .rollTokenizedPositions(
          tokenId,
          newTokenId,
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        );
    });

    it("same pool, two legs: roll the other", async () => {
      await grantTokens(
        WETH_ADDRESS,
        await alice.getAddress(),
        WETH_SLOT,
        ethers.utils.parseEther("100"),
      );
      await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
        positionManager.address,
        ethers.utils.parseEther("100"),
      );
      const positionSize = BigNumber.from(3396e6);

      const tokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 2,
            strike: tick - 1200,
            riskPartner: 0,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
          {
            width: 2,
            strike: tick - 600,
            riskPartner: 1,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      const newTokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 2,
            strike: tick - 800,
            riskPartner: 0,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
          {
            width: 2,
            strike: tick - 600,
            riskPartner: 1,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      await positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          -800000,
          800000,
        );

      await positionManager
        .connect(alice)
        .rollTokenizedPositions(
          tokenId,
          newTokenId,
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        );
    });

    it("same pool, two legs: roll both", async () => {
      await grantTokens(
        WETH_ADDRESS,
        await alice.getAddress(),
        WETH_SLOT,
        ethers.utils.parseEther("100"),
      );
      await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
        positionManager.address,
        ethers.utils.parseEther("100"),
      );
      const positionSize = BigNumber.from(3396e6);

      const tokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 2,
            strike: tick - 600,
            riskPartner: 0,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
          {
            width: 2,
            strike: tick - 1200,
            riskPartner: 1,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      const newTokenId = OptionEncoding.encodeID(
        BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
        [
          {
            width: 2,
            strike: tick - 400,
            riskPartner: 0,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
          {
            width: 2,
            strike: tick - 800,
            riskPartner: 1,
            ratio: 1,
            tokenType: 1,
            asset: 0,
            long: false,
          },
        ],
      );

      await positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          -800000,
          800000,
        );

      await positionManager
        .connect(alice)
        .rollTokenizedPositions(
          tokenId,
          newTokenId,
          await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
          -800000,
          800000,
        );
    });
  });
  it("account liquidity and fee data is updated on token transfer", async () => {
    let router = (await ethers.getContractAt(
      "ISwapRouter",
      "0xe592427a0aece92de3edee1f18e0157c05861564",
    )) as ISwapRouter;
    const ETH_USDC_POOL_ADDRESS = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640";
    const USDC_ADDRESS = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
    const WETH_ADDRESS = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";

    const WETH_SLOT = 3;
    const USDC_SLOT = 9;

    const usdcBalance = ethers.utils.parseUnits("5200000000000000", "6");
    const wethBalance = ethers.utils.parseEther("1000000000000000");

    await grantTokens(WETH_ADDRESS, await alice.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await alice.getAddress(), USDC_SLOT, usdcBalance);
    await IERC20__factory.connect(WETH_ADDRESS, alice).approve(
      positionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, alice).approve(
      positionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, alice).approve(
      router.address,
      ethers.constants.MaxUint256,
    );

    await grantTokens(WETH_ADDRESS, await bob.getAddress(), WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, await bob.getAddress(), USDC_SLOT, usdcBalance);
    await IERC20__factory.connect(WETH_ADDRESS, bob).approve(
      positionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, bob).approve(
      positionManager.address,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, bob).approve(
      router.address,
      ethers.constants.MaxUint256,
    );

    const tokenId = OptionEncoding.encodeID(
      BigInt(ETH_USDC_POOL_ADDRESS.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 3,
          strike: 195015,
          riskPartner: 0,
          ratio: 1,
          tokenType: 0,
          asset: 0,
          long: false,
        },
      ],
    );

    await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        100000000000000,
        -800000,
        800000,
      );
    await positionManager
      .connect(bob)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        100000000000000,
        -800000,
        800000,
      );

    await router.connect(alice).exactInputSingle({
      tokenIn: USDC_ADDRESS,
      tokenOut: WETH_ADDRESS,
      fee: 500,
      recipient: alice.getAddress(),
      deadline: 4825814790,
      amountIn: BigNumber.from("100000000000000000"),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    });

    await expect(
      positionManager
        .connect(alice)
        .safeTransferFrom(
          await alice.getAddress(),
          "0x0000000000000000000000000000000000000001",
          tokenId.toString(),
          10,
          "0x",
        ),
    ).to.be.revertedWith("TransferFailed()");
    await expect(
      positionManager
        .connect(alice)
        .safeTransferFrom(
          await alice.getAddress(),
          await bob.getAddress(),
          tokenId.toString(),
          100000000000000,
          "0x",
        ),
    ).to.be.revertedWith("TransferFailed()");
    await positionManager
      .connect(alice)
      .safeTransferFrom(
        alice.getAddress(),
        "0x0000000000000000000000000000000000000001",
        tokenId.toString(),
        100000000000000,
        "0x",
      );
    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountLiquidity(ETH_USDC_POOL_ADDRESS, await alice.getAddress(), 0, 195000, 195030)
      ).toString(),
    ).to.be.equal("0,0");
    expect(
      (
        await positionManager
          .connect(alice)
          .getAccountFeesBase(ETH_USDC_POOL_ADDRESS, await alice.getAddress(), 0, 195000, 195030)
      ).toString(),
    ).to.be.equal("0,0");

    await positionManager
      .connect(bob)
      .safeTransferFrom(
        bob.getAddress(),
        alice.getAddress(),
        tokenId.toString(),
        100000000000000,
        "0x",
      );

    expect(
      (
        await positionManager.getAccountLiquidity(
          ETH_USDC_POOL_ADDRESS,
          bob.getAddress(),
          0,
          195000,
          195030,
        )
      )[1],
    ).to.be.equal(0);
    expect(
      (
        await positionManager.getAccountFeesBase(
          ETH_USDC_POOL_ADDRESS,
          bob.getAddress(),
          0,
          195000,
          195030,
        )
      ).feesBase0,
    ).to.be.equal(0);
    expect(
      (
        await positionManager.getAccountLiquidity(
          ETH_USDC_POOL_ADDRESS,
          alice.getAddress(),
          0,
          195000,
          195030,
        )
      ).toString(),
    ).to.be.equal("0,1143972574226364867717");
    expect(
      (
        await positionManager.getAccountFeesBase(
          ETH_USDC_POOL_ADDRESS,
          alice.getAddress(),
          0,
          195000,
          195030,
        )
      ).feesBase0.toString(),
    ).to.be.equal("1468372318892345");
  });
});
