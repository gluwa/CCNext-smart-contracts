# Cross-Chain Loan Readability (Example)

End-to-end reference: register, fund, and repay a loan on Sepolia (source chain), then mirror loan state on CC3 testnet (hub) via attested block proofs and `USCLoanReadabilityManager`.

---

## Flow Components

Each loan lifecycle step on the source chain produces an event that can be proved to CC3. The hub never holds ERC20 — it only updates read-only loan state.

| Step | Source chain | Event / action | Prover output | Hub action | Hub state after |
|------|--------------|----------------|---------------|------------|-----------------|
| **Register** | `SourceLoanRegistry.registerLoan` | `LoanRegistered` | Inclusion + continuity proof of source tx | `USCLoanReadabilityManager.execute(LoanRegistered, …)` → `HubLoan.registerLoan(loanId, …)` | `Created` |
| **Fund** | `SourceLoanHelper.fundLoan` | `LoanFunded` | Inclusion + continuity proof of source tx | `execute(LoanFunded, …)` → `HubLoan.markLoanAsFunded(loanId)` | `Funded` |
| **Repay** | `SourceLoanHelper.repayLoan` | `LoanRepaid` | Inclusion + continuity proof of source tx | `execute(LoanRepaid, …)` → `HubLoan.recordLoanRepayment(loanId, amount)` | `Repaid` / `PartlyRepaid` |

**Why `SourceLoanRegistry` and `SourceLoanHelper` are split:**

- **Registry** — bilateral loan agreement: lender + borrower signatures, full `LoanTerms`, assigns `loanId`. No token transfers. Used for the heavy **register** proof (event + tx calldata cross-check).
- **Helper** — ERC20 settlement: lender funds borrower, borrower repays lender. Emits simple **fund/repay** events keyed by `loanId`. CC3 mirrors settlement status only; tokens stay on source.

**Loan ID sync:** Hub `loanId` is **not** auto-incremented. It is taken from the attested `LoanRegistered` event on the source chain (`topics[1]`). Fund and repay proofs must use the same ID.

**Deadline:** `LoanTerms.deadlineTimestamp` is Unix seconds (not block number) so the same deadline is valid across chains with different block heights.

---

## Architecture

### Readability Flow

```
Phase 1 — Source chain (Sepolia)

  Lender + Borrower sign loan terms hash
      │
      ▼
  SourceLoanRegistry.registerLoan(...)
      → assigns loanId (e.g. 1)
      → emits LoanRegistered(loanId, lender, borrower, …)
      → Prover indexes tx → REGISTER_PROOF_URL

  Deployer → SourceLoanHelper.registerLoanFund(loanId, …)   [setup, owner-only]

  Lender → SourceLoanHelper.fundLoan(loanId)
      → ERC20: lender → borrower
      → emits LoanFunded(loanId)
      → Prover indexes tx → FUND_PROOF_URL

  Borrower → SourceLoanHelper.repayLoan(loanId, amount)
      → ERC20: borrower → lender
      → emits LoanRepaid(loanId, amount)
      → Prover indexes tx → REPAY_PROOF_URL

Phase 2 — Hub setup (CC3 testnet, once per deploy)

  Admin → USCLoanReadabilityManager.setLoanTarget(HubLoan)
  Admin → HubLoan.grantRole(READABILITY_ROLE, manager)
  Admin → manager.setAuthorizedLoanRegistry(chainKey, SourceLoanRegistry)
  Admin → manager.setAuthorizedSourceContract(chainKey, SourceLoanHelper)

Phase 3 — Mirror state on CC3

  Operator → USCLoanReadabilityManager.execute(action, chainKey, blockHeight,
                                               inclusionProof, continuityProof)
      → USCProofVerifier.verifyProofs(...)  → encoded tx + receipt logs
      → decode event, validate emitter
      → HubLoan.registerLoan / markLoanAsFunded / recordLoanRepayment
```

### Contract Interaction

```
// ── Step 1: Register on source ───────────────────────────────────────────────
Lender, Borrower → sign keccak256(abi.encodePacked(fundFlow, repayFlow, loanTerms))
User             → SourceLoanRegistry.registerLoan(fundFlow, repayFlow, loanTerms,
                                                   sigLender, sigBorrower)
                   └─ verifies ECDSA signatures
                   └─ loanId = nextLoanId++
                   └─ emits LoanRegistered(loanId, lender, borrower, loanAmount, repayAmount, deadlineTimestamp)

// ── Step 2: Fund / repay on source ───────────────────────────────────────────
Owner   → SourceLoanHelper.registerLoanFund(loanId, lender, borrower, token, fundAmount, repayAmount)
Lender  → ERC20.approve(helper, fundAmount)
Lender  → SourceLoanHelper.fundLoan(loanId)
          └─ emits LoanFunded(loanId)

Borrower → ERC20.approve(helper, repayAmount)
Borrower → SourceLoanHelper.repayLoan(loanId, amount)
           └─ emits LoanRepaid(loanId, amount)

// ── Step 3: Fetch proof (off-chain) ──────────────────────────────────────────
Operator → GET PROOF_BUILDER_URL/api/v1/proof/{chainKey}/{headerNumber}/{txIndex}
           └─ returns { txBytes, merkleProof, continuityProof, … }

// ── Step 4: Submit proof on CC3 ──────────────────────────────────────────────
Operator → USCLoanReadabilityManager.execute(
               action,           // 0=LoanFunded, 1=LoanRepaid, 2=LoanRegistered
               chainKey,         // bytes32(sourceChainId), e.g. chainKey(1) for Sepolia
               blockHeight,
               inclusionProof,
               continuityProof)
           └─ proofVerifier.verifyProofs → encodedTransaction
           └─ EvmV1Decoder.decodeReceiptFields → logs
           └─ action == LoanRegistered:
                  validate emitter ∈ authorizedLoanRegistries[chainKey]
                  read loanId from LoanRegistered log
                  decode registerLoan calldata from tx; cross-check vs event
                  loanTarget.registerLoan(loanId, …)   [READABILITY_ROLE on HubLoan]
           └─ action == LoanFunded:
                  validate emitter ∈ authorizedSourceContracts[chainKey]
                  loanTarget.markLoanAsFunded(loanId)
           └─ action == LoanRepaid:
                  validate emitter ∈ authorizedSourceContracts[chainKey]
                  loanTarget.recordLoanRepayment(loanId, amount)
```

Register proofs are heavier (calldata + event match). Fund/repay proofs only read `loanId` (and `amount` for repay) from event logs.

### Component Map

```
╔══════════════════════════════════════════════════════════════════════════════════════════╗
║                     CROSS-CHAIN LOAN READABILITY — COMPONENT MAP                         ║
╚══════════════════════════════════════════════════════════════════════════════════════════╝

 ┌────────────────────────────── SOURCE CHAIN (Sepolia) ──────────────────────────────────┐
 │                                                                                        │
 │   ┌──────────────────────┐         ┌──────────────────────┐                            │
 │   │  SourceLoanRegistry  │         │   SourceLoanHelper   │                            │
 │   │                      │         │                      │                            │
 │   │  registerLoan()      │         │  registerLoanFund()  │  ← owner setup             │
 │   │    → LoanRegistered  │         │  fundLoan()          │                            │
 │   │                      │         │    → LoanFunded      │                            │
 │   │  (terms + signatures)│         │  repayLoan()         │                            │
 │   │  assigns loanId      │         │    → LoanRepaid      │                            │
 │   └──────────┬───────────┘         └──────────┬───────────┘                            │
 │              │ events                        │ events + ERC20                         │
 │              └────────────────┬─────────────┘                                        │
 │                               │ txs indexed by                                         │
 │                               ▼                                                        │
 │                    ┌─────────────────────┐                                             │
 │                    │  Creditcoin Prover  │                                             │
 │                    │  (PROOF_BUILDER_URL)│                                             │
 │                    └──────────┬──────────┘                                             │
 └───────────────────────────────┼────────────────────────────────────────────────────────┘
                                 │ inclusionProof + continuityProof
                                 │
 ┌───────────────────────────────┼──────────── HUB CHAIN (CC3 testnet) ───────────────────┐
 │                               ▼                                                        │
 │   ┌──────────────────────────────────────────────────────────────────────────────┐    │
 │   │                    USCLoanReadabilityManager                                  │    │
 │   │                                                                               │    │
 │   │  execute(action, chainKey, blockHeight, inclusionProof, continuityProof)    │    │
 │   │    → USCProofVerifier.verifyProofs                                            │    │
 │   │    → EvmV1Decoder (tx + receipt logs)                                         │    │
 │   │    → authorizedLoanRegistries / authorizedSourceContracts                     │    │
 │   └───────────────────────────────┬──────────────────────────────────────────────┘    │
 │                                   │ READABILITY_ROLE                                  │
 │                                   ▼                                                    │
 │   ┌──────────────────────┐   ┌──────────────────────┐                                │
 │   │      HubLoan         │   │   USCProofVerifier   │                                │
 │   │                      │   │                      │                                │
 │   │  registerLoan(id,…)  │   │  verifyProofs()      │                                │
 │   │  markLoanAsFunded()  │   │  calculateTxIndex()  │                                │
 │   │  recordLoanRepayment │   └──────────────────────┘                                │
 │   │  (state mirror only) │                                                            │
 │   └──────────────────────┘                                                            │
 └────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Loan Terms & Registration Hash

Lender and borrower sign an Ethereum signed message over:

```
msgHash = keccak256(abi.encodePacked(
    fundFlow.from, fundFlow.to, fundFlow.withToken,
    repayFlow.from, repayFlow.to, repayFlow.withToken,
    loanTerms.loanAmount,
    loanTerms.interestRate,
    loanTerms.expectedRepaymentAmount,
    loanTerms.deadlineTimestamp
))
ethHash = toEthSignedMessageHash(msgHash)
```

| Field | Type | Notes |
|-------|------|-------|
| `fundFlow` | `(from, to, withToken)` | Lender → borrower, ERC20 address |
| `repayFlow` | `(from, to, withToken)` | Borrower → lender, same token |
| `loanAmount` | `uint256` | Principal in token smallest units |
| `interestRate` | `uint256` | Basis points (e.g. 500 = 5%) |
| `expectedRepaymentAmount` | `uint256` | Must be ≥ `loanAmount` |
| `deadlineTimestamp` | `uint256` | Unix seconds; must be > `block.timestamp` at register |

Default script values: `loanAmount = 1_000_000`, `interestRate = 500`, duration = 7 days (`604_800` seconds).

### Manager Actions

| `action` | Enum | Source event | Emitter check |
|----------|------|--------------|---------------|
| `0` | `LoanFunded` | `LoanFunded(uint256 loanId)` | `authorizedSourceContracts[chainKey]` |
| `1` | `LoanRepaid` | `LoanRepaid(uint256 loanId, uint256 amount)` | `authorizedSourceContracts[chainKey]` |
| `2` | `LoanRegistered` | `LoanRegistered(…)` + tx calldata | `authorizedLoanRegistries[chainKey]` |

If an authorized address mapping is `address(0)`, emitter validation is skipped (permissive); proof verification still required.

---

## Smart Contracts

### 1. SourceLoanRegistry (Sepolia)

**Responsibility:** Source-chain loan agreement registry. Assigns `loanId`, stores signed terms, emits `LoanRegistered`.

```solidity
function registerLoan(
    LoanFlow memory fundFlow,
    LoanFlow memory repayFlow,
    LoanTerms memory loanTerms,
    bytes memory signatureOfLender,
    bytes memory signatureOfBorrower
) external returns (uint256 loanId);
```

- `nextLoanId` starts at `1`.
- No ERC20 transfers.

---

### 2. SourceLoanHelper (Sepolia)

**Responsibility:** Source-chain ERC20 fund/repay escrow. Emits events proved on CC3.

```solidity
function registerLoanFund(
    uint256 loanId, address lender, address borrower,
    address token, uint256 fundAmount, uint256 repayAmount
) external onlyOwner;

function fundLoan(uint256 loanId) external;      // lender only → emits LoanFunded
function repayLoan(uint256 loanId, uint256 amount) external;  // borrower only → emits LoanRepaid
```

- Token must be in `authorizedTokens`.
- Not linked on-chain to `SourceLoanRegistry` in this example — operator/script binds the same `loanId`.

---

### 3. HubLoan (CC3)

**Responsibility:** Hub loan state mirror. Updated only by `USCLoanReadabilityManager` (`READABILITY_ROLE`).

```solidity
function registerLoan(
    uint256 loanId,
    LoanFlow memory fundFlow,
    LoanFlow memory repayFlow,
    LoanTerms memory loanTerms,
    bytes memory signatureOfLender,
    bytes memory signatureOfBorrower
) external onlyRole(READABILITY_ROLE) returns (uint256);

function markLoanAsFunded(uint256 loanId) external onlyRole(READABILITY_ROLE);
function recordLoanRepayment(uint256 loanId, uint256 amount) external onlyRole(READABILITY_ROLE);
```

| Status | Value | Meaning |
|--------|-------|---------|
| `Created` | 0 | Registered on hub, not yet funded |
| `Funded` | 1 | Fund proof applied |
| `PartlyRepaid` | 2 | Partial repayment |
| `Repaid` | 3 | Full repayment |
| `Expired` | 4 | Past deadline (admin `markLoanAsExpired`) |

---

### 4. USCProofVerifier (CC3)

**Responsibility:** Verify Merkle inclusion + continuity proofs from the Creditcoin prover; return encoded source transaction bytes.

---

### 5. USCLoanReadabilityManager (CC3)

**Responsibility:** Orchestrate proof verification and hub updates. Dedupes queries via `processedQueries[queryId]`.

```solidity
function execute(
    uint8 action,
    bytes32 chainKey,
    uint64 blockHeight,
    BlockProverTypes.InclusionProof calldata inclusionProof,
    BlockProverTypes.ContinuityProof calldata continuityProof
) external whenNotPaused nonReentrant returns (bool);
```

**Setup (admin):**

```solidity
setLoanTarget(hubLoan);
setAuthorizedLoanRegistry(chainKey, sourceLoanRegistry);   // register proofs
setAuthorizedSourceContract(chainKey, sourceLoanHelper);  // fund/repay proofs
```

On `HubLoan`: `grantRole(READABILITY_ROLE, manager)`.

---

## Submission Flow

```
━━━ Phase 0: Deploy ━━━

Step 0a — Source stack (Sepolia)
  yarn loan_readability:deploy:source
  → ERC20Mintable, SourceLoanRegistry, SourceLoanHelper

Step 0b — Hub stack (CC3 testnet)
  yarn loan_readability:deploy:cc3
  → HubLoan, USCProofVerifier, USCLoanReadabilityManager

Step 0c — Wire roles
  yarn loan_readability:setup

━━━ Phase 1: Source chain actions (Sepolia) ━━━

Step 1 — Register loan
  Lender + Borrower sign terms
  → SourceLoanRegistry.registerLoan(...)
  → loanId assigned (reference run: loanId = 1)
  → Wait for prover → REGISTER_PROOF_URL

Step 2 — Prepare helper (if not already)
  Owner → authorizeToken(ERC20)
  Owner → registerLoanFund(loanId, …)

Step 3 — Fund loan
  Lender → approve + fundLoan(loanId)
  → Wait for prover → FUND_PROOF_URL

Step 4 — Repay loan
  Borrower → approve + repayLoan(loanId, expectedRepaymentAmount)
  → Wait for prover → REPAY_PROOF_URL

  Script prints:
    READABILITY_LOAN_ID, REGISTER_PROOF_URL, FUND_PROOF_URL, REPAY_PROOF_URL

━━━ Phase 2: Hub mirror (CC3) ━━━

Step 5 — Register proof (action = 2)
  Operator → USCLoanReadabilityManager.execute(2, chainKey, blockHeight, proofs…)
  → HubLoan.registerLoan(attestedLoanId, …)
  → Hub status: Created

Step 6 — Fund proof (action = 0)
  Operator → execute(0, …)
  → HubLoan.markLoanAsFunded(loanId)
  → Hub status: Funded

Step 7 — Repay proof (action = 1)
  Operator → execute(1, …)
  → HubLoan.recordLoanRepayment(loanId, amount)
  → Hub status: Repaid
```

Run via scripts:

```sh
yarn loan_readability:source    # Phase 1
yarn loan_readability:cc3       # Phase 2 (after copying proof URLs to .env)
```

Optional flags: `SKIP_PROVER_WAIT=true`, `SKIP_HUB_REGISTER=true`.

---

## Reference Run (Sepolia → CC3 testnet)

### Deployed contracts

**Sepolia**

| Contract | Explorer |
|----------|----------|
| `SourceLoanRegistry` | [0x8dBd4071…](https://sepolia.etherscan.io/address/0x8dbd40713814d12d7ab02a05b3b884eb65fb055d#code) |
| `SourceLoanHelper` | [0x4F7e29eB…](https://sepolia.etherscan.io/address/0x4F7e29eB471F8D0e125e6F6dAa42A7Ce1B0eeBa7) |

**CC3 testnet**

| Contract | Explorer |
|----------|----------|
| `HubLoan` | [0x4B6c288f…](https://creditcoin-testnet.blockscout.com/address/0x4B6c288fb4e81af06C9c7BAb831c4F4081C8E81C) |
| `USCProofVerifier` | [0x501bD7B3…](https://creditcoin-testnet.blockscout.com/address/0x501bD7B37094D00e8520Ed4DF557ce326649847E) |
| `USCLoanReadabilityManager` | [0xd48bBBD4…](https://creditcoin-testnet.blockscout.com/address/0xd48bBBD40D0410F271c2e417897a7eeC725d7B46) |

### End-to-end transaction map (`loanId = 1`)

| Step | Sepolia tx | Prover proof | CC3 hub tx |
|------|------------|--------------|------------|
| 1 Register | [0x35c7b288…](https://sepolia.etherscan.io/tx/0x35c7b288bc4b7a78abdb42dfcdaebbd1ba6933f3336affd4934460a17b653fcb) | [proof 217](https://prover.cc3-testnet.creditcoin.network/api/v1/proof/1/11089085/217) | [execute → registerLoan](https://creditcoin-testnet.blockscout.com/tx/0xf2b0b3e578feb27f8ec571289398be4eb896cec3b16edaf67cfd0440c1587fb4) |
| 2 Fund | [0x05f5315a…](https://sepolia.etherscan.io/tx/0x05f5315ab3e84920473c3afbf634396fdd4d65982d8047cd1ec129c4e7a6d29c) | [proof 235](https://prover.cc3-testnet.creditcoin.network/api/v1/proof/1/11089131/235) | [execute → markLoanAsFunded](https://creditcoin-testnet.blockscout.com/tx/0xe782f3ba54b81aa6a21cbc5832badddf01e3d3d712dbedab535b76b594c4bd0a) |
| 3 Repay | [0xf98884e2…](https://sepolia.etherscan.io/tx/0xf98884e2b5d3bdc74309217d937a7d23d3b477abd83725fa2176044003b9b683) | [proof 219](https://prover.cc3-testnet.creditcoin.network/api/v1/proof/1/11089187/219) | [execute → recordLoanRepayment](https://creditcoin-testnet.blockscout.com/tx/0xe60b03070ecbd635d05d365d5a039b3fab2ce44a12e28b2ee4dd51348070ccf5) |

### End state

| Chain | After register | After fund | After repay |
|-------|----------------|------------|-------------|
| Sepolia | Loan registered | ERC20 lender → borrower | Repayment borrower → lender |
| CC3 `HubLoan` | `Created` | `Funded` | `Repaid` |

---

## Scripts & Environment

| Script | Network | Purpose |
|--------|---------|---------|
| `yarn loan_readability:deploy:source` | Sepolia | Deploy token, registry, helper |
| `yarn loan_readability:deploy:cc3` | cc3_testnet | Deploy hub, verifier, manager |
| `yarn loan_readability:setup` | cc3_testnet | Roles + authorized emitters |
| `yarn loan_readability:source` | Sepolia | Full source flow + proof URLs |
| `yarn loan_readability:cc3` | cc3_testnet | Submit proofs, update hub |

Key `.env` variables (see `.env.example`):

| Variable | Set by |
|----------|--------|
| `SOURCE_LOAN_REGISTRY_CONTRACT_ADDRESS` | deploy:source |
| `SOURCE_LOAN_HELPER_CONTRACT_ADDRESS` | deploy:source |
| `HUB_LOAN_CONTRACT_ADDRESS` | deploy:cc3 |
| `USC_LOAN_READABILITY_MANAGER_CONTRACT_ADDRESS` | deploy:cc3 |
| `READABILITY_LOAN_ID` | source script summary |
| `REGISTER_PROOF_URL`, `FUND_PROOF_URL`, `REPAY_PROOF_URL` | source script summary |
| `PROOF_BUILDER_URL` | default: `https://prover.cc3-testnet.creditcoin.network` |
| `SOURCE_CHAIN_KEY` | Sepolia chain key for proofs (default `1`) |

Each deploy script targets **one chain only** — do not mix Sepolia and CC3 addresses in the same `.env` group.

---

## Security Considerations

| Topic | Behavior |
|-------|----------|
| **Proof replay** | `processedQueries[queryId]` prevents re-submitting the same `(chainKey, blockHeight, txIndex)` proof |
| **Emitter trust** | Non-zero `authorizedLoanRegistries` / `authorizedSourceContracts` enforce expected log emitter per `chainKey` |
| **Register integrity** | `LoanRegistered` event fields are cross-checked against decoded `registerLoan` calldata (`RegisterEventMismatch`) |
| **Hub write access** | Only `READABILITY_ROLE` (manager) can mutate `HubLoan`; signatures re-verified on hub register |
| **Loan ID collision** | `LoanAlreadyRegistered` on hub if the same attested `loanId` is registered twice |
| **Deadline** | Fund/repay on hub revert if `block.timestamp > deadlineTimestamp` |
| **Registry/helper split** | No on-chain link between registry and helper in this demo — production should enforce `loanId` binding or use a single contract |
| **Order** | Register proof must be submitted before fund/repay proofs; hub loan must exist before `markLoanAsFunded` |

