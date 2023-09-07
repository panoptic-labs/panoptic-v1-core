/**
 * Deploy the Core Math library.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const deployMath: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  await deploy("Math", {
    contract: "src/contracts/libraries/Math.sol:Math",
    from: deployer,
    log: true,
  });
};

export default deployMath;
deployMath.tags = ["Math"];
