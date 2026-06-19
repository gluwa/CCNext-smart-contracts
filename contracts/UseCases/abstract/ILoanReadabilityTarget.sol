// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LoanFlow, LoanTerms} from "./LoanTypes.sol";

/// @title ILoanReadabilityTarget
/// @notice Hub loan contract interface updated by `USCLoanReadabilityManager` after proof verification.
interface ILoanReadabilityTarget {
    function registerLoan(
        bytes32 chainKey,
        uint256 sourceLoanId,
        uint256 sourceChainId,
        address sourceRegistry,
        LoanFlow memory fundFlow,
        LoanFlow memory repayFlow,
        LoanTerms memory loanTerms,
        bytes memory signatureOfLender,
        bytes memory signatureOfBorrower
    ) external returns (bytes32 loanKey);

    function markLoanAsFunded(bytes32 chainKey, uint256 sourceLoanId) external;

    function recordLoanRepayment(bytes32 chainKey, uint256 sourceLoanId, uint256 amount) external;
}
