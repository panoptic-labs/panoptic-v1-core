import { BigNumber } from "ethers";
import { ethers } from "hardhat";

const grantTokens = async (token: string, address: string, slot: number, amount: BigNumber) => {
  const index = ethers.utils.solidityKeccak256(
    ["uint256", "uint256"],
    [address, slot] // key, slot
  );

  const amountBytes32 = ethers.utils.hexlify(ethers.utils.zeroPad(amount.toHexString(), 32));

  await ethers.provider.send("hardhat_setStorageAt", [token, index, amountBytes32]);
  await ethers.provider.send("evm_mine", []); // Just mines to the next block
};

const initPoolAddress = async (sfpm: string, poolId: string, slot: number, address: string) => {
  const index = ethers.utils.solidityKeccak256(
    ["uint256", "uint256"],
    [poolId, slot] // key, slot
  );
  const addressBytes32 = ethers.utils.hexlify(ethers.utils.zeroPad(address, 32));

  await ethers.provider.send("hardhat_setStorageAt", [sfpm, index, addressBytes32]);
  await ethers.provider.send("evm_mine", []); // Just mines to the next block
};

function revertReason(reason: string) {
  return `VM Exception while processing transaction: reverted with reason string '${reason}'`;
}

function revertCustom(reason: string) {
  return `VM Exception while processing transaction: reverted with custom error '${reason}'`;
}

export { grantTokens, initPoolAddress, revertReason, revertCustom };
