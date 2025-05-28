// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './utility/console.sol';
import './Prover.sol';

contract ProverForTesting is CreditcoinPublicProver {
    uint64 private fakeVerifierResult;
    ResultSegment[] private fakeQueryResultSegments;

    function mock_setVerifierResult(uint64 value) public {
        fakeVerifierResult = value;
    }

    function mock_pushQueryResultSegment(ResultSegment memory value) public {
        fakeQueryResultSegments.push(value);
    }

    // this will be called by submitQueryProof()
    function _call_verifier_verify(QueryId, bytes calldata) external view override returns (uint64) {
        return fakeVerifierResult;
    }

    // this will be called by getQueryResultSegments()
    function _call_verifier_get_result_segments(QueryId)
        internal
        view
        virtual
        override
        returns (ResultSegment[] memory)
    {
        return fakeQueryResultSegments;
    }

    constructor(
        address _proceedsAccount,
        uint256 _costPerByte,
        uint256 _baseFee,
        uint64 _chainKey,
        string memory _displayName,
        uint32 _timeoutBlocks
    ) CreditcoinPublicProver(_proceedsAccount, _costPerByte, _baseFee, _chainKey, _displayName, _timeoutBlocks) {}

    function getTotalEscrowBalance() public view returns (Balance) {
        return totalEscrowBalance;
    }

    function allQueryIds() external view returns (QueryId[] memory) {
        return queryIds;
    }

    function mock_setQueryState(QueryId queryId, QueryState newState) public onlyOwner {
        queries[queryId].state = newState;
    }

    function mock_drainBalance(uint256 howMuch) public onlyOwner {
        payable(0).transfer(howMuch);
    }

    function mock_addBalance() public payable {
        // calling this will automatically accumulate balance on the contract
    }

    function mock_drainTotalEscrowBalance(uint256 howMuch) public onlyOwner {
        totalEscrowBalance = Balance.wrap(Balance.unwrap(totalEscrowBalance) - howMuch);
    }

    function mock_submitQueryWithState(ChainQuery calldata query, address principal, QueryState newState)
        public
        payable
    {
        QueryId queryId = computeQueryId(query);

        submitQuery(query, principal);
        mock_setQueryState(queryId, newState);
    }
}
