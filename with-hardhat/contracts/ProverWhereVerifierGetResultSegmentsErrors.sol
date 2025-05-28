// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './utility/console.sol';
import './ProverForTesting.sol';

contract ProverWhereVerifierGetResultSegmentsErrors is ProverForTesting {
    function _call_verifier_get_result_segments(QueryId) internal pure override returns (ResultSegment[] memory) {
        require(true == false, "Errored on purpose");
        return new ResultSegment[](0);
    }

    constructor(
        address _proceedsAccount,
        uint256 _costPerByte,
        uint256 _baseFee,
        uint64 _chainKey,
        string memory _displayName,
        uint32 _timeoutBlocks
    ) ProverForTesting(_proceedsAccount, _costPerByte, _baseFee, _chainKey, _displayName, _timeoutBlocks) {}
}
