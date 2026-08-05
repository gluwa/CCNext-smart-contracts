# 🗳️ Crosschain Stake & Governance Voting using USC Readability

This example demonstrates how the Creditcoin `Universal Smart Contracts` (USC) readability feature
can be used to run a **GovernorBravo-style governance vote across multiple chains**, with the final
result consolidated on a single chain (Creditcoin USC).

⚠️ Note: These contracts are provided as examples only and are not production-ready. They are
intended for learning and reference purposes.

## The problem

Protocols are increasingly deployed across many chains, but their governance usually lives on a
single chain. Token holders who have staked on other chains are either excluded from voting or
forced to bridge their tokens back to the governance chain.

## The proposed solution

Instead of bridging tokens or bridging every individual vote, each chain runs its own local
stake-and-vote contract and **only the final per-chain tally crosses chains** via an attested USC
readability proof. This means one prover proof per chain per proposal, regardless of how many voters
participated.

The system consists of two contracts:

| Contract | Deployed on | Role |
| --- | --- | --- |
| [`StakedGovernanceVoting.sol`](./StakedGovernanceVoting.sol) | Each voting chain (3 or more, e.g. `Ethereum`, `Base`, `BNB Chain`) | Users stake an ERC20 token and cast Bravo-style votes (`Against` / `For` / `Abstain`). Once voting ends, anyone can finalize the local tally, which emits a `ChainTallyFinalized` event. |
| [`CrossChainGovernorHub.sol`](./CrossChainGovernorHub.sol) | Creditcoin USC (the consolidation chain) | Verifies a USC readability proof of each chain's `ChainTallyFinalized` event through the shared `USCProofVerifier`, records the per-chain tallies, and consolidates them into a single crosschain result once at least 3 chains have reported. |

## How USC readability works here

This example uses the current USC readability model: a **synchronous, single-transaction proof**.

- A shared `USCProofVerifier` on Creditcoin USC fronts the native query-verifier precompile at
  `0xFD2`. This is the same verifier USC bridge and loan-readability contracts use.
- A relayer fetches the source-chain **inclusion proof** and **continuity proof** of the finalize
  transaction from the CC3 prover API and submits them to the hub in one call.
- `USCProofVerifier.verifyProofs(...)` verifies inclusion + continuity and **returns the proved
  transaction+receipt bytes**. The hub decodes the receipt with the `EvmV1Decoder` library and
  reads the tally directly out of the `ChainTallyFinalized` log — no polling, no off-chain result
  storage, and no pre-decoded result segments.

The USC primitives this example depends on are vendored under [`usc/`](./usc) (copied verbatim from
the USC core, with the pragma relaxed to compile here):

- [`usc/IUSCProofVerifier.sol`](./usc/IUSCProofVerifier.sol) — the shared verifier interface.
- [`usc/BlockProverTypes.sol`](./usc/BlockProverTypes.sol) — inclusion / continuity proof structs.
- [`usc/EvmV1Decoder.sol`](./usc/EvmV1Decoder.sol) — decodes the proved transaction + receipt.
- [`usc/QueryProofVerificationLib.sol`](./usc/QueryProofVerificationLib.sol) — proof helpers.

[`MockUSCProofVerifier.sol`](./MockUSCProofVerifier.sol) is a local stand-in for the verifier used
by the tests (returns the proved tx bytes carried in the inclusion proof; `setValid(false)` forces
a verification failure).

## Architecture

```text
   Chain A (e.g. Ethereum)          Chain B (e.g. Base)             Chain C (e.g. BNB)
 ┌───────────────────────┐      ┌───────────────────────┐      ┌───────────────────────┐
 │ StakedGovernanceVoting│      │ StakedGovernanceVoting│      │ StakedGovernanceVoting│
 │  1. stake(amount)     │      │  1. stake(amount)     │      │  1. stake(amount)     │
 │  2. castVote(id, s)   │      │  2. castVote(id, s)   │      │  2. castVote(id, s)   │
 │  3. finalizeChainTally│      │  3. finalizeChainTally│      │  3. finalizeChainTally│
 │     ─ emits ─┐        │      │     ─ emits ─┐        │      │     ─ emits ─┐        │
 └──────────────┼────────┘      └──────────────┼────────┘      └──────────────┼────────┘
                │ ChainTallyFinalized          │ ChainTallyFinalized          │
                ▼                              ▼                              ▼
        ┌─────────────────────────────────────────────────────────────────────────┐
        │            CC3 prover API → inclusion proof + continuity proof           │
        │        one proof per chain proving the finalized tally transaction       │
        └──────────────────────────────────┬──────────────────────────────────────┘
                                           ▼
                          Creditcoin USC (consolidation chain)
                 ┌───────────────────────────────────────────────────┐
                 │                CrossChainGovernorHub                │
                 │  4. submitChainTally(chainKey, height, proofs)      │  ← once per chain
                 │       → USCProofVerifier.verifyProofs (0xFD2)       │
                 │       → EvmV1Decoder reads ChainTallyFinalized      │
                 │  5. finalizeProposal(proposalId)                    │  ← requires ≥ 3 chains
                 │       → Succeeded / Defeated                        │
                 └───────────────────────────────────────────────────┘
```

## End-to-end flow

1. **Setup (once):** Deploy `StakedGovernanceVoting` on each voting chain with that chain's
   USC source-chain `chainKey` and the ERC20 staking token. This is the chain's unique key in the
   Creditcoin chain registry, not its native EVM chain ID. Deploy `CrossChainGovernorHub` on
   Creditcoin USC with the shared `USCProofVerifier` address, then register each
   `(chainKey, spoke contract)` via `registerVotingChain` and the trusted relayer accounts via
   `setTrustedQuerySubmitter`.
2. **Create a proposal:** Call `createProposal` on the hub, choose shared `votingStart` and
   `votingEnd` timestamps, then call `openProposal(proposalId, votingStart, votingEnd)` with the
   same proposal id and timestamps on each voting chain.
3. **Stake & vote:** On each chain, users `stake` tokens for voting weight, then `castVote` with
   Bravo semantics (`0 = Against`, `1 = For`, `2 = Abstain`). Voting weight equals the user's staked
   balance at the time of voting, and their stake stays locked on that chain until the voting
   window closes.
4. **Finalize local tallies:** After the voting window ends, anyone calls `finalizeChainTally` on
   each chain, emitting `ChainTallyFinalized(proposalId, chainKey, forVotes, againstVotes, abstainVotes)`.
5. **Prove the tallies:** For each chain, build the proof payload for the finalize transaction with
   [`scripts/buildGovernanceTallyProof.js`](../../scripts/buildGovernanceTallyProof.js), then a
   trusted relayer calls `submitChainTally(chainKey, blockHeight, inclusionProof, continuityProof)`
   on the hub. The hub verifies the proof and records the tally in the same transaction.
6. **Consolidate:** Once at least 3 chains (configurable per proposal, minimum 3) have reported,
   anyone calls `finalizeProposal` to consolidate all tallies into the final crosschain result.

## How the hub verifies a tally proof

`submitChainTally` accepts a proof only when **all** of the following hold:

- the caller is a trusted relayer;
- the voting chain (`chainKey`) is registered;
- the source coordinates `(chainKey, blockHeight, txIndex)` have not been used before (replay
  protection — the tx index is derived from the inclusion proof, binding the id to one source
  transaction);
- `USCProofVerifier.verifyProofs` confirms transaction inclusion and chain continuity — otherwise
  it reverts and nothing is recorded;
- the proved source transaction succeeded (receipt status `1`);
- the proved receipt contains exactly one `ChainTallyFinalized` log emitted by the spoke registered
  for that `chainKey`;
- the `chainKey` embedded in the event matches the chain the proof is claimed for, so a spoke
  cannot report a tally on behalf of a different chain;
- the proposal exists, is still active, and that chain has not already reported.

Authorization is intentionally tied to the trusted hub caller. The proof itself only attests that a
particular source transaction was included and succeeded; it says nothing about who is allowed to
relay it. Anyone could regenerate the same inclusion/continuity proof for a public transaction, so
the hub gates submission on `trustedQuerySubmitters` and derives every recorded value from the
proven event rather than from caller-supplied arguments.

## Reading the tally from the proved receipt

The hub does not trust any pre-decoded result; it decodes the proved transaction itself. The
`ChainTallyFinalized` event has no indexed arguments, so its only topic is the event signature and
all five values live in the log `data` as five 32-byte words:

```text
topic[0] : ChainTallyFinalized(uint256,uint64,uint256,uint256,uint256) signature
data     : abi.encode(proposalId, chainKey, forVotes, againstVotes, abstainVotes)
```

`EvmV1Decoder.decodeReceiptFields` returns the receipt status and logs; the hub scans the logs for
one emitted by the registered spoke with the expected signature and `abi.decode`s its `data`.

## Build a tally proof

After `finalizeChainTally` is mined on a voting chain, run:

```bash
node scripts/buildGovernanceTallyProof.js \
  <usc-source-chain-key> \
  <finalize-transaction-hash> \
  <cc3-prover-api-url>
```

The script uses `@gluwa/usc-sdk`'s `ProverAPIProofGenerator` to fetch the inclusion + continuity
proofs for the finalize transaction and packs them (via the reusable `packTallyProof` helper) into
the `chainKey`, `blockHeight`, `inclusionProof`, and `continuityProof` arguments for
`submitChainTally`. Submit those from the trusted relayer account. The hub validates that the
proved receipt carries a `ChainTallyFinalized` event from the registered spoke, so no source-chain
RPC is required by the script itself.

## Why consolidate tallies instead of relaying votes?

Relaying each `VoteCast` event individually would work with the exact same mechanism (the spoke
emits Bravo-style `VoteCast` events precisely so that this is possible), but it would require one
prover proof per vote. Consolidating on the spoke first compresses an entire chain's participation
into a single event — and therefore a single readability proof — making the gas and proof cost of a
proposal constant in the number of voters.
