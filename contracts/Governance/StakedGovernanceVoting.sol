// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StakedGovernanceVoting
 * @notice Spoke contract of the crosschain governance example. Deployed on each voting chain
 *         (at least 3, e.g. Ethereum, Base, BNB Chain). Users stake an ERC20 token for voting
 *         weight and cast GovernorBravo-style votes on proposals mirrored from the hub.
 *
 *         Once a proposal's voting window closes, anyone can finalize the local tally, which
 *         emits a single `ChainTallyFinalized` event. That event is read by the USC prover
 *         (readability) and consolidated on Creditcoin USC by `CrossChainGovernorHub`, so the
 *         crosschain cost of a proposal is one readability query per chain, regardless of how
 *         many votes were cast.
 */
contract StakedGovernanceVoting is Ownable {
    // GovernorBravo vote semantics
    enum VoteSupport {
        /*0*/
        Against,
        /*1*/
        For,
        /*2*/
        Abstain
    }

    struct Proposal {
        uint256 votingStart;
        uint256 votingEnd;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool tallyFinalized;
    }

    event Staked(address indexed staker, uint256 amount, uint256 totalStaked);
    event Unstaked(address indexed staker, uint256 amount, uint256 totalStaked);
    event ProposalOpened(uint256 indexed proposalId, uint256 votingStart, uint256 votingEnd);
    /// @dev GovernorBravo-style vote event, emitted per vote so individual votes are also
    ///      provable through USC readability if per-vote relaying is ever needed.
    event VoteCast(address indexed voter, uint256 proposalId, uint8 support, uint256 votes);
    /// @notice The event proven by the USC prover and consolidated on the hub chain.
    event ChainTallyFinalized(
        uint256 proposalId,
        uint64 chainKey,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes
    );

    // keccak256(abi.encode(uint256(keccak256("stakedGovernanceVoting.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0x5ca8436aeefba7c5bba704cf6e40b7c8d950ec07a759dab343654f607ae8c500;

    struct VotingStorage {
        mapping(address => uint256) stakedBalance;
        // stake stays locked until the latest votingEnd among proposals the user voted on,
        // so voting weight cannot be reused across chains within the same voting window
        mapping(address => uint256) voteLockedUntil;
        mapping(uint256 => Proposal) proposals;
        mapping(uint256 => mapping(address => bool)) hasVoted;
    }

    IERC20 public immutable stakeToken;
    /// @notice Chain key identifying this chain inside the USC protocol, embedded in the
    ///         finalized tally event so the hub can attribute the result.
    uint64 public immutable chainKey;

    constructor(address stakeToken_, uint64 chainKey_) Ownable(msg.sender) {
        require(stakeToken_ != address(0), "Voting: Invalid stake token");
        stakeToken = IERC20(stakeToken_);
        chainKey = chainKey_;
    }

    function _getVotingStorage() private pure returns (VotingStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    function stakedBalanceOf(address staker) external view returns (uint256) {
        return _getVotingStorage().stakedBalance[staker];
    }

    function voteLockedUntil(address staker) external view returns (uint256) {
        return _getVotingStorage().voteLockedUntil[staker];
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _getVotingStorage().proposals[proposalId];
    }

    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return _getVotingStorage().hasVoted[proposalId][voter];
    }

    /// @notice Stake tokens to gain voting weight on this chain
    function stake(uint256 amount) external {
        require(amount > 0, "Voting: Amount must be greater than 0");
        VotingStorage storage $ = _getVotingStorage();
        require(
            stakeToken.transferFrom(msg.sender, address(this), amount),
            "Voting: Transfer failed"
        );
        $.stakedBalance[msg.sender] += amount;
        emit Staked(msg.sender, amount, $.stakedBalance[msg.sender]);
    }

    /// @notice Withdraw staked tokens once no voting window the staker voted in is still open
    function unstake(uint256 amount) external {
        VotingStorage storage $ = _getVotingStorage();
        require(amount > 0, "Voting: Amount must be greater than 0");
        require($.stakedBalance[msg.sender] >= amount, "Voting: Insufficient staked balance");
        require(
            block.timestamp > $.voteLockedUntil[msg.sender],
            "Voting: Stake locked until voting ends"
        );
        $.stakedBalance[msg.sender] -= amount;
        require(stakeToken.transfer(msg.sender, amount), "Voting: Transfer failed");
        emit Unstaked(msg.sender, amount, $.stakedBalance[msg.sender]);
    }

    /**
     * @notice Mirror a hub proposal on this chain, opening its local voting window.
     * @param proposalId Proposal id created on the hub (`CrossChainGovernorHub`)
     * @param votingPeriod Duration of the voting window in seconds
     */
    function openProposal(uint256 proposalId, uint256 votingPeriod) external onlyOwner {
        VotingStorage storage $ = _getVotingStorage();
        require($.proposals[proposalId].votingEnd == 0, "Voting: Proposal already exists");
        require(votingPeriod > 0, "Voting: Invalid voting period");
        uint256 votingStart = block.timestamp;
        uint256 votingEnd = votingStart + votingPeriod;
        $.proposals[proposalId] = Proposal({
            votingStart: votingStart,
            votingEnd: votingEnd,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            tallyFinalized: false
        });
        emit ProposalOpened(proposalId, votingStart, votingEnd);
    }

    /**
     * @notice Cast a vote with weight equal to the sender's current staked balance
     * @param support GovernorBravo semantics: 0 = Against, 1 = For, 2 = Abstain
     */
    function castVote(uint256 proposalId, uint8 support) external {
        require(support <= uint8(VoteSupport.Abstain), "Voting: Invalid support value");
        VotingStorage storage $ = _getVotingStorage();
        Proposal storage proposal = $.proposals[proposalId];
        require(proposal.votingEnd != 0, "Voting: Proposal does not exist");
        require(
            block.timestamp >= proposal.votingStart && block.timestamp < proposal.votingEnd,
            "Voting: Voting is closed"
        );
        require(!$.hasVoted[proposalId][msg.sender], "Voting: Already voted");
        uint256 weight = $.stakedBalance[msg.sender];
        require(weight > 0, "Voting: No staked balance");

        $.hasVoted[proposalId][msg.sender] = true;
        if (proposal.votingEnd > $.voteLockedUntil[msg.sender]) {
            $.voteLockedUntil[msg.sender] = proposal.votingEnd;
        }

        if (support == uint8(VoteSupport.For)) {
            proposal.forVotes += weight;
        } else if (support == uint8(VoteSupport.Against)) {
            proposal.againstVotes += weight;
        } else {
            proposal.abstainVotes += weight;
        }
        emit VoteCast(msg.sender, proposalId, support, weight);
    }

    /**
     * @notice Finalize this chain's tally once the voting window has closed. Emits the
     *         `ChainTallyFinalized` event which is proven through a USC readability query and
     *         submitted to `CrossChainGovernorHub.submitChainTally` on Creditcoin USC.
     */
    function finalizeChainTally(uint256 proposalId) external {
        VotingStorage storage $ = _getVotingStorage();
        Proposal storage proposal = $.proposals[proposalId];
        require(proposal.votingEnd != 0, "Voting: Proposal does not exist");
        require(block.timestamp >= proposal.votingEnd, "Voting: Voting still open");
        require(!proposal.tallyFinalized, "Voting: Tally already finalized");
        proposal.tallyFinalized = true;
        emit ChainTallyFinalized(
            proposalId,
            chainKey,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes
        );
    }
}
