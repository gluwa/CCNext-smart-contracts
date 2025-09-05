// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@gluwa/creditcoin-public-prover/contracts/sol/Types.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UniversalSmartContract_Core} from "./UniversalSmartContract_Core.sol";

abstract contract MintableUSCBridge is UniversalSmartContract_Core, ERC20 {
    event TokensMinted(
        address indexed token,
        address indexed recipient,
        uint256 amount,
        bytes32 indexed queryId
    );

    error InvalidFunctionSignature();
    error InvalidSegmentLength();
    error ZeroAmount();
    error InvalidBurnAddress();
    error InvalidRecipient();
    error QueryAlreadyProcessed();

    bytes4 private constant TRANSFER_EVENT_SIG = 0xddf252ad;
    mapping(bytes32 => bool) public processedQueries;

    /// @notice Executes USC query processing and mints based on extracted Transfer event
    function mintFromQuery(
        address proverContractAddr,
        bytes32 queryId
    ) external {
        if (processedQueries[queryId]) revert QueryAlreadyProcessed();
        processedQueries[queryId] = true;

        // Get function signature and event data
        (
            bytes32 functionSig,
            ResultSegment[] memory eventSegments
        ) = _processUSCQuery(proverContractAddr, queryId);

        if (bytes4(functionSig) != TRANSFER_EVENT_SIG)
            revert InvalidFunctionSignature();
        if (eventSegments.length < 3) revert InvalidSegmentLength();

        address from = address(
            uint160(uint256(bytes32(eventSegments[0].abiBytes)))
        );
        address to = address(
            uint160(uint256(bytes32(eventSegments[1].abiBytes)))
        );
        uint256 amount = uint256(bytes32(eventSegments[2].abiBytes));
        
        if (amount == 0) revert ZeroAmount();
        if (to != address(0)) revert InvalidBurnAddress();
        if (from == address(0)) revert InvalidRecipient();

        // Mint tokens on destination chain
        _mint(from, amount);

        emit TokensMinted(address(this), from, amount, queryId);
    }

    function _toAddress(bytes memory data) internal pure returns (address) {
        return abi.decode(data, (address));
    }

    function _toUint256(bytes memory data) internal pure returns (uint256) {
        return abi.decode(data, (uint256));
    }

    function _onQueryValidated(
        bytes32,
        bytes32,
        ResultSegment[] memory
    ) internal virtual override {
        // Hook for extended logic
    }
}
