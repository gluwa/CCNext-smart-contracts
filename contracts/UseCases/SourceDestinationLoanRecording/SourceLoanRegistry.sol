// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {LoanFlow, LoanStatus, LoanOrder, LoanTerms} from "./abstract/LoanTypes.sol";
import {LoanRegisterEIP712} from "./abstract/LoanRegisterEIP712.sol";

/// @title SourceLoanRegistry
/// @notice Source-chain loan registration (Sepolia). Loan ids must match `DestinationLoanRecording` on CC3.
contract SourceLoanRegistry is EIP712 {
    using ECDSA for bytes32;

    mapping(uint256 => LoanOrder) public loanOrders;
    mapping(uint256 => bool) public registeredLoans;

    uint256 public nextLoanId;

    event LoanRegistered(
        uint256 indexed loanId,
        address indexed lender,
        address indexed borrower,
        uint256 loanAmount,
        uint256 repayAmount,
        uint256 deadlineTimestamp
    );

    error LoanNotRegistered(uint256 loanId);
    error LoanAlreadyRegistered(uint256 loanId);
    error UnexpectedLoanId(uint256 provided, uint256 expected);
    error InvalidLoanAmount();
    error DeadlineMustBeInFuture();
    error RepaymentBelowLoanAmount();
    error InvalidLenderSignature();
    error InvalidBorrowerSignature();

    constructor() EIP712("SourceLoanRegistry", "1") {
        nextLoanId = 1;
    }

    function registerLoan(
        uint256 loanId,
        LoanFlow memory fundFlow,
        LoanFlow memory repayFlow,
        LoanTerms memory loanTerms,
        bytes memory signatureOfLender,
        bytes memory signatureOfBorrower
    ) external returns (uint256) {
        uint256 expectedLoanId = nextLoanId;
        if (loanId != expectedLoanId) revert UnexpectedLoanId(loanId, expectedLoanId);
        if (registeredLoans[loanId]) revert LoanAlreadyRegistered(loanId);
        _requireValidTerms(loanTerms);

        bytes32 structHash = LoanRegisterEIP712.hashLoanRegister(
            loanId, fundFlow, repayFlow, loanTerms
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        if (digest.recover(signatureOfLender) != fundFlow.from) revert InvalidLenderSignature();
        if (digest.recover(signatureOfBorrower) != fundFlow.to) revert InvalidBorrowerSignature();

        loanOrders[loanId] = LoanOrder({
            sourceChainKey: bytes32(0),
            sourceLoanId: loanId,
            fundFlow: fundFlow,
            repayFlow: repayFlow,
            terms: loanTerms,
            signatureOfLender: signatureOfLender,
            signatureOfBorrower: signatureOfBorrower,
            createdAtBlock: block.number,
            status: LoanStatus.Created,
            repaidAmount: 0
        });
        registeredLoans[loanId] = true;

        emit LoanRegistered(
            loanId,
            fundFlow.from,
            fundFlow.to,
            loanTerms.loanAmount,
            loanTerms.expectedRepaymentAmount,
            loanTerms.deadlineTimestamp
        );

        nextLoanId += 1;
        return loanId;
    }

    function getLoanOrder(uint256 loanId) external view returns (LoanOrder memory) {
        if (!registeredLoans[loanId]) revert LoanNotRegistered(loanId);
        return loanOrders[loanId];
    }

    function _requireValidTerms(LoanTerms memory loanTerms) internal view {
        if (loanTerms.loanAmount == 0) revert InvalidLoanAmount();
        if (loanTerms.deadlineTimestamp <= block.timestamp) revert DeadlineMustBeInFuture();
        if (loanTerms.expectedRepaymentAmount < loanTerms.loanAmount) revert RepaymentBelowLoanAmount();
    }
}
