// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct LoanFlow {
    address from;
    address to;
    address withToken;
}

enum LoanStatus {
    Created,
    Funded,
    PartlyRepaid,
    Repaid,
    Expired
}

struct LoanTerms {
    uint256 loanAmount;
    uint256 interestRate;
    uint256 expectedRepaymentAmount;
    uint256 deadlineTimestamp;
}

struct LoanOrder {
    bytes32 sourceChainKey;
    uint256 sourceLoanId;
    LoanFlow fundFlow;
    LoanFlow repayFlow;
    LoanTerms terms;
    bytes signatureOfLender;
    bytes signatureOfBorrower;
    uint256 createdAtBlock;
    LoanStatus status;
    uint256 repaidAmount;
}

library LoanIdLib {
    function loanKey(bytes32 chainKey, uint256 sourceLoanId) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainKey, sourceLoanId));
    }
}
