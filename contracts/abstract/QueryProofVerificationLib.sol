// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BlockProverTypes} from "./BlockProverTypes.sol";

library QueryProofVerificationLib {
    function continuityDigest(
        uint64 blockNumber,
        bytes32 merkleRoot,
        bytes32 prevDigest
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(blockNumber, merkleRoot, prevDigest));
    }

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

    function decodeBinaryMerklePayload(
        bytes calldata data
    )
        internal
        pure
        returns (bytes memory txBytes, BlockProverTypes.MerkleProofEntry[] memory siblings)
    {
        return abi.decode(data, (bytes, BlockProverTypes.MerkleProofEntry[]));
    }

    function txBytesFromInclusion(
        BlockProverTypes.InclusionProof calldata inclusionProof
    ) internal pure returns (bytes memory txBytes) {
        (txBytes, ) = decodeBinaryMerklePayload(inclusionProof.data);
    }
}
