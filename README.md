# CCNext-smart-contracts
This repository hosts templates for smart contracts which integrate with the decentralized bridge infrastructure of the creditcoin `Universal Smart Contracts` project, code named `CCNext`. Most important of these is the Universal Bridge Proxy contract, which is intended to interpret bridged data from foreign chains (EX: Ethereum) on behalf of other Creditcoin EVM smart contracts.

# Deploying UniversalBridgeProxy and ERC20Mintable Contracts on Creditcoin USC Testnet

## 1. Install node package
```shell
yarn
```

## 2. Fund an Address on Your Target Creditcoin USC Network
If you're launching contracts as part of a tutorial from `ccnext-testnet-bridge-examples`, then skip this step and use the testnet account you already funded.

For Creditcoin USC Testnet use step 2 [here](https://github.com/gluwa/ccnext-testnet-bridge-examples/blob/main/hello-bridge/README.md)

## 3. Create .env File
For initial setup, you need to create a .env file in the top level directory of this repository.
You then need to add the following contents:
```
OWNER_PRIVATE_KEY=your_creditcoin_account_private_key_here
```

## 4. Compile smart contracts
```shell
npx hardhat compile
```

## 5. Run script to deploy contracts
Deploy at target network as `cc3_usc_testnet`
```shell
npx hardhat deploy --network cc3_usc_testnet --proceedsaccount <your_credticoin_account_public_key> --erc20name Test --erc20symbol TEST --chainkey 102033 --timeout 300 --lockupduration 86400 --approvalthreshold 2 --maxinstantmint 100 --admin <your_creditcoin_account_public_key>
```
Sometimes deploy.js can be flaky for various reasons. Try re-running it a few times if it gets stuck or fails.
