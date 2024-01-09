import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import '@openzeppelin/hardhat-upgrades';
import "@nomicfoundation/hardhat-foundry";
import { config as dotenvConfig } from "dotenv";

dotenvConfig();

const PRIVATE_KEY = process.env.PRIVATE_KEY || "";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: { enabled: true, runs: 9999 }
    }
  },
  paths: {
    sources: "./src"
  },
  networks: {
    op: {
      url: "https://mainnet.optimism.io",
      chainId: 10,
      accounts: [`0x${PRIVATE_KEY}`],
    },
    bsc: {
      url: "https://bsc-dataseed.binance.org/",
      chainId: 56,
      accounts: [`0x${PRIVATE_KEY}`],
    },
  },
  etherscan: {
    apiKey: { 
      bsc: process.env.ETHERSCAN_KEY || "",
    }
  },
};

export default config;
