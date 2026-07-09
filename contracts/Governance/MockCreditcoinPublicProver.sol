// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@gluwa/creditcoin-public-prover/contracts/sol/Types.sol";
import {ICreditcoinPublicProver} from "@gluwa/creditcoin-public-prover/contracts/sol/Prover.sol";

contract MockCreditcoinPublicProver is ICreditcoinPublicProver {
    mapping(bytes32 => QueryDetails) private queries;

    function setTallyQuery(
        bytes32 queryId,
        QueryState state,
        uint64 sourceChainId,
        address principal,
        address emitter,
        bytes32 eventSignature,
        uint256 proposalId,
        uint64 eventChainKey,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes
    ) external {
        QueryDetails storage queryDetails = queries[queryId];
        queryDetails.state = state;
        queryDetails.query.chainId = sourceChainId;
        queryDetails.query.height = 1;
        queryDetails.query.index = 1;
        queryDetails.principal = principal;
        queryDetails.timestamp = block.timestamp;

        delete queryDetails.query.layoutSegments;
        for (uint64 i; i < 10; ) {
            queryDetails.query.layoutSegments.push(LayoutSegment({offset: i * 32, size: 32}));
            unchecked {
                ++i;
            }
        }

        delete queryDetails.resultSegments;
        queryDetails.resultSegments.push(_segment(0, bytes32(uint256(1))));
        queryDetails.resultSegments.push(_segment(32, bytes32(0)));
        queryDetails.resultSegments.push(_segment(64, bytes32(0)));
        queryDetails.resultSegments.push(_segment(96, bytes32(uint256(uint160(emitter)))));
        queryDetails.resultSegments.push(_segment(128, eventSignature));
        queryDetails.resultSegments.push(_segment(160, bytes32(proposalId)));
        queryDetails.resultSegments.push(_segment(192, bytes32(uint256(eventChainKey))));
        queryDetails.resultSegments.push(_segment(224, bytes32(forVotes)));
        queryDetails.resultSegments.push(_segment(256, bytes32(againstVotes)));
        queryDetails.resultSegments.push(_segment(288, bytes32(abstainVotes)));
    }

    function getQueryDetails(
        bytes32 queryId
    ) external view override returns (QueryDetails memory queryDetails) {
        return queries[queryId];
    }

    function setReceiptStatus(bytes32 queryId, uint256 status) external {
        queries[queryId].resultSegments[0].abiBytes = bytes32(status);
    }

    function setLayoutSegment(
        bytes32 queryId,
        uint256 index,
        uint64 offset,
        uint64 size
    ) external {
        queries[queryId].query.layoutSegments[index] = LayoutSegment({offset: offset, size: size});
    }

    function _segment(uint256 offset, bytes32 abiBytes) private pure returns (ResultSegment memory) {
        return ResultSegment({offset: offset, abiBytes: abiBytes});
    }
}
