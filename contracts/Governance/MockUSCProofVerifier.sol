// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUSCProofVerifier} from "./usc/IUSCProofVerifier.sol";
import {BlockProverTypes} from "./usc/BlockProverTypes.sol";
import {QueryProofVerificationLib} from "./usc/QueryProofVerificationLib.sol";

/**
 * @title MockUSCProofVerifier
 * @notice Test stand-in for the USC core `USCProofVerifier`, mirroring the mock the USC core
 *         uses in its own tests. `verifyProofs` returns the proved transaction bytes carried
 *         inside the inclusion proof (instead of running the `0xFD2` precompile), and
 *         `setValid(false)` forces a verification failure. `calculateTxIndex` derives the index
 *         from the Merkle sibling positions exactly like the native verifier, so the hub's
 *         replay-protection query id lines up with production.
 */
contract MockUSCProofVerifier is IUSCProofVerifier {
    error MockProofInvalid();

    bool public isValid = true;

    function setValid(bool nextValue) external {
        isValid = nextValue;
    }

    function verifyProofs(
        bytes32,
        uint64,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata
    ) external view override returns (bytes memory) {
        if (!isValid) revert MockProofInvalid();
        return QueryProofVerificationLib.txBytesFromInclusion(inclusionProof);
    }

    function calculateTxIndex(
        BlockProverTypes.InclusionProof calldata inclusionProof
    ) external pure override returns (uint64 index) {
        (, BlockProverTypes.MerkleProofEntry[] memory siblings) = QueryProofVerificationLib
            .decodeBinaryMerklePayload(inclusionProof.data);
        for (uint256 i; i < siblings.length; ++i) {
            index = siblings[i].isLeft ? (index << 1) | 1 : index << 1;
        }
    }
}
