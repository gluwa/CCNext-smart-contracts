// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library TypeDecoder {
    error UnsupportedType(string typeName);
    error InvalidLayout(string layout);
    error DecodingError(string reason);

    function compareStrings(
        string memory stringA,
        string memory stringB
    ) internal pure returns (bool) {
        return
            keccak256(abi.encodePacked(stringA)) ==
            keccak256(abi.encodePacked(stringB));
    }

    function bytes32ToUint(bytes memory data) internal pure returns (uint) {
        return uint(bytes32(data));
    }

    function toUint256(bytes memory data) internal pure returns (uint256) {
        require(data.length >= 32, "Data too short for uint256");
        uint256 value;
        assembly {
            value := mload(add(data, 32))
        }
        return value;
    }

    function toAddress(bytes memory data) internal pure returns (address) {
        require(data.length >= 32, "Data too short for address");
        uint256 value;
        assembly {
            value := mload(add(data, 32))
        }
        return address(uint160(value));
    }

    function toBytes32(bytes memory data) internal pure returns (bytes32) {
        require(data.length >= 32, "Data too short for bytes32");
        bytes32 value;
        assembly {
            value := mload(add(data, 32))
        }
        return value;
    }

    function extractBytes(
        bytes calldata encodedData,
        uint256 offset,
        uint256 length
    ) internal pure returns (bytes memory) {
        require(offset + length <= encodedData.length, "Offset out of bounds");
        bytes memory value = new bytes(length);
        for (uint256 i; i < length;) {
            value[i] = encodedData[offset + i];
            unchecked {
                ++i;
            }
        }
        return value;
    }

    function slice(
        bytes memory data,
        uint256 start,
        uint256 length
    ) internal pure returns (bytes memory) {
        require(start + length <= data.length, "Slice out of bounds");
        bytes memory result = new bytes(length);
        for (uint256 i; i < length;) {
            result[i] = data[start + i];
            unchecked {
                ++i;
            }
        }
        return result;
    }

    function startsWith(
        string memory str,
        string memory prefix
    ) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);
        uint prefixByteLength = prefixBytes.length;
        if (strBytes.length < prefixByteLength) {
            return false;
        }
        for (uint256 i; i < prefixByteLength;) {
            if (strBytes[i] != prefixBytes[i]) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function endsWith(
        string memory str,
        string memory suffix
    ) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory suffixBytes = bytes(suffix);
        uint suffixByteLength = suffixBytes.length;
        if (strBytes.length < suffixByteLength) {
            return false;
        }
        for (uint256 i; i < suffixByteLength;) {
            if (
                strBytes[strBytes.length - suffixByteLength + i] !=
                suffixBytes[i]
            ) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function substring(
        string memory str,
        uint256 startIndex,
        uint256 endIndex
    ) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        require(
            startIndex <= endIndex && endIndex <= strBytes.length,
            "Invalid substring indices"
        );
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex;) {
            result[i - startIndex] = strBytes[i];
            unchecked {
                ++i;
            }
        }
        return string(result);
    }

    function isTupleType(
        string memory typeDescription
    ) internal pure returns (bool) {
        bytes memory typeBytes = bytes(typeDescription);
        if (typeBytes.length < 6) {
            return false;
        }
        return (typeBytes[0] == "t" &&
            typeBytes[1] == "u" &&
            typeBytes[2] == "p" &&
            typeBytes[3] == "l" &&
            typeBytes[4] == "e" &&
            typeBytes[5] == "(");
    }

    function isArrayType(
        string memory typeDescription
    ) internal pure returns (bool) {
        bytes memory typeBytes = bytes(typeDescription);
        for (uint256 i; i < typeBytes.length;) {
            if (typeBytes[i] == "[") {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function isStaticType(string memory typeName) internal pure returns (bool) {
        if (
            compareStrings(typeName, "string") ||
            compareStrings(typeName, "bytes") ||
            endsWith(typeName, "[]") ||
            startsWith(typeName, "tuple(")
        ) {
            return false;
        }
        return true;
    }

    function isDynamicType(
        string memory typeDescription
    ) internal pure returns (bool) {
        bytes memory typeBytes = bytes(typeDescription);
        if (
            typeBytes.length >= 2 &&
            typeBytes[typeBytes.length - 2] == "[" &&
            typeBytes[typeBytes.length - 1] == "]"
        ) {
            return true;
        }
        bytes32 typeHash = keccak256(abi.encodePacked(typeDescription));
        if (
            typeHash == keccak256(abi.encodePacked("bytes")) ||
            typeHash == keccak256(abi.encodePacked("string"))
        ) {
            return true;
        }
        if (isTupleType(typeDescription)) {
            string[] memory components = parseTupleComponents(typeDescription);
            for (uint256 i; i < components.length;) {
                if (isDynamicType(components[i])) {
                    return true;
                }
                unchecked {
                    ++i;
                }
            }
        }
        return false;
    }

    function parseTupleComponents(
        string memory tupleType
    ) internal pure returns (string[] memory) {
        bytes memory typeBytes = bytes(tupleType);
        uint256 openParenIndex;
        uint256 closeParenIndex = typeBytes.length - 1;
        for (uint256 i; i < typeBytes.length;) {
            if (typeBytes[i] == "(") {
                openParenIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }
        for (uint256 i = typeBytes.length - 1; i > 0;) {
            if (typeBytes[i] == ")") {
                closeParenIndex = i;
                break;
            }
            unchecked {
                --i;
            }
        }
        bytes memory componentsBytes = new bytes(
            closeParenIndex - openParenIndex - 1
        );
        for (uint256 i; i < componentsBytes.length;) {
            componentsBytes[i] = typeBytes[openParenIndex + 1 + i];
            unchecked {
                ++i;
            }
        }
        uint256 commaCount;
        uint256 nestedLevel;
        for (uint256 i; i < componentsBytes.length;) {
            if (componentsBytes[i] == "(") {
                nestedLevel++;
            } else if (componentsBytes[i] == ")") {
                nestedLevel--;
            } else if (componentsBytes[i] == "," && nestedLevel == 0) {
                commaCount++;
            }
            unchecked {
                ++i;
            }
        }
        string[] memory components = new string[](commaCount + 1);
        uint256 startPos;
        uint256 componentIndex;
        nestedLevel = 0;
        uint byteLength = componentsBytes.length;
        for (uint256 i; i <= byteLength;) {
            if (
                i == byteLength ||
                (componentsBytes[i] == "," && nestedLevel == 0)
            ) {
                bytes memory componentBytes = new bytes(i - startPos);
                for (uint256 j; j < i - startPos;) {
                    componentBytes[j] = componentsBytes[startPos + j];
                    unchecked {
                        ++j;
                    }
                }
                components[componentIndex] = string(componentBytes);
                componentIndex++;
                startPos = i + 1;
            } else if (componentsBytes[i] == "(") {
                nestedLevel++;
            } else if (componentsBytes[i] == ")") {
                nestedLevel--;
            }
            unchecked {
                ++i;
            }
        }
        return components;
    }

    function parseArrayType(
        string memory arrayType
    )
        internal
        pure
        returns (
            string memory elementType,
            uint256 length,
            bool isDynamicLength
        )
    {
        bytes memory typeBytes = bytes(arrayType);
        uint256 openBracketIndex;
        for (uint256 i; i < typeBytes.length;) {
            if (typeBytes[i] == "[") {
                openBracketIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }
        bytes memory elementTypeBytes = new bytes(openBracketIndex);
        for (uint256 i; i < openBracketIndex;) {
            elementTypeBytes[i] = typeBytes[i];
            unchecked {
                ++i;
            }
        }
        elementType = string(elementTypeBytes);
        if (
            openBracketIndex + 1 < typeBytes.length &&
            typeBytes[openBracketIndex + 1] == "]"
        ) {
            isDynamicLength = true;
            length = 0;
        } else {
            isDynamicLength = false;
            uint256 closeBracketIndex;
            uint loopLength = typeBytes.length;
            for (uint256 i = openBracketIndex + 1; i < length;) {
                if (typeBytes[i] == "]") {
                    closeBracketIndex = i;
                    break;
                }
                unchecked {
                    ++i;
                }
            }
            bytes memory lengthBytes = new bytes(
                closeBracketIndex - openBracketIndex - 1
            );
            loopLength =  lengthBytes.length;
            for (uint256 i; i < length;) {
                lengthBytes[i] = typeBytes[openBracketIndex + 1 + i];
                unchecked {
                    ++i;
                }
            }
            length = parseDecimalString(string(lengthBytes));
        }
        return (elementType, length, isDynamicLength);
    }

    function parseDecimalString(
        string memory decimalString
    ) internal pure returns (uint256) {
        bytes memory stringBytes = bytes(decimalString);
        uint256 result;
        uint8 digit;
        for (uint256 i; i < stringBytes.length;) {
            digit = uint8(stringBytes[i]) - 48;
            require(digit <= 9, "Invalid decimal string");
            result = result * 10 + digit;
            unchecked {
                ++i;
            }
        }
        return result;
    }
}