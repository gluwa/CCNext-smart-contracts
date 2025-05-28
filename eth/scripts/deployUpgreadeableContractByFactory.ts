import { ethers } from "hardhat";

export async function deployUpgradeableContract(factoryAddress: string, implementation: string, proxyAdmin: string) {
  const Factory = await ethers.getContractAt("ContractFactory", factoryAddress);

  // Deploy implementation contract
  const contractBaseCode = await ethers.getContractFactory(implementation);
  
  const implementationContract = await contractBaseCode.deploy();
  await implementationContract.waitForDeployment();

  const implementationAddress =  await implementationContract.getAddress();

  console.log("Implementation contract deployed at:", implementationAddress);

  // Salt for deterministic address
  const salt = ethers.keccak256(contractBaseCode.bytecode);


  const tx = await Factory.deployWithProxy(
    implementationAddress,
    proxyAdmin,
    salt,
    "0x"
  );
  console.log(tx);

  await tx.wait();

  console.log("Upgradeable Proxy deployed at:", await Factory.computeAddress(salt, factoryAddress));
}


