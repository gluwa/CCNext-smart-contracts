// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {LoanFlow, LoanStatus, LoanOrder, LoanTerms, LoanIdLib} from "./abstract/LoanTypes.sol";
import {ILoanReadabilityTarget} from "./abstract/ILoanReadabilityTarget.sol";
import {LoanRegisterEIP712} from "./abstract/LoanRegisterEIP712.sol";

/// @title DestinationLoanRecording
/// @notice CC3 destination loan registry mirroring exactly one source chain (1:1).
/// @dev Updated only by `USCLoanReadabilityManager` after source-chain proofs.
contract DestinationLoanRecording is AccessControl, ReentrancyGuard, ILoanReadabilityTarget {
    using ECDSA for bytes32;

    bytes32 public constant READABILITY_ROLE = keccak256("READABILITY_ROLE");

    /// @notice Creditcoin prover chain key for the single linked source network.
    bytes32 public sourceChainKey;
    /// @notice EVM `chainId` of the linked source chain (EIP-712 domain for register signatures).
    uint256 public sourceEvmChainId;
    /// @notice Trusted `SourceLoanRegistry` on the linked source chain.
    address public authorizedLoanRegistry;

    mapping(uint256 => LoanOrder) public loanOrders;
    mapping(uint256 => bool) public registeredLoans;

    event SourceChainConfigured(
        bytes32 indexed chainKey, uint256 sourceEvmChainId, address indexed loanRegistry
    );
    event LoanRegistered(
        bytes32 indexed chainKey,
        uint256 indexed sourceLoanId,
        address indexed lender,
        address borrower,
        uint256 loanAmount,
        uint256 repayAmount,
        uint256 deadlineTimestamp
    );
    event LoanFunded(bytes32 indexed chainKey, uint256 indexed sourceLoanId);
    event LoanPartiallyRepaid(bytes32 indexed chainKey, uint256 indexed sourceLoanId, uint256 amount);
    event LoanRepaid(bytes32 indexed chainKey, uint256 indexed sourceLoanId);
    event LoanExpired(bytes32 indexed chainKey, uint256 indexed sourceLoanId);

    error ZeroAddress();
    error SourceChainNotConfigured();
    error InvalidSourceChainKey(bytes32 provided, bytes32 expected);
    error InvalidSourceEvmChainId(uint256 provided, uint256 expected);
    error InvalidSourceRegistry(address provided, address expected);
    error LoanNotRegistered(uint256 sourceLoanId);
    error LoanAlreadyRegistered(uint256 sourceLoanId);
    error InvalidLoanAmount();
    error DeadlineMustBeInFuture();
    error RepaymentBelowLoanAmount();
    error InvalidLenderSignature();
    error InvalidBorrowerSignature();
    error InvalidLoanStatusForFunding(LoanStatus current);
    error LoanExpiredForFunding(uint256 deadlineTimestamp);
    error InvalidLoanStatusForRepayment(LoanStatus current);
    error LoanExpiredForRepayment(uint256 deadlineTimestamp);
    error LoanAlreadyFinalized();
    error LoanNotYetExpired();

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Bind this destination registry to a single source chain (1:1).
    function configureSourceChain(
        bytes32 chainKey_,
        uint256 sourceEvmChainId_,
        address loanRegistry_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainKey_ == bytes32(0) || sourceEvmChainId_ == 0 || loanRegistry_ == address(0)) {
            revert ZeroAddress();
        }
        sourceChainKey = chainKey_;
        sourceEvmChainId = sourceEvmChainId_;
        authorizedLoanRegistry = loanRegistry_;
        emit SourceChainConfigured(chainKey_, sourceEvmChainId_, loanRegistry_);
    }

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
    ) external onlyRole(READABILITY_ROLE) nonReentrant returns (bytes32 loanKey) {
        _requireConfiguredChain(chainKey);
        _requireSourceRegistry(sourceChainId, sourceRegistry);

        if (registeredLoans[sourceLoanId]) revert LoanAlreadyRegistered(sourceLoanId);
        _requireValidTerms(loanTerms);

        bytes32 digest = LoanRegisterEIP712.digest(
            sourceChainId,
            sourceRegistry,
            sourceLoanId,
            fundFlow,
            repayFlow,
            loanTerms
        );

        if (digest.recover(signatureOfLender) != fundFlow.from) revert InvalidLenderSignature();
        if (digest.recover(signatureOfBorrower) != fundFlow.to) revert InvalidBorrowerSignature();

        _storeLoan(
            chainKey, sourceLoanId, fundFlow, repayFlow, loanTerms, signatureOfLender, signatureOfBorrower
        );
        return LoanIdLib.loanKey(chainKey, sourceLoanId);
    }

    function markLoanAsFunded(bytes32 chainKey, uint256 sourceLoanId) external onlyRole(READABILITY_ROLE) {
        _requireConfiguredChain(chainKey);
        if (!registeredLoans[sourceLoanId]) revert LoanNotRegistered(sourceLoanId);

        LoanOrder storage loan = loanOrders[sourceLoanId];
        if (loan.status != LoanStatus.Created) revert InvalidLoanStatusForFunding(loan.status);
        if (block.timestamp > loan.terms.deadlineTimestamp) {
            revert LoanExpiredForFunding(loan.terms.deadlineTimestamp);
        }

        loan.status = LoanStatus.Funded;
        emit LoanFunded(chainKey, sourceLoanId);
    }

    function recordLoanRepayment(bytes32 chainKey, uint256 sourceLoanId, uint256 amount)
        external
        onlyRole(READABILITY_ROLE)
    {
        _requireConfiguredChain(chainKey);
        if (!registeredLoans[sourceLoanId]) revert LoanNotRegistered(sourceLoanId);

        LoanOrder storage loan = loanOrders[sourceLoanId];
        if (loan.status != LoanStatus.Funded && loan.status != LoanStatus.PartlyRepaid) {
            revert InvalidLoanStatusForRepayment(loan.status);
        }
        if (block.timestamp > loan.terms.deadlineTimestamp) {
            revert LoanExpiredForRepayment(loan.terms.deadlineTimestamp);
        }

        loan.repaidAmount += amount;

        if (loan.repaidAmount >= loan.terms.expectedRepaymentAmount) {
            loan.status = LoanStatus.Repaid;
            emit LoanRepaid(chainKey, sourceLoanId);
        } else {
            loan.status = LoanStatus.PartlyRepaid;
            emit LoanPartiallyRepaid(chainKey, sourceLoanId, amount);
        }
    }

    function markLoanAsExpired(bytes32 chainKey, uint256 sourceLoanId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireConfiguredChain(chainKey);
        if (!registeredLoans[sourceLoanId]) revert LoanNotRegistered(sourceLoanId);
        LoanOrder storage loan = loanOrders[sourceLoanId];
        if (loan.status == LoanStatus.Repaid || loan.status == LoanStatus.Expired) {
            revert LoanAlreadyFinalized();
        }
        if (block.timestamp < loan.terms.deadlineTimestamp) revert LoanNotYetExpired();

        loan.status = LoanStatus.Expired;
        emit LoanExpired(chainKey, sourceLoanId);
    }

    function getLoanOrder(bytes32 chainKey, uint256 sourceLoanId) external view returns (LoanOrder memory) {
        _requireConfiguredChain(chainKey);
        if (!registeredLoans[sourceLoanId]) revert LoanNotRegistered(sourceLoanId);
        return loanOrders[sourceLoanId];
    }

    function _requireConfiguredChain(bytes32 chainKey) internal view {
        bytes32 configured = sourceChainKey;
        if (configured == bytes32(0)) revert SourceChainNotConfigured();
        if (chainKey != configured) revert InvalidSourceChainKey(chainKey, configured);
    }

    function _requireSourceRegistry(uint256 sourceChainId, address sourceRegistry) internal view {
        if (sourceChainId != sourceEvmChainId) {
            revert InvalidSourceEvmChainId(sourceChainId, sourceEvmChainId);
        }
        address expected = authorizedLoanRegistry;
        if (expected == address(0) || sourceRegistry != expected) {
            revert InvalidSourceRegistry(sourceRegistry, expected);
        }
    }

    function _storeLoan(
        bytes32 chainKey,
        uint256 sourceLoanId,
        LoanFlow memory fundFlow,
        LoanFlow memory repayFlow,
        LoanTerms memory loanTerms,
        bytes memory signatureOfLender,
        bytes memory signatureOfBorrower
    ) internal {
        loanOrders[sourceLoanId] = LoanOrder({
            sourceChainKey: chainKey,
            sourceLoanId: sourceLoanId,
            fundFlow: fundFlow,
            repayFlow: repayFlow,
            terms: loanTerms,
            signatureOfLender: signatureOfLender,
            signatureOfBorrower: signatureOfBorrower,
            createdAtBlock: block.number,
            status: LoanStatus.Created,
            repaidAmount: 0
        });
        registeredLoans[sourceLoanId] = true;

        emit LoanRegistered(
            chainKey,
            sourceLoanId,
            fundFlow.from,
            fundFlow.to,
            loanTerms.loanAmount,
            loanTerms.expectedRepaymentAmount,
            loanTerms.deadlineTimestamp
        );
    }

    function _requireValidTerms(LoanTerms memory loanTerms) internal view {
        if (loanTerms.loanAmount == 0) revert InvalidLoanAmount();
        if (loanTerms.deadlineTimestamp <= block.timestamp) revert DeadlineMustBeInFuture();
        if (loanTerms.expectedRepaymentAmount < loanTerms.loanAmount) revert RepaymentBelowLoanAmount();
    }
}
