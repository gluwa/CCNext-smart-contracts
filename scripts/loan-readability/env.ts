import { ethers } from "hardhat";
import { chainKeyBytes32, optionalEnv, requireAddress } from "./shared";

export async function loadReadabilityEnv() {
  const adminKey = optionalEnv("OWNER_PRIVATE_KEY") || optionalEnv("CREDITCOIN_WALLET_PRIVATE_KEY");
  if (!adminKey) {
    throw new Error("Set OWNER_PRIVATE_KEY or CREDITCOIN_WALLET_PRIVATE_KEY in .env");
  }

  const hubLoanAddress = requireAddress(
    "HUB_LOAN_CONTRACT_ADDRESS",
    optionalEnv("HUB_LOAN_CONTRACT_ADDRESS")
  );
  const proofVerifierAddress = requireAddress(
    "USC_PROOF_VERIFIER_CONTRACT_ADDRESS",
    optionalEnv("USC_PROOF_VERIFIER_CONTRACT_ADDRESS")
  );
  const readabilityManagerAddress = requireAddress(
    "USC_LOAN_READABILITY_MANAGER_CONTRACT_ADDRESS",
    optionalEnv("USC_LOAN_READABILITY_MANAGER_CONTRACT_ADDRESS")
  );
  const sourceHelperAddress = optionalEnv("SOURCE_LOAN_HELPER_CONTRACT_ADDRESS");
  const sourceRegistryAddress = optionalEnv("SOURCE_LOAN_REGISTRY_CONTRACT_ADDRESS");

  const chainKey = chainKeyBytes32(Number(process.env.SOURCE_CHAIN_KEY ?? "1"));

  const hubLoan = await ethers.getContractAt("HubLoan", hubLoanAddress);
  const proofVerifier = await ethers.getContractAt("USCProofVerifier", proofVerifierAddress);
  const readabilityManager = await ethers.getContractAt(
    "USCLoanReadabilityManager",
    readabilityManagerAddress
  );

  const admin = new ethers.Wallet(adminKey, ethers.provider);
  const onChainTarget = await readabilityManager.loanTarget();
  const needsTargetSync = onChainTarget.toLowerCase() !== hubLoanAddress.toLowerCase();

  return {
    admin,
    hubLoan,
    hubLoanAddress,
    proofVerifier,
    proofVerifierAddress,
    readabilityManager,
    readabilityManagerAddress,
    sourceHelperAddress,
    sourceRegistryAddress,
    chainKey,
    needsTargetSync
  };
}

export async function wireReadabilityRoles() {
  const env = await loadReadabilityEnv();
  const { admin, hubLoan, readabilityManager, hubLoanAddress, sourceHelperAddress, sourceRegistryAddress, chainKey } =
    env;

  console.log("HubLoan:              ", hubLoanAddress);
  console.log("ReadabilityManager:   ", env.readabilityManagerAddress);
  console.log("ProofVerifier:        ", env.proofVerifierAddress);

  if (env.needsTargetSync) {
    console.log("Syncing loanTarget → HubLoan…");
    const tx = await readabilityManager.connect(admin).setLoanTarget(hubLoanAddress);
    await tx.wait();
    console.log("setLoanTarget tx:", tx.hash);
  } else {
    console.log("loanTarget matches HubLoan");
  }

  const readabilityRole = await hubLoan.READABILITY_ROLE();
  const hasRole = await hubLoan.hasRole(readabilityRole, env.readabilityManagerAddress);
  if (!hasRole) {
    console.log("Granting READABILITY_ROLE to manager…");
    const tx = await hubLoan.connect(admin).grantRole(readabilityRole, env.readabilityManagerAddress);
    await tx.wait();
    console.log("grantRole tx:", tx.hash);
  } else {
    console.log("READABILITY_ROLE already granted");
  }

  if (sourceRegistryAddress) {
    const registry = ethers.getAddress(sourceRegistryAddress);
    const onChainRegistry = await readabilityManager.authorizedLoanRegistries(chainKey);
    if (onChainRegistry.toLowerCase() !== registry.toLowerCase()) {
      console.log("Authorizing SourceLoanRegistry…");
      const tx = await readabilityManager
        .connect(admin)
        .setAuthorizedLoanRegistry(chainKey, registry);
      await tx.wait();
      console.log("setAuthorizedLoanRegistry tx:", tx.hash);
    } else {
      console.log("SourceLoanRegistry already authorized");
    }
  } else {
    console.log("SOURCE_LOAN_REGISTRY_CONTRACT_ADDRESS not set — skipping registry authorization");
  }

  if (sourceHelperAddress) {
    const helper = ethers.getAddress(sourceHelperAddress);
    const onChain = await readabilityManager.authorizedSourceContracts(chainKey);
    if (onChain.toLowerCase() !== helper.toLowerCase()) {
      console.log("Authorizing SourceLoanHelper…");
      const tx = await readabilityManager
        .connect(admin)
        .setAuthorizedSourceContract(chainKey, helper);
      await tx.wait();
      console.log("setAuthorizedSourceContract tx:", tx.hash);
    } else {
      console.log("SourceLoanHelper already authorized");
    }
  } else {
    console.log("SOURCE_LOAN_HELPER_CONTRACT_ADDRESS not set — skipping emitter authorization");
  }

  console.log("Setup complete.");
}
