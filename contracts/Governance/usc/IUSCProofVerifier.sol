// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Vendored from the Creditcoin USC core (write-ability-research):
// contracts/abstract/IUSCProofVerifier.sol. The USC core deploys a single `USCProofVerifier`
// that fronts the native query-verifier precompile at `0xFD2`; USC dApps (bridge inbound, loan
// readability, and this governance example) call it to verify source-chain transaction proofs.

import {BlockProverTypes} from "./BlockProverTypes.sol";

interface IUSCProofVerifier {
    /// @notice Verifies transaction inclusion and chain continuity for a source chain.
    /// @return encodedTransaction The proved source transaction+receipt bytes (EVM v1 encoding).
    function verifyProofs(
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) external returns (bytes memory encodedTransaction);

    /// @notice Returns the transaction index implied by a BinaryMerkle inclusion proof.
    function calculateTxIndex(
        BlockProverTypes.InclusionProof calldata inclusionProof
    ) external view returns (uint64);
}
