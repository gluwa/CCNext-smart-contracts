import { ethers } from "hardhat";

async function main() {
  const signers = await ethers.getSigners();

  const Factory = await ethers.getContractFactory("ContractFactory");
  const factory = await Factory.deploy(signers[0].address);

  await factory.waitForDeployment();
  console.log("Factory deployed at:", await factory.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
