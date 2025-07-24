# CCNext-smart-contracts
This repository hosts templates for smart contracts which integrate with the decentralized bridge infrastructure of CCNext. Most important of these is the Universal Bridge Proxy contract, which is intended to interpret bridged data from foreign chains (EX: Ethereum) on behalf of other CCNext EVM smart contracts.

# Deploying UniversalBridgeProxy and ERC20Mintable Contracts on CCNext

## 1. Install node package
```shell
cd eth
npm i
```

## 2. Fund an Address on Your Target CCNext Network
If you're launching contracts as part of a tutorial from `ccnext-testnet-bridge-examples`, then skip this step and use the testnet account you already funded.

For CCNext Testnet use step 2 [here](https://github.com/gluwa/ccnext-testnet-bridge-examples/blob/main/hello-bridge/README.md)

## 3. Create .env File
For initial setup, you need to create a .env file in your `/eth` directory.
You then need to add the following contents:
```
OWNER_PRIVATE_KEY=your_ccnext_account_private_key_here
```

## 4. Compile smart contracts
```shell
npx hardhat compile
```

## 5. Run script to deploy contracts
TODO: Once testnet is live, change this target network to ccnext_testnet and add as option in hardhat.config.ts
Deploy at target network as `ccnext_devnet`
```shell
npx hardhat deploy --network ccnext_devnet --proceedsaccount <your_ccnext_account_public_key> --erc20name Test --erc20symbol TEST --chainkey 42 --timeout 300 --lockupduration 86400 --approvalthreshold 2 --maxinstantmint 100 --admin <your_ccnext_account_public_key>
```

Devnet testing public key: 0x3Cd0A705a2DC65e5b1E1205896BaA2be8A07c6e0