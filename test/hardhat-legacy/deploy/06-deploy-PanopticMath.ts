/**
 * Deploy the Panoptic Math library. Math helper functions specific to Panoptic.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployments } from "hardhat";

const deployPanopticMath: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  const { address: MathLibAddress } = await deployments.get("Math");
  const { address: leftRightLibAddress } = await deployments.get("LeftRight");
  const { address: tokenIdLibAddress } = await deployments.get("TokenId");

  await deploy("PanopticMath", {
    from: deployer,
    log: true,
    libraries: {
      Math: MathLibAddress,
      LeftRight: leftRightLibAddress,
      TokenId: tokenIdLibAddress,
    },
  });
};

export default deployPanopticMath;
deployPanopticMath.tags = ["PanopticMath"];
