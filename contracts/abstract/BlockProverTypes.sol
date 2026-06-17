// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library BlockProverTypes {
    enum ProofKind {
        BinaryMerkle
    }

    struct MerkleProofEntry {
        bytes32 sibling;
        bool isLeft;
    }

    struct InclusionProof {
        ProofKind kind;
        bytes32 root;
        bytes data;
    }

    struct ContinuityProof {
        bytes32 lowerEndpointDigest;
        bytes32[] roots;
    }
}
