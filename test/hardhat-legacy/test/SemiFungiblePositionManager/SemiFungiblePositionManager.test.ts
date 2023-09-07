/**
 * Test SemiFungiblePositionManager.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { deployments, ethers, getNamedAccounts, network } from "hardhat";
import { expect } from "chai";
import { grantTokens } from "../utils";
import {
  SemiFungiblePositionManager,
  Token,
  MockUniswapV3Pool,
  IERC20__factory,
} from "../../typechain";
import * as OptionEncoding from "../Libraries/OptionEncoding";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("SemiFungiblePositionManager", function () {
  let positionManager: SemiFungiblePositionManager;
  let token0: Token;
  let token1: Token;
  let pool: MockUniswapV3Pool;
  let users: SignerWithAddress[];
  const SFPMContractName = "SemiFungiblePositionManager";
  const Token0DeploymentName = "Token0";
  const Token0ContractName = "Token";
  const Token1DeploymentName = "Token1";
  const Token1ContractName = "Token";
  const UniswapV3MockPoolDeploymentName = "MockUniswapV3Pool";
  const UniswapV3MockPoolContractName = "MockUniswapV3Pool";

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
      "FeesCalc",
      "Math",
      "PanopticMath",
      "InteractionHelper",
      "TokenId",
      "LeftRight",
      SFPMContractName,
      UniswapV3MockPoolDeploymentName,
    ]);

    const { address: sfpmAddress } = await deployments.get(SFPMContractName);
    const { address: uniswapV3PoolAddress } = await deployments.get(
      UniswapV3MockPoolDeploymentName,
    );
    const { address: token0Address } = await deployments.get(Token0DeploymentName);
    const { address: token1Address } = await deployments.get(Token1DeploymentName);
    positionManager = (await ethers.getContractAt(
      SFPMContractName,
      sfpmAddress,
    )) as SemiFungiblePositionManager;
    token0 = (await ethers.getContractAt(Token0ContractName, token0Address)) as Token;
    token1 = (await ethers.getContractAt(Token1ContractName, token1Address)) as Token;
    pool = (await ethers.getContractAt(
      UniswapV3MockPoolContractName,
      uniswapV3PoolAddress,
    )) as MockUniswapV3Pool;

    users = await ethers.getSigners();
    const [alice] = users;

    // const slotnum = ethers.BigNumber.from(await positionManager.getSlot()).toString();
    // console.log(slotnum);

    // let val0 = await ethers.provider.getStorageAt(positionManager.address, "0x0");
    // let val1 = await ethers.provider.getStorageAt(positionManager.address, "0x1");
    // let val2 = await ethers.provider.getStorageAt(positionManager.address, "0x2");
    // let val3 = await ethers.provider.getStorageAt(positionManager.address, "0x3");
    // let val4 = await ethers.provider.getStorageAt(positionManager.address, "0x4");
    // let val5 = await ethers.provider.getStorageAt(positionManager.address, "0x5");
    // let val6 = await ethers.provider.getStorageAt(positionManager.address, "0x6");

    // console.log("STORAGE: ", val0);
    // console.log("STORAGE: ", val1);
    // console.log("STORAGE: ", val2);
    // console.log("STORAGE: ", val3);
    // console.log("STORAGE: ", val4);
    // console.log("STORAGE: ", val5);
    // console.log("STORAGE: ", val6);

    // const index = ethers.utils.solidityKeccak256(
    //   ["uint256", "uint256"],
    //   [poolId, 4] // key, slot
    // );
    // const addressBytes32 = ethers.utils.hexlify(ethers.utils.zeroPad(address, 32));

    // await ethers.provider.send("hardhat_setStorageAt", [sfpm, index, addressBytes32]);
    // await ethers.provider.send("evm_mine", []); // Just mines to the next block

    // // mock pool address for unit tests
    // await initPoolAddress(
    //   positionManager.address,
    //   String(pool.address.slice(0, 18).toLowerCase()),
    //   4,
    //   pool.address
    // );

    // const tokenId = OptionEncoding.encodeID(BigInt(pool.address.slice(0, 18).toLowerCase()), [
    //   { width: 1, strike: 0, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: true },
    // ]);
    // await positionManager.connect(alice)["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId.toString(), 3, 0, 0);

    // await ethers.provider.getStorageAt(positionManager.address, "0x0")
  });

  it("option mint fails: invalid pool 0 address", async () => {
    const positionSize = 3;
    const [alice] = users;

    const tokenId = OptionEncoding.encodeID(BigInt(0), [
      { width: 1, strike: 0, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: true },
    ]);
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(0)");
  });

  it("option mint fails: invalid pool id - not initialized", async () => {
    const positionSize = 3;
    const [alice] = users;

    const tokenId = OptionEncoding.encodeID(BigInt(1), [
      { width: 1, strike: 0, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: true },
    ]);
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("UniswapPoolNotInitialized()");
  });

  it("option mint fails: zero ratio position 0", async () => {
    const positionSize = 3;
    const [alice] = users;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [{ width: 0, strike: 0, riskPartner: 0, ratio: 0, tokenType: 1, asset: 0, long: true }],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          0,
          0,
        ),
    ).to.revertedWith("InvalidTokenIdParameter(1)");
  });

  it("option mint fails: invalid ratio", async () => {
    const positionSize = 3;
    const [alice] = users;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: 0, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: true },
        { width: 1, strike: 0, riskPartner: 0, ratio: 0, tokenType: 1, asset: 0, long: true },
        { width: 1, strike: 0, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: true },
      ],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          0,
          0,
        ),
    ).to.revertedWith("InvalidTokenIdParameter(1)");
  });

  it("option mint fails: invalid ratio", async () => {
    const [alice] = users;
    const positionSize = 3;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 5, strike: 1, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: false },
        { width: 5, strike: 2, riskPartner: 1, ratio: 0, tokenType: 1, asset: 0, long: false },
        { width: 5, strike: 3, riskPartner: 2, ratio: 1, tokenType: 1, asset: 0, long: false },
        { width: 5, strike: 4, riskPartner: 3, ratio: 1, tokenType: 1, asset: 0, long: false },
      ],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(1)");
  });

  it("option mint fails: invalid width", async () => {
    const [alice] = users;
    const positionSize = 3;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [{ width: 0, strike: 1, riskPartner: 0, ratio: 6, tokenType: 1, asset: 0, long: false }],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(5)");
  });

  it("option mint fails: invalid strike", async () => {
    const [alice] = users;
    const positionSize = 3;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 1,
          strike: 887272,
          riskPartner: 0,
          ratio: 6,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(4)");
  });

  it("option mint fails: invalid risk partner", async () => {
    const [alice] = users;
    const positionSize = 3;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [{ width: 1, strike: 1, riskPartner: 2, ratio: 6, tokenType: 1, asset: 0, long: true }],
    );
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(3)");
  });

  it("option mint fails: invalid risk partner pair", async () => {
    const [alice] = users;
    const positionSize = 3;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: -1, riskPartner: 1, ratio: 1, tokenType: 1, asset: 0, long: false },
        { width: 1, strike: 2, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: true },
        { width: 1, strike: 1, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: true },
      ],
    );
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(3)");
  });

  it("option mint fails: invalid risk partner parameters", async () => {
    const [alice] = users;
    const positionSize = 3;

    var tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: -1, riskPartner: 1, ratio: 1, tokenType: 1, asset: 0, long: false },
        { width: 1, strike: 1, riskPartner: 0, ratio: 1, tokenType: 1, asset: 1, long: true },
      ],
    );
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(3)");

    var tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: -1, riskPartner: 1, ratio: 2, tokenType: 1, asset: 1, long: false },
        { width: 1, strike: 1, riskPartner: 0, ratio: 1, tokenType: 1, asset: 1, long: true },
      ],
    );
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(3)");

    var tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: -1, riskPartner: 1, ratio: 1, tokenType: 1, asset: 1, long: false },
        { width: 1, strike: 1, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: true },
      ],
    );
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(3)");

    var tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: 100, riskPartner: 1, ratio: 1, tokenType: 0, asset: 0, long: true },
        {
          width: 1,
          strike: -100,
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
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(21)");

    var tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 1,
          strike: 100,
          riskPartner: 1,
          ratio: 1,
          tokenType: 0,
          asset: 0,
          long: false,
        },
        {
          width: 1,
          strike: -100,
          riskPartner: 0,
          ratio: 1,
          tokenType: 1,
          asset: 0,
          long: false,
        },
      ],
    );

    var tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        {
          width: 1,
          strike: 100,
          riskPartner: 1,
          ratio: 1,
          tokenType: 1,
          asset: 1,
          long: false,
        },
        {
          width: 1,
          strike: -100,
          riskPartner: 0,
          ratio: 1,
          tokenType: 0,
          asset: 1,
          long: true,
        },
      ],
    );
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(21)");
  });

  it("option mint fails: invalid risk partner pair different ratio or different tokenType", async () => {
    const [alice] = users;
    const positionSize = 3;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: 1, riskPartner: 1, ratio: 1, tokenType: 1, asset: 0, long: true },
        { width: 1, strike: 1, riskPartner: 0, ratio: 6, tokenType: 1, asset: 0, long: false },
        { width: 1, strike: 1, riskPartner: 2, ratio: 1, tokenType: 1, asset: 0, long: false },
      ],
    );
    await expect(
      // wrong ratio
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(3)");
    const tokenId2 = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: 1, riskPartner: 1, ratio: 1, tokenType: 1, asset: 0, long: true },
        { width: 1, strike: 1, riskPartner: 0, ratio: 1, tokenType: 0, asset: 0, long: false },
        { width: 1, strike: 1, riskPartner: 2, ratio: 1, tokenType: 1, asset: 0, long: false },
      ],
    );
    await expect(
      // wrong tokenType
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId2, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(21)");

    const tokenId3 = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: 1, riskPartner: 1, ratio: 1, tokenType: 1, asset: 0, long: true },
        { width: 1, strike: 1, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: true },
        { width: 1, strike: 1, riskPartner: 2, ratio: 1, tokenType: 1, asset: 0, long: false },
      ],
    );

    await expect(
      // same long value
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId3, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(21)");

    const tokenId4 = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: 1, riskPartner: 1, ratio: 1, tokenType: 1, asset: 0, long: true },
        { width: 1, strike: 1, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: false },
        { width: 1, strike: 1, riskPartner: 2, ratio: 1, tokenType: 1, asset: 0, long: false },
      ],
    );
    await expect(
      // same strike+width
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId4, positionSize, 0, 0),
    ).to.revertedWith("InvalidTokenIdParameter(4)");

    const tokenId5 = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [
        { width: 1, strike: -1, riskPartner: 1, ratio: 1, tokenType: 1, asset: 0, long: true },
        { width: 1, strike: 1, riskPartner: 0, ratio: 1, tokenType: 1, asset: 0, long: false },
        { width: 1, strike: 1, riskPartner: 2, ratio: 1, tokenType: 1, asset: 0, long: false },
      ],
    );
  });

  it("option mint fails: 0 options", async () => {
    const [alice] = users;
    const positionSize = 0;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [{ width: 1, strike: 1, riskPartner: 0, ratio: 6, tokenType: 1, asset: 0, long: true }],
    );
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0),
    ).to.revertedWith("OptionsBalanceZero()");
  });

  xit("option mint succeeds", async () => {
    const positionSize = 3;
    const [alice] = users;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [{ width: 1, strike: 2, riskPartner: 0, ratio: 4, tokenType: 1, asset: 0, long: false }],
    );
    //await expect(
    //  positionManager.connect(alice)["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId.toString(), positionSize, 0, 0)
    //).to.emit(positionManager, "TokenizedPositionMinted");

    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
        tokenId.toString(),
        positionSize,
        0,
        0,
      );

    const receipt = await resolved.wait();
  });

  it("fails to mint options on 'no option minted'", async () => {
    const [alice] = users;

    const tokenId = OptionEncoding.encodeID(
      BigInt(pool.address.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [{ width: 1, strike: 0, riskPartner: 0, ratio: 6, tokenType: 1, asset: 0, long: true }],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, 0, 0, 0),
    ).to.revertedWith("OptionsBalanceZero()");
  });

  xit("option burn succeeds", async () => {
    const [alice] = users;
    const positionSize = 3;
    const poolId = pool.address.slice(0, 18).toLowerCase();

    const tokenId = OptionEncoding.encodeID(
      BigInt(poolId), // extract first 8 bytes for pool id
      [{ width: 1, strike: 2, riskPartner: 0, ratio: 4, tokenType: 0, asset: 0, long: false }],
    );
    const resolved = await positionManager
      .connect(alice)
      ["mintTokenizedPosition(uint256,uint128,int24,int24)"](tokenId, positionSize, 0, 0);
    const receipt = await resolved.wait();

    const resolvedB = await positionManager
      .connect(alice)
      .burnTokenizedPosition(
        tokenId,
        await positionManager.balanceOf(await alice.getAddress(), tokenId.toString()),
        0,
        0,
      );

    const receiptB = await resolvedB.wait();
  });

  it("permission checks uniswapV3MintCallback", async () => {
    const [alice] = users;
    const encoded_data = ethers.utils.defaultAbiCoder.encode(
      ["address", "address", "uint24", "address"],
      [token0.address, token1.address, 0, alice.address],
    );

    await expect(positionManager.connect(alice).uniswapV3MintCallback(100, 100, encoded_data)).to.be
      .reverted;
  });

  it("allows the mock Univ3pool to modify the current tick", async () => {
    const MockUniswapV3Pool__factory = await ethers.getContractFactory("MockUniswapV3Pool");
    const ppool = await MockUniswapV3Pool__factory.deploy(token0.address, token1.address, 0, 40000);

    expect(await ppool.tick()).to.equal(40000);

    let tx = await ppool.setCurrentTick(100);
    await tx.wait();
    expect(await ppool.tick()).to.equal(100);

    tx = await ppool.setCurrentTick(-212);
    await tx.wait();
    expect(await ppool.tick()).to.equal(-212);
  });

  it("allows getting the fee growth parameters", async () => {
    const MockUniswapV3Pool__factory = await ethers.getContractFactory("MockUniswapV3Pool");
    const ppool = await MockUniswapV3Pool__factory.deploy(token0.address, token1.address, 0, 40000);

    expect(await ppool.feeGrowthGlobal0X128()).to.equal(0);
    expect(await ppool.feeGrowthGlobal1X128()).to.equal(0);
  });

  it("initializes a pool", async () => {
    const positionSize = 3;
    const [alice] = users;

    const ETH_USDC_POOL_ADDRESS = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640";
    const USDC_ADDRESS = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
    const WETH_ADDRESS = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";

    const tokenId = OptionEncoding.encodeID(
      BigInt(ETH_USDC_POOL_ADDRESS.slice(0, 18).toLowerCase()), // extract first 8 bytes for pool id
      [{ width: 1, strike: 2, riskPartner: 0, ratio: 4, tokenType: 1, asset: 0, long: false }],
    );

    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          0,
          0,
        ),
    ).to.revertedWith("UniswapPoolNotInitialized()");

    // initialize the pool
    await expect(
      positionManager.initializeAMMPool(USDC_ADDRESS, WETH_ADDRESS, 501),
    ).to.be.revertedWith("UniswapPoolNotInitialized()");

    // initialize the pool
    // to do this the caller (deployer) needs funds... b/c of the donation to full-range
    const { address: sfpmAddress } = await deployments.get("SemiFungiblePositionManager");
    const { deployer, seller, buyer } = await getNamedAccounts();
    const [deployerSigner] = await ethers.getSigners();
    const WETH_SLOT = 3;
    const USDC_SLOT = 9;

    const usdcBalance = ethers.utils.parseUnits("520000000", "6");
    const wethBalance = ethers.utils.parseEther("1000");

    await grantTokens(WETH_ADDRESS, deployer, WETH_SLOT, wethBalance);
    await grantTokens(USDC_ADDRESS, deployer, USDC_SLOT, usdcBalance);
    await IERC20__factory.connect(WETH_ADDRESS, deployerSigner).approve(
      sfpmAddress,
      ethers.constants.MaxUint256,
    );
    await IERC20__factory.connect(USDC_ADDRESS, deployerSigner).approve(
      sfpmAddress,
      ethers.constants.MaxUint256,
    );
    // now we are ready to initialize a pool:
    await expect(positionManager.initializeAMMPool(USDC_ADDRESS, WETH_ADDRESS, 500))
      .to.emit(positionManager, "PoolInitialized")
      .withArgs("0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640");

    // initialize the pool again, nothing emitted
    await expect(positionManager.initializeAMMPool(USDC_ADDRESS, WETH_ADDRESS, 500));

    // passes pool id check
    await expect(
      positionManager
        .connect(alice)
        ["mintTokenizedPosition(uint256,uint128,int24,int24)"](
          tokenId.toString(),
          positionSize,
          0,
          0,
        ),
    ).to.revertedWith("PriceBoundFail()");
  });
});
