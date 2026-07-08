// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@gluwa/creditcoin-public-prover/contracts/sol/Types.sol";
import {ICreditcoinPublicProver} from "@gluwa/creditcoin-public-prover/contracts/sol/Prover.sol";

/**
 * @title CrossChainGovernorHub
 * @notice Hub contract of the crosschain governance example, deployed on Creditcoin USC (the
 *         consolidation chain). Each voting chain runs a `StakedGovernanceVoting` spoke where
 *         users stake and vote locally; after a proposal's voting window closes the spoke emits
 *         a `ChainTallyFinalized` event. This hub verifies a USC readability query proving that
 *         event for each chain and, once at least `minChainTallies` chains (3 or more) have
 *         reported, consolidates all per-chain tallies into the final crosschain result.
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

    struct HubStorage {
        // chainKey => StakedGovernanceVoting spoke contract on that chain
        mapping(uint64 => address) votingChains;
        // accounts allowed to be the principal of accepted readability queries
        mapping(address => bool) trustedQuerySubmitters;
        mapping(uint256 => Proposal) proposals;
        // proposalId => chainKey => recorded tally
        mapping(uint256 => mapping(uint64 => ChainTally)) chainTallies;
        mapping(address => mapping(bytes32 => bool)) usedQueryId;
    }

    constructor() Ownable(msg.sender) {}

    function _getHubStorage() private pure returns (HubStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    function votingChain(uint64 chainKey) external view returns (address) {
        return _getHubStorage().votingChains[chainKey];
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

    function isQueryUsed(address proverContract, bytes32 queryId) external view returns (bool) {
        return _getHubStorage().usedQueryId[proverContract][queryId];
    }

    /// @notice Register (or update) the trusted spoke contract for a voting chain
    function registerVotingChain(uint64 chainKey, address spokeContract) external onlyOwner {
        require(spokeContract != address(0), "Governor: Invalid spoke contract");
        _getHubStorage().votingChains[chainKey] = spokeContract;
        emit VotingChainRegistered(chainKey, spokeContract);
    }

    /// @notice Allow or disallow an account as principal of accepted readability queries
    function setTrustedQuerySubmitter(address submitter, bool trusted) external onlyOwner {
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
        Proposal storage proposal = $.proposals[proposalId];
        proposal.description = description;
        proposal.minChainTallies = minChainTallies;
        proposal.state = ProposalState.Active;
        emit ProposalCreated(proposalId, description, minChainTallies);
    }

    /**
     * @notice Record one voting chain's finalized tally, proven by a USC readability query of the
     *         spoke's `ChainTallyFinalized` event.
     *
     *         Expected result segment layout:
     *         0: Rx - Status
     *         1: Tx - From
     *         2: Tx - To
     *         3: Event - Addr (spoke contract emitting the event)
     *         4: Event - Signature (ChainTallyFinalized selector)
     *         5: Event - proposalId
     *         6: Event - chainKey
     *         7: Event - forVotes
     *         8: Event - againstVotes
     *         9: Event - abstainVotes
     */
    function submitChainTally(address proverContract, bytes32 queryId) external {
        HubStorage storage $ = _getHubStorage();
        require(!$.usedQueryId[proverContract][queryId], "Governor: Query ID already used");

        QueryDetails memory queryDetails = ICreditcoinPublicProver(proverContract).getQueryDetails(
            queryId
        );

        // We only accept queries submitted using trusted keys, such as from our own query
        // builder worker. Otherwise there is no guarantee that the result segments provided
        // actually pertain to our protocol. They could be constructed by bad actors to look
        // like a finalized tally, when in fact they come from some completely unrelated
        // finalized transaction on the source chain.
        require(
            $.trustedQuerySubmitters[queryDetails.principal],
            "Governor: Untrusted query submitter"
        );

        ResultSegment[] memory resultSegments = queryDetails.resultSegments;
        require(resultSegments.length >= 10, "Governor: Invalid result length");
        require(
            bytes32(resultSegments[4].abiBytes) == CHAIN_TALLY_FINALIZED_SELECTOR,
            "Governor: Invalid event signature"
        );

        address emitter = address(uint160(uint256(bytes32(resultSegments[3].abiBytes))));
        uint256 proposalId = uint256(bytes32(resultSegments[5].abiBytes));
        uint64 chainKey = uint64(uint256(bytes32(resultSegments[6].abiBytes)));
        uint256 forVotes = uint256(bytes32(resultSegments[7].abiBytes));
        uint256 againstVotes = uint256(bytes32(resultSegments[8].abiBytes));
        uint256 abstainVotes = uint256(bytes32(resultSegments[9].abiBytes));

        // The tally must have been emitted by the registered spoke contract for the chain key
        // it claims, so one chain's result cannot impersonate another's
        address registeredSpoke = $.votingChains[chainKey];
        require(
            registeredSpoke != address(0) && emitter == registeredSpoke,
            "Governor: Event not from registered spoke"
        );

        Proposal storage proposal = $.proposals[proposalId];
        require(proposal.state == ProposalState.Active, "Governor: Proposal not active");
        require(
            !$.chainTallies[proposalId][chainKey].recorded,
            "Governor: Chain already tallied"
        );

        $.usedQueryId[proverContract][queryId] = true;
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
}
