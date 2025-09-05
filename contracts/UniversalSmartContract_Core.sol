// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@gluwa/creditcoin-public-prover/contracts/sol/Types.sol";
import {ICreditcoinPublicProver} from "@gluwa/creditcoin-public-prover/contracts/sol/Prover.sol";

abstract contract UniversalSmartContract_Core  {
    bytes32 private constant USCStorageLocation =
        0x6873a84df95308b16f5c8aa284ac06f406edc8315b9626bdacc9b42f5ee1d200;

    struct USCStorage {
        mapping(address => mapping(bytes32 => bool)) usedQueryId;
    }

    function _getUSCStorage() internal pure returns (USCStorage storage $) {
        assembly {
            $.slot := USCStorageLocation
        }
    }

    function isQueryUsed(
        address user,
        bytes32 queryId
    ) public view returns (bool) {
        return _getUSCStorage().usedQueryId[user][queryId];
    }

    function _markQueryUsed(address user, bytes32 queryId) internal {
        _getUSCStorage().usedQueryId[user][queryId] = true;
    }

    /// @notice Processes a query from the prover and extracts data, deferring action to child contract
    function _processUSCQuery(
        address proverContractAddr,
        bytes32 queryId
    ) internal returns(bytes32 functionSignature, ResultSegment[] memory eventSegments) {
        USCStorage storage $ = _getUSCStorage();
        require(
            !$.usedQueryId[proverContractAddr][queryId],
            "QueryId already used"
        );

        ICreditcoinPublicProver prover = ICreditcoinPublicProver(
            proverContractAddr
        );
        QueryDetails memory queryDetails = prover.getQueryDetails(queryId);
        ResultSegment[] memory resultSegments = queryDetails.resultSegments;

        require(resultSegments.length >= 8, "Invalid result length");
        functionSignature = resultSegments[4].abiBytes;

        uint256 resultLength = resultSegments.length;
        eventSegments = new ResultSegment[](resultLength - 5);
        for (uint256 i = 5; i < resultLength;) {
            eventSegments[i] = resultSegments[i];
            unchecked {
                ++i;
            }
        }       

        // Hook validation logic for implementation contract to use 
        _onQueryValidated(queryId, functionSignature, eventSegments);
    }

    /// @dev Must be implemented by child contract to handle validated data
    function _onQueryValidated(
        bytes32 queryId,
        bytes32 functionSignature,
        ResultSegment[] memory eventSegments
    ) internal virtual;
}
