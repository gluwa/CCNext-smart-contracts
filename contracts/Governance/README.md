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
   USC source-chain `chainKey` and the ERC20 staking token. This is the chain's unique key in the
   Creditcoin chain registry, not its native EVM chain ID. Deploy `CrossChainGovernorHub` on
   Creditcoin USC and register each `(chainKey, spoke contract, prover contract)` via
   `registerVotingChain`, plus the trusted query relayer accounts via `setTrustedQuerySubmitter`.
2. **Create a proposal:** Call `createProposal` on the hub, choose shared `votingStart` and
   `votingEnd` timestamps, then call `openProposal(proposalId, votingStart, votingEnd)` with the
   same proposal id and timestamps on each voting chain.
3. **Stake & vote:** On each chain, users `stake` tokens for voting weight, then `castVote` with
   Bravo semantics (`0 = Against`, `1 = For`, `2 = Abstain`). Voting weight equals the user's staked
   balance at the time of voting, and their stake stays locked on that chain until the voting
   window closes.
4. **Finalize local tallies:** After the voting window ends, anyone calls `finalizeChainTally` on
   each chain, emitting `ChainTallyFinalized(proposalId, chainKey, forVotes, againstVotes, abstainVotes)`.
5. **Prove the tallies:** For each chain, build the ten-field USC readability query with
   [`scripts/buildGovernanceTallyQuery.js`](../../scripts/buildGovernanceTallyQuery.js), submit it
   to that chain's public prover, and wait for the result. Then a trusted relayer calls
   `submitChainTally(proverContract, queryId)` on the hub, which verifies and records the tally.
6. **Consolidate:** Once at least 3 chains (configurable per proposal, minimum 3) have reported,
   anyone calls `finalizeProposal` to consolidate all tallies into the final crosschain result.

## How the hub verifies a tally query

`submitChainTally` accepts a query only when **all** of the following hold:

- the caller is a trusted relayer;
- the query id has not been used before (replay protection);
- the query has a verified result available from the registered USC prover for that voting chain;
- the returned result segments match the query layout and the source transaction succeeded;
- the proof's USC source-chain key matches the `chainKey` embedded in the tally event;
- the event signature segment matches `ChainTallyFinalized(uint256,uint64,uint256,uint256,uint256)`;
- the contract that emitted the event is the registered spoke contract for the chain key claimed
  inside the event itself;
- the proposal exists, is still active, and that chain has not already reported.

Authorization is intentionally tied to the hub caller, not the prover's stored `principal`.
`principal` is caller-supplied when a query is submitted and is not included in the query id, so it
cannot authenticate who selected a query. If someone front-runs the same query with a different
principal, its proven transaction, layout, and query id remain identical and the trusted relayer can
still submit the result to the hub.

The layout check accepts transaction-specific segment offsets but requires every segment to read a
full 32-byte word. The governance query builder computes those offsets from the actual finalized
transaction and receipt using `@gluwa/usc-sdk`; offsets cannot be copied from another transaction or
event layout. The hub relies on segment ordering rather than the prover's reported
`ResultSegment.offset`, which the prover types mark as redundant.

## Build a tally query

After `finalizeChainTally` is mined on a voting chain, run:

```bash
node scripts/buildGovernanceTallyQuery.js \
  <source-rpc-url> \
  <finalize-transaction-hash> \
  <staked-governance-voting-address> \
  <usc-source-chain-key>
```

The script locates the `ChainTallyFinalized` event from the expected spoke and chain key, computes
the ten transaction-specific layout segments, and prints the `ChainQuery` and its `queryId`. Submit
that exact `ChainQuery` to the public prover with the trusted relayer address as the principal, wait
until its state is `ResultAvailable`, and pass the printed query id to `submitChainTally`.

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
