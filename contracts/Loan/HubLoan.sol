// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {LoanFlow, LoanStatus, LoanOrder, LoanTerms} from "../abstract/LoanTypes.sol";
import {ILoanReadabilityTarget} from "../abstract/ILoanReadabilityTarget.sol";

/// @title HubLoan
/// @notice CC3 hub loan registry updated by `USCLoanReadabilityManager` after source-chain proofs.
contract HubLoan is AccessControl, ReentrancyGuard, ILoanReadabilityTarget {
    using ECDSA for bytes32;

    bytes32 public constant READABILITY_ROLE = keccak256("READABILITY_ROLE");

    mapping(uint256 => LoanOrder) public loanOrders;
    mapping(uint256 => bool) public registeredLoans;

    uint256 public nextLoanId;

    event LoanRegistered(
        uint256 indexed loanId,
        address indexed lender,
        address indexed borrower,
        uint256 loanAmount,
        uint256 repayAmount,
        uint256 deadlineBlockNumber
    );
    event LoanFunded(uint256 indexed loanId);
    event LoanPartiallyRepaid(uint256 indexed loanId, uint256 amount);
    event LoanRepaid(uint256 indexed loanId);
    event LoanExpired(uint256 indexed loanId);

    error LoanNotRegistered(uint256 loanId);
    error InvalidLoanAmount();
    error DeadlineMustBeInFuture();
    error RepaymentBelowLoanAmount();
    error InvalidLenderSignature();
    error InvalidBorrowerSignature();
    error InvalidLoanStatusForFunding(LoanStatus current);
    error LoanExpiredForFunding(uint256 deadlineBlockNumber);
    error InvalidLoanStatusForRepayment(LoanStatus current);
    error LoanExpiredForRepayment(uint256 deadlineBlockNumber);
    error LoanAlreadyFinalized();
    error LoanNotYetExpired();

    constructor(address admin_) {
        require(admin_ != address(0), "HubLoan: zero address");
        nextLoanId = 1;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function registerLoan(
        LoanFlow memory fundFlow,
        LoanFlow memory repayFlow,
        LoanTerms memory loanTerms,
        bytes memory signatureOfLender,
        bytes memory signatureOfBorrower
    ) external nonReentrant returns (uint256) {
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
                loanTerms.deadlineBlockNumber
            )
        );
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(msgHash);

        if (ethHash.recover(signatureOfLender) != fundFlow.from) revert InvalidLenderSignature();
        if (ethHash.recover(signatureOfBorrower) != fundFlow.to) revert InvalidBorrowerSignature();

        return _storeLoan(fundFlow, repayFlow, loanTerms, signatureOfLender, signatureOfBorrower);
    }

    function markLoanAsFunded(uint256 loanId) external onlyRole(READABILITY_ROLE) {
        if (!registeredLoans[loanId]) revert LoanNotRegistered(loanId);

        LoanOrder storage loan = loanOrders[loanId];
        if (loan.status != LoanStatus.Created) revert InvalidLoanStatusForFunding(loan.status);
        if (block.number > loan.terms.deadlineBlockNumber) {
            revert LoanExpiredForFunding(loan.terms.deadlineBlockNumber);
        }

        loan.status = LoanStatus.Funded;
        emit LoanFunded(loanId);
    }

    function recordLoanRepayment(uint256 loanId, uint256 amount) external onlyRole(READABILITY_ROLE) {
        if (!registeredLoans[loanId]) revert LoanNotRegistered(loanId);

        LoanOrder storage loan = loanOrders[loanId];
        if (loan.status != LoanStatus.Funded && loan.status != LoanStatus.PartlyRepaid) {
            revert InvalidLoanStatusForRepayment(loan.status);
        }
        if (block.number > loan.terms.deadlineBlockNumber) {
            revert LoanExpiredForRepayment(loan.terms.deadlineBlockNumber);
        }

        loan.repaidAmount += amount;

        if (loan.repaidAmount >= loan.terms.expectedRepaymentAmount) {
            loan.status = LoanStatus.Repaid;
            emit LoanRepaid(loanId);
        } else {
            loan.status = LoanStatus.PartlyRepaid;
            emit LoanPartiallyRepaid(loanId, amount);
        }
    }

    function markLoanAsExpired(uint256 loanId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!registeredLoans[loanId]) revert LoanNotRegistered(loanId);
        LoanOrder storage loan = loanOrders[loanId];
        if (loan.status == LoanStatus.Repaid || loan.status == LoanStatus.Expired) {
            revert LoanAlreadyFinalized();
        }
        if (block.number < loan.terms.deadlineBlockNumber) revert LoanNotYetExpired();

        loan.status = LoanStatus.Expired;
        emit LoanExpired(loanId);
    }

    function getLoanOrder(uint256 loanId) external view returns (LoanOrder memory) {
        if (!registeredLoans[loanId]) revert LoanNotRegistered(loanId);
        return loanOrders[loanId];
    }

    function _storeLoan(
        LoanFlow memory fundFlow,
        LoanFlow memory repayFlow,
        LoanTerms memory loanTerms,
        bytes memory signatureOfLender,
        bytes memory signatureOfBorrower
    ) internal returns (uint256 loanId) {
        loanId = nextLoanId;
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
            loanTerms.deadlineBlockNumber
        );

        nextLoanId += 1;
    }

    function _requireValidTerms(LoanTerms memory loanTerms) internal view {
        if (loanTerms.loanAmount == 0) revert InvalidLoanAmount();
        if (loanTerms.deadlineBlockNumber <= block.number) revert DeadlineMustBeInFuture();
        if (loanTerms.expectedRepaymentAmount < loanTerms.loanAmount) revert RepaymentBelowLoanAmount();
    }
}
