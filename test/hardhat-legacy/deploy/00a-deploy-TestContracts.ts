/**
 * Deploy the test contracts. These are not going into Production.
 * @note NOT FOR PRODUCTION.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployments } from "hardhat";

const deployTestContracts: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;
  const { deployer } = await getNamedAccounts();
  if (process.env.WITH_PROXY) return;

  // ======================== Initial Deployments ==============================
  await deploy("TestLiquidityChunk", {
    from: deployer,
    log: true,
  });

  await deploy("TestTickPriceFeeInfo", {
    from: deployer,
    log: true,
  });

  await deploy("TestTickLimits", {
    from: deployer,
    log: true,
  });

  await deploy("TestTokenId", {
    from: deployer,
    log: true,
  });

  await deploy("TestLeftRight", {
    from: deployer,
    log: true,
  });

  // ======================== TestMath Deployment ==============================
  await deploy("Math", {
    from: deployer,
    log: true,
  });
  const { address: mathLibAddress } = await deployments.get("Math");
  await deploy("TestMath", {
    from: deployer,
    log: true,
    libraries: {
      Math: mathLibAddress,
    },
  });

  // ======================== TestPanopticMath Deployment ==============================
  await deploy("LeftRight", {
    from: deployer,
    log: true,
  });
  await deploy("TokenId", {
    from: deployer,
    log: true,
  });
  const { address: leftRightLibAddress } = await deployments.get("LeftRight");
  const { address: tokenIdAddress } = await deployments.get("TokenId");

  await deploy("PanopticMath", {
    from: deployer,
    log: true,
    libraries: {
      Math: mathLibAddress,
      LeftRight: leftRightLibAddress,
      TokenId: tokenIdAddress,
    },
  });

  const { address: panopticMathAddress } = await deployments.get("PanopticMath");

  await deploy("TestPanopticMath", {
    from: deployer,
    log: true,
    libraries: {
      PanopticMath: panopticMathAddress,
      Math: mathLibAddress,
      LeftRight: leftRightLibAddress,
      TokenId: tokenIdAddress,
    },
  });

  // ======================== OTHER TEST Deployments ==============================
  await deploy("FeesCalc", {
    from: deployer,
    log: true,
    libraries: {
      PanopticMath: panopticMathAddress,
      LeftRight: leftRightLibAddress,
      TokenId: tokenIdAddress,
    },
  });

  const { address: feesCalcAddress } = await deployments.get("FeesCalc");

  await deploy("TestSemiFungiblePositionManager", {
    from: deployer,
    libraries: {
      PanopticMath: panopticMathAddress,
      FeesCalc: feesCalcAddress,
      LeftRight: leftRightLibAddress,
      TokenId: tokenIdAddress,
    },
    log: true,
  });
};

// ======================== EXPORT ALL TEST CONTRACTS ==============================

export default deployTestContracts;
deployTestContracts.tags = [
  "ISwapRouter",
  "TestTokenId",
  "TestLeftRight",
  "TestLiquidityChunk",
  "TestTickPriceFeeInfo",
  "TestTickLimits",
  "TestMath",
  "TestPanopticMath",
  "TestSemiFungiblePositionManager",
];
