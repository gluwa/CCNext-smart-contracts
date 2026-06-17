// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILoanReadabilityTarget
/// @notice Hub loan contract interface updated by `USCLoanReadabilityManager` after proof verification.
interface ILoanReadabilityTarget {
    function markLoanAsFunded(uint256 loanId) external;

    function recordLoanRepayment(uint256 loanId, uint256 amount) external;
}
