// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Vendored from the Creditcoin USC core (write-ability-research):
// contracts/common/QueryProofVerificationLib.sol. Pure helpers for CC3 query proofs. This
// example only exercises `decodeBinaryMerklePayload` / `txBytesFromInclusion` (used by the mock
// verifier), but the full library is copied verbatim so the vendored file matches the core.

import {BlockProverTypes} from "./BlockProverTypes.sol";

/// @dev Pure helpers for CC3 query proofs (prover API + on-chain verifier).
library QueryProofVerificationLib {
    /// @dev `digest[i] = keccak256(abi.encodePacked(blockNumber, merkleRoot, prevDigest))`.
    function continuityDigest(
        uint64 blockNumber,
        bytes32 merkleRoot,
        bytes32 prevDigest
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(blockNumber, merkleRoot, prevDigest));
    }

    /// @notice Verifies continuity from query block through attestation roots.
    /// @dev `roots[0]` must equal the transaction block Merkle root (inclusion root).
    function verifyContinuity(
        uint64 blockHeight,
        bytes32 lowerEndpointDigest,
        bytes32[] memory roots,
        bytes32 inclusionMerkleRoot
    ) internal pure returns (bool) {
        if (roots.length == 0) {
            return false;
        }
        if (roots[0] != inclusionMerkleRoot) {
            return false;
        }

        bytes32 digest = lowerEndpointDigest;
        for (uint256 i = 0; i < roots.length; i++) {
            digest = continuityDigest(blockHeight + uint64(i), roots[i], digest);
        }
        return digest != bytes32(0);
    }

    /// @notice Binary Merkle inclusion (Keccak-256, sibling position flag).
    function verifyMerkleInclusion(
        bytes32 leaf,
        bytes32 root,
        BlockProverTypes.MerkleProofEntry[] memory siblings
    ) internal pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < siblings.length; i++) {
            BlockProverTypes.MerkleProofEntry memory entry = siblings[i];
            if (entry.isLeft) {
                computed = keccak256(abi.encodePacked(entry.sibling, computed));
            } else {
                computed = keccak256(abi.encodePacked(computed, entry.sibling));
            }
        }
        return computed == root;
    }

    /// @dev `BinaryMerkle` payload: `abi.encode(bytes txBytes, MerkleProofEntry[] siblings)`.
    function decodeBinaryMerklePayload(
        bytes calldata data
    )
        internal
        pure
        returns (bytes memory txBytes, BlockProverTypes.MerkleProofEntry[] memory siblings)
    {
        return abi.decode(data, (bytes, BlockProverTypes.MerkleProofEntry[]));
    }

    /// @notice Extracts proved transaction bytes from a BinaryMerkle inclusion proof envelope.
    function txBytesFromInclusion(
        BlockProverTypes.InclusionProof calldata inclusionProof
    ) internal pure returns (bytes memory txBytes) {
        (txBytes, ) = decodeBinaryMerklePayload(inclusionProof.data);
    }
}
