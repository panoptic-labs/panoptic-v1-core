/**
 * Deploy the PanopticHelper - a utility contract for token ID construction and advanced queries.
 * @author Axicon Labs Limited
 * @year 2023
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployments } from "hardhat";

const deployPanopticHelper: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  const { address: panopticMathLibAddress } = await deployments.get("PanopticMath");
  const { address: tokenIdLibAddress } = await deployments.get("TokenId");
  const { address: sfpmAddress } = await deployments.get("SemiFungiblePositionManager");

  await deploy("PanopticHelper", {
    from: deployer,
    args: [sfpmAddress],
    libraries: {
      PanopticMath: panopticMathLibAddress,
      TokenId: tokenIdLibAddress,
    },
    log: true,
  });
};

export default deployPanopticHelper;
deployPanopticHelper.tags = ["PanopticHelper"];
