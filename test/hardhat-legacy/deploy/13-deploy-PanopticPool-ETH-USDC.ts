/**
 * Deploy an example Panoptic Pool on the ETH/USDC Univ3 pool.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { ABI, DeployFunction } from "hardhat-deploy/types";
import { ethers } from "hardhat";
import { IERC20__factory, PanopticFactory } from "../typechain";
import { grantTokens } from "../test/utils";

const deployPanopticPool: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  if (process.env.WITH_PROXY) return;

  const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  const WETH_SLOT = 3;

  const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const USDC_SLOT = 9;

  // =4744124650659840, make sure no leading zeros or else hardhat errors out
  const usdcBalance = ethers.BigNumber.from("0x10dac19892a000");
  const wethBalance = ethers.utils.parseEther(ethers.BigNumber.from("0x10dac19892a000").toString());

  const { address: factoryAddress } = await deployments.get("PanopticFactory");
  const { address: panopticMathLibAddress } = await deployments.get("PanopticMath");
  const { address: feesCalcLibAddress } = await deployments.get("FeesCalc");
  const { address: interactionHelperLibAddress } = await deployments.get("InteractionHelper");

  const { address: sfpmAddress } = await deployments.get("SemiFungiblePositionManager");

  const { deployer, seller, buyer } = await getNamedAccounts();
  const [deployerSigner] = await ethers.getSigners();

  //granting USDC and WETH
  await grantTokens(WETH_ADDRESS, deployer, WETH_SLOT, wethBalance);
  await grantTokens(USDC_ADDRESS, deployer, USDC_SLOT, usdcBalance);

  await grantTokens(WETH_ADDRESS, seller, WETH_SLOT, wethBalance);
  await grantTokens(USDC_ADDRESS, seller, USDC_SLOT, usdcBalance);

  await grantTokens(WETH_ADDRESS, buyer, WETH_SLOT, wethBalance);
  await grantTokens(USDC_ADDRESS, buyer, USDC_SLOT, usdcBalance);

  // SINCE deployment of a pool costs money (to create the full-range chunk)
  // make sure to allow access from the SFPM to the deployer's funds
  // this is in order for the SFPM (which, in turn, is called from the factory)
  // to move funds from the deployer to uniswap on initial deployment (the full-range amount)
  await IERC20__factory.connect(WETH_ADDRESS, deployerSigner).approve(
    factoryAddress,
    ethers.constants.MaxUint256
  );
  await IERC20__factory.connect(USDC_ADDRESS, deployerSigner).approve(
    factoryAddress,
    ethers.constants.MaxUint256
  );

  const factory = (await ethers.getContractAt(
    "PanopticFactory",
    factoryAddress
  )) as PanopticFactory;

  const deployPoolTx = await factory
    .connect(deployerSigner)
    .deployNewPool(USDC_ADDRESS, WETH_ADDRESS, 500, 1500);
  const receipt = await deployPoolTx.wait();
  const { poolAddress } = receipt.events![receipt.events.length - 1].args!; // get the panoptic pool address from the PoolDeployed event
  const pool = await ethers.getContractFactory("PanopticPool", {
    libraries: {
      PanopticMath: panopticMathLibAddress,
      FeesCalc: feesCalcLibAddress,
      InteractionHelper: interactionHelperLibAddress,
    },
  });
  const abi = pool.interface.format(ethers.utils.FormatTypes.json);

  await deployments.save("PanopticPool-ETH-USDC", { address: poolAddress, abi: abi as ABI });
};

export default deployPanopticPool;
deployPanopticPool.tags = ["PanopticPool-ETH-USDC"];
