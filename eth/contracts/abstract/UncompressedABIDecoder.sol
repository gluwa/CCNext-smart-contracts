// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./TypeDecoder.sol";
import "../utility/Console.sol";
import "../utility/DataTypeHelper.sol";


/**
 * @dev A contract that breaks ABI encoded data into 32-byte chunks and provides generic decoding based on type layout
 */
contract UncompressedABIDecoder {   

    struct DecodedChunk {
        bytes32 rawData; // The raw 32-byte chunk
        DataTypeHelper.DataType dataType; // The type of data this chunk represents
        string typeString; // String representation of the type
        uint256 position; // Position in the original data (in chunks)
        bool isDynamic;
        bool isOffset;
    }

    /**
     * @param data The ABI encoded data to split
     */
    function splitIntoChunks(
        bytes calldata data
    ) public pure returns (bytes32[] memory) {
        require(
            data.length % 32 == 0,
            "Data length must be a multiple of 32 bytes"
        );

        uint256 chunkCount = data.length / 32;
        bytes32[] memory chunks = new bytes32[](chunkCount);

        for (uint256 i; i < chunkCount; ) {
            bytes32 chunk;
            // Copy 32 bytes from the data at position i*32
            assembly {
                chunk := calldataload(add(data.offset, mul(i, 32)))
            }
            chunks[i] = chunk;
            unchecked {
                ++i;
            }
        }

        return chunks;
    }

    /**
     * @dev Decodes ABI encoded data according to a type layout
     * @param data The ABI encoded data
     * @param typeLayout A comma-separated string of types (e.g., "uint8,uint64,address")
     */
    function genericDecodeData(
        bytes calldata data,
        string calldata typeLayout
    ) public pure returns (DecodedChunk[] memory) {
        bytes32[] memory chunks = splitIntoChunks(data);
        string[] memory types = parseTypeLayout(typeLayout);

        // Create an array to hold all decoded chunks
        DecodedChunk[] memory decodedChunks = new DecodedChunk[](chunks.length);

        // Track which chunks have been processed
        bool[] memory processedChunks = new bool[](chunks.length);

        // Process the data according to the type layout
        uint256 headIndex;

        for (uint256 i; i < types.length && headIndex < chunks.length; ) {
            string memory typeStr = types[i];
            DataTypeHelper.DataType dataType = DataTypeHelper.getDataTypeFromString(typeStr);
            bool isDynamic = DataTypeHelper.isTypeDynamic(dataType, typeStr);

            if (!isDynamic) {
                // Static types are stored directly in the data area
                decodedChunks[headIndex] = DecodedChunk({
                    rawData: chunks[headIndex],
                    dataType: dataType,
                    typeString: typeStr,
                    position: headIndex,
                    isDynamic: false,
                    isOffset: false
                });

                processedChunks[headIndex] = true;
                headIndex++;
            } else {
                // Dynamic types have an offset in the head area
                uint256 offset = uint256(chunks[headIndex]);
                uint256 tailPosition = offset / 32; // Convert byte offset to chunk index

                // Mark the offset chunk
                decodedChunks[headIndex] = DecodedChunk({
                    rawData: chunks[headIndex],
                    dataType: dataType,
                    typeString: string(abi.encodePacked(typeStr, " (offset)")),
                    position: headIndex,
                    isDynamic: true,
                    isOffset: true
                });

                processedChunks[headIndex] = true;
                headIndex++;

                // Process the dynamic data in the tail area
                if (tailPosition < chunks.length) {
                    processDynamicType(
                        chunks,
                        decodedChunks,
                        processedChunks,
                        tailPosition,
                        dataType,
                        typeStr
                    );
                }
            }

            unchecked {
                ++i;
            }
        }

        // Mark any remaining unprocessed chunks
        for (uint256 i = 0; i < chunks.length; i++) {
            if (!processedChunks[i]) {
                decodedChunks[i] = DecodedChunk({
                    rawData: chunks[i],
                    dataType: DataTypeHelper.DataType.UNKNOWN,
                    typeString: "unknown",
                    position: i,
                    isDynamic: false,
                    isOffset: false
                });
            }
        }

        return decodedChunks;
    }

    /**
     * @dev Process a dynamic type at the given tail position
     */
    function processDynamicType(
        bytes32[] memory chunks,
        DecodedChunk[] memory decodedChunks,
        bool[] memory processedChunks,
        uint256 tailPosition,
        DataTypeHelper.DataType dataType,
        string memory typeStr
    ) internal pure {
        if (dataType == DataTypeHelper.DataType.BYTES || dataType == DataTypeHelper.DataType.STRING) {
            processBytesOrString(
                chunks,
                decodedChunks,
                processedChunks,
                tailPosition,
                dataType,
                typeStr
            );
        } else if (dataType == DataTypeHelper.DataType.ARRAY) {
            processArray(
                chunks,
                decodedChunks,
                processedChunks,
                tailPosition,
                typeStr
            );
        } else if (dataType == DataTypeHelper.DataType.TUPLE) {
            processTuple(
                chunks,
                decodedChunks,
                processedChunks,
                tailPosition,
                typeStr
            );
        }
    }

    /**
     * @dev Process bytes or string type at the given tail position
     */
    function processBytesOrString(
        bytes32[] memory chunks,
        DecodedChunk[] memory decodedChunks,
        bool[] memory processedChunks,
        uint256 tailPosition,
        DataTypeHelper.DataType dataType,
        string memory typeStr
    ) internal pure {
        // First chunk in tail area is the length
        uint256 length = uint256(chunks[tailPosition]);

        decodedChunks[tailPosition] = DecodedChunk({
            rawData: chunks[tailPosition],
            dataType: dataType,
            typeString: string(abi.encodePacked(typeStr, " (length)")),
            position: tailPosition,
            isDynamic: true,
            isOffset: false
        });

        processedChunks[tailPosition] = true;

        // How many chunks the data takes up
        uint256 dataChunks = (length + 31) / 32;

        // Process data chunks
        for (
            uint256 i = 0;
            i < dataChunks && tailPosition + 1 + i < chunks.length;
            i++
        ) {
            decodedChunks[tailPosition + 1 + i] = DecodedChunk({
                rawData: chunks[tailPosition + 1 + i],
                dataType: dataType,
                typeString: string(abi.encodePacked(typeStr, " (data)")),
                position: tailPosition + 1 + i,
                isDynamic: true,
                isOffset: false
            });

            processedChunks[tailPosition + 1 + i] = true;
        }
    }

    /**
     * @dev Process an array type at the given tail position
     */
    function processArray(
        bytes32[] memory chunks,
        DecodedChunk[] memory decodedChunks,
        bool[] memory processedChunks,
        uint256 tailPosition,
        string memory typeStr
    ) internal pure {
        // First chunk in tail area is the array length
        uint256 length = uint256(chunks[tailPosition]);

        string memory elementTypeStr = extractArrayElementType(typeStr);
        DataTypeHelper.DataType elementType = DataTypeHelper.getDataTypeFromString(elementTypeStr);
        bool isElementDynamic = DataTypeHelper.isTypeDynamic(elementType, elementTypeStr);

        decodedChunks[tailPosition] = DecodedChunk({
            rawData: chunks[tailPosition],
            dataType: DataTypeHelper.DataType.ARRAY,
            typeString: string(abi.encodePacked(typeStr, " (length)")),
            position: tailPosition,
            isDynamic: true,
            isOffset: false
        });

        processedChunks[tailPosition] = true;

        // Process array elements
        uint256 currentPosition = tailPosition + 1;

        for (
            uint256 i = 0;
            i < length && currentPosition < chunks.length;
            i++
        ) {
            if (!isElementDynamic) {
                decodedChunks[currentPosition] = DecodedChunk({
                    rawData: chunks[currentPosition],
                    dataType: elementType,
                    typeString: string(
                        abi.encodePacked(
                            typeStr,
                            " element: ",
                            elementTypeStr                           
                        )
                    ),
                    position: currentPosition,
                    isDynamic: false,
                    isOffset: false
                });

                processedChunks[currentPosition] = true;
                currentPosition++;
            } else {
                // Dynamic types within arrays have their own offset
                uint256 elementOffset = uint256(chunks[currentPosition]);
                uint256 elementTailPosition = tailPosition + elementOffset / 32;

                decodedChunks[currentPosition] = DecodedChunk({
                    rawData: chunks[currentPosition],
                    dataType: elementType,
                    typeString: string(
                        abi.encodePacked(
                            typeStr,
                            " element (",
                            elementTypeStr,
                            " offset)"
                        )
                    ),
                    position: currentPosition,
                    isDynamic: true,
                    isOffset: true
                });

                processedChunks[currentPosition] = true;
                currentPosition++;

                // Process the dynamic element in the tail area
                if (elementTailPosition < chunks.length) {
                    processDynamicType(
                        chunks,
                        decodedChunks,
                        processedChunks,
                        elementTailPosition,
                        elementType,
                        elementTypeStr
                    );
                }
            }
        }
    }

    /**
     * @dev Process a tuple type at the given tail position
     */
    function processTuple(
        bytes32[] memory chunks,
        DecodedChunk[] memory decodedChunks,
        bool[] memory processedChunks,
        uint256 tailPosition,
        string memory tupleType
    ) internal pure {
        // Extract the tuple elements from the type string
        string[] memory tupleElements = parseTupleElements(tupleType);

        // Mark the start of tuple data
        decodedChunks[tailPosition] = DecodedChunk({
            rawData: chunks[tailPosition],
            dataType: DataTypeHelper.DataType.TUPLE,
            typeString: "tuple (start)",
            position: tailPosition,
            isDynamic: true,
            isOffset: false
        });

        processedChunks[tailPosition] = true;

        // Process each tuple element
        uint256 currentPosition = tailPosition + 1;
        for (
            uint256 i = 0;
            i < tupleElements.length && currentPosition < chunks.length;
            i++
        ) {
            string memory elementTypeStr = tupleElements[i];
            DataTypeHelper.DataType elementType = DataTypeHelper.getDataTypeFromString(elementTypeStr);
            bool isElementDynamic = DataTypeHelper.isTypeDynamic(elementType, elementTypeStr);

            if (!isElementDynamic) {
                decodedChunks[currentPosition] = DecodedChunk({
                    rawData: chunks[currentPosition],
                    dataType: elementType,
                    typeString: string(
                        abi.encodePacked("tuple element (", elementTypeStr, ")")
                    ),
                    position: currentPosition,
                    isDynamic: false,
                    isOffset: false
                });

                processedChunks[currentPosition] = true;
                currentPosition++;
            } else {
                // Dynamic types within tuples have their own offset
                uint256 elementOffset = uint256(chunks[currentPosition]);
                uint256 elementTailPosition = tailPosition + elementOffset / 32;

                decodedChunks[currentPosition] = DecodedChunk({
                    rawData: chunks[currentPosition],
                    dataType: elementType,
                    typeString: string(
                        abi.encodePacked(
                            "tuple element (",
                            elementTypeStr,
                            " offset)"
                        )
                    ),
                    position: currentPosition,
                    isDynamic: true,
                    isOffset: true
                });

                processedChunks[currentPosition] = true;
                currentPosition++;

                // Process the dynamic element in the tail area
                if (elementTailPosition < chunks.length) {
                    processDynamicType(
                        chunks,
                        decodedChunks,
                        processedChunks,
                        elementTailPosition,
                        elementType,
                        elementTypeStr
                    );
                }
            }
        }
    }
   

    /**
     * @dev Parses a type layout string into an array of individual types
     * @param typeLayout The comma-separated type layout string
     */
    function parseTypeLayout(
        string memory typeLayout
    ) public pure returns (string[] memory) {
        // Count the number of types by counting commas
        uint256 typeCount = 1;
        bytes memory layoutBytes = bytes(typeLayout);

        uint256 parenthesisDepth = 0;
        for (uint256 i = 0; i < layoutBytes.length; i++) {
            if (layoutBytes[i] == "(") {
                parenthesisDepth++;
            } else if (layoutBytes[i] == ")") {
                parenthesisDepth--;
            } else if (layoutBytes[i] == "," && parenthesisDepth == 0) {
                typeCount++;
            }
        }

        string[] memory types = new string[](typeCount);

        // Split the type layout by commas, respecting parentheses
        uint256 startPos;
        uint256 typeIndex;
        parenthesisDepth = 0;
        uint256 layoutByteLength = layoutBytes.length;
        for (uint256 i; i <= layoutByteLength; ) {
            if (
                i == layoutByteLength ||
                (layoutBytes[i] == "," && parenthesisDepth == 0)
            ) {
                // Extract the type substring
                bytes memory typeBytes = new bytes(i - startPos);
                for (uint256 j; j < i - startPos; ) {
                    typeBytes[j] = layoutBytes[startPos + j];
                    unchecked {
                        ++j;
                    }
                }
                types[typeIndex] = string(typeBytes);

                typeIndex++;
                startPos = i + 1;
            } else if (layoutBytes[i] == "(") {
                parenthesisDepth++;
            } else if (layoutBytes[i] == ")") {
                parenthesisDepth--;
            }
            unchecked {
                ++i;
            }
        }

        return types;
    }

    /**
     * @dev Parses the elements of a tuple type
     * @param tupleType The tuple type string (e.g., "(address,bytes32[],bytes)")
     */
    function parseTupleElements(
        string memory tupleType
    ) public pure returns (string[] memory) {
        // Remove the outer parentheses
        bytes memory tupleBytes = bytes(tupleType);

        // Find the content inside the parentheses
        uint256 startPos = 1;
        uint256 endPos = tupleBytes.length -1;
        
        // Extract the content inside the parentheses
        bytes memory contentBytes = new bytes(endPos - startPos);
        for (uint256 i; i < endPos - startPos; ) {
            contentBytes[i] = tupleBytes[startPos + i];
            unchecked {
                ++i;
            }
        }

        return parseTypeLayout(string(contentBytes));
    }

    /**
     * @dev Extracts the element type from an array type
     * @param arrayType The array type string (e.g., "uint256[]" or "tuple(address,bytes32[],bytes)[]")
     */
    function extractArrayElementType(
        string memory arrayType
    ) public pure returns (string memory) {
        bytes memory typeBytes = bytes(arrayType);
        // The last 2 is []
        uint256 typeByteLength = typeBytes.length -2;

        bytes memory elementTypeBytes = new bytes(typeByteLength);
        for (uint256 i; i < typeByteLength; ) {
             elementTypeBytes[i] = typeBytes[i];
            unchecked {
                ++i;
            }
        }

        return string(elementTypeBytes);
    }   
}