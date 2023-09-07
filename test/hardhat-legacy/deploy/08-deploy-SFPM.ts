/**
 * Deploy the SemiFungiblePositionManager - the ERC1155 to handle option positions.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployments } from "hardhat";

const deploySFPM: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  const { address: panopticMathLibAddress } = await deployments.get("PanopticMath");
  const { address: feesCalcLibAddress } = await deployments.get("FeesCalc");
  const { address: leftRightLibAddress } = await deployments.get("LeftRight");
  const { address: tokenIdLibAddress } = await deployments.get("TokenId");

  await deploy("LiquidityChunk", {
    from: deployer,
    log: true,
  });

  const { address: liquidityChunkAddress } = await deployments.get("LiquidityChunk");

  const UNISWAPV3_FACTORY_ADDRESS = "0x1F98431c8aD98523631AE4a59f267346ea31F984";

  await deploy("SemiFungiblePositionManager", {
    from: deployer,
    args: [UNISWAPV3_FACTORY_ADDRESS],
    libraries: {
      PanopticMath: panopticMathLibAddress,
      FeesCalc: feesCalcLibAddress,
      LeftRight: leftRightLibAddress,
      TokenId: tokenIdLibAddress,
      LiquidityChunk: liquidityChunkAddress,
    },
    log: true,
  });
};

export default deploySFPM;
deploySFPM.tags = ["SemiFungiblePositionManager"];
