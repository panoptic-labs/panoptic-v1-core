/**
 * Test the Panoptic Factory.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { deployments, ethers, network } from "hardhat";
import { expect } from "chai";
import { PanopticPool } from "../../typechain";
import { revertReason, revertCustom } from "../utils";

import { Signer } from "ethers";

const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

describe("Panoptic Factory Owner Operations", async function () {
  const contractName = "PanopticPool";
  const deploymentName = "PanopticPool-ETH-USDC";

  let pool: PanopticPool;

  let deployer: Signer;
  let optionWriter: Signer;
  let optionBuyer: Signer;
  let liquidityProvider: Signer;
  let swapper: Signer;

  beforeEach(async () => {
    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.NODE_URL,
            blockNumber: 14487083,
          },
        },
      ],
    });
    await deployments.fixture([
      deploymentName,
      "PanopticFactory",
      "CollateralTracker",
      "PanopticPool",
      "LeftRight",
      "TokenId",
      "FeesCalc",
      "OptionEncoding",
      "Math",
      "PanopticMath",
      "InteractionHelper",
      "SemiFungiblePositionManager",
    ]);
    const { address } = await deployments.get(deploymentName);

    [deployer, optionWriter, optionBuyer, liquidityProvider, swapper] = await ethers.getSigners();

    pool = (await ethers.getContractAt(contractName, address)) as PanopticPool;
  });

  it("should not update base parameters: not factoryOwner", async function () {
    await expect(
      pool.connect(swapper).updateParameters([0, 0, 0, 0, 0, 0, 0, 0, 0])
    ).to.be.revertedWith("NotOwner()");
  });

  it("should update base parameters", async function () {
    await pool.connect(deployer).updateParameters([0, 0, 0, 0, 0, 0, 0, 0, 0]);
  });
});
