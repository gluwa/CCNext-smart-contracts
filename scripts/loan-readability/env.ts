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
  const sourceHelperAddress = requireAddress(
    "SOURCE_LOAN_HELPER_CONTRACT_ADDRESS",
    optionalEnv("SOURCE_LOAN_HELPER_CONTRACT_ADDRESS")
  );
  const sourceRegistryAddress = requireAddress(
    "SOURCE_LOAN_REGISTRY_CONTRACT_ADDRESS",
    optionalEnv("SOURCE_LOAN_REGISTRY_CONTRACT_ADDRESS")
  );

  const chainKey = chainKeyBytes32(Number(process.env.SOURCE_CHAIN_KEY ?? "1"));
  const sourceEvmChainId = BigInt(process.env.SOURCE_EVM_CHAIN_ID ?? "11155111");

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
    sourceEvmChainId,
    needsTargetSync
  };
}

export async function wireReadabilityRoles() {
  const env = await loadReadabilityEnv();
  const {
    admin,
    hubLoan,
    readabilityManager,
    hubLoanAddress,
    sourceHelperAddress,
    sourceRegistryAddress,
    chainKey,
    sourceEvmChainId
  } = env;

  console.log("HubLoan:              ", hubLoanAddress);
  console.log("ReadabilityManager:   ", env.readabilityManagerAddress);
  console.log("ProofVerifier:        ", env.proofVerifierAddress);
  console.log("Source chainKey:      ", chainKey);
  console.log("Source EVM chainId:   ", sourceEvmChainId.toString());

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

  const onChainKey = await readabilityManager.sourceChainKey();
  const onChainRegistry = await readabilityManager.authorizedLoanRegistry();
  const onChainHelper = await readabilityManager.authorizedSourceContract();

  const onChainEvmChainId = await readabilityManager.sourceEvmChainId();

  const needsSourceChainConfig =
    onChainKey !== chainKey ||
    onChainEvmChainId !== sourceEvmChainId ||
    onChainRegistry.toLowerCase() !== sourceRegistryAddress.toLowerCase() ||
    onChainHelper.toLowerCase() !== sourceHelperAddress.toLowerCase();

  if (needsSourceChainConfig) {
    console.log("Configuring manager 1:1 source chain (chainKey + EVM chainId + registry + helper)…");
    const tx = await readabilityManager
      .connect(admin)
      .configureSourceChain(chainKey, sourceEvmChainId, sourceRegistryAddress, sourceHelperAddress);
    await tx.wait();
    console.log("manager.configureSourceChain tx:", tx.hash);
  } else {
    console.log("Manager source chain already configured");
  }

  const hubChainKey = await hubLoan.sourceChainKey();
  const hubEvmChainId = await hubLoan.sourceEvmChainId();
  const hubRegistry = await hubLoan.authorizedLoanRegistry();

  const needsHubSourceChainConfig =
    hubChainKey !== chainKey ||
    hubEvmChainId !== sourceEvmChainId ||
    hubRegistry.toLowerCase() !== sourceRegistryAddress.toLowerCase();

  if (needsHubSourceChainConfig) {
    console.log("Configuring HubLoan 1:1 source chain (chainKey + EVM chainId + registry)…");
    const tx = await hubLoan
      .connect(admin)
      .configureSourceChain(chainKey, sourceEvmChainId, sourceRegistryAddress);
    await tx.wait();
    console.log("hubLoan.configureSourceChain tx:", tx.hash);
  } else {
    console.log("HubLoan source chain already configured");
  }

  console.log("Setup complete.");
}
