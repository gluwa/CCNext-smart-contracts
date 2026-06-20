# Cross-Chain Loan Readability (Example)

End-to-end reference: register, fund, and repay a loan on Sepolia (source chain), then mirror loan state on CC3 testnet (hub) via attested block proofs and `USCLoanReadabilityManager`.

### Contract layout

```
contracts/
  abstract/                          # shared CCNext types (IUSCProofVerifier, BlockProverTypes, …)
  UseCases/
    SourceDestinationLoanRecording/
      abstract/
        LoanTypes.sol
        ILoanReadabilityTarget.sol
        LoanRegisterEIP712.sol
      SourceLoanRegistry.sol         # Sepolia — register + EIP-712 signatures
      SourceLoanHelper.sol           # Sepolia — ERC20 fund/repay events
      DestinationLoanRecording.sol     # CC3 — destination state (1:1 source chain)
      USCProofVerifier.sol           # CC3 — proof verification
      USCLoanReadabilityManager.sol  # CC3 — proof → hub updates
      EvmV1Decoder.sol               # internal lib (inlined at compile time)
scripts/loan-readability/            # deploy, setup, source, cc3 scripts
```

---

## Flow Components

Each loan lifecycle step on the source chain produces an event that can be proved to CC3. The hub never holds ERC20 — it only updates read-only loan state.

| Step | Source chain | Event / action | Prover output | Hub action | Hub state after |
|------|--------------|----------------|---------------|------------|-----------------|
| **Register** | `SourceLoanRegistry.registerLoan` | `LoanRegistered` | Inclusion + continuity proof of source tx | `USCLoanReadabilityManager.execute(LoanRegistered, …)` → `DestinationLoanRecording.registerLoan(chainKey, sourceLoanId, …)` | `Created` |
| **Fund** | `SourceLoanHelper.fundLoan` | `LoanFunded` | Inclusion + continuity proof of source tx | `execute(LoanFunded, …)` → `DestinationLoanRecording.markLoanAsFunded(chainKey, sourceLoanId)` | `Funded` |
| **Repay** | `SourceLoanHelper.repayLoan` | `LoanRepaid` | Inclusion + continuity proof of source tx | `execute(LoanRepaid, …)` → `DestinationLoanRecording.recordLoanRepayment(chainKey, sourceLoanId, amount)` | `Repaid` / `PartlyRepaid` |

**Why `SourceLoanRegistry` and `SourceLoanHelper` are split:**

- **Registry** — bilateral loan agreement: lender + borrower signatures, full `LoanTerms`, assigns `loanId`. No token transfers. Used for the heavy **register** proof (event + tx calldata cross-check).
- **Helper** — ERC20 settlement: lender funds borrower, borrower repays lender. Emits simple **fund/repay** events keyed by `loanId`. CC3 mirrors settlement status only; tokens stay on source.

**Loan ID sync:** Hub `sourceLoanId` is taken from the attested `LoanRegistered` event on the source chain (`topics[1]`). Both `USCLoanReadabilityManager` and `DestinationLoanRecording` enforce a **1:1** link to a single prover `chainKey`. Fund and repay proofs must use the same ID.

**Signatures:** Lender and borrower sign **EIP-712** typed data (`SourceLoanRegistry` / `1` / `chainId` / registry address) including the explicit `loanId` (= `nextLoanId` at sign time). See `LoanRegisterEIP712.sol` and `scripts/loan-readability/shared.ts`.

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

  Admin → USCLoanReadabilityManager.setLoanTarget(DestinationLoanRecording)
  Admin → DestinationLoanRecording.grantRole(READABILITY_ROLE, manager)
  Admin → manager.configureSourceChain(chainKey, sourceEvmChainId, SourceLoanRegistry, SourceLoanHelper)
  Admin → DestinationLoanRecording.configureSourceChain(chainKey, sourceEvmChainId, SourceLoanRegistry)
      (single 1:1 source link — manager and hub reject other chainKeys)

Phase 3 — Mirror state on CC3

  Operator → USCLoanReadabilityManager.execute(action, chainKey, blockHeight,
                                               inclusionProof, continuityProof)
      → USCProofVerifier.verifyProofs(...)  → encoded tx + receipt logs
      → decode event, validate emitter
      → DestinationLoanRecording.registerLoan / markLoanAsFunded / recordLoanRepayment
```

### Contract Interaction

```
// ── Step 1: Register on source ───────────────────────────────────────────────
Lender, Borrower → EIP-712 sign LoanRegister(loanId, fundFlow, repayFlow, loanTerms)
                   domain: SourceLoanRegistry / 1 / sourceChainId / registry address
User             → SourceLoanRegistry.registerLoan(loanId, fundFlow, repayFlow, loanTerms,
                                                   sigLender, sigBorrower)
                   └─ requires loanId == nextLoanId
                   └─ verifies EIP-712 signatures
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
           └─ require chainKey == sourceChainKey (hub mirrors one source chain only)
           └─ action == LoanRegistered:
                  validate emitter == authorizedLoanRegistry (fail-closed)
                  read loanId from LoanRegistered log
                  decode registerLoan calldata from tx; cross-check vs event
                  loanTarget.registerLoan(chainKey, loanId, sourceEvmChainId, registry, …)
           └─ action == LoanFunded:
                  validate emitter == authorizedSourceContract (fail-closed)
                  loanTarget.markLoanAsFunded(chainKey, loanId)
           └─ action == LoanRepaid:
                  validate emitter == authorizedSourceContract (fail-closed)
                  loanTarget.recordLoanRepayment(chainKey, loanId, amount)
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
 │   │    → sourceChainKey / authorizedLoanRegistry / authorizedSourceContract       │    │
 │   └───────────────────────────────┬──────────────────────────────────────────────┘    │
 │                                   │ READABILITY_ROLE                                  │
 │                                   ▼                                                    │
 │   ┌──────────────────────┐   ┌──────────────────────┐                                │
 │   │      DestinationLoanRecording         │   │   USCProofVerifier   │                                │
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
| `0` | `LoanFunded` | `LoanFunded(uint256 loanId)` | `authorizedSourceContract` (reverts if unset) |
| `1` | `LoanRepaid` | `LoanRepaid(uint256 loanId, uint256 amount)` | `authorizedSourceContract` (reverts if unset) |
| `2` | `LoanRegistered` | `LoanRegistered(…)` + tx calldata | `authorizedLoanRegistry` (reverts if unset) |

`execute` also reverts if `sourceChainKey` is unset or if the proof `chainKey` does not match the configured source chain (1:1 hub ↔ source).

---

## Smart Contracts

### 1. SourceLoanRegistry (Sepolia)

**Responsibility:** Source-chain loan agreement registry. Assigns `loanId`, stores signed terms, emits `LoanRegistered`.

```solidity
function registerLoan(
    uint256 loanId,
    LoanFlow memory fundFlow,
    LoanFlow memory repayFlow,
    LoanTerms memory loanTerms,
    bytes memory signatureOfLender,
    bytes memory signatureOfBorrower
) external returns (uint256);
```

- `nextLoanId` starts at `1`; caller must pass `loanId == nextLoanId`.
- Signatures are **EIP-712** (not plain `eth_sign`).
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

### 3. DestinationLoanRecording (CC3)

**Responsibility:** Hub loan state mirror (1:1 with one source chain). Updated only by `USCLoanReadabilityManager` (`READABILITY_ROLE`).

```solidity
function configureSourceChain(bytes32 chainKey, uint256 sourceEvmChainId, address loanRegistry) external;

function registerLoan(
    bytes32 chainKey,
    uint256 sourceLoanId,
    uint256 sourceChainId,
    address sourceRegistry,
    LoanFlow memory fundFlow,
    LoanFlow memory repayFlow,
    LoanTerms memory loanTerms,
    bytes memory signatureOfLender,
    bytes memory signatureOfBorrower
) external onlyRole(READABILITY_ROLE) returns (bytes32 loanKey);

function markLoanAsFunded(bytes32 chainKey, uint256 sourceLoanId) external onlyRole(READABILITY_ROLE);
function recordLoanRepayment(bytes32 chainKey, uint256 sourceLoanId, uint256 amount) external onlyRole(READABILITY_ROLE);

function getLoanOrder(bytes32 chainKey, uint256 sourceLoanId) external view returns (LoanOrder memory);
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
// USCLoanReadabilityManager
configureSourceChain(chainKey, sourceEvmChainId, sourceLoanRegistry, sourceLoanHelper);

// DestinationLoanRecording
configureSourceChain(chainKey, sourceEvmChainId, sourceLoanRegistry);
grantRole(READABILITY_ROLE, manager);
```

`yarn loan_readability:setup` configures both manager and hub.

---

## Submission Flow

```
━━━ Phase 0: Deploy ━━━

Step 0a — Source stack (Sepolia)
  yarn loan_readability:deploy:source
  → ERC20Mintable, SourceLoanRegistry, SourceLoanHelper

Step 0b — Hub stack (CC3 testnet)
  yarn loan_readability:deploy:cc3
  → DestinationLoanRecording, USCProofVerifier, USCLoanReadabilityManager

Step 0c — Wire roles
  yarn loan_readability:setup

━━━ Phase 1: Source chain actions (Sepolia) ━━━

Step 1 — Register loan
  Read registry.nextLoanId; lender + borrower EIP-712 sign for that loanId
  → SourceLoanRegistry.registerLoan(loanId, …)
  → loanId assigned (reference run: `sourceLoanId = 2`)
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
  → DestinationLoanRecording.registerLoan(attestedLoanId, …)
  → Hub status: Created

Step 6 — Fund proof (action = 0)
  Operator → execute(0, …)
  → DestinationLoanRecording.markLoanAsFunded(loanId)
  → Hub status: Funded

Step 7 — Repay proof (action = 1)
  Operator → execute(1, …)
  → DestinationLoanRecording.recordLoanRepayment(loanId, amount)
  → Hub status: Repaid
```

Run via scripts:

```sh
yarn loan_readability:source    # Phase 1
yarn loan_readability:cc3       # Phase 2 (after copying proof URLs to .env)
```

Optional flags: `SKIP_PROVER_WAIT=true`, `SKIP_HUB_REGISTER=true`.

**Hardhat verify** (after deploy) — use paths under `contracts/UseCases/SourceDestinationLoanRecording/`:

```sh
# Sepolia (Etherscan API v2 — set apiKey to ETHERSCAN string in hardhat.config.ts)
npx hardhat verify --network sepolia --contract contracts/UseCases/SourceDestinationLoanRecording/SourceLoanRegistry.sol:SourceLoanRegistry <ADDR>
npx hardhat verify --network sepolia --contract contracts/UseCases/SourceDestinationLoanRecording/SourceLoanHelper.sol:SourceLoanHelper <ADDR> <OWNER>

# CC3 (Blockscout — apiKey.cc3_testnet = BLOCKSCOUT_API_KEY)
npx hardhat verify --network cc3_testnet --contract contracts/UseCases/SourceDestinationLoanRecording/DestinationLoanRecording.sol:DestinationLoanRecording <ADDR> <ADMIN>
npx hardhat verify --network cc3_testnet --contract contracts/UseCases/SourceDestinationLoanRecording/USCProofVerifier.sol:USCProofVerifier <ADDR>
npx hardhat verify --network cc3_testnet --contract contracts/UseCases/SourceDestinationLoanRecording/USCLoanReadabilityManager.sol:USCLoanReadabilityManager <ADDR> <DESTINATION_LOAN_RECORDING> <VERIFIER> <ADMIN>
```

---

## Reference Run (Sepolia → CC3 testnet)

### Deployed contracts

**Sepolia**

| Contract | Address | Explorer |
|----------|---------|----------|
| `ERC20Mintable` | `0xd25A8849414e964b495a668589aB03a1D98f530F` | [Etherscan](https://sepolia.etherscan.io/address/0xd25A8849414e964b495a668589aB03a1D98f530F) |
| `SourceLoanRegistry` | `0x66b001E61371cC7d958bDD82D43E6AFfB4ca2189` | [Etherscan](https://sepolia.etherscan.io/address/0x66b001E61371cC7d958bDD82D43E6AFfB4ca2189) |
| `SourceLoanHelper` | `0x06F44eE53dD82bd06dC59921aD49d64357ffe40f` | [Etherscan](https://sepolia.etherscan.io/address/0x06F44eE53dD82bd06dC59921aD49d64357ffe40f) |

**CC3 testnet**

| Contract | Address | Explorer |
|----------|---------|----------|
| `DestinationLoanRecording` | `0x4ce9842E24f629Ed957045707F31e279633fcBe2` | [Blockscout](https://creditcoin-testnet.blockscout.com/address/0x4ce9842E24f629Ed957045707F31e279633fcBe2) |
| `USCProofVerifier` | `0xD9562EefD43aB187f0f4B0BF9b2D59710490825A` | [Blockscout](https://creditcoin-testnet.blockscout.com/address/0xD9562EefD43aB187f0f4B0BF9b2D59710490825A) |
| `USCLoanReadabilityManager` | `0xCb8039903ac0d4167f19B4536AC834Ac6be8E39F` | [Blockscout](https://creditcoin-testnet.blockscout.com/address/0xCb8039903ac0d4167f19B4536AC834Ac6be8E39F) |

### Hub setup (CC3, once per deploy)

| Action | Tx |
|--------|-----|
| `DestinationLoanRecording.grantRole(READABILITY_ROLE, manager)` | [0xa85addac…](https://creditcoin-testnet.blockscout.com/tx/0xa85addace315f40b839aa09177b256e641d52bae2fd75f339d3317250746cbaf) |
| `manager.configureSourceChain(…)` | [0x1f4a0d58…](https://creditcoin-testnet.blockscout.com/tx/0x1f4a0d58aa8dbee411845f5e00135a58d1ee22be2ccd823d3e95c6b68ee92020) |
| `DestinationLoanRecording.configureSourceChain(…)` | [0x106836a4…](https://creditcoin-testnet.blockscout.com/tx/0x106836a41f1456b2859b55face7f8b69aeee14588ae106e64e5ec9cde0077e52) |

### End-to-end transaction map (`sourceLoanId = 2`)

| Step | Sepolia tx | Prover proof | CC3 hub tx |
|------|------------|--------------|------------|
| 1 Register | [0x1c274c54…](https://sepolia.etherscan.io/tx/0x1c274c549be26ec4c5bc2bf9baa3438ff45acf22d9cfd660ddc5a9757c5ccca3) | [proof 153](https://prover.cc3-testnet.creditcoin.network/api/v1/proof/1/11097535/153) | [execute → registerLoan](https://creditcoin-testnet.blockscout.com/tx/0x4801e5605d4d71ffcc59e42f9cb02a7827c140b4f6f285c07dbb5a6555339a2b) |
| 2 Fund | [0xba96e6c0…](https://sepolia.etherscan.io/tx/0xba96e6c00382d64e03a400b9bf2cccf24bfdde8e570975b3b210f22685c77274) | [proof 135](https://prover.cc3-testnet.creditcoin.network/api/v1/proof/1/11097583/135) | [execute → markLoanAsFunded](https://creditcoin-testnet.blockscout.com/tx/0x5c549f16eeac762a564cc2ea08e381483c0c8266c6b8a15ff6990ba28bfead28) |
| 3 Repay | [0xdb2bc555…](https://sepolia.etherscan.io/tx/0xdb2bc555ca62d749b92d1274bda5d5f4d39c110b0ae3073fd71407b4b21ea9b3) | [proof 132](https://prover.cc3-testnet.creditcoin.network/api/v1/proof/1/11097630/132) | [execute → recordLoanRepayment](https://creditcoin-testnet.blockscout.com/tx/0xa8d0ddafadc9431e857add1872f6a1c54f19c75ffc40de9ebbcfb5bc09589fba) |

### End state

| Chain | After register | After fund | After repay |
|-------|----------------|------------|-------------|
| Sepolia | `loanId = 2` registered (EIP-712) | ERC20 lender → borrower (`1_000_000`) | Repayment borrower → lender (`1_050_000`) |
| CC3 `DestinationLoanRecording` | `Created` (status `0`) | `Funded` (status `1`) | `Repaid` (status `3`, `repaidAmount = 1_050_000`) |

**`.env` snapshot from this run:**

```env
READABILITY_LOAN_ID=2
REGISTER_PROOF_URL=https://prover.cc3-testnet.creditcoin.network/api/v1/proof/1/11097535/153
FUND_PROOF_URL=https://prover.cc3-testnet.creditcoin.network/api/v1/proof/1/11097583/135
REPAY_PROOF_URL=https://prover.cc3-testnet.creditcoin.network/api/v1/proof/1/11097630/132
```

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
| `DESTINATION_LOAN_RECORDING_CONTRACT_ADDRESS` | deploy:cc3 |
| `USC_LOAN_READABILITY_MANAGER_CONTRACT_ADDRESS` | deploy:cc3 |
| `READABILITY_LOAN_ID` | source script summary |
| `REGISTER_PROOF_URL`, `FUND_PROOF_URL`, `REPAY_PROOF_URL` | source script summary |
| `PROOF_BUILDER_URL` | default: `https://prover.cc3-testnet.creditcoin.network` |
| `SOURCE_CHAIN_KEY` | Sepolia prover chain key for proofs (default `1`) |
| `SOURCE_EVM_CHAIN_ID` | Source EVM `chainId` for EIP-712 + hub config (default `11155111`) |

Each deploy script targets **one chain only** — do not mix Sepolia and CC3 addresses in the same `.env` group.

---

## Security Considerations

| Topic | Behavior |
|-------|----------|
| **Proof replay** | `processedQueries[queryId]` prevents re-submitting the same `(chainKey, blockHeight, txIndex)` proof |
| **Single source chain** | Manager and `DestinationLoanRecording` accept only configured `sourceChainKey` |
| **Emitter trust (fail-closed)** | `authorizedLoanRegistry` / `authorizedSourceContract` must be set; unset or wrong emitter reverts |
| **Unconfigured hub** | `execute` reverts with `SourceChainNotConfigured` until `configureSourceChain` is called |
| **Register integrity** | `LoanRegistered` event fields are cross-checked against decoded `registerLoan` calldata (`RegisterEventMismatch`) |
| **EIP-712 register** | Signatures bind `loanId`, `chainId`, and registry address; hub re-verifies on register |
| **Hub write access** | Only `READABILITY_ROLE` (manager) can mutate `DestinationLoanRecording` |
| **Loan ID collision** | `LoanAlreadyRegistered` if the same attested `sourceLoanId` is registered twice on hub |
| **Deadline** | Fund/repay on hub revert if `block.timestamp > deadlineTimestamp` |
| **Registry/helper split** | No on-chain link between registry and helper in this demo — production should enforce `loanId` binding or use a single contract |
| **Order** | Register proof must be submitted before fund/repay proofs; hub loan must exist before `markLoanAsFunded` |

