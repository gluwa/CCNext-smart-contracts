// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../abstract/TypeDecoder.sol";


library DataTypeHelper {
    enum DataType {
        UINT8,
        UINT16,
        UINT32,
        UINT64,
        UINT128,
        UINT256,
        INT8,
        INT16,
        INT32,
        INT64,
        INT128,
        INT256,
        ADDRESS,
        BOOL,
        BYTES1,
        BYTES2,
        BYTES4,
        BYTES8,
        BYTES16,
        BYTES32,
        BYTES,
        STRING,
        ARRAY,
        TUPLE,
        UNKNOWN
    }

     function getDataTypeFromString(
        string memory typeStr
    ) internal pure returns (DataType) {
        if (TypeDecoder.compareStrings(typeStr, "uint8")) return DataType.UINT8;
        if (TypeDecoder.compareStrings(typeStr, "uint16"))
            return DataType.UINT16;
        if (TypeDecoder.compareStrings(typeStr, "uint32"))
            return DataType.UINT32;
        if (TypeDecoder.compareStrings(typeStr, "uint64"))
            return DataType.UINT64;
        if (TypeDecoder.compareStrings(typeStr, "uint128"))
            return DataType.UINT128;
        if (TypeDecoder.compareStrings(typeStr, "uint256"))
            return DataType.UINT256;
        if (TypeDecoder.compareStrings(typeStr, "int8")) return DataType.INT8;
        if (TypeDecoder.compareStrings(typeStr, "int16")) return DataType.INT16;
        if (TypeDecoder.compareStrings(typeStr, "int32")) return DataType.INT32;
        if (TypeDecoder.compareStrings(typeStr, "int64")) return DataType.INT64;
        if (TypeDecoder.compareStrings(typeStr, "int128"))
            return DataType.INT128;
        if (TypeDecoder.compareStrings(typeStr, "int256"))
            return DataType.INT256;
        if (TypeDecoder.compareStrings(typeStr, "address"))
            return DataType.ADDRESS;
        if (TypeDecoder.compareStrings(typeStr, "bool")) return DataType.BOOL;
        if (TypeDecoder.compareStrings(typeStr, "bytes1"))
            return DataType.BYTES1;
        if (TypeDecoder.compareStrings(typeStr, "bytes2"))
            return DataType.BYTES2;
        if (TypeDecoder.compareStrings(typeStr, "bytes4"))
            return DataType.BYTES4;
        if (TypeDecoder.compareStrings(typeStr, "bytes8"))
            return DataType.BYTES8;
        if (TypeDecoder.compareStrings(typeStr, "bytes16"))
            return DataType.BYTES16;
        if (TypeDecoder.compareStrings(typeStr, "bytes32"))
            return DataType.BYTES32;
        if (TypeDecoder.compareStrings(typeStr, "bytes")) return DataType.BYTES;
        if (TypeDecoder.compareStrings(typeStr, "string"))
            return DataType.STRING;
        if (TypeDecoder.endsWith(typeStr, "[]")) return DataType.ARRAY;
        if (TypeDecoder.startsWith(typeStr, "(")) return DataType.TUPLE;

        return DataType.UNKNOWN;
    }

    function isTypeDynamic(
        DataType dataType,
        string memory typeStr
    ) internal pure returns (bool) {
        if (
            dataType == DataType.BYTES ||
            dataType == DataType.STRING ||
            dataType == DataType.ARRAY ||
            dataType == DataType.TUPLE
        ) {
            return true;
        }

        if (dataType == DataType.ARRAY) {
            bytes memory typeBytes = bytes(typeStr);
            bool hasFixedSize = false;
            uint typeByteLength = typeBytes.length;
            for (uint256 i; i < typeBytes.length; ) {
                if (
                    typeBytes[i] == "[" &&
                    i + 1 < typeByteLength &&
                    typeBytes[i + 1] != "]"
                ) {
                    hasFixedSize = true;
                    break;
                }
                unchecked {
                    ++i;
                }
            }

            return !hasFixedSize;
        }

        return false;
    }
}
