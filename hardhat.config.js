require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-verify");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-gas-reporter");
require("solidity-coverage");
require("dotenv").config();

// Only pass PRIVATE_KEY to live networks if it looks like a valid 32-byte hex key.
const pk = process.env.PRIVATE_KEY || "";
const liveAccounts = /^(0x)?[0-9a-fA-F]{64}$/.test(pk) ? [pk.startsWith("0x") ? pk : `0x${pk}`] : [];

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.23",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
      evmVersion: "paris",
    },
  },
  networks: {
    hardhat: {
      chainId: 1337,
      allowBlocksWithSameTimestamp: true,
      accounts: {
        mnemonic: "test test test test test test test test test test test junk",
        count: 20,
      },
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 1337,
      loggingEnabled: false,
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "https://sepolia.drpc.org",
      chainId: 11155111,
      accounts: liveAccounts,
      gasPrice: "auto",
    },
    liskSepolia: {
      url: process.env.LISK_SEPOLIA_RPC_URL || "https://rpc.sepolia-api.lisk.com",
      chainId: 4202,
      accounts: liveAccounts,
      gasPrice: "auto",
    },
    lisk: {
      url: process.env.LISK_RPC_URL || "https://rpc.api.lisk.com",
      chainId: 1135,
      accounts: liveAccounts,
      gasPrice: "auto",
    },
    polygonAmoy: {
      url: process.env.POLYGON_AMOY_RPC_URL || "https://rpc-amoy.polygon.technology",
      chainId: 80002,
      accounts: liveAccounts,
      gasPrice: "auto",
    },
    polygon: {
      url: process.env.POLYGON_RPC_URL || "https://polygon-rpc.com",
      chainId: 137,
      accounts: liveAccounts,
      gasPrice: "auto",
    },
  },
  etherscan: {
    // Etherscan's V2 API uses a single key across every chain it covers (including Sepolia
    // and Polygon — Polygonscan keys were folded into this same system). Lisk's explorer is
    // Blockscout, not Etherscan, so it keeps its own separate key below.
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY || "",
      polygonAmoy: process.env.ETHERSCAN_API_KEY || "",
      polygon: process.env.ETHERSCAN_API_KEY || "",
      liskSepolia: process.env.LISK_SEPOLIA_API_KEY || "",
    },
    customChains: [
      {
        network: "liskSepolia",
        chainId: 4202,
        urls: {
          apiURL: "https://sepolia-blockscout.lisk.com/api",
          browserURL: "https://sepolia-blockscout.lisk.com",
        },
      },
    ],
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};

