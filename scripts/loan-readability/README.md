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
Grants `READABILITY_ROLE`, syncs `loanTarget`, and authorizes `SourceLoanHelper` as the trusted log emitter.

## 3. Run

```sh
# Step 1 — Sepolia
yarn loan_readability:source

# Copy READABILITY_LOAN_ID and proof URLs from the summary into .env

# Step 2 — CC3
yarn loan_readability:setup
yarn loan_readability:cc3
```