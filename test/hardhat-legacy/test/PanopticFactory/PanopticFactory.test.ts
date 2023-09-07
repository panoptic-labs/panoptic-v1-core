/**
 * Test the Panoptic Factory.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { deployments, ethers, getNamedAccounts, network } from "hardhat";
import { expect } from "chai";
import { IERC20__factory, PanopticFactory } from "../../typechain";
import { BigNumber, Signer } from "ethers";
import { revertReason, revertCustom, grantTokens } from "../utils";
const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

const FRAX_ADDRESS = "0x853d955aCEf822Db058eb8505911ED77F175b99e";
const UNI_ADDRESS = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984";

describe("PanopticFactory", function () {
  const contractName = "PanopticFactory";
  let factory: PanopticFactory;

  let deployer: Signer;
  let optionWriter: Signer;
  let attacker: Signer;
  let alice: Signer;

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
      contractName,
      "CollateralTracker",
      "PanopticPool",
      "LeftRight",
      "TokenId",
      "Math",
      "PanopticMath",
      "InteractionHelper",
      "FeesCalc",
      "SemiFungiblePositionManager",
    ]);
    const { address } = await deployments.get(contractName);

    factory = (await ethers.getContractAt(contractName, address)) as PanopticFactory;

    [deployer, optionWriter, attacker, alice] = await ethers.getSigners();
  });

  describe("General Panoptic Factory Tests", async () => {
    it("should deploy the factory", async function () {
      expect(factory.address).to.be.not.undefined;
    });

    it("should not setOwner: not factory owner", async function () {
      await expect(
        factory.connect(optionWriter).setOwner(optionWriter.getAddress()),
      ).to.be.revertedWith(revertCustom("NotOwner()"));
    });

    it("should setOwner", async function () {
      await expect(
        factory.connect(optionWriter).setOwner(optionWriter.getAddress()),
      ).to.be.revertedWith(revertCustom("NotOwner()"));

      await expect(factory.factoryOwner().toString()).to.equal(deployer.getAddress().toString());
      await factory.connect(deployer).setOwner(optionWriter.getAddress());
      await expect(factory.factoryOwner().toString()).to.equal(
        optionWriter.getAddress().toString(),
      );

      await expect(factory.connect(deployer).setOwner(deployer.getAddress())).to.be.revertedWith(
        revertCustom("NotOwner()"),
      );

      await factory.connect(optionWriter).setOwner(deployer.getAddress());
      await expect(factory.factoryOwner().toString()).to.equal(deployer.getAddress().toString());
    });

    it("should not deploy on top of non-existing pool", async function () {
      await expect(factory.deployNewPool(UNI_ADDRESS, FRAX_ADDRESS, 500, 1)).to.be.revertedWith(
        revertCustom("UniswapPoolNotInitialized()"),
      );
      await expect(factory.deployNewPool(UNI_ADDRESS, FRAX_ADDRESS, 3000, 2)).to.be.revertedWith(
        revertCustom("UniswapPoolNotInitialized()"),
      );
      await expect(factory.deployNewPool(UNI_ADDRESS, FRAX_ADDRESS, 10000, 3)).to.be.revertedWith(
        revertCustom("UniswapPoolNotInitialized()"),
      );
    });

    it("should not deploy on top of existing Panoptic pool", async function () {
      const uniBalance = ethers.utils.parseEther("1000");
      const wethBalance = ethers.utils.parseEther("1000");
      const WETH_SLOT = 3;
      const UNI_SLOT = 4;
      await grantTokens(WETH_ADDRESS, await deployer.getAddress(), WETH_SLOT, wethBalance);
      await grantTokens(UNI_ADDRESS, await deployer.getAddress(), UNI_SLOT, uniBalance);
      const { address: sfpmAddress } = await deployments.get("SemiFungiblePositionManager");
      await IERC20__factory.connect(WETH_ADDRESS, deployer).approve(
        sfpmAddress,
        ethers.constants.MaxUint256,
      );
      await IERC20__factory.connect(UNI_ADDRESS, deployer).approve(
        sfpmAddress,
        ethers.constants.MaxUint256,
      );

      await IERC20__factory.connect(WETH_ADDRESS, deployer).approve(
        factory.address,
        ethers.constants.MaxUint256,
      );
      await IERC20__factory.connect(UNI_ADDRESS, deployer).approve(
        factory.address,
        ethers.constants.MaxUint256,
      );

      await factory.deployNewPool(UNI_ADDRESS, WETH_ADDRESS, 3000, 3);

      await expect(factory.deployNewPool(UNI_ADDRESS, WETH_ADDRESS, 3000, 4)).to.be.revertedWith(
        revertCustom("PoolAlreadyInitialized()"),
      );
      await expect(factory.deployNewPool(WETH_ADDRESS, UNI_ADDRESS, 3000, 5)).to.be.revertedWith(
        revertCustom("PoolAlreadyInitialized()"),
      );
      //await factory.minePoolAddress(UNI_ADDRESS, WETH_ADDRESS, 500, 350, deployer.getAddress(), 250);
      await factory.deployNewPool(UNI_ADDRESS, WETH_ADDRESS, 500, 381);
    });

    it("Should fail on setting the wrong owners", async function () {
      let deployaddr = (await deployer.getAddress()).toString();
      let attackaddr = (await attacker.getAddress()).toString();

      // make sure current owner is deployer
      expect(await factory.factoryOwner()).to.equal(deployaddr);

      // cannot set new owner if not current owner
      await expect(factory.connect(attacker).setOwner(attackaddr)).to.be.revertedWith(
        revertCustom("NotOwner()"),
      );

      // should be able to set new owner if called from current owner
      await expect(factory.setOwner(attackaddr));
      await expect(await factory.factoryOwner()).to.not.equal(deployaddr);
      await expect(await factory.factoryOwner()).to.equal(attackaddr);

      // switch back to deployer
      await expect(factory.connect(attacker).setOwner(deployaddr));
      await expect(await factory.factoryOwner()).to.equal(deployaddr);

      // make sure it emits the owner changed event
      await expect(factory.setOwner(attackaddr))
        .to.emit(factory, "OwnerChanged")
        .withArgs(deployaddr, attackaddr);
    });
  });

  describe("Mining NFTs for pool address rarity", async () => {
    it("Should be able to mine pool addresses", async () => {
      let deployaddr = (await deployer.getAddress()).toString();
      let result = await factory.minePoolAddress(
        UNI_ADDRESS,
        WETH_ADDRESS,
        3000,
        0,
        deployaddr,
        100,
        0,
      );

      let saltBefore = result[0];
      let rarityBefore = result[1];

      // now set min target of 2, should be the same; but have many loops
      result = await factory.minePoolAddress(
        UNI_ADDRESS,
        WETH_ADDRESS,
        3000,
        0,
        deployaddr,
        2500,
        rarityBefore,
      );
      expect(result[0]).to.equal(saltBefore); // salt
      expect(result[1]).to.equal(rarityBefore); // rarity

      // now have higher rarity plus more loops
      result = await factory.minePoolAddress(
        UNI_ADDRESS,
        WETH_ADDRESS,
        3000,
        0,
        deployaddr,
        2500,
        rarityBefore.add(1),
      );
      expect(result[0]).to.not.equal(saltBefore); // salt
      expect(result[1]).to.equal(rarityBefore.add(1)); // rarity
    });

    it("Should deploy a factory with expected mined address - zero leading zeroes", async () => {
      const { address: sfpmAddress } = await deployments.get("SemiFungiblePositionManager");
      let deployaddr = (await deployer.getAddress()).toString();
      const [deployerSigner] = await ethers.getSigners();
      const WETH_SLOT = 3;
      const USDC_SLOT = 9;

      // give enough tokens to deploy the pool
      const usdcBalance = ethers.utils.parseUnits("99799280149059410", "6");
      const wethBalance = ethers.utils.parseEther("29457207873288923643068749");

      await grantTokens(WETH_ADDRESS, deployaddr, WETH_SLOT, wethBalance);
      await grantTokens(USDC_ADDRESS, deployaddr, USDC_SLOT, usdcBalance);
      await IERC20__factory.connect(WETH_ADDRESS, deployerSigner).approve(
        sfpmAddress,
        ethers.constants.MaxUint256,
      );
      await IERC20__factory.connect(USDC_ADDRESS, deployerSigner).approve(
        sfpmAddress,
        ethers.constants.MaxUint256,
      );

      let result = await factory.minePoolAddress(
        USDC_ADDRESS,
        WETH_ADDRESS,
        3000,
        0,
        deployaddr,
        0,
        0,
      );
      let rarity = result[1];
      expect(rarity).to.equal("0"); // rarity is 0
    });

    it("Should deploy a factory with expected mined address - two leading zero - and should allow transfer of the nft", async () => {
      const { address: sfpmAddress } = await deployments.get("SemiFungiblePositionManager");
      let deployaddr = (await deployer.getAddress()).toString();
      const [deployerSigner] = await ethers.getSigners();
      const WETH_SLOT = 3;
      const USDC_SLOT = 9;

      // give enough tokens to deploy the pool
      const usdcBalance = ethers.utils.parseUnits("997992801490594100", "6");
      const wethBalance = ethers.utils.parseEther("294572078732889236430687490");

      await grantTokens(WETH_ADDRESS, deployaddr, WETH_SLOT, wethBalance);
      await grantTokens(USDC_ADDRESS, deployaddr, USDC_SLOT, usdcBalance);
      await IERC20__factory.connect(WETH_ADDRESS, deployerSigner).approve(
        sfpmAddress,
        ethers.constants.MaxUint256,
      );
      await IERC20__factory.connect(USDC_ADDRESS, deployerSigner).approve(
        sfpmAddress,
        ethers.constants.MaxUint256,
      );

      await IERC20__factory.connect(WETH_ADDRESS, deployerSigner).approve(
        factory.address,
        ethers.constants.MaxUint256,
      );
      await IERC20__factory.connect(USDC_ADDRESS, deployerSigner).approve(
        factory.address,
        ethers.constants.MaxUint256,
      );

      // set rarity target to 1 now
      let result = await factory.minePoolAddress(
        USDC_ADDRESS,
        WETH_ADDRESS,
        3000,
        3000,
        deployaddr,
        2000,
        2,
      );
      let rarity = result[1];

      expect(rarity).to.equal("2"); // rarity is 2
      expect(rarity).to.not.equal("0");

      // make sure the NFT balance before mint is 0
      expect(await factory.balanceOf(deployaddr, 0)).to.equal(0);
      expect(await factory.balanceOf(deployaddr, 1)).to.equal(0); // zero before mint
      expect(await factory.balanceOf(deployaddr, 2)).to.equal(0);

      // now deploy using the salt found (result[0])
      const tx = await factory.deployNewPool(WETH_ADDRESS, USDC_ADDRESS, 3000, result[0]);
      const receipt = await tx.wait();

      expect(receipt.events[receipt.events.length - 1].args[0].startsWith("0x00")).to.be.true;
      // ^^^ note that the pool address indeed has 1 leading zero!

      // make sure the caller received their NFT
      expect(await factory.balanceOf(deployaddr, 0)).to.equal(0); // zero not a valid id for the nfts
      expect(await factory.balanceOf(deployaddr, 1)).to.equal(1); // now the deployer got the NFT
      expect(await factory.balanceOf(deployaddr, 2)).to.equal(0);

      // someone else:
      let aliceaddr = (await alice.getAddress()).toString();

      expect(await factory.balanceOf(aliceaddr, 0)).to.equal(0);
      expect(await factory.balanceOf(aliceaddr, 1)).to.equal(0);
      expect(await factory.balanceOf(aliceaddr, 2)).to.equal(0);

      expect(await factory.uri(0)).to.equal("");
      expect(await factory.uri(1)).to.equal("");
      expect(await factory.uri(2)).to.equal("");

      // the user can transfer the NFT if they want:
      // give the factory access to the nft
      // the deployer sends a tx to the factory setting the factory's own address as approved
      factory.connect(deployer).setApprovalForAll(factory.address, true);

      // first: alice shouldn't be able to steal the NFT
      await expect(factory.connect(alice).safeTransferFrom(deployaddr, aliceaddr, 1, 1, [])).to.be
        .reverted;

      // first: alice shouldn't be able to steal the NFT
      await factory.connect(deployer).safeTransferFrom(deployaddr, aliceaddr, 1, 1, []);

      // now alice owns the nft
      expect(await factory.balanceOf(deployaddr, 0)).to.equal(0);
      expect(await factory.balanceOf(deployaddr, 1)).to.equal(0);
      expect(await factory.balanceOf(deployaddr, 2)).to.equal(0);

      expect(await factory.balanceOf(aliceaddr, 0)).to.equal(0);
      expect(await factory.balanceOf(aliceaddr, 1)).to.equal(1);
      expect(await factory.balanceOf(aliceaddr, 2)).to.equal(0);

      // can't move it back
      await expect(factory.connect(deployer).safeTransferFrom(aliceaddr, deployaddr, 1, 1, [])).to
        .be.reverted;
    });
  });
});
