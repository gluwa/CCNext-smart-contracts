// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUSCProofVerifier} from "./usc/IUSCProofVerifier.sol";
import {BlockProverTypes} from "./usc/BlockProverTypes.sol";
import {EvmV1Decoder} from "./usc/EvmV1Decoder.sol";

/**
 * @title CrossChainGovernorHub
 * @notice Hub contract of the crosschain governance example, deployed on Creditcoin USC (the
 *         consolidation chain). Each voting chain runs a `StakedGovernanceVoting` spoke where
 *         users stake and vote locally; after a proposal's voting window closes the spoke emits
 *         a `ChainTallyFinalized` event.
 *
 *         The hub reads that event through USC readability. A trusted relayer submits the
 *         source-chain inclusion + continuity proofs of the finalize transaction to the shared
 *         `USCProofVerifier` (fronting the native `0xFD2` precompile). Verification is
 *         synchronous: `verifyProofs` returns the proved transaction+receipt bytes, the hub
 *         decodes the receipt with `EvmV1Decoder`, and reads the tally straight out of the
 *         `ChainTallyFinalized` log. Once at least `minChainTallies` chains (3 or more) have
 *         reported, anyone consolidates the per-chain tallies into the final crosschain result.
 */
contract CrossChainGovernorHub is Ownable {
    /// @notice A crosschain vote must aggregate at least this many chains
    uint64 public constant MIN_VOTING_CHAINS = 3;

    // ChainTallyFinalized(uint256,uint64,uint256,uint256,uint256)
    bytes32 public constant CHAIN_TALLY_FINALIZED_SELECTOR =
        0x91478558dbd572f982da5048e94a9d7ebaac6a871971c4e168e0ecc3accb08ec;

    enum ProposalState {
        /*0*/
        None,
        /*1*/
        Active,
        /*2*/
        Succeeded,
        /*3*/
        Defeated
    }

    struct ChainTally {
        bool recorded;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
    }

    struct Proposal {
        string description;
        uint64 minChainTallies;
        uint64 talliedChains;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        ProposalState state;
    }

    event ProofVerifierSet(address indexed previous, address indexed next);
    event VotingChainRegistered(uint64 indexed chainKey, address spokeContract);
    event TrustedQuerySubmitterSet(address indexed submitter, bool trusted);
    event ProposalCreated(uint256 indexed proposalId, string description, uint64 minChainTallies);
    event ChainTallyRecorded(
        uint256 indexed proposalId,
        uint64 indexed chainKey,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes,
        bytes32 queryId
    );
    event ProposalConsolidated(
        uint256 indexed proposalId,
        ProposalState state,
        uint64 talliedChains,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes
    );

    // keccak256(abi.encode(uint256(keccak256("crossChainGovernorHub.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0x737e03fe02bda182a7d9c29b29d27ded023bc42630f3ce5d0dc49e8fddee1800;

    struct VotingChainConfig {
        bool registered;
        address spokeContract;
    }

    struct HubStorage {
        // shared USC proof verifier (native 0xFD2 precompile front)
        IUSCProofVerifier proofVerifier;
        // chainKey => voting chain metadata
        mapping(uint64 => VotingChainConfig) votingChains;
        uint64 registeredChainCount;
        // accounts allowed to relay verified source-chain proofs
        mapping(address => bool) trustedQuerySubmitters;
        mapping(uint256 => Proposal) proposals;
        // proposalId => chainKey => recorded tally
        mapping(uint256 => mapping(uint64 => ChainTally)) chainTallies;
        // proved-once guard, keyed by the source coordinates (chainKey, blockHeight, txIndex)
        mapping(bytes32 => bool) usedQueryId;
    }

    constructor(address proofVerifier_) Ownable(msg.sender) {
        require(proofVerifier_ != address(0), "Governor: Invalid proof verifier");
        _getHubStorage().proofVerifier = IUSCProofVerifier(proofVerifier_);
        emit ProofVerifierSet(address(0), proofVerifier_);
    }

    function _getHubStorage() private pure returns (HubStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    function proofVerifier() external view returns (address) {
        return address(_getHubStorage().proofVerifier);
    }

    function votingChain(uint64 chainKey) external view returns (address) {
        return _getHubStorage().votingChains[chainKey].spokeContract;
    }

    function votingChainConfig(
        uint64 chainKey
    ) external view returns (VotingChainConfig memory) {
        return _getHubStorage().votingChains[chainKey];
    }

    function registeredVotingChainCount() external view returns (uint64) {
        return _getHubStorage().registeredChainCount;
    }

    function isTrustedQuerySubmitter(address submitter) external view returns (bool) {
        return _getHubStorage().trustedQuerySubmitters[submitter];
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _getHubStorage().proposals[proposalId];
    }

    function getChainTally(
        uint256 proposalId,
        uint64 chainKey
    ) external view returns (ChainTally memory) {
        return _getHubStorage().chainTallies[proposalId][chainKey];
    }

    function isQueryUsed(bytes32 queryId) external view returns (bool) {
        return _getHubStorage().usedQueryId[queryId];
    }

    /// @notice Point the hub at a (new) shared USC proof verifier
    function setProofVerifier(address newVerifier) external onlyOwner {
        require(newVerifier != address(0), "Governor: Invalid proof verifier");
        HubStorage storage $ = _getHubStorage();
        address previous = address($.proofVerifier);
        $.proofVerifier = IUSCProofVerifier(newVerifier);
        emit ProofVerifierSet(previous, newVerifier);
    }

    /// @notice Register (or update) the trusted spoke for a USC source-chain key
    function registerVotingChain(
        uint64 chainKey,
        address spokeContract
    ) external onlyOwner {
        require(chainKey != 0, "Governor: Invalid chain key");
        require(spokeContract != address(0), "Governor: Invalid spoke contract");
        HubStorage storage $ = _getHubStorage();
        if (!$.votingChains[chainKey].registered) {
            $.registeredChainCount += 1;
        }
        $.votingChains[chainKey] = VotingChainConfig({
            registered: true,
            spokeContract: spokeContract
        });
        emit VotingChainRegistered(chainKey, spokeContract);
    }

    /// @notice Allow or disallow an account to relay verified source-chain proofs
    function setTrustedQuerySubmitter(address submitter, bool trusted) external onlyOwner {
        require(submitter != address(0), "Governor: Invalid submitter");
        _getHubStorage().trustedQuerySubmitters[submitter] = trusted;
        emit TrustedQuerySubmitterSet(submitter, trusted);
    }

    /**
     * @notice Create a crosschain proposal. The same `proposalId` must then be opened on each
     *         voting chain via `StakedGovernanceVoting.openProposal`.
     * @param minChainTallies Number of chains that must report before consolidation, at least 3
     */
    function createProposal(
        uint256 proposalId,
        string calldata description,
        uint64 minChainTallies
    ) external onlyOwner {
        HubStorage storage $ = _getHubStorage();
        require($.proposals[proposalId].state == ProposalState.None, "Governor: Proposal exists");
        require(minChainTallies >= MIN_VOTING_CHAINS, "Governor: Need at least 3 chains");
        require(
            minChainTallies <= $.registeredChainCount,
            "Governor: Not enough registered chains"
        );
        Proposal storage proposal = $.proposals[proposalId];
        proposal.description = description;
        proposal.minChainTallies = minChainTallies;
        proposal.state = ProposalState.Active;
        emit ProposalCreated(proposalId, description, minChainTallies);
    }

    /**
     * @notice Record one voting chain's finalized tally, proven by a USC readability proof of the
     *         spoke's `ChainTallyFinalized` event. Verification runs synchronously: the shared
     *         proof verifier returns the proved source transaction bytes, which the hub decodes.
     *
     * @param chainKey        USC source-chain key of the voting chain the proof is for
     * @param blockHeight     Source-chain block number containing the finalize transaction
     * @param inclusionProof  BinaryMerkle inclusion proof envelope (from the CC3 prover API)
     * @param continuityProof Continuity proof envelope (from the CC3 prover API)
     */
    function submitChainTally(
        uint64 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) external {
        HubStorage storage $ = _getHubStorage();
        require($.trustedQuerySubmitters[msg.sender], "Governor: Untrusted submitter");

        VotingChainConfig memory chainConfig = $.votingChains[chainKey];
        require(chainConfig.registered, "Governor: Voting chain not registered");

        // Replay protection keyed by the proved source coordinates. The tx index is derived from
        // the inclusion proof, so the id is bound to a single source transaction and cannot be
        // reused. This matches the USC core's readability query id.
        uint64 txIndex = $.proofVerifier.calculateTxIndex(inclusionProof);
        bytes32 queryId = keccak256(abi.encodePacked(chainKey, blockHeight, txIndex));
        require(!$.usedQueryId[queryId], "Governor: Query ID already used");

        // Synchronously verify inclusion + continuity and recover the proved tx+receipt bytes.
        bytes memory encodedTransaction = $.proofVerifier.verifyProofs(
            bytes32(uint256(chainKey)),
            blockHeight,
            inclusionProof,
            continuityProof
        );

        require(
            EvmV1Decoder.isValidTransactionType(EvmV1Decoder.getTransactionType(encodedTransaction)),
            "Governor: Unsupported tx type"
        );
        EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder.decodeReceiptFields(
            encodedTransaction
        );
        require(receipt.receiptStatus == 1, "Governor: Source tx failed");

        (
            uint256 proposalId,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes
        ) = _readChainTally(receipt, chainConfig.spokeContract, chainKey);

        Proposal storage proposal = $.proposals[proposalId];
        require(proposal.state == ProposalState.Active, "Governor: Proposal not active");
        require(
            !$.chainTallies[proposalId][chainKey].recorded,
            "Governor: Chain already tallied"
        );

        $.usedQueryId[queryId] = true;
        $.chainTallies[proposalId][chainKey] = ChainTally({
            recorded: true,
            forVotes: forVotes,
            againstVotes: againstVotes,
            abstainVotes: abstainVotes
        });
        proposal.talliedChains += 1;
        proposal.forVotes += forVotes;
        proposal.againstVotes += againstVotes;
        proposal.abstainVotes += abstainVotes;

        emit ChainTallyRecorded(proposalId, chainKey, forVotes, againstVotes, abstainVotes, queryId);
    }

    /**
     * @notice Consolidate the crosschain result once enough chains have reported. The proposal
     *         succeeds when the aggregated for-votes strictly exceed the against-votes.
     */
    function finalizeProposal(uint256 proposalId) external {
        HubStorage storage $ = _getHubStorage();
        Proposal storage proposal = $.proposals[proposalId];
        require(proposal.state == ProposalState.Active, "Governor: Proposal not active");
        require(
            proposal.talliedChains >= proposal.minChainTallies,
            "Governor: Not enough chain tallies"
        );

        proposal.state = proposal.forVotes > proposal.againstVotes
            ? ProposalState.Succeeded
            : ProposalState.Defeated;

        emit ProposalConsolidated(
            proposalId,
            proposal.state,
            proposal.talliedChains,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes
        );
    }

    /**
     * @notice Extract the single `ChainTallyFinalized` tally from a proved receipt.
     * @dev The event must have been emitted by the spoke registered for `chainKey`. It carries no
     *      indexed arguments, so its only topic is the signature and all five values live in
     *      `data` as five 32-byte words. The chain key embedded in the event must also match the
     *      chain the proof is claimed for, so a spoke cannot report on behalf of another chain.
     */
    function _readChainTally(
        EvmV1Decoder.ReceiptFields memory receipt,
        address spokeContract,
        uint64 chainKey
    )
        private
        pure
        returns (uint256 proposalId, uint256 forVotes, uint256 againstVotes, uint256 abstainVotes)
    {
        bool found;
        for (uint256 i; i < receipt.receiptLogs.length; ++i) {
            EvmV1Decoder.LogEntry memory log = receipt.receiptLogs[i];
            if (
                log.address_ != spokeContract ||
                log.topics.length == 0 ||
                log.topics[0] != CHAIN_TALLY_FINALIZED_SELECTOR
            ) {
                continue;
            }
            require(log.topics.length == 1, "Governor: Invalid event topics");
            require(log.data.length == 160, "Governor: Invalid event data");
            require(!found, "Governor: Ambiguous tally event");

            uint64 eventChainKey;
            (proposalId, eventChainKey, forVotes, againstVotes, abstainVotes) = abi.decode(
                log.data,
                (uint256, uint64, uint256, uint256, uint256)
            );
            require(eventChainKey == chainKey, "Governor: Unexpected source chain");
            found = true;
        }
        require(found, "Governor: Tally event not found");
    }
}
