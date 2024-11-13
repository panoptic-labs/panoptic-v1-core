// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

// Libraries
import {LibZip} from "solady/utils/LibZip.sol";

type Pointer is uint256;
using PointerLibrary for Pointer global;

/// @notice Data type that represents a pointer to a slice of contract code at an address.
/// @author Axicon Labs Limited
library PointerLibrary {
    /// @notice Create a pointer to a slice of contract code at an address.
    /// @param _location The address of the contract code
    /// @param _start The starting position of the slice
    /// @param _size The size of the slice
    function createPointer(
        address _location,
        uint48 _start,
        uint48 _size
    ) internal pure returns (Pointer) {
        return
            Pointer.wrap((uint256(_size) << 208) + (uint256(_start) << 160) + uint160(_location));
    }

    /// @notice Get the address of the pointed contract code from a pointer.
    /// @param self The pointer to the slice of contract code
    /// @return The address of the contract code
    function location(Pointer self) internal pure returns (address) {
        return address(uint160(Pointer.unwrap(self)));
    }

    /// @notice Get the starting position of the pointed slice from a pointer.
    /// @param self The pointer to the section of contract code
    /// @return The starting position of the slice
    function start(Pointer self) internal pure returns (uint48) {
        return uint48(Pointer.unwrap(self) >> 160);
    }

    /// @notice Get the size of the pointed slice from a pointer.
    /// @param self The pointer to the slice of contract code
    /// @return The size of the slice
    function size(Pointer self) internal pure returns (uint48) {
        return uint48(Pointer.unwrap(self) >> 208);
    }

    /// @notice Get the data of the pointed slice from a pointer as a bytearray.
    /// @param self The pointer to the slice of contract code
    /// @return The pointed slice as a bytearray
    function data(Pointer self) internal view returns (bytes memory) {
        address _location = self.location();
        uint256 _start = self.start();
        uint256 _size = self.size();

        bytes memory pointerData = new bytes(_size);

        assembly ("memory-safe") {
            extcodecopy(_location, add(pointerData, 0x20), _start, _size)
        }

        return pointerData;
    }

    /// @notice Get the data of the pointed slice from a pointer as a string.
    /// @param self The pointer to the slice of contract code
    /// @return The pointed slice as a string
    function dataStr(Pointer self) internal view returns (string memory) {
        return string(data(self));
    }

    /// @notice Returns the result of decompressing the pointed slice of data with LZ-77 interpreted as a UTF-8-encoded string.
    /// @param self The pointer to the slice of contract code
    /// @return The LZ-77 decompressed data as a string
    function decompressedDataStr(Pointer self) internal view returns (string memory) {
        return string(LibZip.flzDecompress(data(self)));
    }
}
