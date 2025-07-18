# 1. Install node package
```shell
cd eth
npm i
```

# 2. Fund an Address on Your Target Network

# 3. Create .env File
For initial setup, you need to create a .env file in your `/eth` directory.
You then need to add the following contents:
```
OWNER_PRIVATE_KEY=your_private_key_here
```

# 4. Compile smart contracts
```shell
npx hardhat compile
```

# 5. Run script to deploy contracts
Deploy at target network as `ccnext_devnet`
```shell
npx hardhat deploy --network ccnext_devnet --proceedsaccount 0x3Cd0A705a2DC65e5b1E1205896BaA2be8A07c6e0 --costperbyte 10 --basefee 100 --chainkey 42 --displayname "My Contract" --timeout 300 --lockupduration 86400 --approvalthreshold 2 --maxinstantmint 100 --admin 0x3Cd0A705a2DC65e5b1E1205896BaA2be8A07c6e0
```