// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Custom types
import {Pointer} from "@types/Pointer.sol";

/// @title MetadataStore: Cost-effective structured data storage.
/// @notice Base contract that can store two-deep objects with large value sizes at deployment time.
/// @author Axicon Labs Limited
contract MetadataStore {
    /// @notice Stores metadata pointers for future retrieval.
    /// @dev Can hold 2-deep object structures.
    /// @dev Examples include `{"A": ["B", "C"]}` and `{"A": {"B": "C"}}`.
    /// @dev The first and second keys can be up-to-32-char strings (or array indices.
    /// @dev Values are pointers to a certain section of contract code: [address, start, length].
    /// @dev The maximum size of a value is theoretically unlimited, but depends on the effective contract size limit for a given chain.
    mapping(bytes32 property => mapping(uint256 index => Pointer pointer)) internal metadata;

    /// @notice Stores provided metadata pointers for future retrieval.
    /// @param properties An array of identifiers for different categories of metadata
    /// @param indices A nested array of keys for K-V metadata pairs for each property in `properties`
    /// @param pointers Contains pointers to the metadata values stored in contract data slices for each index in `indices`
    constructor(
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    ) {
        for (uint256 i = 0; i < properties.length; i++) {
            for (uint256 j = 0; j < indices[i].length; j++) {
                metadata[properties[i]][indices[i][j]] = pointers[i][j];
            }
        }
    }
}
