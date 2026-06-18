# Loan Readability Flow

End-to-end example: register, fund, and repay a loan on Sepolia, then mirror state on CC3 via `USCLoanReadabilityManager`.

## 1. Deploy

```sh
cp .env.example .env
# fill OWNER_PRIVATE_KEY and lender/borrower keys

# Sepolia only — token, registry, helper
yarn loan_readability:deploy:source

# CC3 only — hub, verifier, manager (EvmV1Decoder is inlined; no library deploy)
yarn loan_readability:deploy:cc3
```
Each script deploys **only** the contracts for that chain. Do not use CC3 addresses for source `.env` vars (or vice versa).
Copy deployed addresses into `.env`.

## 2. Wire CC3 roles

```sh
yarn loan_readability:setup
```
Grants `READABILITY_ROLE`, syncs `loanTarget`, authorizes `SourceLoanRegistry` for register proofs and `SourceLoanHelper` for fund/repay proofs.

## 3. Run

```sh
# Step 1 — Sepolia
yarn loan_readability:source

# Copy READABILITY_LOAN_ID and proof URLs from the summary into .env

# Step 2 — CC3
yarn loan_readability:setup
yarn loan_readability:cc3
```

## Loan flow

This example mirrors a loan from Sepolia (source) onto CC3 (hub) using cross-chain proofs.

### Source chain (Sepolia)

**Contracts:** `SourceLoanRegistry`, `SourceLoanHelper`, `ERC20Mintable`

1. **Register the loan** (`SourceLoanRegistry.registerLoan`)
   - Lender and borrower sign a message hash over fund flow, repay flow, and loan terms (amount, interest, expected repayment, `deadlineTimestamp`).
   - Registry assigns the next `loanId` (starts at 1) and stores the loan in `Created` status.
   - Emits `LoanRegistered(loanId, lender, borrower, …)`.

2. **Prepare helper for funding** (`SourceLoanHelper`)
   - Deployer authorizes the ERC20 token (if not already).
   - Deployer calls `registerLoanFund(loanId, lender, borrower, token, fundAmount, repayAmount)` so the helper knows about this loan.

3. **Fund the loan** (`SourceLoanHelper.fundLoan`)
   - Lender approves and transfers tokens to the borrower via the helper.
   - Emits `LoanFunded(loanId)`.

4. **Repay the loan** (`SourceLoanHelper.repayLoan`)
   - Borrower approves and transfers repayment tokens back to the lender.
   - Emits `LoanRepaid(loanId, amount)`.

5. **Build proofs**
   - After each tx, the script waits for the Creditcoin prover to index the block.
   - It prints `REGISTER_PROOF_URL`, `FUND_PROOF_URL`, and `REPAY_PROOF_URL` — copy these (and `READABILITY_LOAN_ID`) into `.env`.

### CC3 hub setup

**Contracts:** `HubLoan`, `USCProofVerifier`, `USCLoanReadabilityManager`

Run `yarn loan_readability:setup` once (or again after redeploy):

- Point `USCLoanReadabilityManager.loanTarget` at `HubLoan`.
- Grant `READABILITY_ROLE` on `HubLoan` to the manager.
- Set `authorizedLoanRegistries[chainKey]` → `SourceLoanRegistry` (register proofs).
- Set `authorizedSourceContracts[chainKey]` → `SourceLoanHelper` (fund/repay proofs).

### Mirror state on CC3 (`yarn loan_readability:cc3`)

For each source action, an operator submits the corresponding proof to `USCLoanReadabilityManager.execute(action, chainKey, blockHeight, inclusionProof, continuityProof)`:

| Txn | Action | Source event | Hub update |
|-----|--------|--------------|------------|
| 1 | `LoanRegistered` (2) | `LoanRegistered` on registry | Decodes source tx calldata + event; calls `HubLoan.registerLoan(loanId, …)` with attested ID |
| 2 | `LoanFunded` (0) | `LoanFunded` on helper | `HubLoan.markLoanAsFunded(loanId)` |
| 3 | `LoanRepaid` (1) | `LoanRepaid` on helper | `HubLoan.recordLoanRepayment(loanId, amount)` |

**Per-txn details:**

1. **Register proof** — Manager verifies the source inclusion/continuity proof, reads `loanId` from the `LoanRegistered` log, decodes `registerLoan` calldata from the same tx, cross-checks event vs calldata, then registers on `HubLoan` with that exact `loanId`. Hub loan status → `Created`.

2. **Fund proof** — Manager verifies proof, reads `loanId` from `LoanFunded`, calls `markLoanAsFunded`. Hub status → `Funded`.

3. **Repay proof** — Manager verifies proof, reads `loanId` and `amount` from `LoanRepaid`, calls `recordLoanRepayment`. Hub status → `Repaid` (or `PartlyRepaid` for partial repayment).

### End state

| Chain | After register | After fund | After repay |
|-------|----------------|------------|-------------|
| Sepolia (registry + helper) | Loan registered & funded/repaid on-chain | ERC20 moved lender → borrower → lender | — |
| CC3 (`HubLoan`) | `Created` | `Funded` | `Repaid` |