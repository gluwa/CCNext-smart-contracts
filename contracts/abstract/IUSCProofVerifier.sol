// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BlockProverTypes} from "./BlockProverTypes.sol";

interface IUSCProofVerifier {
    function verifyProofs(
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) external returns (bytes memory encodedTransaction);

    function calculateTxIndex(
        BlockProverTypes.InclusionProof calldata inclusionProof
    ) external view returns (uint64);
}
