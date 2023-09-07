import dotenv from "dotenv";
import "@typechain/hardhat";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-waffle";
import "hardhat-deploy";
import "hardhat-deploy-ethers";
import "hardhat-contract-sizer";
import "hardhat-gas-reporter";
import { HardhatUserConfig } from "hardhat/types";
import { task } from "hardhat/config";
require("hardhat-abi-exporter");

dotenv.config();

// =============== HELPERS ===============
/// @dev easy way to print out all accounts
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

// =============== COMPILERS - CAN BE USED IN THE FINAL CONFIG AT THE END ===============
// the main compiler settings used
const DEFAULT_COMPILER_SETTINGS = {
  version: "0.8.18",
  settings: {
    evmVersion: "paris",
    viaIR: false,
    optimizer: {
      enabled: true,
      runs: 9_999_999,
    },
    metadata: {
      // do not include the metadata hash, since this is machine dependent
      // and we want all generated code to be deterministic
      bytecodeHash: "none",
    },
  },
};

const LOW_OPTIMIZER_COMPILER_SETTINGS = {
  version: "0.8.18",
  settings: {
    evmVersion: "paris",
    optimizer: {
      enabled: true,
      runs: 2_000,
    },
    metadata: {
      bytecodeHash: "none",
    },
  },
};

const LOWEST_OPTIMIZER_COMPILER_SETTINGS = {
  version: "0.8.18",
  settings: {
    evmVersion: "paris",
    optimizer: {
      enabled: true,
      runs: 1_000,
    },
    metadata: {
      bytecodeHash: "none",
    },
  },
};

const IR_COMPILER_SETTINGS = {
  version: "0.8.18",
  settings: {
    evmVersion: "paris",
    viaIR: true,
    optimizer: {
      enabled: true,
      runs: 9_999_999,
    },
    metadata: {
      bytecodeHash: "none",
    },
  },
};

const TEMP_COLTRACKER_COMPILER_SETTINGS = {
  version: "0.8.18",
  settings: {
    evmVersion: "paris",
    viaIR: true,
    optimizer: {
      enabled: true,
      runs: 10_000,
      optimizerSteps: "u",
    },
    metadata: {
      bytecodeHash: "none",
    },
  },
};
// =============== EXPORT THE HARDHAT USER CONFIGURATION ===============
export default {
  solidity: {
    compilers: [DEFAULT_COMPILER_SETTINGS], // @dev you can add more compilers here if needed
  },
  paths: {
    sources: "./src",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  mocha: {
    timeout: 1200000,
  },
  networks: {
    hardhat: {
      deploy: ["./deploy"],
      allowUnlimitedContractSize: true,
      forking: {
        blockNumber: 14487083,
        url: process.env.NODE_URL,
      },
    },
  },
  typechain: {
    outDir: "typechain/",
    target: "ethers-v5",
    include: ["./test/Uniswapv3"],
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: true,
    disambiguatePaths: false,
  },
  gasReporter: {
    currency: "USD",
    gasPrice: 21,
  },
  namedAccounts: {
    deployer: 0,
    seller: 1,
    buyer: 2,
  },
  abiExporter: [
    {
      path: "./abi/json",
      format: "json",
    },
    {
      path: "./abi/minimal",
      format: "minimal",
    },
    {
      path: "./abi/fullName",
      format: "fullName",
    },
  ],
} as HardhatUserConfig;
