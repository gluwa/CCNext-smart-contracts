// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./TypeDecoder.sol";

/**
 * @dev To break ABI encoded data into 32-byte chunks and matches them to a type layout
 */
contract ABIChunker {
    struct DecodedChunk {
        bytes32 rawData; // The raw 32-byte chunk
        string dataType; // The type of data this chunk represents
        uint256 position; // Position in the original data (in chunks)
    }

    /**
     * @dev Splits ABI encoded data into 32-byte chunks
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
     * @dev Matches chunks to a type layout and decodes them
     * @param data The ABI encoded data
     * @param typeLayout A comma-separated string of types (e.g., "uint8,uint64,address")
     */
    function matchChunksToLayout(
        bytes calldata data,
        string calldata typeLayout
    ) public pure returns (DecodedChunk[] memory) {
        bytes32[] memory chunks = splitIntoChunks(data);
        string[] memory types = parseTypeLayout(typeLayout);

        // Create an array to hold all decoded chunks
        DecodedChunk[] memory decodedChunks = new DecodedChunk[](chunks.length);

        // Track which chunks have been processed
        bool[] memory processedChunks = new bool[](chunks.length);

        uint256 headChunkIndex;

        for (uint256 i; i < types.length && headChunkIndex < chunks.length; ) {
            string memory currentType = types[i];

            if (TypeDecoder.isStaticType(currentType)) {
                // Static types are stored directly in the data area
                decodedChunks[headChunkIndex] = DecodedChunk({
                    rawData: chunks[headChunkIndex],
                    dataType: currentType,
                    position: headChunkIndex
                });

                processedChunks[headChunkIndex] = true;
                headChunkIndex++;
            } else {
                // Dynamic types have an offset in the head area
                uint256 offset = uint256(chunks[headChunkIndex]);
                uint256 tailPosition = offset / 32; // Convert byte offset to chunk index

                // Mark the offset chunk
                decodedChunks[headChunkIndex] = DecodedChunk({
                    rawData: chunks[headChunkIndex],
                    dataType: string(
                        abi.encodePacked(currentType, " (offset)")
                    ),
                    position: headChunkIndex
                });

                processedChunks[headChunkIndex] = true;
                headChunkIndex++;

                // Process the dynamic data in the tail area
                if (tailPosition < chunks.length) {
                    if (TypeDecoder.compareStrings(currentType, "bytes")) {
                        processBytesType(
                            chunks,
                            decodedChunks,
                            processedChunks,
                            tailPosition
                        );
                    } else if (
                        TypeDecoder.compareStrings(currentType, "string")
                    ) {
                        processStringType(
                            chunks,
                            decodedChunks,
                            processedChunks,
                            tailPosition
                        );
                    } else if (TypeDecoder.startsWith(currentType, "(")) {
                        processTupleType(
                            chunks,
                            decodedChunks,
                            processedChunks,
                            tailPosition,
                            currentType
                        );
                    } else if (TypeDecoder.endsWith(currentType, "[]")) {
                        processArrayType(
                            chunks,
                            decodedChunks,
                            processedChunks,
                            tailPosition,
                            currentType
                        );
                    }
                }
            }

            unchecked {
                ++i;
            }
        }

        // Mark any remaining unprocessed chunks
        for (uint256 i; i < chunks.length; ) {
            if (!processedChunks[i]) {
                decodedChunks[i] = DecodedChunk({
                    rawData: chunks[i],
                    dataType: "unknown",
                    position: i
                });
            }
            unchecked {
                ++i;
            }
        }

        return decodedChunks;
    }

    /**
     * @dev Process a bytes type at the given tail position
     */
    function processBytesType(
        bytes32[] memory chunks,
        DecodedChunk[] memory decodedChunks,
        bool[] memory processedChunks,
        uint256 tailPosition
    ) internal pure {
        // First chunk in tail area is the length
        uint256 length = uint256(chunks[tailPosition]);

        decodedChunks[tailPosition] = DecodedChunk({
            rawData: chunks[tailPosition],
            dataType: "bytes (length)",
            position: tailPosition
        });

        processedChunks[tailPosition] = true;

        // Calculate how many chunks the data takes up
        uint256 dataChunks = (length + 31) / 32; // Ceiling division

        // Process data chunks
        for (
            uint256 i;
            i < dataChunks && tailPosition + 1 + i < chunks.length;

        ) {
            unchecked {
                decodedChunks[tailPosition + 1 + i] = DecodedChunk({
                    rawData: chunks[tailPosition + 1 + i],
                    dataType: "bytes (data)",
                    position: tailPosition + 1 + i
                });

                processedChunks[tailPosition + 1 + i] = true;
                ++i;
            }
        }
    }

    /**
     * @dev Process a string type at the given tail position
     */
    function processStringType(
        bytes32[] memory chunks,
        DecodedChunk[] memory decodedChunks,
        bool[] memory processedChunks,
        uint256 tailPosition
    ) internal pure {
        processBytesType(chunks, decodedChunks, processedChunks, tailPosition);

        // Just update the type label
        decodedChunks[tailPosition].dataType = "string (length)";

        uint256 length = uint256(chunks[tailPosition]);
        uint256 dataChunks = (length + 31) / 32;

        for (
            uint256 i;
            i < dataChunks && tailPosition + 1 + i < chunks.length;

        ) {
            unchecked {
                decodedChunks[tailPosition + 1 + i].dataType = "string (data)";
                ++i;
            }
        }
    }

    /**
     * @dev Process a tuple type at the given tail position
     */
    function processTupleType(
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
            dataType: "tuple (start)",
            position: tailPosition
        });

        processedChunks[tailPosition] = true;

        // Process each tuple element
        uint256 currentPosition = tailPosition + 1;
        string memory elementType;
        for (
            uint256 i;
            i < tupleElements.length && currentPosition < chunks.length;

        ) {
            elementType = tupleElements[i];

            if (TypeDecoder.isStaticType(elementType)) {
                decodedChunks[currentPosition] = DecodedChunk({
                    rawData: chunks[currentPosition],
                    dataType: string(
                        abi.encodePacked("tuple element (", elementType, ")")
                    ),
                    position: currentPosition
                });

                processedChunks[currentPosition] = true;
                currentPosition++;
            } else {
                // Dynamic types within tuples have their own offset
                uint256 elementOffset = uint256(chunks[currentPosition]);
                uint256 elementTailPosition = tailPosition + elementOffset / 32;

                decodedChunks[currentPosition] = DecodedChunk({
                    rawData: chunks[currentPosition],
                    dataType: string(
                        abi.encodePacked(
                            "tuple element (",
                            elementType,
                            " offset)"
                        )
                    ),
                    position: currentPosition
                });

                processedChunks[currentPosition] = true;
                currentPosition++;

                // Mark the dynamic data in the tail area
                if (elementTailPosition < chunks.length) {
                    decodedChunks[elementTailPosition] = DecodedChunk({
                        rawData: chunks[elementTailPosition],
                        dataType: string(
                            abi.encodePacked(
                                "tuple element (",
                                elementType,
                                " data)"
                            )
                        ),
                        position: elementTailPosition
                    });

                    processedChunks[elementTailPosition] = true;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Process an array type at the given tail position
     */
    function processArrayType(
        bytes32[] memory chunks,
        DecodedChunk[] memory decodedChunks,
        bool[] memory processedChunks,
        uint256 tailPosition,
        string memory arrayType
    ) internal pure {
        // First chunk in tail area is the array length
        uint256 length = uint256(chunks[tailPosition]);

        // Extract the element type from the array type
        string memory elementType = extractArrayElementType(arrayType);

        decodedChunks[tailPosition] = DecodedChunk({
            rawData: chunks[tailPosition],
            dataType: string(abi.encodePacked(arrayType, " (length)")),
            position: tailPosition
        });

        processedChunks[tailPosition] = true;

        // Process array elements
        uint256 currentPosition = tailPosition + 1;

        for (
            uint256 i = 0;
            i < length && currentPosition < chunks.length;
            i++
        ) {
            if (TypeDecoder.isStaticType(elementType)) {
                decodedChunks[currentPosition] = DecodedChunk({
                    rawData: chunks[currentPosition],
                    dataType: string(
                        abi.encodePacked(
                            arrayType,
                            " element (",
                            elementType,
                            ")"
                        )
                    ),
                    position: currentPosition
                });

                processedChunks[currentPosition] = true;
                currentPosition++;
            } else {
                // Dynamic types within arrays have their own offset
                uint256 elementOffset = uint256(chunks[currentPosition]);
                uint256 elementTailPosition = tailPosition + elementOffset / 32;

                decodedChunks[currentPosition] = DecodedChunk({
                    rawData: chunks[currentPosition],
                    dataType: string(
                        abi.encodePacked(
                            arrayType,
                            " element (",
                            elementType,
                            " offset)"
                        )
                    ),
                    position: currentPosition
                });

                processedChunks[currentPosition] = true;
                currentPosition++;

                // Mark the dynamic data in the tail area
                if (elementTailPosition < chunks.length) {
                    decodedChunks[elementTailPosition] = DecodedChunk({
                        rawData: chunks[elementTailPosition],
                        dataType: string(
                            abi.encodePacked(
                                arrayType,
                                " element (",
                                elementType,
                                " data)"
                            )
                        ),
                        position: elementTailPosition
                    });

                    processedChunks[elementTailPosition] = true;
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
        uint256 startPos = 0;
        uint256 typeIndex = 0;
        parenthesisDepth = 0;

        for (uint256 i = 0; i <= layoutBytes.length; i++) {
            if (
                i == layoutBytes.length ||
                (layoutBytes[i] == "," && parenthesisDepth == 0)
            ) {
                // Extract the type substring
                bytes memory typeBytes = new bytes(i - startPos);
                for (uint256 j = 0; j < i - startPos; j++) {
                    typeBytes[j] = layoutBytes[startPos + j];
                }
                types[typeIndex] = string(typeBytes);

                typeIndex++;
                startPos = i + 1;
            } else if (layoutBytes[i] == "(") {
                parenthesisDepth++;
            } else if (layoutBytes[i] == ")") {
                parenthesisDepth--;
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
        uint256 endPos = tupleBytes.length - 1;

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
        uint256 typeByteLength = typeBytes.length - 2;

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
