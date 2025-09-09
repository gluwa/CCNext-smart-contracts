# 🧾 CCNext-smart-contracts 🧾

This repository hosts smart contract templates which integrate with the Creditcoin `Universal 
Smart Contracts` update. Most important of these is the [Universal Bridge Proxy contract], which can
be used to interpret bridged data from foreign _source chains_ (EX: `Ethereum`) on behalf of other
Creditcoin `EVM` smart contracts.

## External dependencies

To deploy your own contracts, you will first need to have the following dependencies available
locally:

- [yarn]
- [npm]

> [!TIP]
> This project provides a `flake.nix` you can use to download all the dependencies you will need for
> this tutorial inside of a sandboxed environment. Just keep in mind you will have to
> **[enable flakes]** for this to work. To start you development environment, simply run:
>
> ```bash
> nix develop
> ```

Once you have all your dependencies setup, you will need to download some packages with `yarn`:

```bash
yarn install
```

## Get some test funds on Creditcoin USC Testnet

Before you can deploy your own contracts, you will need to fund your account on the Creditcoin USC
Testnet, otherwise contract deployment will fail due to lack of funds. Head over to the
[🚰 creditcoin discord faucet] to request some test tokens there. Now that you have enough funds
you can move on to deploying your contracts.

## Deploying contracts

### 1. Configure your `.env`

> [!CAUTION]
> We will be using you wallet's private key to deploy contracts. _This for development purposes
> only_ and should never be used in any other scenario. **Never share your private key, it can be
> used to steal your funds!**

You will need to create a `.env` file at the root of this repository file with some configuration
options for the contracts to use during deployment. Add the following contents:

```bash
OWNER_PRIVATE_KEY=your_creditcoin_account_private_key_here
```

### 2. Compile smart contracts

Next, you will need to compile the smart contracts using [👷🏻‍♀️ hardhat] to prepare them for deployment.
Run the following command:

```bash
npx hardhat compile
```

### 3. Run script to deploy contracts

Finally, you can deploy your contracts to the Creditcoin USC Testnet by running the following
command:

```bash
npx hardhat deploy                                     \
    --network ccnext_testnet                           \
    --proceedsaccount <Your Creditcoin wallet address> \
    --erc20name Test                                   \
    --erc20symbol TEST                                 \
    --chainkey 102033                                  \
    --timeout 300                                      \
    --lockupduration 86400                             \
    --approvalthreshold 2                              \
    --maxinstantmint 100                               \
    --admin <Your Creditcoin wallet address>
```

> [!TIP]
> Sometimes `deploy.js` can be flaky for various reasons. Try re-running it a few times in case it
> gets stuck or fails.

[Universal Bridge Proxy contract]: ./contracts/UniversalBridgeProxy.sol
[yarn]: https://yarnpkg.com/getting-started/install
[npm]: https://docs.npmjs.com/downloading-and-installing-node-js-and-npm
[enable flakes]: https://nixos.wiki/wiki/flakes#Enable_flakes_temporarily
[🚰 creditcoin usc testnet discord faucet]: https://discord.com/channels/762302877518528522/1407843256636539000
[👷🏻‍♀️ hardhat]: https://hardhat.org/
