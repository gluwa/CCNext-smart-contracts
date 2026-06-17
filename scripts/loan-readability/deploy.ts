import { ethers, network } from "hardhat";
import { optionalEnv } from "./shared";

const CC3_NETWORKS = new Set(["cc3_testnet", "cc3_usc_testnet"]);
const SOURCE_NETWORKS = new Set(["sepolia"]);

async function deploySourceStack(admin: ethers.Wallet, deployer: string) {
  const tokenName = optionalEnv("READABILITY_ERC20_NAME") || "Loan Test Token";
  const tokenSymbol = optionalEnv("READABILITY_ERC20_SYMBOL") || "LTT";

  const Token = await ethers.getContractFactory("ERC20Mintable");
  const token = await Token.connect(admin).deploy(tokenName, tokenSymbol);
  await token.waitForDeployment();
  console.log("ERC20Mintable:", await token.getAddress());

  const Registry = await ethers.getContractFactory("SourceLoanRegistry");
  const registry = await Registry.connect(admin).deploy();
  await registry.waitForDeployment();
  console.log("SourceLoanRegistry:", await registry.getAddress());

  const Helper = await ethers.getContractFactory("SourceLoanHelper");
  const helper = await Helper.connect(admin).deploy(deployer);
  await helper.waitForDeployment();
  console.log("SourceLoanHelper:", await helper.getAddress());

  console.log("\nSource-chain deploy complete. Set in .env:");
  console.log(`SOURCE_CHAIN_ERC20_CONTRACT_ADDRESS=${await token.getAddress()}`);
  console.log(`SOURCE_LOAN_REGISTRY_CONTRACT_ADDRESS=${await registry.getAddress()}`);
  console.log(`SOURCE_LOAN_HELPER_CONTRACT_ADDRESS=${await helper.getAddress()}`);
}

async function deployCc3Stack(admin: ethers.Wallet, deployer: string) {
  const HubLoan = await ethers.getContractFactory("HubLoan");
  const hubLoan = await HubLoan.connect(admin).deploy(deployer);
  await hubLoan.waitForDeployment();
  console.log("HubLoan:", await hubLoan.getAddress());

  const ProofVerifier = await ethers.getContractFactory("USCProofVerifier");
  const proofVerifier = await ProofVerifier.connect(admin).deploy();
  await proofVerifier.waitForDeployment();
  console.log("USCProofVerifier:", await proofVerifier.getAddress());

  // EvmV1Decoder is an internal-only library — inlined at compile time, no deploy/link step.
  const Manager = await ethers.getContractFactory("USCLoanReadabilityManager");
  const manager = await Manager.connect(admin).deploy(
    await hubLoan.getAddress(),
    await proofVerifier.getAddress(),
    deployer
  );
  await manager.waitForDeployment();
  console.log("USCLoanReadabilityManager:", await manager.getAddress());

  console.log("\nCC3 deploy complete. Set in .env:");
  console.log(`HUB_LOAN_CONTRACT_ADDRESS=${await hubLoan.getAddress()}`);
  console.log(`USC_PROOF_VERIFIER_CONTRACT_ADDRESS=${await proofVerifier.getAddress()}`);
  console.log(`USC_LOAN_READABILITY_MANAGER_CONTRACT_ADDRESS=${await manager.getAddress()}`);
}

async function main() {
  const adminKey = optionalEnv("OWNER_PRIVATE_KEY") || optionalEnv("CREDITCOIN_WALLET_PRIVATE_KEY");
  if (!adminKey) throw new Error("Set OWNER_PRIVATE_KEY or CREDITCOIN_WALLET_PRIVATE_KEY");

  const admin = new ethers.Wallet(adminKey, ethers.provider);
  const deployer = admin.address;
  const { chainId } = await ethers.provider.getNetwork();

  console.log("Network:", network.name, `(chainId ${chainId})`);
  console.log("Deployer:", deployer);

  if (CC3_NETWORKS.has(network.name)) {
    await deployCc3Stack(admin, deployer);
  } else if (SOURCE_NETWORKS.has(network.name)) {
    await deploySourceStack(admin, deployer);
  } else {
    throw new Error(
      `Unknown network "${network.name}". Use --network sepolia for source contracts ` +
        `or --network cc3_testnet / cc3_usc_testnet for hub contracts.`
    );
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
