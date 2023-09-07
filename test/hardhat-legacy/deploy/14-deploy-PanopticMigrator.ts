/**
 * Deploy the PanopticMigrator - a tool to migrate NFPM liquidity to the SFPM.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployments } from "hardhat";

const deployPanopticMigrator: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  const { address: panopticMathLibAddress } = await deployments.get("PanopticMath");
  const { address: tokenIdLibAddress } = await deployments.get("TokenId");
  const { address: sfpmAddress } = await deployments.get("SemiFungiblePositionManager");

  await deploy("LiquidityChunk", {
    from: deployer,
    log: true,
  });

  const UNISWAPV3_FACTORY_ADDRESS = "0x1F98431c8aD98523631AE4a59f267346ea31F984";
  const NFPM_ADDRESS = "0xC36442b4a4522E871399CD717aBDD847Ab11FE88";

  await deploy("PanopticMigrator", {
    from: deployer,
    args: [NFPM_ADDRESS, sfpmAddress, UNISWAPV3_FACTORY_ADDRESS],
    libraries: {
      PanopticMath: panopticMathLibAddress,
      TokenId: tokenIdLibAddress,
    },
    log: true,
  });
};

export default deployPanopticMigrator;
deployPanopticMigrator.tags = ["PanopticMigrator"];
