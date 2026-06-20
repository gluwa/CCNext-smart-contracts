import { ethers } from "hardhat";
import { chainKeyBytes32, optionalEnv, requireAddress } from "./shared";

export async function loadReadabilityEnv() {
  const adminKey = optionalEnv("OWNER_PRIVATE_KEY") || optionalEnv("CREDITCOIN_WALLET_PRIVATE_KEY");
  if (!adminKey) {
    throw new Error("Set OWNER_PRIVATE_KEY or CREDITCOIN_WALLET_PRIVATE_KEY in .env");
  }

  const destinationLoanRecordingAddress = requireAddress(
    "DESTINATION_LOAN_RECORDING_CONTRACT_ADDRESS",
    optionalEnv("DESTINATION_LOAN_RECORDING_CONTRACT_ADDRESS") ||
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

  const destinationLoanRecording = await ethers.getContractAt(
    "DestinationLoanRecording",
    destinationLoanRecordingAddress
  );
  const proofVerifier = await ethers.getContractAt("USCProofVerifier", proofVerifierAddress);
  const readabilityManager = await ethers.getContractAt(
    "USCLoanReadabilityManager",
    readabilityManagerAddress
  );

  const admin = new ethers.Wallet(adminKey, ethers.provider);
  const onChainTarget = await readabilityManager.loanTarget();
  const needsTargetSync =
    onChainTarget.toLowerCase() !== destinationLoanRecordingAddress.toLowerCase();

  return {
    admin,
    destinationLoanRecording,
    destinationLoanRecordingAddress,
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
    destinationLoanRecording,
    readabilityManager,
    destinationLoanRecordingAddress,
    sourceHelperAddress,
    sourceRegistryAddress,
    chainKey,
    sourceEvmChainId
  } = env;

  console.log("DestinationLoanRecording:", destinationLoanRecordingAddress);
  console.log("ReadabilityManager:       ", env.readabilityManagerAddress);
  console.log("ProofVerifier:            ", env.proofVerifierAddress);
  console.log("Source chainKey:          ", chainKey);
  console.log("Source EVM chainId:       ", sourceEvmChainId.toString());

  if (env.needsTargetSync) {
    console.log("Syncing loanTarget → DestinationLoanRecording…");
    const tx = await readabilityManager
      .connect(admin)
      .setLoanTarget(destinationLoanRecordingAddress);
    await tx.wait();
    console.log("setLoanTarget tx:", tx.hash);
  } else {
    console.log("loanTarget matches DestinationLoanRecording");
  }

  const readabilityRole = await destinationLoanRecording.READABILITY_ROLE();
  const hasRole = await destinationLoanRecording.hasRole(
    readabilityRole,
    env.readabilityManagerAddress
  );
  if (!hasRole) {
    console.log("Granting READABILITY_ROLE to manager…");
    const tx = await destinationLoanRecording
      .connect(admin)
      .grantRole(readabilityRole, env.readabilityManagerAddress);
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

  const destinationChainKey = await destinationLoanRecording.sourceChainKey();
  const destinationEvmChainId = await destinationLoanRecording.sourceEvmChainId();
  const destinationRegistry = await destinationLoanRecording.authorizedLoanRegistry();

  const needsDestinationSourceChainConfig =
    destinationChainKey !== chainKey ||
    destinationEvmChainId !== sourceEvmChainId ||
    destinationRegistry.toLowerCase() !== sourceRegistryAddress.toLowerCase();

  if (needsDestinationSourceChainConfig) {
    console.log(
      "Configuring DestinationLoanRecording 1:1 source chain (chainKey + EVM chainId + registry)…"
    );
    const tx = await destinationLoanRecording
      .connect(admin)
      .configureSourceChain(chainKey, sourceEvmChainId, sourceRegistryAddress);
    await tx.wait();
    console.log("destinationLoanRecording.configureSourceChain tx:", tx.hash);
  } else {
    console.log("DestinationLoanRecording source chain already configured");
  }

  console.log("Setup complete.");
}
