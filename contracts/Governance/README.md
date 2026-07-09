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
readability query. This means one prover query per chain per proposal, regardless of how many voters
participated.

The system consists of two contracts:

| Contract | Deployed on | Role |
| --- | --- | --- |
| [`StakedGovernanceVoting.sol`](./StakedGovernanceVoting.sol) | Each voting chain (3 or more, e.g. `Ethereum`, `Base`, `BNB Chain`) | Users stake an ERC20 token and cast Bravo-style votes (`Against` / `For` / `Abstain`). Once voting ends, anyone can finalize the local tally, which emits a `ChainTallyFinalized` event. |
| [`CrossChainGovernorHub.sol`](./CrossChainGovernorHub.sol) | Creditcoin USC (the consolidation chain) | Verifies USC prover queries proving each chain's `ChainTallyFinalized` event, records the per-chain tallies, and consolidates them into a single crosschain result once at least 3 chains have reported. |

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
        │                    USC Prover (readability queries)                     │
        │      one attested query per chain proving the finalized tally event     │
        └──────────────────────────────────┬──────────────────────────────────────┘
                                           ▼
                          Creditcoin USC (consolidation chain)
                        ┌─────────────────────────────────────┐
                        │        CrossChainGovernorHub        │
                        │  4. submitChainTally(prover, qId)   │  ← once per chain
                        │  5. finalizeProposal(proposalId)    │  ← requires ≥ 3 chains
                        │     → Succeeded / Defeated          │
                        └─────────────────────────────────────┘
```

## End-to-end flow

1. **Setup (once):** Deploy `StakedGovernanceVoting` on each voting chain with that chain's
   `chainKey` and the ERC20 staking token. Deploy `CrossChainGovernorHub` on Creditcoin USC and
   register each `(chainKey, sourceChainId, spoke contract, prover contract)` via
   `registerVotingChain`, plus the trusted query submitter accounts via `setTrustedQuerySubmitter`.
2. **Create a proposal:** Call `createProposal` on the hub, choose shared `votingStart` and
   `votingEnd` timestamps, then call `openProposal(proposalId, votingStart, votingEnd)` with the
   same proposal id and timestamps on each voting chain.
3. **Stake & vote:** On each chain, users `stake` tokens for voting weight, then `castVote` with
   Bravo semantics (`0 = Against`, `1 = For`, `2 = Abstain`). Voting weight equals the user's staked
   balance at the time of voting, and their stake stays locked on that chain until the voting
   window closes.
4. **Finalize local tallies:** After the voting window ends, anyone calls `finalizeChainTally` on
   each chain, emitting `ChainTallyFinalized(proposalId, chainKey, forVotes, againstVotes, abstainVotes)`.
5. **Prove the tallies:** For each chain, a USC readability query is submitted proving the
   `ChainTallyFinalized` event. Once attested, `submitChainTally(proverContract, queryId)` is called
   on the hub, which verifies the query and records the chain's tally.
6. **Consolidate:** Once at least 3 chains (configurable per proposal, minimum 3) have reported,
   anyone calls `finalizeProposal` to consolidate all tallies into the final crosschain result.

## How the hub verifies a tally query

`submitChainTally` accepts a query only when **all** of the following hold:

- the caller is a trusted submitter and matches the query principal;
- the query id has not been used before (replay protection);
- the query has a verified result available from the registered USC prover for that voting chain;
- the returned result segments match the query layout and the source transaction succeeded;
- the proof source chain id matches the chain registered for the tally's `chainKey`;
- the event signature segment matches `ChainTallyFinalized(uint256,uint64,uint256,uint256,uint256)`;
- the contract that emitted the event is the registered spoke contract for the chain key claimed
  inside the event itself;
- the proposal exists, is still active, and that chain has not already reported.

The submitter check is intentionally tied to `msg.sender`, not only the prover's stored
`principal`: the public prover accepts `principal` as query-submission data, so the hub must also
require the same trusted account to relay `submitChainTally`.

Because a query id is `keccak256(abi.encode(query))` and `principal` is set by whoever calls the
prover's `submitQuery` first, a bad actor watching the mempool can front-run the trusted worker
with the identical query but their own `principal`. This does not let them forge a tally — the hub
still rejects the resulting query on the `principal == msg.sender` (untrusted caller) check — but it
does grief the trusted worker, whose own `submitQuery` reverts because the query already exists.
The effect is a bounded delay only: the prover allows the query to be resubmitted once it times out,
after which the worker can claim the principal and relay the tally normally.

The layout check accepts any segment offsets but requires every segment to read a full 32-byte word,
matching the real USC readability layout (`scripts/common/utils.js` `LAYOUT_SEGMENTS`). It relies on
segment ordering rather than the prover's reported `ResultSegment.offset`, which the prover types
mark as redundant.

The expected result segment layout follows the standard USC readability layout:

```text
0: Rx  - Status
1: Tx  - From
2: Tx  - To
3: Event - Addr (spoke contract emitting the event)
4: Event - Signature (ChainTallyFinalized selector)
5: Event - proposalId
6: Event - chainKey
7: Event - forVotes
8: Event - againstVotes
9: Event - abstainVotes
```

## Why consolidate tallies instead of relaying votes?

Relaying each `VoteCast` event individually would work with the exact same mechanism (the spoke
emits Bravo-style `VoteCast` events precisely so that this is possible), but it would require one
prover query per vote. Consolidating on the spoke first compresses an entire chain's participation
into a single event — and therefore a single readability query — making the gas and query cost of a
proposal constant in the number of voters.
