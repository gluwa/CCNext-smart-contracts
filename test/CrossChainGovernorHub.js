const assert = require("node:assert/strict");
const { ethers } = require("hardhat");

// USC source-chain keys, not the chains' native EVM chain IDs.
const CHAIN_KEY = 1;
const CHAIN_KEY_2 = 2;
const CHAIN_KEY_3 = 3;
const RESULT_AVAILABLE = 2;
const SUBMITTED = 1;

describe("CrossChainGovernorHub", function () {
    let owner;
    let trustedSubmitter;
    let attacker;
    let hub;
    let prover;
    let prover2;
    let prover3;
    let fakeProver;
    let spokeContract;

    beforeEach(async function () {
        [owner, trustedSubmitter, attacker] = await ethers.getSigners();
        spokeContract = owner.address;

        const Hub = await ethers.getContractFactory("CrossChainGovernorHub");
        hub = await Hub.deploy();
        await hub.waitForDeployment();

        const MockProver = await ethers.getContractFactory("MockCreditcoinPublicProver");
        prover = await MockProver.deploy();
        await prover.waitForDeployment();
        prover2 = await MockProver.deploy();
        await prover2.waitForDeployment();
        prover3 = await MockProver.deploy();
        await prover3.waitForDeployment();
        fakeProver = await MockProver.deploy();
        await fakeProver.waitForDeployment();

        await registerVotingChain(CHAIN_KEY, hub, prover);
        await registerVotingChain(CHAIN_KEY_2, hub, prover2);
        await registerVotingChain(CHAIN_KEY_3, hub, prover3);
        await hub.setTrustedQuerySubmitter(trustedSubmitter.address, true);
        await hub.createProposal(1, "proposal", 3);
    });

    it("records a tally from the registered prover and source chain", async function () {
        const queryId = id("valid-tally");
        await setTallyQuery(prover, queryId);

        await hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId);

        const proposal = await hub.getProposal(1);
        assert.equal(proposal.talliedChains, 1n);
        assert.equal(proposal.forVotes, 10n);
        assert.equal(proposal.againstVotes, 4n);
        assert.equal(proposal.abstainVotes, 2n);

        const tally = await hub.getChainTally(1, CHAIN_KEY);
        assert.equal(tally.recorded, true);
        assert.equal(tally.forVotes, 10n);
    });

    it("consolidates a result after three registered chains report", async function () {
        const queryId1 = id("chain-1");
        const queryId2 = id("chain-2");
        const queryId3 = id("chain-3");
        await setTallyQuery(prover, queryId1, { forVotes: 10, againstVotes: 4 });
        await setTallyQuery(prover2, queryId2, {
            eventChainKey: CHAIN_KEY_2,
            forVotes: 9,
            againstVotes: 3,
        });
        await setTallyQuery(prover3, queryId3, {
            eventChainKey: CHAIN_KEY_3,
            forVotes: 8,
            againstVotes: 5,
        });

        await hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId1);
        await hub.connect(trustedSubmitter).submitChainTally(await prover2.getAddress(), queryId2);
        await hub.connect(trustedSubmitter).submitChainTally(await prover3.getAddress(), queryId3);
        await hub.finalizeProposal(1);

        const proposal = await hub.getProposal(1);
        assert.equal(proposal.talliedChains, 3n);
        assert.equal(proposal.forVotes, 27n);
        assert.equal(proposal.againstVotes, 12n);
        assert.equal(proposal.state, 2n);
    });

    it("rejects proposals that require more chains than registered", async function () {
        const Hub = await ethers.getContractFactory("CrossChainGovernorHub");
        const emptyHub = await Hub.deploy();
        await emptyHub.waitForDeployment();

        await registerVotingChain(CHAIN_KEY, emptyHub, prover);
        await registerVotingChain(CHAIN_KEY_2, emptyHub, prover2);

        await assert.rejects(
            emptyHub.createProposal(1, "proposal", 3),
            /Not enough registered chains/,
        );
    });

    it("counts each USC source-chain key only once", async function () {
        const Hub = await ethers.getContractFactory("CrossChainGovernorHub");
        const emptyHub = await Hub.deploy();
        await emptyHub.waitForDeployment();

        await registerVotingChain(CHAIN_KEY, emptyHub, prover);
        await registerVotingChain(CHAIN_KEY, emptyHub, fakeProver);
        await registerVotingChain(CHAIN_KEY_2, emptyHub, prover2);

        assert.equal(await emptyHub.registeredVotingChainCount(), 2n);
        await assert.rejects(
            emptyHub.createProposal(1, "proposal", 3),
            /Not enough registered chains/,
        );
    });

    it("validates voting chain and submitter configuration", async function () {
        const Hub = await ethers.getContractFactory("CrossChainGovernorHub");
        const emptyHub = await Hub.deploy();
        await emptyHub.waitForDeployment();

        await assert.rejects(
            emptyHub.registerVotingChain(
                0,
                spokeContract,
                await prover.getAddress(),
            ),
            /Invalid chain key/,
        );
        await assert.rejects(
            emptyHub.registerVotingChain(
                CHAIN_KEY,
                ethers.ZeroAddress,
                await prover.getAddress(),
            ),
            /Invalid spoke contract/,
        );
        await assert.rejects(
            emptyHub.registerVotingChain(CHAIN_KEY, spokeContract, ethers.ZeroAddress),
            /Invalid prover contract/,
        );
        await assert.rejects(
            emptyHub.setTrustedQuerySubmitter(ethers.ZeroAddress, true),
            /Invalid submitter/,
        );
    });

    it("rejects a spoofed principal when the caller is not trusted", async function () {
        const queryId = id("spoofed-principal");
        await setTallyQuery(prover, queryId, { principal: trustedSubmitter.address });

        await assert.rejects(
            hub.connect(attacker).submitChainTally(await prover.getAddress(), queryId),
            /Untrusted submitter/,
        );
    });

    it("accepts the intended query when its principal was front-run", async function () {
        const queryId = id("front-run-principal");
        await setTallyQuery(prover, queryId, { principal: attacker.address });

        await hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId);

        assert.equal((await hub.getChainTally(1, CHAIN_KEY)).recorded, true);
    });

    it("rejects tallies from an unregistered prover contract", async function () {
        const queryId = id("fake-prover");
        await setTallyQuery(fakeProver, queryId);

        await assert.rejects(
            hub.connect(trustedSubmitter).submitChainTally(await fakeProver.getAddress(), queryId),
            /Unexpected prover/,
        );
    });

    it("rejects tallies proven for a different source chain", async function () {
        const queryId = id("wrong-source-chain");
        await setTallyQuery(prover, queryId, { sourceChainKey: CHAIN_KEY + 1 });

        await assert.rejects(
            hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId),
            /Unexpected source chain/,
        );
    });

    it("rejects queries without an available verified result", async function () {
        const queryId = id("not-ready");
        await setTallyQuery(prover, queryId, { state: SUBMITTED });

        await assert.rejects(
            hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId),
            /Query result unavailable/,
        );
    });

    it("rejects failed source transactions", async function () {
        const queryId = id("failed-source-tx");
        await setTallyQuery(prover, queryId);
        await prover.setReceiptStatus(queryId, 0);

        await assert.rejects(
            hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId),
            /Source tx failed/,
        );
    });

    it("rejects malformed query layouts", async function () {
        const queryId = id("bad-layout");
        await setTallyQuery(prover, queryId);
        // A segment that does not read a full 32-byte word is rejected
        await prover.setLayoutSegment(queryId, 4, 128, 16);

        await assert.rejects(
            hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId),
            /Invalid query layout/,
        );
    });

    async function setTallyQuery(targetProver, queryId, overrides = {}) {
        await targetProver.setTallyQuery(
            queryId,
            overrides.state ?? RESULT_AVAILABLE,
            overrides.sourceChainKey ?? overrides.eventChainKey ?? CHAIN_KEY,
            overrides.principal ?? trustedSubmitter.address,
            overrides.emitter ?? spokeContract,
            await hub.CHAIN_TALLY_FINALIZED_SELECTOR(),
            overrides.proposalId ?? 1,
            overrides.eventChainKey ?? CHAIN_KEY,
            overrides.forVotes ?? 10,
            overrides.againstVotes ?? 4,
            overrides.abstainVotes ?? 2,
        );
    }

    async function registerVotingChain(chainKey, targetHub = hub, targetProver = prover) {
        await targetHub.registerVotingChain(
            chainKey,
            spokeContract,
            await targetProver.getAddress(),
        );
    }
});

function id(label) {
    return ethers.keccak256(ethers.toUtf8Bytes(label));
}
