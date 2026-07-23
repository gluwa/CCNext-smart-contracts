const { ethers } = require("ethers");
const { proofGenerator } = require("@gluwa/usc-sdk");

// BlockProverTypes.ProofKind.BinaryMerkle
const PROOF_KIND_BINARY_MERKLE = 0;
// BlockProverTypes.InclusionProof.data layout: abi.encode(bytes txBytes, MerkleProofEntry[] siblings)
const MERKLE_SIBLING_TYPE = "tuple(bytes32 sibling,bool isLeft)";

/**
 * Pack a CC3 prover-API proof response into the `(inclusionProof, continuityProof)` tuples that
 * `CrossChainGovernorHub.submitChainTally` expects.
 *
 * `proofData` is the `data` field of a `@gluwa/usc-sdk` `ProofGenerationResult`, i.e.:
 *   { chainKey, headerNumber, txIndex, txHash, txBytes,
 *     merkleProof: { root, siblings: [{ hash, isLeft }] },
 *     continuityProof: { lowerEndpointDigest, roots: [...] } }
 *
 * This is a pure transform (no network / RPC), so it is unit-testable and reused by the tests.
 */
function packTallyProof(proofData) {
    if (!proofData || !proofData.merkleProof || !proofData.continuityProof) {
        throw new Error("packTallyProof: incomplete proof data");
    }

    const siblings = proofData.merkleProof.siblings.map((sibling) => ({
        sibling: sibling.hash,
        isLeft: sibling.isLeft,
    }));

    const inclusionProof = {
        kind: PROOF_KIND_BINARY_MERKLE,
        root: proofData.merkleProof.root,
        data: ethers.AbiCoder.defaultAbiCoder().encode(
            ["bytes", `${MERKLE_SIBLING_TYPE}[]`],
            [proofData.txBytes, siblings],
        ),
    };

    const continuityProof = {
        lowerEndpointDigest: proofData.continuityProof.lowerEndpointDigest,
        roots: proofData.continuityProof.roots,
    };

    return {
        chainKey: BigInt(proofData.chainKey),
        blockHeight: BigInt(proofData.headerNumber),
        txIndex: BigInt(proofData.txIndex),
        inclusionProof,
        continuityProof,
    };
}

/**
 * Fetch a proof for the `ChainTallyFinalized` transaction from the CC3 prover API and pack it for
 * the hub. Submit the returned `chainKey`, `blockHeight`, `inclusionProof`, and `continuityProof`
 * to `CrossChainGovernorHub.submitChainTally` from a trusted relayer account.
 *
 * The prover API resolves the block height and transaction index itself, and the hub validates
 * that the proved receipt carries a `ChainTallyFinalized` event from the registered spoke, so no
 * source-chain RPC is required here.
 */
async function buildGovernanceTallyProof(chainKey, transactionHash, proverApiUrl) {
    const normalizedChainKey = BigInt(chainKey);
    if (normalizedChainKey === 0n || normalizedChainKey > 2n ** 64n - 1n) {
        throw new Error("chainKey must be a non-zero uint64 USC source-chain key");
    }

    const generator = new proofGenerator.api.ProverAPIProofGenerator(
        Number(normalizedChainKey),
        proverApiUrl,
    );
    const result = await generator.generateProof(transactionHash);
    if (!result.success || !result.data) {
        throw new Error(`Proof generation failed: ${result.error ?? "unknown error"}`);
    }

    return packTallyProof(result.data);
}

function printable(value) {
    return JSON.stringify(
        value,
        (_, v) => (typeof v === "bigint" ? v.toString() : v),
        2,
    );
}

async function main() {
    const [chainKey, transactionHash, proverApiUrl] = process.argv.slice(2);
    if (!chainKey || !transactionHash || !proverApiUrl) {
        throw new Error(
            "Usage: node scripts/buildGovernanceTallyProof.js " +
                "<usc-chain-key> <finalize-tx-hash> <prover-api-url>",
        );
    }

    const result = await buildGovernanceTallyProof(chainKey, transactionHash, proverApiUrl);
    console.log(printable(result));
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error.message);
        process.exitCode = 1;
    });
}

module.exports = {
    PROOF_KIND_BINARY_MERKLE,
    packTallyProof,
    buildGovernanceTallyProof,
};
