const assert = require("node:assert/strict");
const { ethers } = require("hardhat");

const CHAIN_KEY = 100;
const SOURCE_CHAIN_ID = 11155111;
const CHAIN_KEY_2 = 101;
const SOURCE_CHAIN_ID_2 = 84532;
const CHAIN_KEY_3 = 102;
const SOURCE_CHAIN_ID_3 = 97;
const RESULT_AVAILABLE = 2;
const SUBMITTED = 1;

describe("CrossChainGovernorHub", function () {
    let owner;
    let trustedSubmitter;
    let otherTrustedSubmitter;
    let attacker;
    let hub;
    let prover;
    let fakeProver;
    let spokeContract;

    beforeEach(async function () {
        [owner, trustedSubmitter, otherTrustedSubmitter, attacker] = await ethers.getSigners();
        spokeContract = owner.address;

        const Hub = await ethers.getContractFactory("CrossChainGovernorHub");
        hub = await Hub.deploy();
        await hub.waitForDeployment();

        const MockProver = await ethers.getContractFactory("MockCreditcoinPublicProver");
        prover = await MockProver.deploy();
        await prover.waitForDeployment();
        fakeProver = await MockProver.deploy();
        await fakeProver.waitForDeployment();

        await registerVotingChain(CHAIN_KEY, SOURCE_CHAIN_ID);
        await registerVotingChain(CHAIN_KEY_2, SOURCE_CHAIN_ID_2);
        await registerVotingChain(CHAIN_KEY_3, SOURCE_CHAIN_ID_3);
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
        await setTallyQuery(prover, queryId2, {
            sourceChainId: SOURCE_CHAIN_ID_2,
            eventChainKey: CHAIN_KEY_2,
            forVotes: 9,
            againstVotes: 3,
        });
        await setTallyQuery(prover, queryId3, {
            sourceChainId: SOURCE_CHAIN_ID_3,
            eventChainKey: CHAIN_KEY_3,
            forVotes: 8,
            againstVotes: 5,
        });

        await hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId1);
        await hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId2);
        await hub.connect(trustedSubmitter).submitChainTally(await prover.getAddress(), queryId3);
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

        await registerVotingChain(CHAIN_KEY, SOURCE_CHAIN_ID, emptyHub);
        await registerVotingChain(CHAIN_KEY_2, SOURCE_CHAIN_ID_2, emptyHub);

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
                SOURCE_CHAIN_ID,
                spokeContract,
                await prover.getAddress(),
            ),
            /Invalid chain key/,
        );
        await assert.rejects(
            emptyHub.registerVotingChain(
                CHAIN_KEY,
                0,
                spokeContract,
                await prover.getAddress(),
            ),
            /Invalid source chain/,
        );
        await assert.rejects(
            emptyHub.registerVotingChain(
                CHAIN_KEY,
                SOURCE_CHAIN_ID,
                ethers.ZeroAddress,
                await prover.getAddress(),
            ),
            /Invalid spoke contract/,
        );
        await assert.rejects(
            emptyHub.registerVotingChain(CHAIN_KEY, SOURCE_CHAIN_ID, spokeContract, ethers.ZeroAddress),
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

    it("requires the trusted caller to match the query principal", async function () {
        const queryId = id("principal-mismatch");
        await hub.setTrustedQuerySubmitter(otherTrustedSubmitter.address, true);
        await setTallyQuery(prover, queryId, { principal: trustedSubmitter.address });

        await assert.rejects(
            hub.connect(otherTrustedSubmitter).submitChainTally(await prover.getAddress(), queryId),
            /Query principal mismatch/,
        );
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
        await setTallyQuery(prover, queryId, { sourceChainId: SOURCE_CHAIN_ID + 1 });

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
            overrides.sourceChainId ?? SOURCE_CHAIN_ID,
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

    async function registerVotingChain(chainKey, sourceChainId, targetHub = hub) {
        await targetHub.registerVotingChain(
            chainKey,
            sourceChainId,
            spokeContract,
            await prover.getAddress(),
        );
    }
});

function id(label) {
    return ethers.keccak256(ethers.toUtf8Bytes(label));
}
