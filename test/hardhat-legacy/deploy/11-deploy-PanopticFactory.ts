/**
 * Deploy the Panoptic Factory capable of spinning up new options pools on top of Univ3 pairs.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const deployPanopticFactory: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
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
  const { address: panopticPoolAddress } = await deployments.get("PanopticPool");
  const { address: collateralTrackerAddress } = await deployments.get("CollateralTracker");

  const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  await deploy("PanopticFactory", {
    from: deployer,
    args: [
      WETH_ADDRESS,
      sfpmAddress,
      "0x1F98431c8aD98523631AE4a59f267346ea31F984",
      panopticPoolAddress,
      collateralTrackerAddress,
    ],
    libraries: {
      Math: mathLibAddress,
      PanopticMath: panopticMathLibAddress,
      FeesCalc: feesCalcLibAddress,
    },
    log: true,
  });
};

export default deployPanopticFactory;
deployPanopticFactory.tags = ["PanopticFactory"];
