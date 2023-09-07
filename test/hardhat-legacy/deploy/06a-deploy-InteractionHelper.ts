/**
 * Deploy the InteractionHelper library.
 * @author Axicon Labs Limited
 * @year 2023
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployments } from "hardhat";

const deployInteractionHelper: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  await deploy("InteractionHelper", {
    from: deployer,
    log: true,
  });
};

export default deployInteractionHelper;
deployInteractionHelper.tags = ["InteractionHelper"];
