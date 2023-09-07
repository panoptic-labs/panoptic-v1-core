/**
 * Deploy the Fee Calculation library helpful for calculating fees from the concentrated liquidity AMM.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployments } from "hardhat";

const deployFeesCalc: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  const { address: panopticMathLibAddress } = await deployments.get("PanopticMath");
  const { address: leftRightLibAddress } = await deployments.get("LeftRight");
  const { address: tokenIdLibAddress } = await deployments.get("TokenId");

  await deploy("FeesCalc", {
    from: deployer,
    log: true,
    libraries: {
      PanopticMath: panopticMathLibAddress,
      LeftRight: leftRightLibAddress,
      TokenId: tokenIdLibAddress,
    },
  });
};

export default deployFeesCalc;
deployFeesCalc.tags = ["FeesCalc"];
