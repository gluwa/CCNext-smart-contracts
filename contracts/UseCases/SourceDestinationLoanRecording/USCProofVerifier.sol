// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUSCProofVerifier} from "../../abstract/IUSCProofVerifier.sol";
import {BlockProverTypes} from "../../abstract/BlockProverTypes.sol";
import {INativeQueryVerifier, NativeQueryVerifierLib} from "../../abstract/INativeQueryVerifier.sol";
import {QueryProofVerificationLib} from "../../abstract/QueryProofVerificationLib.sol";

/// @title USCProofVerifier
/// @notice CC3 query proof verification via native precompile `0xFD2`.
contract USCProofVerifier is IUSCProofVerifier {
    event ProofVerified(
        bytes32 indexed chainKey,
        uint64 blockHeight,
        BlockProverTypes.ProofKind kind,
        address precompileUsed,
        bool success
    );

    error ProofInvalid(bytes32 chainKey, uint64 blockHeight);
    error UnsupportedProofKind(BlockProverTypes.ProofKind kind);

    function verifyProofs(
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) external returns (bytes memory) {
        if (inclusionProof.kind != BlockProverTypes.ProofKind.BinaryMerkle) {
            _emitVerified(chainKey, blockHeight, inclusionProof.kind, address(0), false);
            revert ProofInvalid(chainKey, blockHeight);
        }
        return _verifyBinaryMerkle(chainKey, blockHeight, inclusionProof, continuityProof);
    }

    function calculateTxIndex(
        BlockProverTypes.InclusionProof calldata inclusionProof
    ) external view returns (uint64) {
        if (inclusionProof.kind != BlockProverTypes.ProofKind.BinaryMerkle) {
            revert UnsupportedProofKind(inclusionProof.kind);
        }
        INativeQueryVerifier.MerkleProof memory merkleProof = _nativeMerkleProof(inclusionProof);
        return NativeQueryVerifierLib.getVerifier().calculateTxIndex(merkleProof);
    }

    function _verifyBinaryMerkle(
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) internal returns (bytes memory txBytes) {
        txBytes = QueryProofVerificationLib.txBytesFromInclusion(inclusionProof);
        if (txBytes.length == 0) {
            _emitVerified(chainKey, blockHeight, inclusionProof.kind, address(0), false);
            revert ProofInvalid(chainKey, blockHeight);
        }

        if (!NativeQueryVerifierLib.hasPrecompile()) {
            _emitVerified(chainKey, blockHeight, inclusionProof.kind, address(0), false);
            revert ProofInvalid(chainKey, blockHeight);
        }

        bool ok = _verifyViaNativeQueryPrecompile(
            chainKey,
            blockHeight,
            txBytes,
            inclusionProof,
            continuityProof
        );
        _emitVerified(
            chainKey,
            blockHeight,
            inclusionProof.kind,
            address(NativeQueryVerifierLib.getVerifier()),
            ok
        );
        if (!ok) revert ProofInvalid(chainKey, blockHeight);
    }

    function _verifyViaNativeQueryPrecompile(
        bytes32 chainKey,
        uint64 blockHeight,
        bytes memory txBytes,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) internal returns (bool) {
        INativeQueryVerifier.MerkleProof memory merkleProof = _nativeMerkleProof(inclusionProof);
        INativeQueryVerifier.ContinuityProof memory nativeContinuity = INativeQueryVerifier.ContinuityProof({
            lowerEndpointDigest: continuityProof.lowerEndpointDigest,
            roots: continuityProof.roots
        });

        return
            NativeQueryVerifierLib.getVerifier().verifyAndEmit(
                uint64(uint256(chainKey)),
                blockHeight,
                txBytes,
                merkleProof,
                nativeContinuity
            );
    }

    function _nativeMerkleProof(
        BlockProverTypes.InclusionProof calldata inclusionProof
    ) internal pure returns (INativeQueryVerifier.MerkleProof memory merkleProof) {
        BlockProverTypes.MerkleProofEntry[] memory siblings = _merkleSiblings(inclusionProof);
        INativeQueryVerifier.MerkleProofEntry[] memory nativeSiblings =
            new INativeQueryVerifier.MerkleProofEntry[](siblings.length);
        for (uint256 i = 0; i < siblings.length; i++) {
            nativeSiblings[i] = INativeQueryVerifier.MerkleProofEntry({
                hash: siblings[i].sibling,
                isLeft: siblings[i].isLeft
            });
        }
        merkleProof = INativeQueryVerifier.MerkleProof({
            root: inclusionProof.root,
            siblings: nativeSiblings
        });
    }

    function _merkleSiblings(
        BlockProverTypes.InclusionProof calldata inclusionProof
    ) internal pure returns (BlockProverTypes.MerkleProofEntry[] memory siblings) {
        (, siblings) = QueryProofVerificationLib.decodeBinaryMerklePayload(inclusionProof.data);
    }

    function _emitVerified(
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.ProofKind kind,
        address precompileUsed,
        bool success
    ) internal {
        emit ProofVerified(chainKey, blockHeight, kind, precompileUsed, success);
    }
}
