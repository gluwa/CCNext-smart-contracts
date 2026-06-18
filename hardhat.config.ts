import { HardhatUserConfig, task } from "hardhat/config";
import "@nomicfoundation/hardhat-ethers";
import "@openzeppelin/hardhat-upgrades";
import "@nomicfoundation/hardhat-verify";

import * as dotenv from "dotenv";
dotenv.config({ path: ".env" });

const DEFAULT_OWNER = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC = process.env.SEPOLIA_RPC_URL ?? "https://sepolia-proxy-rpc.creditcoin.network";
const SOURCE_PRIVATE_KEY = process.env.SOURCE_WALLET_PRIVATE_KEY ?? DEFAULT_OWNER;

const CREDITCOIN_PRIVATE_KEY = process.env.CREDITCOIN_WALLET_PRIVATE_KEY ?? DEFAULT_OWNER;

// Hardhat configuration
const config: HardhatUserConfig = {
  networks: {
    cc3_usc_testnet: {
      url: "https://rpc.usc-testnet.creditcoin.network",
      chainId: 102033,
      accounts: CREDITCOIN_PRIVATE_KEY ? [`${CREDITCOIN_PRIVATE_KEY}`] : [],
      timeout: 360000, // increase timeout  6 minutes
    },
    cc3_testnet: {
      url: "https://rpc.cc3-testnet.creditcoin.network",
      chainId: 102031,
      accounts: CREDITCOIN_PRIVATE_KEY ? [`${CREDITCOIN_PRIVATE_KEY}`] : [],
      timeout: 360000,
    },
    sepolia: {
      url: SEPOLIA_RPC,
      chainId: 11155111,
      accounts: SOURCE_PRIVATE_KEY ? [`${SOURCE_PRIVATE_KEY}`] : [],
    }
  },
  mocha: {
    timeout: 2000000
  },
  solidity: {
    compilers: [
      {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
          evmVersion: "shanghai",
          viaIR: true
        }
      },
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
          viaIR: true
        }
      }
    ]
  },
  etherscan: {
    // Sepolia: single key uses Etherscan API v2. CC3 testnet uses Blockscout via customChains + per-network key.
    apiKey: process.env.BLOCKSCOUT_API_KEY
      ? {
          sepolia: process.env.ETHERSCAN_API_KEY ?? "",
          cc3_testnet: process.env.BLOCKSCOUT_API_KEY
        }
      : (process.env.ETHERSCAN_API_KEY ?? ""),
    customChains: [
      {
        network: "cc3_testnet",
        chainId: 102031,
        urls: {
          apiURL: "https://creditcoin-testnet.blockscout.com/api",
          browserURL: "https://creditcoin-testnet.blockscout.com"
        }
      }
    ]
  },
  sourcify: {
    enabled: false
  }
};

export default config;

//npx hardhat deployWithFactory --factoryaddress 0xAd310ae3495aE4bDf6655d8057499188EB945c3e --implementation UniversalBridgeProxy --proxyadmin 0x2a7124FA2e830E85741761d9A9F4DE6455b049c7 --network cc3_testnet
task(
  "deployWithFactory",
  "Deploy an upgradeable contract using contract factory"
)
  .addParam("factoryaddress", "The address of factory")
  .addParam("implementation", "The name of implementation contract")
  .addParam("proxyadmin", "The address of proxy either EoAs or multisig")
  .setAction(async taskArgs => {
    const { factoryaddress, implementation, proxyadmin } = taskArgs;

    try {
      const {
        deployUpgradeableContract
      } = require("./scripts/deployUpgreadeableContractByFactory.ts");

      await deployUpgradeableContract(
        factoryaddress,
        implementation,
        proxyadmin
      );

      process.exit(0);
    } catch (err) {
      console.error("Error deploying contract:", err);
      process.exit(1);
    }
  });


// Example Usage: 
// npx hardhat deploy --network cc_devnet --proceedsaccount 0x2a7124FA2e830E85741761d9A9F4DE6455b049c7 --erc20name Test --erc20symbol TEST --chainkey 42 --timeout 300 --lockupduration 86400 --approvalthreshold 2 --maxinstantmint 10 --admin 0x2a7124FA2e830E85741761d9A9F4DE6455b049c7
// [OPTIONAL for verification process] npx hardhat verify --network cc_devnet  0x0E79C7bC5b92cB86bA635522D2238A1D79E67d84 0x2a7124FA2e830E85741761d9A9F4DE6455b049c7 10 100 42 "My Contract" 300
task("deploy", "Deploys the contract with constructor args")
  .addParam("proceedsaccount", "The proceeds account address")
  .addParam("erc20name", "Name of the ERC20 token")
  .addParam("erc20symbol", "Symbol of the ERC20 token")
  .addParam("chainkey", "Chain key")
  .addParam("timeout", "Timeout")
  .addParam("lockupduration", "Lockup duration ")
  .addParam("approvalthreshold", "Approval threshold ")
  .addParam("maxinstantmint", "Max instant mint (unit: ether)")
  .addParam("admin", "Admin address")

  .setAction(async (taskArgs, hre) => {

    const { deployUSC } = require("./scripts/deploy"); 

    await deployUSC(
      taskArgs.proceedsaccount,
      taskArgs.erc20name,
      taskArgs.erc20symbol,
      taskArgs.chainkey,
      taskArgs.timeout,
      taskArgs.lockupduration,
      taskArgs.approvalthreshold,
      taskArgs.maxinstantmint,      
      taskArgs.admin
    );
  
  });
