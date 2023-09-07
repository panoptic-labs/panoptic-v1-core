/**
 * Deploy the Panoptic Factory capable of spinning up new options pools on top of Univ3 pairs.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const deployPanopticPool: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments,
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  const { address: mathLibAddress } = await deployments.get("Math");
  const { address: panopticMathLibAddress } = await deployments.get("PanopticMath");
  const { address: feesCalcLibAddress } = await deployments.get("FeesCalc");
  const { address: sfpmAddress } = await deployments.get("SemiFungiblePositionManager");
  const { address: interactionHelperLibAddress } = await deployments.get("InteractionHelper");

  await deploy("PanopticPool", {
    from: deployer,
    args: [sfpmAddress],
    libraries: {
      Math: mathLibAddress,
      PanopticMath: panopticMathLibAddress,
      FeesCalc: feesCalcLibAddress,
      InteractionHelper: interactionHelperLibAddress,
    },
    log: true,
  });
};

export default deployPanopticPool;
deployPanopticPool.tags = ["PanopticPool"];
