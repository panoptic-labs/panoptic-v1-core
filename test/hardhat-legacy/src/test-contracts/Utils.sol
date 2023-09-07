// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *
 * WARNING: TEST HELPER CONTRACT - NOT TO BE DEPLOYED INTO PRODUCTION
 *
 */
pragma solidity =0.8.18;

// Foundry
import {console2} from "forge-std/console2.sol";

/*
 * @title Utils used in test contracts.
 * @author Axicon Labs Limited
 * @notice
 * @notice ***** NOT TO BE DEPLOYED INTO PRODUCTION *****
 * @notice
 */
contract Utils {
    uint256 globalCounter = 1; // keep track of the tests run and print this to std out during testing

    /// @notice helper function to print the Status of a test to std out
    modifier printStatus() {
        _;
        console2.log("Test #%d: PASS", globalCounter++);
    }

    /******************************************
     * HELPER FUNCTIONS FOR TESTING
     ******************************************/

    /// view functions

    /**
     * @notice Helper to print bits in a uint256 bit pattern; prints to std out.
     * @dev useful during building the tests to visualize the underlying bit pattern ensuring that values go where expected
     * @param bitpattern to print the bits of
     * @param startingAtBitIndex which bit index to start at (zero-indexed)
     * @param numBits the number of bits to print
     */
    function printBits(
        uint256 bitpattern,
        uint256 startingAtBitIndex,
        uint256 numBits
    ) internal view {
        console2.log(">>> printing bits for %s", bitpattern);
        for (uint256 i = 0; i < numBits; i++) {
            if (i >= 255) break;

            if (i < 10)
                console2.log(
                    "bit index %s   = %s",
                    startingAtBitIndex + i,
                    bit(bitpattern, uint8(startingAtBitIndex + i))
                );
            else if (i < 100)
                console2.log(
                    "bit index %s  = %s",
                    startingAtBitIndex + i,
                    bit(bitpattern, uint8(startingAtBitIndex + i))
                );
            else
                console2.log(
                    "bit index %s = %s",
                    startingAtBitIndex + i,
                    bit(bitpattern, uint8(startingAtBitIndex + i))
                );
        }
        console2.log("<<< end.");
    }

    /// pure functions

    /**
     * @notice Custom expect function to throw an error if two numbers are not equal
     * @param value the value that is being tested
     * @param toEqual the expected value that `value` should equal, e.g.: value = 4, expected = 4, no error is thrown.
     * @param msgIfNot the message to display if the `require` call fails
     */
    function expectEqual(uint256 value, uint256 toEqual, string memory msgIfNot) internal pure {
        require(value == toEqual, msgIfNot);
    }

    /**
     * @notice Set bit value at `index` to 1 (note: `index` starts at 0, so if calling with `index==0` against 0 the result is 1)
     * @param bitMaskAsInt the incoming bit mask (as a uint256) to set the bit index for.
     * @param index the bit index to set to true (starts at 0)
     */
    function setBitToTrue(uint256 bitMaskAsInt, uint256 index) internal pure returns (uint256) {
        return bitMaskAsInt | (1 << index); // sets bit at `index` to 1
    }

    /**
     * @notice Get the value of the bit at the given 'index' in 'self' (uint256).
     * @dev uint8 is the smallest amount bits we can return storing this result
     * @param self the bitpattern to return the bit at `index` for
     * @param index the index of the bit in `self` to return
     * @return the value of the bit in `self` at `index`
     */
    function bit(uint256 self, uint8 index) internal pure returns (uint8) {
        return uint8((self >> index) & 1);
    }

    /**
     * @notice Get the value of the bit at the given 'index' in 'self' (int48).
     * @param self the bitpattern to return the bit at `index` for
     * @param index the index of the bit in `self` to return
     * @return the value of the bit in `self` at `index`
     */
    function bit(int48 self, uint8 index) internal pure returns (uint8) {
        return uint8(uint48((self >> index) & 1));
    }

    /**
     * @notice Set `isLong` bits in the bitmask of a Panoptic option position with up to four legs.
     * @notice Example: incoming: `theid=0`, and `bitsToSet=[1,0,0,0]` this sets the `isLong=true` for the first leg.
     * @notice Example: incoming: `theid=0`, and `bitsToSet=[0,1,0,1]` this sets the `isLong=true` for the second and the fourth leg.
     * @param self is the option position (tokenId) to set the isLong parameter for, for its legs.
     * @param bitsToSet is a 4-item array of either 0 or 1. 1 signals that this leg should be active aka `isLong=true`.
     * @return the Panoptic option position (tokenId) with the isLong of its relevant legs set to true.
     */
    function setAllIsLongBits(
        uint256 self,
        uint256[4] memory bitsToSet
    ) internal pure returns (uint256) {
        for (uint256 i; i < bitsToSet.length; i++)
            if (bitsToSet[i] == 1) self = setBitToTrue(self, 72 + 48 * i);
        return self;
    }

    function setAllOptionRatioBits(
        uint256 self,
        uint256[4] memory bitsToSet
    ) internal pure returns (uint256) {
        for (uint256 i; i < bitsToSet.length; i++)
            if (bitsToSet[i] == 1) self = setBitToTrue(self, 65 + 48 * i);
        return self;
    }

    function validateBit(uint256 self, uint8 index, uint8 expected) internal pure {
        require(bit(self, index) == expected, "bit not set as expected");
    }

    function validateBitsBatch(uint256 self, uint8 offset, uint8[] memory expected) internal pure {
        for (uint8 i = 0; i < expected.length; i++) {
            validateBit(self, offset + i, expected[i]);
        }
    }

    function validateUniformBitsBatch(
        uint256 self,
        uint8 offset,
        uint8 size,
        uint8 expected
    ) internal pure {
        uint8[] memory expectedArr = new uint8[](size);
        for (uint8 i = 0; i < size; i++) {
            expectedArr[i] = expected;
        }
        validateBitsBatch(self, offset, expectedArr);
    }

    function validatePreviousAndNewBits(
        uint256 selfPrev,
        uint256 self,
        uint8 offset,
        uint256 expected
    ) internal view {
        require(
            self & (~uint256(0) >> (256 - offset)) == selfPrev,
            "previous bits have been mutated"
        );
        require(self >> offset == expected, "new bits are not as expected");
    }
}
