// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@gluwa/universal-smart-contract/contracts/abstract/Types.sol";
import {DecodeRLP} from "@gluwa/universal-smart-contract/contracts/abstract/DecodeRLP.sol";

import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UniversalBridgeProxy} from "@gluwa/universal-smart-contract/contracts/UniversalBridgeProxy.sol";
import {ICreditcoinPublicProver} from "@gluwa/universal-smart-contract/contracts/Prover.sol";

/**
 * @dev User-defined implementation contract containing hook logic for:
 *  - Performing additional validations
 *  - Formatting and normalizing data
 *  - Managing and processing fees
 *  - Enforcing access control
 *  - Handling messaging and notifications
 */
contract UniversalBridgeProxyImpl is
    UniversalBridgeProxy
{
    // keccak256(abi.encode(uint256(keccak256("usc.storage.UniversalBridgeProxyV1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ProxyStorageLocation =
         0x5a424ef2997b7c86f52bf52e034f4a31d38a6c1e378677e01757465f39d04700;


    /// @dev we will include hook logic for: addtional validation, data formatting and wapping process

}
