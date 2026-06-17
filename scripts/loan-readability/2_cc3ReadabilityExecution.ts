import { ethers } from "hardhat";
import { loadReadabilityEnv } from "./env";
import {
  LoanFlow,
  LoanTerms,
  decodeReceiptFromTxBytes,
  decodeRegisterLoanFromTxBytes,
  fetchProof,
  filterLogsBySignature,
  loanRegisterMessageHash,
  LOAN_FUNDED_EVENT_SIG,
  LOAN_REPAID_EVENT_SIG,
  optionalEnv,
  plainRegisterLoanArgs,
  requireAddress,
  signLoanRegisterMessage,
  walletFromEnv
} from "./shared";

const SKIP_HUB_REGISTER = optionalEnv("SKIP_HUB_REGISTER").toLowerCase() === "true";

async function main() {
  const env = await loadReadabilityEnv();
  const { admin, hubLoan, readabilityManager, chainKey } = env;

  const loanId = BigInt(optionalEnv("READABILITY_LOAN_ID") || "0");
  if (loanId === 0n) {
    throw new Error("Set READABILITY_LOAN_ID in .env (from source step summary)");
  }

  const registerProofUrl = optionalEnv("REGISTER_PROOF_URL");
  const fundProofUrl = optionalEnv("FUND_PROOF_URL");
  const repayProofUrl = optionalEnv("REPAY_PROOF_URL");

  const lender = await walletFromEnv("LENDER_WALLET_PRIVATE_KEY", admin);
  const borrower = await walletFromEnv("BORROWER_WALLET_PRIVATE_KEY", null);
  if (!borrower) throw new Error("Set BORROWER_WALLET_PRIVATE_KEY in .env");

  const tokenAddress = requireAddress(
    "SOURCE_CHAIN_ERC20_CONTRACT_ADDRESS",
    optionalEnv("SOURCE_CHAIN_ERC20_CONTRACT_ADDRESS")
  );

  console.log("loanId:", loanId.toString());
  console.log("HubLoan:", env.hubLoanAddress);

  if (!SKIP_HUB_REGISTER) {
    console.log("\n── Txn 1: registerLoan on HubLoan (CC3) ──");

    let fundFlow: LoanFlow;
    let repayFlow: LoanFlow;
    let loanTerms: LoanTerms;

    if (registerProofUrl) {
      const registerProof = await fetchProof(registerProofUrl);
      if (!registerProof) throw new Error("Failed to fetch REGISTER_PROOF_URL");

      const decoded = decodeRegisterLoanFromTxBytes(registerProof.packed.txBytes);
      if (!decoded) throw new Error("Register proof tx is not a registerLoan call");

      fundFlow = decoded.fundFlow;
      repayFlow = decoded.repayFlow;
      const hubBlock = BigInt(await ethers.provider.getBlockNumber());
      loanTerms = {
        loanAmount: decoded.loanTerms.loanAmount,
        interestRate: decoded.loanTerms.interestRate,
        expectedRepaymentAmount: decoded.loanTerms.expectedRepaymentAmount,
        deadlineBlockNumber: hubBlock + 10_000n
      };

      console.log("Loan terms from proof:", {
        loanAmount: loanTerms.loanAmount.toString(),
        interestRate: loanTerms.interestRate.toString(),
        expectedRepaymentAmount: loanTerms.expectedRepaymentAmount.toString(),
        deadlineBlockNumber: loanTerms.deadlineBlockNumber.toString()
      });
    } else {
      fundFlow = {
        from: lender.address,
        to: borrower.address,
        withToken: tokenAddress
      };
      repayFlow = {
        from: borrower.address,
        to: lender.address,
        withToken: tokenAddress
      };
      loanTerms = {
        loanAmount: 1_000_000n,
        interestRate: 500n,
        expectedRepaymentAmount: 1_050_000n,
        deadlineBlockNumber: BigInt(await ethers.provider.getBlockNumber()) + 10_000n
      };
    }

    const msgHash = loanRegisterMessageHash(fundFlow, repayFlow, loanTerms);
    const [sigLender, sigBorrower] = await Promise.all([
      signLoanRegisterMessage(lender, msgHash),
      signLoanRegisterMessage(borrower, msgHash)
    ]);

    const tx = await hubLoan
      .connect(admin)
      .registerLoan(
        ...plainRegisterLoanArgs(fundFlow, repayFlow, loanTerms, sigLender, sigBorrower)
      );
    console.log("HubLoan.registerLoan tx:", tx.hash);
    await tx.wait();

    const stored = await hubLoan.getLoanOrder(loanId);
    console.log("hub loan status:", stored.status.toString(), "(0=Created)");
  } else {
    console.log("\n── Txn 1: skipped (SKIP_HUB_REGISTER=true) ──");
  }

  if (fundProofUrl) {
    console.log("\n── Txn 2: execute LoanFunded proof ──");
    const fundProof = await fetchProof(fundProofUrl);
    if (!fundProof) throw new Error("Failed to fetch FUND_PROOF_URL");

    const fundReceipt = decodeReceiptFromTxBytes(fundProof.packed.txBytes);
    const fundedLogs = filterLogsBySignature(fundReceipt.logs, LOAN_FUNDED_EVENT_SIG);
    console.log("LoanFunded logs:", fundedLogs.length);

    const { inclusionProof, continuityProof } = fundProof.packed;
    const blockHeight = BigInt(fundProof.raw.headerNumber);

    const ok = await readabilityManager.execute.staticCall(
      0,
      chainKey,
      blockHeight,
      inclusionProof,
      continuityProof
    );
    if (!ok) throw new Error("execute(LoanFunded) staticCall returned false");

    const fundTx = await readabilityManager
      .connect(admin)
      .execute(0, chainKey, blockHeight, inclusionProof, continuityProof);
    console.log("execute(LoanFunded) tx:", fundTx.hash);
    await fundTx.wait();

    const loanAfterFund = await hubLoan.getLoanOrder(loanId);
    console.log("loan status after fund:", loanAfterFund.status.toString(), "(1=Funded)");
  } else {
    console.log("\n── Txn 2: skipped (no FUND_PROOF_URL) ──");
  }

  if (repayProofUrl) {
    console.log("\n── Txn 3: execute LoanRepaid proof ──");
    const repayProof = await fetchProof(repayProofUrl);
    if (!repayProof) throw new Error("Failed to fetch REPAY_PROOF_URL");

    const repayReceipt = decodeReceiptFromTxBytes(repayProof.packed.txBytes);
    const repaidLogs = filterLogsBySignature(repayReceipt.logs, LOAN_REPAID_EVENT_SIG);
    console.log("LoanRepaid logs:", repaidLogs.length);

    const { inclusionProof, continuityProof } = repayProof.packed;
    const blockHeight = BigInt(repayProof.raw.headerNumber);

    const ok = await readabilityManager.execute.staticCall(
      1,
      chainKey,
      blockHeight,
      inclusionProof,
      continuityProof
    );
    if (!ok) throw new Error("execute(LoanRepaid) staticCall returned false");

    const repayTx = await readabilityManager
      .connect(admin)
      .execute(1, chainKey, blockHeight, inclusionProof, continuityProof);
    console.log("execute(LoanRepaid) tx:", repayTx.hash);
    await repayTx.wait();

    const loanAfterRepay = await hubLoan.getLoanOrder(loanId);
    console.log("loan status after repay:", loanAfterRepay.status.toString());
    console.log("repaidAmount:", loanAfterRepay.repaidAmount.toString());
  } else {
    console.log("\n── Txn 3: skipped (no REPAY_PROOF_URL) ──");
  }

  console.log("\nCC3 readability flow complete.");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
