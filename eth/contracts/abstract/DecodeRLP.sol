// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "solidity-rlp/contracts/RLPReader.sol";
contract DecodeRLP {
    using RLPReader for RLPReader.RLPItem;
    using RLPReader for RLPReader.Iterator;
    using RLPReader for bytes;

    function decodeTransaction(bytes memory rlpEncodedTx) public pure returns (
        uint256 nonce,
        uint256 gasPrice,
        uint256 gasLimit,
        address to,
        uint256 value,
        bytes memory data,
        uint256 amount
    ) {
        RLPReader.RLPItem[] memory decodedTx = 
            rlpEncodedTx.toRlpItem().toList()[0].toBytes().toRlpItem().toList();
        nonce = decodedTx[0].toUint();
        gasPrice = decodedTx[1].toUint();
        gasLimit = decodedTx[2].toUint();
        to = decodedTx[3].toAddress();
        value = decodedTx[4].toUint();
        data = decodedTx[5].toBytes();
        assembly {
            amount := mload(add(data, 36))
        }
    }

}
