// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LoanFlow, LoanTerms} from "./LoanTypes.sol";

/// @title LoanRegisterEIP712
/// @notice Shared EIP-712 typed data for source-chain loan registration signatures.
library LoanRegisterEIP712 {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Must match the type string used by off-chain signers.
    bytes32 public constant LOAN_REGISTER_TYPEHASH = keccak256(
        "LoanRegister(uint256 loanId,address fundFrom,address fundTo,address fundToken,address repayFrom,address repayTo,address repayToken,uint256 loanAmount,uint256 interestRate,uint256 expectedRepaymentAmount,uint256 deadlineTimestamp)"
    );

    string internal constant NAME = "SourceLoanRegistry";
    string internal constant VERSION = "1";

    function domainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(NAME)),
                keccak256(bytes(VERSION)),
                chainId,
                verifyingContract
            )
        );
    }

    function hashLoanRegister(
        uint256 loanId,
        LoanFlow memory fundFlow,
        LoanFlow memory repayFlow,
        LoanTerms memory loanTerms
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                LOAN_REGISTER_TYPEHASH,
                loanId,
                fundFlow.from,
                fundFlow.to,
                fundFlow.withToken,
                repayFlow.from,
                repayFlow.to,
                repayFlow.withToken,
                loanTerms.loanAmount,
                loanTerms.interestRate,
                loanTerms.expectedRepaymentAmount,
                loanTerms.deadlineTimestamp
            )
        );
    }

    /// @notice EIP-712 digest verified on source (`SourceLoanRegistry`) and hub (`HubLoan`).
    function digest(
        uint256 chainId,
        address verifyingContract,
        uint256 loanId,
        LoanFlow memory fundFlow,
        LoanFlow memory repayFlow,
        LoanTerms memory loanTerms
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator(chainId, verifyingContract),
                hashLoanRegister(loanId, fundFlow, repayFlow, loanTerms)
            )
        );
    }
}
