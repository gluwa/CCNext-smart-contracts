# 1. Install node package
```shell
cd eth
npm i
```

# 1.2 Create .env File
For initial setup, you need to create a .env file in your `/eth` directory.
You then need to add the following contents:
```
OWNER_PRIVATE_KEY=your_private_key_here
```

# 2. Compile smart contracts
```shell
npx hardhat compile
```

# 3. Run script to deploy contracts
Deploy at target network as `ccnext_devnet`
```shell
npx hardhat deploy --network ccnext_devnet --proceedsaccount 0x2a7124FA2e830E85741761d9A9F4DE6455b049c7 --costperbyte 10 --basefee 100 --chainkey 42 --displayname "My Contract" --timeout 300 --lockupduration 86400 --approvalthreshold 2 --maxinstantmint 10 --admin 0x2a7124FA2e830E85741761d9A9F4DE6455b049c7
```