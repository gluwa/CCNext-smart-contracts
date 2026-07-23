const assert = require("node:assert/strict");
const { ethers } = require("hardhat");

const CHAIN_KEY = 1;
const CHAIN_TALLY_FINALIZED = ethers.id(
    "ChainTallyFinalized(uint256,uint64,uint256,uint256,uint256)",
);

describe("StakedGovernanceVoting", function () {
    let voter;
    let token;
    let voting;

    beforeEach(async function () {
        [, voter] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("ERC20Mintable");
        token = await Token.deploy("Stake Token", "STK");
        await token.waitForDeployment();
        await token.mint(voter.address, 1000);

        const Voting = await ethers.getContractFactory("StakedGovernanceVoting");
        voting = await Voting.deploy(await token.getAddress(), CHAIN_KEY);
        await voting.waitForDeployment();

        await token.connect(voter).approve(await voting.getAddress(), 1000);
    });

    it("uses the shared voting window and unlocks stake when the window ends", async function () {
        await voting.connect(voter).stake(100);
        const { start, end } = await openFutureProposal(1);

        await assert.rejects(voting.connect(voter).castVote(1, 1), /Voting is closed/);

        await setNextBlockTimestamp(start);
        await voting.connect(voter).castVote(1, 1);

        const proposalAfterVote = await voting.getProposal(1);
        assert.equal(proposalAfterVote.forVotes, 100n);
        assert.equal(await voting.voteLockedUntil(voter.address), BigInt(end));

        await assert.rejects(
            voting.connect(voter).unstake(100),
            /Stake locked until voting ends/,
        );

        await setNextBlockTimestamp(end);
        await voting.connect(voter).unstake(100);
        assert.equal(await voting.stakedBalanceOf(voter.address), 0n);
    });

    it("rejects already-ended voting windows", async function () {
        const now = await latestTimestamp();

        await assert.rejects(
            voting.openProposal(1, now - 100, now),
            /Voting window already ended/,
        );
    });

    it("prevents double voting and finalizes the local tally after the window closes", async function () {
        await voting.connect(voter).stake(100);
        const { start, end } = await openFutureProposal(1);

        await setNextBlockTimestamp(start);
        await voting.connect(voter).castVote(1, 0);

        await assert.rejects(voting.connect(voter).castVote(1, 1), /Already voted/);

        await setNextBlockTimestamp(end);
        const finalizeTransaction = await voting.finalizeChainTally(1);
        const finalizeReceipt = await finalizeTransaction.wait();

        const proposal = await voting.getProposal(1);
        assert.equal(proposal.againstVotes, 100n);
        assert.equal(proposal.tallyFinalized, true);

        // The finalize transaction emits a single ChainTallyFinalized event carrying the whole
        // per-chain tally. This is the event a USC readability proof surfaces to the hub.
        const tallyEvent = finalizeReceipt.logs
            .map((log) => {
                try {
                    return voting.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find((parsed) => parsed && parsed.name === "ChainTallyFinalized");

        assert.ok(tallyEvent, "expected a ChainTallyFinalized event");
        assert.equal(tallyEvent.topic, CHAIN_TALLY_FINALIZED);
        assert.equal(tallyEvent.args.proposalId, 1n);
        assert.equal(tallyEvent.args.chainKey, BigInt(CHAIN_KEY));
        assert.equal(tallyEvent.args.forVotes, 0n);
        assert.equal(tallyEvent.args.againstVotes, 100n);
        assert.equal(tallyEvent.args.abstainVotes, 0n);

        await assert.rejects(voting.finalizeChainTally(1), /Tally already finalized/);
    });

    it("rejects a zero USC source-chain key", async function () {
        const Voting = await ethers.getContractFactory("StakedGovernanceVoting");

        await assert.rejects(
            Voting.deploy(await token.getAddress(), 0),
            /Invalid chain key/,
        );
    });

    async function openFutureProposal(proposalId) {
        const now = await latestTimestamp();
        const start = now + 10;
        const end = start + 100;
        await voting.openProposal(proposalId, start, end);
        return { start, end };
    }
});

async function latestTimestamp() {
    return (await ethers.provider.getBlock("latest")).timestamp;
}

async function setNextBlockTimestamp(timestamp) {
    await ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
}
