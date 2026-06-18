// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LoanFlow, LoanTerms} from "./LoanTypes.sol";

/// @title ILoanReadabilityTarget
/// @notice Hub loan contract interface updated by `USCLoanReadabilityManager` after proof verification.
interface ILoanReadabilityTarget {
    function registerLoan(
        uint256 loanId,
        LoanFlow memory fundFlow,
        LoanFlow memory repayFlow,
        LoanTerms memory loanTerms,
        bytes memory signatureOfLender,
        bytes memory signatureOfBorrower
    ) external returns (uint256);

    function markLoanAsFunded(uint256 loanId) external;

    function recordLoanRepayment(uint256 loanId, uint256 amount) external;
}
