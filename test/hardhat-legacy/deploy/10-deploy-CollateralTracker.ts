/**
 * Deploy the Panoptic Factory capable of spinning up new options pools on top of Univ3 pairs.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const deployCollateralTracker: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments,
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  const { address: mathLibAddress } = await deployments.get("Math");
  const { address: panopticMathLibAddress } = await deployments.get("PanopticMath");
  const { address: interactionHelperLibAddress } = await deployments.get("InteractionHelper");
  await deploy("CollateralTracker", {
    from: deployer,
    libraries: {
      Math: mathLibAddress,
      PanopticMath: panopticMathLibAddress,
      InteractionHelper: interactionHelperLibAddress,
    },
    log: true,
  });
};

export default deployCollateralTracker;
deployCollateralTracker.tags = ["CollateralTracker"];
