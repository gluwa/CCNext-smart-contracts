// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./abstract/Types.sol";
import "./abstract/Ownable.sol";

address constant PROOF_VERIFIER_ADDRESS = 0x0000000000000000000000000000000000000Be9;
interface ICreditcoinPublicProver {
    function getQueryResultSegments(
        bytes32 queryId
    ) external view returns (ResultSegment[] memory resultSegments);
    function getQueryDetails(
        bytes32 queryId
    ) external view returns (QueryDetails memory queryDetails);
}

contract CreditcoinPublicProver is ICreditcoinPublicProver, Ownable {
    mapping(QueryId => QueryDetails) internal queries;
    QueryId[] public queryIds;
    Balance totalEscrowBalance;
    QueryVerifierContract verifier;
    uint32 timeout = 100;
    uint64 chainKey;
    address proceedsAccount;
    uint256 public costPerByte;
    uint256 public baseFee;
    string public displayName;

    constructor(
        address _proceedsAccount,
        uint256 _costPerByte,
        uint256 _baseFee,
        uint64 _chainKey,
        string memory _displayName,
        uint32 _timeout
    ) Ownable() {
        verifier = QueryVerifierContract(PROOF_VERIFIER_ADDRESS);
        proceedsAccount = _proceedsAccount;
        totalEscrowBalance = Balance.wrap(0);
        costPerByte = _costPerByte;
        baseFee = _baseFee;
        chainKey = _chainKey;
        displayName = _displayName;
        timeout = _timeout;

        emit ProverDeployed(
            address(this),
            msg.sender,
            _proceedsAccount,
            _costPerByte,
            _baseFee,
            _chainKey,
            _displayName,
            _timeout
        );
    }

    function computeQueryCost(
        ChainQuery calldata query
    ) public view returns (uint256 cost, uint256 segmentCount) {
        // Cost function is based on the size of the query layoutsegments
        // I think it should also somehow include the distance between the required
        // block height and its nearest checkpoint or something of sorts (if distance
        // to a checkpoint determines the time prover needs to generate the proof)
        // not sure yet how to implement something like that

        // Calculate the total size of the query based on its layout segments
        uint256 totalBytes;
        segmentCount = query.layoutSegments.length;
        unchecked {
            for (uint256 i; i < segmentCount; ) {
                totalBytes += query.layoutSegments[i].size;
                ++i;
            }
            // Calculate the total cost as a function of the size and base cost
            cost = (totalBytes * costPerByte) + baseFee;
        }
    }

    function updateCostPerByte(uint256 _newCostPerByte) external onlyOwner {
        costPerByte = _newCostPerByte;
        emit CostPerByteUpdated(_newCostPerByte);
    }

    function updateBaseFee(uint256 _newBaseFee) external onlyOwner {
        baseFee = _newBaseFee;
        emit BaseFeeUpdated(_newBaseFee);
    }

    function computeQueryId(
        ChainQuery calldata query
    ) internal pure returns (QueryId) {
        return QueryId.wrap(keccak256(abi.encode(query)));
    }

    function submitQuery(
        ChainQuery calldata query,
        address principal
    ) public payable {
        require(query.chainId == chainKey, "Chain not supported");
        QueryId queryId = computeQueryId(query);
        // require(queries[queryId].principal == address(0));
        // Need a more complex guard for the queries that allows replay attack protection.

        (uint256 estimatedCost, uint256 segmentCount) = computeQueryCost(query);
        require(
            msg.value >= estimatedCost,
            "Insufficient funds: msg.value must be >= estimatedCost"
        );

        totalEscrowBalance = Balance.wrap(
            Balance.unwrap(totalEscrowBalance) + msg.value
        );

        // Allow resubmission of queries that have timed out or have default state (Uninitialized)
        if (
            !(queries[queryId].state == QueryState.Uninitialized ||
                isQueryTimedOut(queryId))
        ) {
            revert("Query already exists");
        }

        // Store query details
        // .state
        queries[queryId].state = QueryState.Submitted;
        // .query
        queries[queryId].query.chainId = query.chainId;
        queries[queryId].query.height = query.height;
        queries[queryId].query.index = query.index;
        for (uint256 i; i < segmentCount;) {
            queries[queryId].query.layoutSegments.push(query.layoutSegments[i]);
            unchecked {
                ++i;
            }
        }
        // .result doesn't need to be set here
        // .escrowedAmount
        queries[queryId].escrowedAmount = Balance.wrap(msg.value);
        // .principal
        queries[queryId].principal = principal;
        // .estimatedCost
        queries[queryId].estimatedCost = Balance.wrap(estimatedCost);
        // .timestamp
        queries[queryId].timestamp = block.timestamp;

        // Add to unprocessed queries
        queryIds.push(queryId);

        // Emit event
        emit QuerySubmitted(queryId, estimatedCost, msg.value, query);
    }

    function reclaimEscrowedPayment(QueryId queryId) public {
        require(
            queries[queryId].principal == msg.sender,
            "Sender different from query.principal"
        );

        QueryState state = queries[queryId].state;
        // Explicitly revert if the state is ResultAvailable
        require(
            state != QueryState.ResultAvailable,
            "Cannot reclaim: query result is available"
        );

        // Allow reclaim if timeout has passed OR if the query is invalid
        bool isInvalidQuery = (state == QueryState.InvalidQuery);

        require(
            isInvalidQuery || isQueryTimedOut(queryId),
            "Cannot reclaim: neither timeout nor invalid query state met"
        );

        uint256 escrowedAmount = Balance.unwrap(
            queries[queryId].escrowedAmount
        );

        totalEscrowBalance = Balance.wrap(
            Balance.unwrap(totalEscrowBalance) - escrowedAmount
        );

        payable(msg.sender).transfer(escrowedAmount);

        queries[queryId].escrowedAmount = Balance.wrap(0);

        emit EscrowedPaymentReclaimed(queryId, escrowedAmount);
    }

    // wrapper which can be used to mock the verifier precompile for testing
    function _call_verifier_verify(
        QueryId queryId,
        bytes calldata proof
    ) external virtual returns (uint64) {
        return verifier.verify(proof, queries[queryId].query);
    }

    // wrapper which can be used to mock the verifier precompile for testing
    function _call_verifier_get_result_segments(
        QueryId queryId
    ) internal view virtual returns (ResultSegment[] memory) {
        return verifier.get_result_segments(queryId);
    }

    function _getRevertReason(
        bytes memory revertData
    ) internal pure returns (string memory) {
        if (revertData.length < 68) return "Cannot decode revert reason";
        assembly {
            // Skip the function selector 4 bytes
            revertData := add(revertData, 0x04)
        }
        return abi.decode(revertData, (string));
    }

    // submitQueryProof is called by the prover when a query's proof is ready.
    function submitQueryProof(
        QueryId queryId,
        bytes calldata proof
    ) public onlyOwner returns (ResultSegment[] memory) {
        // Check if timeout has occurred
        if (isQueryTimedOut(queryId)) {
            revert("Query has timed out");
        }

        // Start proof verification
        try this._call_verifier_verify(queryId, proof) {
            // Calculate the prover's fee
            // Transfer the prover's fee to the prover
            uint256 proverFee = Balance.unwrap(queries[queryId].escrowedAmount);

            totalEscrowBalance = Balance.wrap(
                Balance.unwrap(totalEscrowBalance) - proverFee
            );

            // Send to proceedsAccount
            payable(proceedsAccount).transfer(proverFee);

            queries[queryId].escrowedAmount = Balance.wrap(0);

            queries[queryId].state = QueryState.ResultAvailable;

            ResultSegment[]
                memory resultSegments = _call_verifier_get_result_segments(
                    queryId
                );

            // Emit event with query ID, proof, and state
            emit QueryProofVerified(
                queryId,
                resultSegments,
                queries[queryId].state
            );

            return resultSegments;
        } catch (bytes memory revertData) {
            queries[queryId].state = QueryState.InvalidQuery;

            string memory reason = _getRevertReason(revertData);

            emit QueryProofVerificationFailed(queryId, reason);

            revert(
                string(abi.encodePacked("Proof verification failed: ", reason))
            );
        }
    }

    function withdrawProceeds() public onlyOwner {
        // allows the prover to withdraw the balance of the contract that's not
        // still escrowed

        // Compute the withdrawable balance
        uint256 contractBalance = address(this).balance;
        uint256 totalEscrowed = Balance.unwrap(totalEscrowBalance);
        uint256 withdrawable = contractBalance > totalEscrowed
            ? contractBalance - totalEscrowed
            : 0;

        require(withdrawable > 0, "No withdrawable proceeds available");

        // Transfer the amount to the proceeds account
        payable(proceedsAccount).transfer(withdrawable);

        emit ProceedsWithdrawn(proceedsAccount, withdrawable);
    }

    function getUnprocessedQueries() public view returns (ChainQuery[] memory result) {
        uint256 queryLength = queryIds.length;
        ChainQuery[] memory temp = new ChainQuery[](queryLength);
        uint256 count;

        for (uint256 i; i < queryLength;) {
            QueryDetails storage current = queries[queryIds[i]];
            if (
                current.state == QueryState.Submitted &&
                !isQueryTimedOut(queryIds[i])
            ) {
                temp[count++] = current.query;
            }
            unchecked {
                ++i;
            }
        }

        result = new ChainQuery[](count);
        for (uint256 i; i < count; i++) {
            result[i] = temp[i];
        }
    }

    function removeQueryId(QueryId queryId) public onlyOwner {
        uint256 lastIndex  = queryIds.length - 1;        
        bytes32 unwrappedQueryId = QueryId.unwrap(queryId);
        for (uint256 i; i <= lastIndex;) {
            // Cast both to bytes for comparison
            if (QueryId.unwrap(queryIds[i]) == unwrappedQueryId) {
                if (i != lastIndex ) {
                    queryIds[i] = queryIds[lastIndex];
                }
                queryIds.pop();
                delete queries[queryId];
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    function getQueryResultSegments(
        bytes32 queryId
    ) public view override returns (ResultSegment[] memory) {
        QueryId typedQueryId = QueryId.wrap(queryId);
        QueryState state = queries[typedQueryId].state;
        require(
            state == QueryState.ResultAvailable,
            "Query result not available"
        );

        ResultSegment[]
            memory resultSegments = _call_verifier_get_result_segments(
                typedQueryId
            );

        return resultSegments;
    }

    function isQueryTimedOut(QueryId queryId) public view returns (bool) {
        return block.timestamp > queries[queryId].timestamp + timeout;
    }

    function getQueryDetails(
        bytes32 queryId
    ) external view override returns (QueryDetails memory queryDetails) {
        queryDetails = queries[QueryId.wrap(queryId)];
        require(
            queryDetails.state != QueryState.Uninitialized,
            "No such query"
        );
        return queryDetails;
    }
}

/// @title QueryVerifierContract interface
/// @notice This interface defines the functions and events for interacting with the QueryVerifierContract.
interface QueryVerifierContract {
    function verify(
        bytes calldata proof,
        ChainQuery calldata query
    ) external returns (uint64);

    function get_result_segments(
        QueryId queryId
    ) external view returns (ResultSegment[] memory);
}

event ProverDeployed(
    address indexed contractAddress,
    address indexed owner,
    address proceedsAccount,
    uint256 costPerByte,
    uint256 baseFee,
    uint64 chainKey,
    string displayName,
    uint32 timeout
);

event QuerySubmitted(
    QueryId indexed queryId,
    uint256 estimatedCost,
    uint256 escrowedAmount,
    ChainQuery chainQuery
);

event QueryProofVerified(
    QueryId indexed queryId,
    ResultSegment[] resultSegments,
    QueryState state
);

event QueryProofVerificationFailed(QueryId indexed queryId, string reason);

event EscrowedPaymentReclaimed(QueryId indexed queryId, uint256 escrowedAmount);

event ProceedsWithdrawn(address indexed proceedsAccount, uint256 amount);

event CostPerByteUpdated(uint256 newCostPerByte);

event BaseFeeUpdated(uint256 newBaseFee);
