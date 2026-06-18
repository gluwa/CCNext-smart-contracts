// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {LoanFlow, LoanStatus, LoanOrder, LoanTerms} from "../abstract/LoanTypes.sol";

/// @title SourceLoanRegistry
/// @notice Source-chain loan registration (Sepolia). Loan ids must match `HubLoan` on CC3.
contract SourceLoanRegistry {
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
    error InvalidLoanAmount();
    error DeadlineMustBeInFuture();
    error RepaymentBelowLoanAmount();
    error InvalidLenderSignature();
    error InvalidBorrowerSignature();

    constructor() {
        nextLoanId = 1;
    }

    function registerLoan(
        LoanFlow memory fundFlow,
        LoanFlow memory repayFlow,
        LoanTerms memory loanTerms,
        bytes memory signatureOfLender,
        bytes memory signatureOfBorrower
    ) external returns (uint256) {
        _requireValidTerms(loanTerms);

        bytes32 msgHash = keccak256(
            abi.encodePacked(
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
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(msgHash);

        if (ethHash.recover(signatureOfLender) != fundFlow.from) revert InvalidLenderSignature();
        if (ethHash.recover(signatureOfBorrower) != fundFlow.to) revert InvalidBorrowerSignature();

        uint256 loanId = nextLoanId;
        loanOrders[loanId] = LoanOrder({
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
