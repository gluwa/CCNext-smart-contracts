// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./MintableUSCBridge.sol";

contract YourToken is ERC20, MintableUSCBridge {

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
    }

    function _onQueryValidated(
        bytes32,
        bytes32,
        ResultSegment[] memory
    ) internal override {
        // Your constructor business logic will be here...
    }

    // More logic below...    
}
