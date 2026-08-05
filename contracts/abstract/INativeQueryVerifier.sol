// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INativeQueryVerifier {
    struct MerkleProofEntry {
        bytes32 hash;
        bool isLeft;
    }

    struct MerkleProof {
        bytes32 root;
        MerkleProofEntry[] siblings;
    }

    struct ContinuityProof {
        bytes32 lowerEndpointDigest;
        bytes32[] roots;
    }

    function verifyAndEmit(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        MerkleProof calldata merkleProof,
        ContinuityProof calldata continuityProof
    ) external returns (bool);

    function calculateTxIndex(
        MerkleProof calldata merkleProof
    ) external view returns (uint64);
}

library NativeQueryVerifierLib {
    address internal constant PRECOMPILE =
        0x0000000000000000000000000000000000000FD2;

    function getVerifier() internal pure returns (INativeQueryVerifier) {
        return INativeQueryVerifier(PRECOMPILE);
    }

    function hasPrecompile() internal view returns (bool) {
        uint256 chainId = block.chainid;
        if (chainId == 102030 || chainId == 102031 || chainId == 102033) {
            return true;
        }
        return PRECOMPILE.code.length > 0;
    }
}
