// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUSCProofVerifier} from "../../abstract/IUSCProofVerifier.sol";
import {BlockProverTypes} from "../../abstract/BlockProverTypes.sol";
import {LoanFlow, LoanTerms} from "./abstract/LoanTypes.sol";
import {EvmV1Decoder} from "./EvmV1Decoder.sol";
import {ILoanReadabilityTarget} from "./abstract/ILoanReadabilityTarget.sol";

/// @title USCLoanReadabilityManager
/// @notice Hub-side contract that verifies source-chain loan event proofs and updates `DestinationLoanRecording`.
/// @dev Each hub instance mirrors exactly one source chain (1:1). Emitter authorization is fail-closed.
contract USCLoanReadabilityManager is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    enum LoanReadabilityAction {
        LoanFunded,
        LoanRepaid,
        LoanRegistered
    }

    bytes4 private constant SOURCE_REGISTER_LOAN_SELECTOR = 0x6ae3c272;

    bytes32 public constant LOAN_REGISTERED_EVENT =
        0x4150dd864303d6b1464100e690e63c0ea11347decbb123e909018da0470f9870;
    bytes32 public constant LOAN_FUNDED_EVENT =
        0x9e71d2fb732e68272b7e74ecfd14638673c1d77e19a5d390a3ffff054d57c44b;

    bytes32 public constant LOAN_REPAID_EVENT =
        0x040cee90ee4799897c30ca04e5feb6fa43dbba9b6d084b4b257cdafd84ba013e;

    IUSCProofVerifier public proofVerifier;
    ILoanReadabilityTarget public loanTarget;

    /// @notice Creditcoin prover chain key for the single linked source network.
    bytes32 public sourceChainKey;
    /// @notice Trusted `SourceLoanRegistry` on the linked source chain (register proofs).
    address public authorizedLoanRegistry;
    /// @notice Trusted `SourceLoanHelper` on the linked source chain (fund/repay proofs).
    address public authorizedSourceContract;
    /// @notice EVM `chainId` of the linked source chain (EIP-712 domain for register signatures).
    uint256 public sourceEvmChainId;

    mapping(bytes32 => bool) public processedQueries;

    event LoanRegisteredVerified(bytes32 indexed queryId, bytes32 indexed chainKey, uint256 indexed loanId);
    event LoanFundedVerified(bytes32 indexed queryId, bytes32 indexed chainKey, uint256 indexed loanId);
    event LoanRepaymentVerified(
        bytes32 indexed queryId,
        bytes32 indexed chainKey,
        uint256 indexed loanId,
        uint256 amount
    );
    event LoanTargetSet(address indexed previous, address indexed next);
    event ProofVerifierSet(address indexed previous, address indexed next);
    event SourceChainConfigured(
        bytes32 indexed chainKey,
        uint256 sourceEvmChainId,
        address indexed loanRegistry,
        address indexed sourceContract
    );
    event QueryProcessed(bytes32 indexed queryId, bytes32 chainKey, uint64 blockHeight, uint64 txIndex);

    error ZeroAddress();
    error InvalidChainKey();
    error SourceChainNotConfigured();
    error InvalidSourceChainKey(bytes32 provided, bytes32 expected);
    error LoanRegistryNotConfigured();
    error SourceContractNotConfigured();
    error QueryAlreadyProcessed(bytes32 queryId);
    error InvalidAction(uint8 action);
    error UnsupportedTxType(uint8 txType);
    error TransactionReverted();
    error NoMatchingLogs(bytes32 eventSignature);
    error UnauthorizedSourceContract(address emitter, address expected);
    error InvalidLogTopicCount(uint256 actual, uint256 expected);
    error InvalidLogDataLength(uint256 actual, uint256 expected);
    error InvalidRegisterCalldata();
    error RegisterCalldataMismatch();
    error RegisterEventMismatch();
    error InvalidSourceEvmChainId();

    constructor(address loanTarget_, address proofVerifier_, address admin_) {
        if (loanTarget_ == address(0) || proofVerifier_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        loanTarget = ILoanReadabilityTarget(loanTarget_);
        proofVerifier = IUSCProofVerifier(proofVerifier_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, admin_);
    }

    function setLoanTarget(address newTarget) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTarget == address(0)) revert ZeroAddress();
        address prev = address(loanTarget);
        loanTarget = ILoanReadabilityTarget(newTarget);
        emit LoanTargetSet(prev, newTarget);
    }

    function setProofVerifier(address newVerifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVerifier == address(0)) revert ZeroAddress();
        address prev = address(proofVerifier);
        proofVerifier = IUSCProofVerifier(newVerifier);
        emit ProofVerifierSet(prev, newVerifier);
    }

    /// @notice Configure the single source chain this hub mirrors (1:1).
    function configureSourceChain(
        bytes32 chainKey_,
        uint256 sourceEvmChainId_,
        address loanRegistry_,
        address sourceContract_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainKey_ == bytes32(0) || sourceEvmChainId_ == 0 || loanRegistry_ == address(0) || sourceContract_ == address(0)) {
            revert ZeroAddress();
        }
        sourceChainKey = chainKey_;
        sourceEvmChainId = sourceEvmChainId_;
        authorizedLoanRegistry = loanRegistry_;
        authorizedSourceContract = sourceContract_;
        emit SourceChainConfigured(chainKey_, sourceEvmChainId_, loanRegistry_, sourceContract_);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function execute(
        uint8 action,
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof,
        BlockProverTypes.ContinuityProof calldata continuityProof
    ) external whenNotPaused nonReentrant returns (bool) {
        _requireConfiguredSourceChain(chainKey);

        bytes32 queryId = _computeQueryId(chainKey, blockHeight, inclusionProof);
        if (processedQueries[queryId]) revert QueryAlreadyProcessed(queryId);
        bytes memory encodedTransaction = proofVerifier.verifyProofs(
            chainKey,
            blockHeight,
            inclusionProof,
            continuityProof
        );
        processedQueries[queryId] = true;
        uint64 txIndex = proofVerifier.calculateTxIndex(inclusionProof);
        emit QueryProcessed(queryId, chainKey, blockHeight, txIndex);
        _processAction(action, chainKey, queryId, encodedTransaction);
        return true;
    }

    function _requireConfiguredSourceChain(bytes32 chainKey) internal view {
        bytes32 configured = sourceChainKey;
        if (configured == bytes32(0)) revert SourceChainNotConfigured();
        if (chainKey != configured) revert InvalidSourceChainKey(chainKey, configured);
    }

    function _processAction(
        uint8 action,
        bytes32 chainKey,
        bytes32 queryId,
        bytes memory encodedTransaction
    ) internal {
        uint8 txType = EvmV1Decoder.getTransactionType(encodedTransaction);
        if (!EvmV1Decoder.isValidTransactionType(txType)) revert UnsupportedTxType(txType);
        EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder.decodeReceiptFields(encodedTransaction);
        if (receipt.receiptStatus != 1) revert TransactionReverted();
        if (action == uint8(LoanReadabilityAction.LoanFunded)) {
            _handleLoanFunded(chainKey, queryId, receipt);
        } else if (action == uint8(LoanReadabilityAction.LoanRepaid)) {
            _handleLoanRepaid(chainKey, queryId, receipt);
        } else if (action == uint8(LoanReadabilityAction.LoanRegistered)) {
            _handleLoanRegistered(chainKey, queryId, encodedTransaction, receipt);
        } else {
            revert InvalidAction(action);
        }
    }

    function _handleLoanRegistered(
        bytes32 chainKey,
        bytes32 queryId,
        bytes memory encodedTransaction,
        EvmV1Decoder.ReceiptFields memory receipt
    ) internal {
        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(receipt, LOAN_REGISTERED_EVENT);
        if (logs.length == 0) revert NoMatchingLogs(LOAN_REGISTERED_EVENT);
        EvmV1Decoder.LogEntry memory log = logs[0];
        _validateLoanRegistry(log.address_);

        if (log.topics.length != 4) revert InvalidLogTopicCount(log.topics.length, 4);
        if (log.data.length != 96) revert InvalidLogDataLength(log.data.length, 96);

        uint256 loanId = uint256(log.topics[1]);
        address lender = address(uint160(uint256(log.topics[2])));
        address borrower = address(uint160(uint256(log.topics[3])));
        (uint256 loanAmount, uint256 repayAmount, uint256 deadlineTimestamp) =
            abi.decode(log.data, (uint256, uint256, uint256));

        (
            uint256 calldataLoanId,
            LoanFlow memory fundFlow,
            LoanFlow memory repayFlow,
            LoanTerms memory loanTerms,
            bytes memory signatureOfLender,
            bytes memory signatureOfBorrower
        ) = _decodeSourceRegisterLoanCalldata(EvmV1Decoder.decodeCommonTxFields(encodedTransaction).data);

        if (calldataLoanId != loanId) revert RegisterCalldataMismatch();
        if (sourceEvmChainId == 0) revert InvalidSourceEvmChainId();
        if (
            fundFlow.from != lender || fundFlow.to != borrower || loanTerms.loanAmount != loanAmount
                || loanTerms.expectedRepaymentAmount != repayAmount
                || loanTerms.deadlineTimestamp != deadlineTimestamp
        ) {
            revert RegisterEventMismatch();
        }

        loanTarget.registerLoan(
            chainKey,
            loanId,
            sourceEvmChainId,
            authorizedLoanRegistry,
            fundFlow,
            repayFlow,
            loanTerms,
            signatureOfLender,
            signatureOfBorrower
        );
        emit LoanRegisteredVerified(queryId, chainKey, loanId);
    }

    function _handleLoanFunded(
        bytes32 chainKey,
        bytes32 queryId,
        EvmV1Decoder.ReceiptFields memory receipt
    ) internal {
        EvmV1Decoder.LogEntry[] memory logs = EvmV1Decoder.getLogsByEventSignature(receipt, LOAN_FUNDED_EVENT);
        if (logs.length == 0) revert NoMatchingLogs(LOAN_FUNDED_EVENT);
        EvmV1Decoder.LogEntry memory log = logs[0];
        _validateSourceContract(log.address_);

        if (log.topics.length != 2) revert InvalidLogTopicCount(log.topics.length, 2);
        uint256 loanId = uint256(log.topics[1]);

        loanTarget.markLoanAsFunded(chainKey, loanId);
        emit LoanFundedVerified(queryId, chainKey, loanId);
    }

    function _handleLoanRepaid(
        bytes32 chainKey,
        bytes32 queryId,
        EvmV1Decoder.ReceiptFields memory receipt
    ) internal {
        EvmV1Decoder.LogEntry[] memory logs = EvmV1Decoder.getLogsByEventSignature(receipt, LOAN_REPAID_EVENT);
        if (logs.length == 0) revert NoMatchingLogs(LOAN_REPAID_EVENT);
        EvmV1Decoder.LogEntry memory log = logs[0];
        _validateSourceContract(log.address_);

        if (log.topics.length != 2) revert InvalidLogTopicCount(log.topics.length, 2);
        if (log.data.length != 32) revert InvalidLogDataLength(log.data.length, 32);

        uint256 loanId = uint256(log.topics[1]);
        uint256 amount = abi.decode(log.data, (uint256));

        loanTarget.recordLoanRepayment(chainKey, loanId, amount);
        emit LoanRepaymentVerified(queryId, chainKey, loanId, amount);
    }

    function _validateSourceContract(address emitter) internal view {
        address expected = authorizedSourceContract;
        if (expected == address(0)) revert SourceContractNotConfigured();
        if (emitter != expected) revert UnauthorizedSourceContract(emitter, expected);
    }

    function _validateLoanRegistry(address emitter) internal view {
        address expected = authorizedLoanRegistry;
        if (expected == address(0)) revert LoanRegistryNotConfigured();
        if (emitter != expected) revert UnauthorizedSourceContract(emitter, expected);
    }

    function _decodeSourceRegisterLoanCalldata(bytes memory data)
        internal
        pure
        returns (
            uint256 loanId,
            LoanFlow memory fundFlow,
            LoanFlow memory repayFlow,
            LoanTerms memory loanTerms,
            bytes memory signatureOfLender,
            bytes memory signatureOfBorrower
        )
    {
        if (data.length < 4) revert InvalidRegisterCalldata();
        bytes4 selector;
        assembly {
            selector := mload(add(data, 32))
        }
        if (selector != SOURCE_REGISTER_LOAN_SELECTOR) revert InvalidRegisterCalldata();

        bytes memory payload = new bytes(data.length - 4);
        for (uint256 i; i < payload.length; i++) {
            payload[i] = data[i + 4];
        }

        (loanId, fundFlow, repayFlow, loanTerms, signatureOfLender, signatureOfBorrower) = abi.decode(
            payload,
            (uint256, LoanFlow, LoanFlow, LoanTerms, bytes, bytes)
        );
    }

    function _computeQueryId(
        bytes32 chainKey,
        uint64 blockHeight,
        BlockProverTypes.InclusionProof calldata inclusionProof
    ) internal view returns (bytes32 queryId) {
        uint64 txIndex = proofVerifier.calculateTxIndex(inclusionProof);
        return keccak256(abi.encodePacked(chainKey, blockHeight, txIndex));
    }
}
