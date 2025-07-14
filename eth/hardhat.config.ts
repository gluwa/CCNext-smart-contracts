import { HardhatUserConfig, task } from "hardhat/config";
import "@nomicfoundation/hardhat-ethers";
import "@openzeppelin/hardhat-upgrades";
import "@nomicfoundation/hardhat-verify";

import * as dotenv from "dotenv";
dotenv.config({ path: ".env" });

const DEFAULT_OWNER = process.env.OWNER_PRIVATE_KEY;

// Hardhat configuration
const config: HardhatUserConfig = {
  networks: {
    hardhat: {
      initialBaseFeePerGas: 1,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic:
          "want tennis tennis galaxy myth obey town patrol heavy innocent consider drill"
      }
    },
    localhost: {
      url: "http://localhost:9933", // Fixed the missing slash in URL
      accounts: {
        mnemonic:
          "want tennis tennis galaxy myth obey town patrol heavy innocent consider drill"
      }
    },
    cc3_testnet: {
      url: "https://rpc.cc3-testnet.creditcoin.network",
      chainId: 102031,
      accounts: [`${DEFAULT_OWNER}`],
      gasPrice: 20000000000
    }
    ,
    cc_devnet: {
      url: "https://rpc.cc3-devnet.creditcoin.network",
      chainId: 102032,
      accounts: [`${DEFAULT_OWNER}`]
    }
    ,
    ccnext_devnet: {
      url: "https://rpc.ccnext-devnet.creditcoin.network",
      chainId: 42,
      accounts: [`${DEFAULT_OWNER}`]
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
    apiKey: {
      cc3: `${process.env.BLOCKSCOUT_API_KEY}`,
      cc3_testnet: `${process.env.BLOCKSCOUT_API_KEY_TESTNET}`,
      cc_devnet: `${process.env.BLOCKSCOUT_API_KEY_DEVNET}`
    },
    customChains: [
      {
        network: "cc3",
        chainId: 102030,
        urls: {
          apiURL: "https://creditcoin.blockscout.com/api",
          browserURL: "https://creditcoin.blockscout.com"
        }
      },
      {
        network: "cc3_testnet",
        chainId: 102031,
        urls: {
          apiURL: "https://creditcoin-testnet.blockscout.com/api",
          browserURL: "https://creditcoin-testnet.blockscout.com"
        }
      }
      ,
      {
        network: "cc_devnet",
        chainId: 102032,
        urls: {
          apiURL: "https://creditcoin-devnet.blockscout.com/api",
          browserURL: "https://creditcoin-devnet.blockscout.com/api"
        }
      }
    ]
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
// npx hardhat deploy --network cc_devnet --proceedsaccount 0x2a7124FA2e830E85741761d9A9F4DE6455b049c7 --costperbyte 10 --basefee 100 --chainkey 42 --displayname "My Contract" --timeout 300 --lockupduration 86400 --approvalthreshold 2 --maxinstantmint 10 --admin 0x2a7124FA2e830E85741761d9A9F4DE6455b049c7
// [OPTIONAL for verification process] npx hardhat verify --network cc_devnet  0x0E79C7bC5b92cB86bA635522D2238A1D79E67d84 0x2a7124FA2e830E85741761d9A9F4DE6455b049c7 10 100 42 "My Contract" 300
task("deploy", "Deploys the contract with constructor args")
  .addParam("proceedsaccount", "The proceeds account address")
  .addParam("costperbyte", "Cost per byte", undefined, undefined, true)
  .addParam("basefee", "Base fee")
  .addParam("chainkey", "Chain key")
  .addParam("displayname", "Display name")
  .addParam("timeout", "Timeout")
  .addParam("lockupduration", "Lockup duration ")
  .addParam("approvalthreshold", "Approval threshold ")
  .addParam("maxinstantmint", "Max instant mint (unit: ether)")
  .addParam("admin", "Admin address")

  .setAction(async (taskArgs, hre) => {

    const { deployUSC } = require("./scripts/deploy"); 

    await deployUSC(
      taskArgs.proceedsaccount,
      taskArgs.costperbyte,
      taskArgs.basefee,
      taskArgs.chainkey,
      taskArgs.displayname,
      taskArgs.timeout,
      taskArgs.lockupduration,
      taskArgs.approvalthreshold,
      taskArgs.maxinstantmint,      
      taskArgs.admin
    );
  
  });
