/**
 * Deploy an example Panoptic Pool on the ETH/USDC Univ3 pool.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { ABI, DeployFunction } from "hardhat-deploy/types";
import { deployments, ethers } from "hardhat";
import { IERC20__factory, PanopticFactory } from "../typechain";
import { grantTokens } from "../test/utils";
const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const WETH_SLOT = 3;

const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_SLOT = 9;

const usdcBalance = ethers.utils.parseUnits("100000000", "6");
const wethBalance = ethers.utils.parseEther("1000");

// deploy/0-deploy-Greeter.ts
const deployPanopticPool100: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;

  if (process.env.WITH_PROXY) return;

  const { address: factoryAddress } = await deployments.get("PanopticFactory");
  const { address: panopticMathLibAddress } = await deployments.get("PanopticMath");
  const { address: feesCalcLibAddress } = await deployments.get("FeesCalc");
  const { address: interactionHelperLibAddress } = await deployments.get("InteractionHelper");

  const factory = (await ethers.getContractAt(
    "PanopticFactory",
    factoryAddress
  )) as PanopticFactory;

  //granting USDC and WETH
  const { deployer, seller, buyer } = await getNamedAccounts();
  const [deployerSigner] = await ethers.getSigners();

  await grantTokens(WETH_ADDRESS, deployer, WETH_SLOT, wethBalance);
  await grantTokens(USDC_ADDRESS, deployer, USDC_SLOT, usdcBalance);

  await grantTokens(WETH_ADDRESS, seller, WETH_SLOT, wethBalance);
  await grantTokens(USDC_ADDRESS, seller, USDC_SLOT, usdcBalance);

  await grantTokens(WETH_ADDRESS, buyer, WETH_SLOT, wethBalance);
  await grantTokens(USDC_ADDRESS, buyer, USDC_SLOT, usdcBalance);

  const { address: sfpmAddress } = await deployments.get("SemiFungiblePositionManager");

  await IERC20__factory.connect(WETH_ADDRESS, deployerSigner).approve(
    factoryAddress,
    ethers.constants.MaxUint256
  );
  await IERC20__factory.connect(USDC_ADDRESS, deployerSigner).approve(
    factoryAddress,
    ethers.constants.MaxUint256
  );

  const deployPoolTx = await factory.deployNewPool(USDC_ADDRESS, WETH_ADDRESS, 10000, 0);
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

  await deployments.save("PanopticPool-ETH-USDC-100", { address: poolAddress, abi: abi as ABI });
};

export default deployPanopticPool100;
deployPanopticPool100.tags = ["PanopticPool-ETH-USDC-100"];
