import { ethers } from "hardhat";
import {
  LoanFlow,
  LoanTerms,
  plainRegisterLoanArgs,
  requireAddress,
  optionalEnv,
  resolveProofTarget,
  printProofTarget,
  signLoanRegisterTypedData,
  waitForNonceReady,
  waitForProver,
  walletFromEnv
} from "./shared";

const DEFAULT_LOAN_DURATION_SECONDS = 604_800n; // 7 days

function parseArgs() {
  const argv = process.argv.slice(2).filter((arg) => !arg.startsWith("--"));
  const loanAmount = argv[0] != null ? BigInt(argv[0]) : 1_000_000n;
  const interestRate = argv[1] != null ? BigInt(argv[1]) : 500n;
  const durationSeconds = argv[2] != null ? BigInt(argv[2]) : DEFAULT_LOAN_DURATION_SECONDS;
  if (loanAmount <= 0n) throw new Error("loanAmount must be > 0");
  if (durationSeconds < 3600n) throw new Error("durationSeconds must be >= 3600 (1 hour)");
  const expectedRepaymentAmount = loanAmount + (loanAmount * interestRate) / 10_000n;
  return { loanAmount, interestRate, durationSeconds, expectedRepaymentAmount };
}

async function extractLoanId(receipt: ethers.TransactionReceipt, registry: any): Promise<bigint> {
  for (const log of receipt.logs) {
    try {
      const parsed = registry.interface.parseLog(log);
      if (parsed?.name === "LoanRegistered") {
        return BigInt(parsed.args.loanId);
      }
    } catch {
      // not from registry
    }
  }
  return 1n;
}

async function main() {
  const args = parseArgs();
  const skipProver = optionalEnv("SKIP_PROVER_WAIT").toLowerCase() === "true";

  const [deployer] = await ethers.getSigners();
  const lender = await walletFromEnv("LENDER_WALLET_PRIVATE_KEY", deployer);
  let borrower = await walletFromEnv("BORROWER_WALLET_PRIVATE_KEY", null);
  if (!borrower) {
    const signers = await ethers.getSigners();
    borrower =
      signers.find((s) => s.address.toLowerCase() !== lender.address.toLowerCase()) ?? null;
  }
  if (!borrower || lender.address.toLowerCase() === borrower.address.toLowerCase()) {
    throw new Error("LENDER_WALLET_PRIVATE_KEY and BORROWER_WALLET_PRIVATE_KEY must differ");
  }

  const tokenAddress = requireAddress(
    "SOURCE_CHAIN_ERC20_CONTRACT_ADDRESS",
    optionalEnv("SOURCE_CHAIN_ERC20_CONTRACT_ADDRESS")
  );
  const registryAddress = requireAddress(
    "SOURCE_LOAN_REGISTRY_CONTRACT_ADDRESS",
    optionalEnv("SOURCE_LOAN_REGISTRY_CONTRACT_ADDRESS")
  );
  const helperAddress = requireAddress(
    "SOURCE_LOAN_HELPER_CONTRACT_ADDRESS",
    optionalEnv("SOURCE_LOAN_HELPER_CONTRACT_ADDRESS")
  );

  const token = await ethers.getContractAt("ERC20Mintable", tokenAddress);
  const registry = await ethers.getContractAt("SourceLoanRegistry", registryAddress);
  const helper = await ethers.getContractAt("SourceLoanHelper", helperAddress);

  console.log("Deployer:", deployer.address);
  console.log("Lender:  ", lender.address);
  console.log("Borrower:", borrower.address);

  await waitForNonceReady(deployer.address);

  const latestBlock = await ethers.provider.getBlock("latest");
  if (!latestBlock) throw new Error("Failed to fetch latest block");
  const deadlineTimestamp = BigInt(latestBlock.timestamp) + args.durationSeconds;
  const fundFlow: LoanFlow = {
    from: lender.address,
    to: borrower.address,
    withToken: tokenAddress
  };
  const repayFlow: LoanFlow = {
    from: borrower.address,
    to: lender.address,
    withToken: tokenAddress
  };
  const loanTerms: LoanTerms = {
    loanAmount: args.loanAmount,
    interestRate: args.interestRate,
    expectedRepaymentAmount: args.expectedRepaymentAmount,
    deadlineTimestamp
  };

  console.log("\n── Step 1: registerLoan on SourceLoanRegistry ──");
  const nextLoanId = await registry.nextLoanId();
  console.log("nextLoanId:", nextLoanId.toString());
  const [sigLender, sigBorrower] = await Promise.all([
    signLoanRegisterTypedData(lender, registryAddress, nextLoanId, fundFlow, repayFlow, loanTerms),
    signLoanRegisterTypedData(borrower, registryAddress, nextLoanId, fundFlow, repayFlow, loanTerms)
  ]);

  const registerTx = await registry.registerLoan(
    ...plainRegisterLoanArgs(nextLoanId, fundFlow, repayFlow, loanTerms, sigLender, sigBorrower)
  );
  console.log("registerLoan tx:", registerTx.hash);
  const registerReceipt = await registerTx.wait();
  const loanId = await extractLoanId(registerReceipt!, registry);
  console.log("loanId:", loanId.toString());

  const registerTarget = await resolveProofTarget(registerReceipt!);
  printProofTarget(registerTarget);
  await waitForProver("registerLoan", registerTarget, skipProver);

  console.log("\n── Step 2: fundLoan on SourceLoanHelper ──");
  const tokenAuthorized = await helper.authorizedTokens(tokenAddress);
  if (!tokenAuthorized) {
    const authTx = await helper.connect(deployer).authorizeToken(tokenAddress);
    await authTx.wait();
    console.log("authorizeToken tx:", authTx.hash);
  }

  const loanRecord = await helper.loans(loanId);
  if (!loanRecord.registered) {
    const regTx = await helper
      .connect(deployer)
      .registerLoanFund(
        loanId,
        lender.address,
        borrower.address,
        tokenAddress,
        args.loanAmount,
        args.expectedRepaymentAmount
      );
    await regTx.wait();
    console.log("registerLoanFund tx:", regTx.hash);
  }

  const lenderBalance = await token.balanceOf(lender.address);
  if (lenderBalance < args.loanAmount) {
    const mintTx = await token
      .connect(deployer)
      .mint(lender.address, args.loanAmount - lenderBalance);
    await mintTx.wait();
    console.log("mint to lender tx:", mintTx.hash);
  }

  const allowance = await token.allowance(lender.address, helperAddress);
  if (allowance < args.loanAmount) {
    const approveTx = await token.connect(lender).approve(helperAddress, args.loanAmount);
    await approveTx.wait();
    console.log("approve tx:", approveTx.hash);
  }

  const fundTx = await helper.connect(lender).fundLoan(loanId);
  console.log("fundLoan tx:", fundTx.hash);
  const fundReceipt = await fundTx.wait();
  const fundTarget = await resolveProofTarget(fundReceipt!);
  printProofTarget(fundTarget);
  await waitForProver("fundLoan", fundTarget, skipProver);

  console.log("\n── Step 3: repayLoan on SourceLoanHelper ──");
  const borrowerBalance = await token.balanceOf(borrower.address);
  if (borrowerBalance < args.expectedRepaymentAmount) {
    const mintTx = await token
      .connect(deployer)
      .mint(borrower.address, args.expectedRepaymentAmount - borrowerBalance);
    await mintTx.wait();
    console.log("mint to borrower tx:", mintTx.hash);
  }

  const repayAllowance = await token.allowance(borrower.address, helperAddress);
  if (repayAllowance < args.expectedRepaymentAmount) {
    const approveTx = await token
      .connect(borrower)
      .approve(helperAddress, args.expectedRepaymentAmount);
    await approveTx.wait();
    console.log("approve repay tx:", approveTx.hash);
  }

  const repayTx = await helper.connect(borrower).repayLoan(loanId, args.expectedRepaymentAmount);
  console.log("repayLoan tx:", repayTx.hash);
  const repayReceipt = await repayTx.wait();
  const repayTarget = await resolveProofTarget(repayReceipt!);
  printProofTarget(repayTarget);
  await waitForProver("repayLoan", repayTarget, skipProver);

  console.log("\n── Summary (copy into .env) ──");
  console.log(`READABILITY_LOAN_ID=${loanId}`);
  console.log(`REGISTER_PROOF_URL=${registerTarget.proofUrl}`);
  console.log(`FUND_PROOF_URL=${fundTarget.proofUrl}`);
  console.log(`REPAY_PROOF_URL=${repayTarget.proofUrl}`);
  console.log(`REGISTER_LOAN_TX_HASH=${registerTarget.txHash}`);
  console.log(`FUND_LOAN_TX_HASH=${fundTarget.txHash}`);
  console.log(`REPAY_LOAN_TX_HASH=${repayTarget.txHash}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
