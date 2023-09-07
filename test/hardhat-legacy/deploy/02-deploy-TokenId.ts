/**
 * Deploy the TokenId library. The tokenId fingerprints each option position into the ERC1155 token.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const deployTokenId: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();

  if (process.env.WITH_PROXY) return;

  await deploy("TokenId", {
    from: deployer,
    log: true,
  });
};

export default deployTokenId;
deployTokenId.tags = ["TokenId"];
