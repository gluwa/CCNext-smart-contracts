const assert = require("node:assert/strict");
const { ethers } = require("hardhat");
const { packTallyProof } = require("../scripts/buildGovernanceTallyProof");

// USC source-chain keys, not the chains' native EVM chain IDs.
const CHAIN_KEY = 1;
const CHAIN_KEY_2 = 2;
const CHAIN_KEY_3 = 3;
const UNREGISTERED_CHAIN_KEY = 4;

const coder = ethers.AbiCoder.defaultAbiCoder();
const CHAIN_TALLY_FINALIZED = ethers.id(
    "ChainTallyFinalized(uint256,uint64,uint256,uint256,uint256)",
);

// Distinct registered spoke addresses per voting chain.
const SPOKE = {
    [CHAIN_KEY]: ethers.getAddress("0x0000000000000000000000000000000000000A01"),
    [CHAIN_KEY_2]: ethers.getAddress("0x0000000000000000000000000000000000000A02"),
    [CHAIN_KEY_3]: ethers.getAddress("0x0000000000000000000000000000000000000A03"),
};

describe("CrossChainGovernorHub", function () {
    let owner;
    let trustedSubmitter;
    let attacker;
    let voter;
    let hub;
    let verifier;

    beforeEach(async function () {
        [owner, trustedSubmitter, attacker, voter] = await ethers.getSigners();

        verifier = await deployVerifier();
        hub = await deployHub(await verifier.getAddress());

        await hub.registerVotingChain(CHAIN_KEY, SPOKE[CHAIN_KEY]);
        await hub.registerVotingChain(CHAIN_KEY_2, SPOKE[CHAIN_KEY_2]);
        await hub.registerVotingChain(CHAIN_KEY_3, SPOKE[CHAIN_KEY_3]);
        await hub.setTrustedQuerySubmitter(trustedSubmitter.address, true);
        await hub.createProposal(1, "proposal", 3);
    });

    it("records a tally from a verified source-chain proof", async function () {
        const encodedTx = tallyTx(SPOKE[CHAIN_KEY], {
            forVotes: 10,
            againstVotes: 4,
            abstainVotes: 2,
        });
        await submitTally(CHAIN_KEY, 100, encodedTx);

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
        await submitTally(
            CHAIN_KEY,
            100,
            tallyTx(SPOKE[CHAIN_KEY], { chainKey: CHAIN_KEY, forVotes: 10, againstVotes: 4 }),
        );
        await submitTally(
            CHAIN_KEY_2,
            100,
            tallyTx(SPOKE[CHAIN_KEY_2], { chainKey: CHAIN_KEY_2, forVotes: 9, againstVotes: 3 }),
        );
        await submitTally(
            CHAIN_KEY_3,
            100,
            tallyTx(SPOKE[CHAIN_KEY_3], { chainKey: CHAIN_KEY_3, forVotes: 8, againstVotes: 5 }),
        );
        await hub.finalizeProposal(1);

        const proposal = await hub.getProposal(1);
        assert.equal(proposal.talliedChains, 3n);
        assert.equal(proposal.forVotes, 27n);
        assert.equal(proposal.againstVotes, 12n);
        assert.equal(proposal.state, 2n); // Succeeded
    });

    it("rejects proposals that require more chains than registered", async function () {
        const emptyHub = await deployHub(await verifier.getAddress());
        await emptyHub.registerVotingChain(CHAIN_KEY, SPOKE[CHAIN_KEY]);
        await emptyHub.registerVotingChain(CHAIN_KEY_2, SPOKE[CHAIN_KEY_2]);

        await assert.rejects(
            emptyHub.createProposal(1, "proposal", 3),
            /Not enough registered chains/,
        );
    });

    it("counts each USC source-chain key only once", async function () {
        const emptyHub = await deployHub(await verifier.getAddress());
        await emptyHub.registerVotingChain(CHAIN_KEY, SPOKE[CHAIN_KEY]);
        // Re-registering the same chain key updates the spoke without inflating the count.
        await emptyHub.registerVotingChain(CHAIN_KEY, SPOKE[CHAIN_KEY_2]);
        await emptyHub.registerVotingChain(CHAIN_KEY_2, SPOKE[CHAIN_KEY_2]);

        assert.equal(await emptyHub.registeredVotingChainCount(), 2n);
        await assert.rejects(
            emptyHub.createProposal(1, "proposal", 3),
            /Not enough registered chains/,
        );
    });

    it("validates configuration inputs", async function () {
        const Hub = await ethers.getContractFactory("CrossChainGovernorHub");
        await assert.rejects(Hub.deploy(ethers.ZeroAddress), /Invalid proof verifier/);

        const freshHub = await deployHub(await verifier.getAddress());
        await assert.rejects(
            freshHub.registerVotingChain(0, SPOKE[CHAIN_KEY]),
            /Invalid chain key/,
        );
        await assert.rejects(
            freshHub.registerVotingChain(CHAIN_KEY, ethers.ZeroAddress),
            /Invalid spoke contract/,
        );
        await assert.rejects(
            freshHub.setTrustedQuerySubmitter(ethers.ZeroAddress, true),
            /Invalid submitter/,
        );
        await assert.rejects(
            freshHub.setProofVerifier(ethers.ZeroAddress),
            /Invalid proof verifier/,
        );
    });

    it("rejects submissions from untrusted callers", async function () {
        await assert.rejects(
            submitTally(CHAIN_KEY, 100, tallyTx(SPOKE[CHAIN_KEY]), attacker),
            /Untrusted submitter/,
        );
    });

    it("rejects a replayed proof for the same source transaction", async function () {
        const encodedTx = tallyTx(SPOKE[CHAIN_KEY]);
        await submitTally(CHAIN_KEY, 100, encodedTx);

        // Same (chainKey, blockHeight, txIndex) => same query id.
        await assert.rejects(
            submitTally(CHAIN_KEY, 100, encodedTx),
            /Query ID already used/,
        );
    });

    it("rejects tallies for an unregistered voting chain", async function () {
        await assert.rejects(
            submitTally(
                UNREGISTERED_CHAIN_KEY,
                100,
                tallyTx(SPOKE[CHAIN_KEY], { chainKey: UNREGISTERED_CHAIN_KEY }),
            ),
            /Voting chain not registered/,
        );
    });

    it("rejects tallies whose event chain key differs from the proven chain", async function () {
        // Emitted by the chain-1 spoke but the event embeds chain key 2.
        const encodedTx = tallyTx(SPOKE[CHAIN_KEY], { chainKey: CHAIN_KEY_2 });
        await assert.rejects(
            submitTally(CHAIN_KEY, 100, encodedTx),
            /Unexpected source chain/,
        );
    });

    it("rejects tallies not emitted by the registered spoke", async function () {
        // Correct chain key in the event, but a different (unregistered-for-this-chain) emitter.
        const encodedTx = tallyTx(SPOKE[CHAIN_KEY_2], { chainKey: CHAIN_KEY });
        await assert.rejects(
            submitTally(CHAIN_KEY, 100, encodedTx),
            /Tally event not found/,
        );
    });

    it("rejects a failed proof verification", async function () {
        await verifier.setValid(false);
        await assert.rejects(
            submitTally(CHAIN_KEY, 100, tallyTx(SPOKE[CHAIN_KEY])),
            /MockProofInvalid/,
        );
    });

    it("rejects failed source transactions", async function () {
        const encodedTx = encodeType2ProofTx(0, [tallyLog(SPOKE[CHAIN_KEY], {})]);
        await assert.rejects(
            submitTally(CHAIN_KEY, 100, encodedTx),
            /Source tx failed/,
        );
    });

    it("rejects a receipt without the expected tally event", async function () {
        const encodedTx = encodeType2ProofTx(1, []);
        await assert.rejects(
            submitTally(CHAIN_KEY, 100, encodedTx),
            /Tally event not found/,
        );
    });

    it("rejects tallies for a non-active proposal", async function () {
        const encodedTx = tallyTx(SPOKE[CHAIN_KEY], { proposalId: 999 });
        await assert.rejects(
            submitTally(CHAIN_KEY, 100, encodedTx),
            /Proposal not active/,
        );
    });

    it("rejects a second tally from a chain that already reported", async function () {
        await submitTally(CHAIN_KEY, 100, tallyTx(SPOKE[CHAIN_KEY]));

        // A different source transaction (new block height => new query id) still cannot
        // double-count a chain that already reported.
        await assert.rejects(
            submitTally(CHAIN_KEY, 101, tallyTx(SPOKE[CHAIN_KEY])),
            /Chain already tallied/,
        );
    });

    it("records a real spoke's finalized tally end-to-end via packTallyProof", async function () {
        const Token = await ethers.getContractFactory("ERC20Mintable");
        const token = await Token.deploy("Stake Token", "STK");
        await token.mint(voter.address, 1000);

        const Voting = await ethers.getContractFactory("StakedGovernanceVoting");
        const spoke = await Voting.deploy(await token.getAddress(), CHAIN_KEY);
        const spokeAddress = await spoke.getAddress();
        await token.connect(voter).approve(spokeAddress, 1000);

        // Point chain 1 at the real spoke deployed above.
        await hub.registerVotingChain(CHAIN_KEY, spokeAddress);

        // Stake, vote For, and finalize the local tally on the spoke.
        await spoke.connect(voter).stake(100);
        const now = (await ethers.provider.getBlock("latest")).timestamp;
        const start = now + 10;
        const end = start + 100;
        await spoke.openProposal(1, start, end);
        await ethers.provider.send("evm_setNextBlockTimestamp", [start]);
        await spoke.connect(voter).castVote(1, 1);
        await ethers.provider.send("evm_setNextBlockTimestamp", [end]);
        const finalizeReceipt = await (await spoke.finalizeChainTally(1)).wait();

        // Take the real ChainTallyFinalized log and encode it into a prover-style transaction.
        const tallyLogEntry = finalizeReceipt.logs.find(
            (log) =>
                log.address.toLowerCase() === spokeAddress.toLowerCase() &&
                log.topics[0] === CHAIN_TALLY_FINALIZED,
        );
        assert.ok(tallyLogEntry, "expected a ChainTallyFinalized log");
        const encodedTx = encodeType2ProofTx(1, [
            [tallyLogEntry.address, [...tallyLogEntry.topics], tallyLogEntry.data],
        ]);

        // Build the proof payload with the same packing helper the CLI script uses, from a
        // synthetic prover response wrapping the real transaction bytes.
        const packed = packTallyProof({
            chainKey: CHAIN_KEY,
            headerNumber: finalizeReceipt.blockNumber,
            txIndex: finalizeReceipt.index,
            txHash: finalizeReceipt.hash,
            txBytes: encodedTx,
            merkleProof: { root: ethers.keccak256(encodedTx), siblings: [] },
            continuityProof: { lowerEndpointDigest: ethers.ZeroHash, roots: [] },
        });

        await hub
            .connect(trustedSubmitter)
            .submitChainTally(
                packed.chainKey,
                packed.blockHeight,
                packed.inclusionProof,
                packed.continuityProof,
            );

        const tally = await hub.getChainTally(1, CHAIN_KEY);
        assert.equal(tally.recorded, true);
        assert.equal(tally.forVotes, 100n);
        assert.equal(tally.againstVotes, 0n);
        assert.equal(tally.abstainVotes, 0n);
    });

    // ---- helpers ----

    async function submitTally(chainKey, blockHeight, encodedTx, submitter = trustedSubmitter) {
        const { inclusionProof, continuityProof } = proofFor(encodedTx);
        return hub
            .connect(submitter)
            .submitChainTally(chainKey, blockHeight, inclusionProof, continuityProof);
    }
});

async function deployVerifier() {
    const Verifier = await ethers.getContractFactory("MockUSCProofVerifier");
    const verifier = await Verifier.deploy();
    await verifier.waitForDeployment();
    return verifier;
}

async function deployHub(verifierAddress) {
    const Hub = await ethers.getContractFactory("CrossChainGovernorHub");
    const hub = await Hub.deploy(verifierAddress);
    await hub.waitForDeployment();
    return hub;
}

/** A single ChainTallyFinalized log tuple: [emitter, topics, data]. */
function tallyLog(
    spoke,
    {
        proposalId = 1,
        chainKey = CHAIN_KEY,
        forVotes = 10,
        againstVotes = 4,
        abstainVotes = 2,
    } = {},
) {
    const data = coder.encode(
        ["uint256", "uint64", "uint256", "uint256", "uint256"],
        [proposalId, chainKey, forVotes, againstVotes, abstainVotes],
    );
    return [spoke, [CHAIN_TALLY_FINALIZED], data];
}

/** A prover-style type-2 transaction carrying exactly one ChainTallyFinalized log. */
function tallyTx(spoke, overrides = {}) {
    return encodeType2ProofTx(1, [tallyLog(spoke, overrides)]);
}

/**
 * Encode an EVM type-2 transaction+receipt in the EvmV1Decoder format:
 * abi.encode(uint8 txType, bytes[] chunks) with chunks = [common, typeSpecific, receipt].
 */
function encodeType2ProofTx(receiptStatus, logs) {
    const common = coder.encode(
        ["uint64", "uint64", "address", "bool", "address", "uint256", "bytes"],
        [
            1n,
            500_000n,
            ethers.getAddress("0x1000000000000000000000000000000000000001"),
            false,
            ethers.getAddress("0x2000000000000000000000000000000000000002"),
            0n,
            "0x",
        ],
    );
    const type2 = coder.encode(
        [
            "uint64",
            "uint128",
            "uint128",
            "tuple(address,bytes32[])[]",
            "uint8",
            "bytes32",
            "bytes32",
        ],
        [1n, 1n, 1n, [], 0, ethers.ZeroHash, ethers.ZeroHash],
    );
    const receipt = coder.encode(
        ["uint8", "uint64", "tuple(address,bytes32[],bytes)[]", "bytes"],
        [receiptStatus, 100_000n, logs, "0x"],
    );
    return coder.encode(["uint8", "bytes[]"], [2, [common, type2, receipt]]);
}

/** Wrap encoded tx bytes in a BinaryMerkle inclusion proof envelope (no siblings => index 0). */
function proofFor(encodedTx) {
    const data = coder.encode(
        ["bytes", "tuple(bytes32 sibling,bool isLeft)[]"],
        [encodedTx, []],
    );
    return {
        inclusionProof: { kind: 0, root: ethers.keccak256(encodedTx), data },
        continuityProof: { lowerEndpointDigest: ethers.ZeroHash, roots: [] },
    };
}
