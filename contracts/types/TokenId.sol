// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";

/// @title Panoptic's tokenId: the fundamental options position.
/// @author Axicon Labs Limited
/// @notice This is the token ID used in the ERC1155 representation of the option position in the SFPM.
/// @notice The SFPM "Overloads" the ERC1155 `id` by storing all option information in said `id`.
/// @notice Contains methods for packing and unpacking a Panoptic options position into a uint256 bit pattern.
/// @notice our terminology: "leg n" or "nth leg" (in {1,2,3,4}) corresponds to "leg index n-1" or `legIndex` (in {0,1,2,3})
/// @dev PACKING RULES FOR A TOKENID:
/// @dev this is how the token Id is packed into its bit-constituents containing position information.
/// @dev the following is a diagram to be read top-down in a little endian format
/// @dev (so (1) below occupies the first 64 least significant bits, e.g.):
/// @dev From the LSB to the MSB:
/// ===== 1 time (same for all legs) ==============================================================
///      Property         Size      Offset      Comment
/// (1) univ3pool        64bits     0bits      : first 8 bytes of the Uniswap v3 pool address (first 64 bits; little-endian), plus a pseudorandom number in the event of a collision
/// ===== 4 times (one for each leg) ==============================================================
/// (2) asset             1bit      0bits      : Specifies the asset (0: token0, 1: token1)
/// (3) optionRatio       7bits     1bits      : number of contracts per leg
/// (4) isLong            1bit      8bits      : long==1 means liquidity is removed, long==0 -> liquidity is added
/// (5) tokenType         1bit      9bits      : put/call: which token is moved when deployed (0 -> token0, 1 -> token1)
/// (6) riskPartner       2bits     10bits     : normally its own index. Partner in defined risk position otherwise
/// (7) strike           24bits     12bits     : strike price; defined as (tickUpper + tickLower) / 2
/// (8) width            12bits     36bits     : width; defined as (tickUpper - tickLower) / tickSpacing
/// Total                48bits                : Each leg takes up this many bits
/// ===============================================================================================
///
/// The bit pattern is therefore, in general:
///
///                        (strike price tick of the 3rd leg)
///                            |             (width of the 2nd leg)
///                            |                   |
/// (8)(7)(6)(5)(4)(3)(2)  (8)(7)(6)(5)(4)(3)(2)  (8)(7)(6)(5)(4)(3)(2)   (8)(7)(6)(5)(4)(3)(2)        (1)
///  <---- 48 bits ---->    <---- 48 bits ---->    <---- 48 bits ---->     <---- 48 bits ---->    <- 64 bits ->
///         Leg 4                  Leg 3                  Leg 2                   Leg 1         Univ3 Pool Address
///
///  <--- most significant bit                                                       least significant bit --->
///
/// @notice Some rules of how legs behave (we enforce these in a `validate()` function):
///   - a leg is inactive if it's not part of the position. Technically it means that all bits are zero.
///   - a leg is active if it has an optionRatio > 0 since this must always be set for an active leg.
///   - if a leg is active (e.g. leg 1) there can be no gaps in other legs meaning: if leg 1 is active then leg 3 cannot be active if leg 2 is inactive.
///
/// Examples:
///  We can think of the bit pattern as an array starting at bit index 0 going to bit index 255 (so 256 total bits)
///  We also refer to the legs via their index, so leg number 2 has leg index 1 (legIndex) (counting from zero), and in general leg number N has leg index N-1.
///  - the underlying strike price of the 2nd leg (leg index = 1) in this option position starts at bit index  (64 + 12 + 48 * (leg index=1))=123
///  - the tokenType of the 4th leg in this option position starts at bit index 64+9+48*3=217
///  - the Uniswap v3 pool id starts at bit index 0 and ends at bit index 63 (and thus takes up 64 bits).
///  - the width of the 3rd leg in this option position starts at bit index 64+36+48*2=196
library TokenId {
    using TokenId for uint256;

    // this mask in hex has a 1 bit in each location of the "isLong" of the tokenId:
    uint256 internal constant LONG_MASK =
        0x100_000000000100_000000000100_000000000100_0000000000000000;
    // This mask contains zero bits where the poolId is. It is used via & to strip the poolId section from a number, leaving the rest.
    uint256 internal constant CLEAR_POOLID_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF_0000000000000000;
    // This mask is used to clear all bits except for the option ratios
    uint256 internal constant OPTION_RATIO_MASK =
        0x0000000000FE_0000000000FE_0000000000FE_0000000000FE_0000000000000000;
    int256 internal constant BITMASK_INT24 = 0xFFFFFF;
    // this mask in hex has a 1 bit in each location except in the strike+width of the tokenId:
    // this ROLL_MASK will make sure that two tokens will have the exact same parameters
    uint256 internal constant ROLL_MASK =
        0xFFF_000000000FFF_000000000FFF_000000000FFF_FFFFFFFFFFFFFFFF;
    // this mask in hex has a 1 bit in each location except in the riskPartner of the 48bits on a position's tokenId:
    // this RISK_PARTNER_MASK will make sure that two tokens will have the exact same parameters
    uint256 internal constant RISK_PARTNER_MASK = 0xFFFFFFFFF3FF;

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice The Uniswap v3 Pool pointed to by this option position.
    /// @param self the option position Id
    /// @return the poolId (Panoptic's uni v3 pool fingerprint) of the Uniswap v3 pool
    function univ3pool(uint256 self) internal pure returns (uint64) {
        unchecked {
            return uint64(self);
        }
    }

    /// @notice Get the asset basis for this position.
    /// @dev which token is the asset - can be token0 (return 0) or token1 (return 1)
    /// @param self the option position Id
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @dev occupies the leftmost bit of the optionRatio 4 bits slot.
    /// @dev The final mod: "% 2" = takes the leftmost bit of the pattern.
    /// @return 0 if asset is token0, 1 if asset is token1
    function asset(uint256 self, uint256 legIndex) internal pure returns (uint256) {
        unchecked {
            return uint256((self >> (64 + legIndex * 48)) % 2);
        }
    }

    /// @notice Get the number of contracts per leg.
    /// @param self the option position Id.
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @dev The final mod: "% 2**7" = takes the rightmost (2 ** 7 = 128) 7 bits of the pattern.
    function optionRatio(uint256 self, uint256 legIndex) internal pure returns (uint256) {
        unchecked {
            return uint256((self >> (64 + legIndex * 48 + 1)) % 128);
        }
    }

    /// @notice Return 1 if the nth leg (leg index `legIndex`) is a long position.
    /// @param self the option position Id
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return 1 if long; 0 if not long.
    function isLong(uint256 self, uint256 legIndex) internal pure returns (uint256) {
        unchecked {
            return uint256((self >> (64 + legIndex * 48 + 8)) % 2);
        }
    }

    /// @notice Get the type of token moved for a given leg (implies a call or put). Either Token0 or Token1.
    /// @param self the tokenId in the SFPM representing an option position
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return 1 if the token moved is token1 or 0 if the token moved is token0
    function tokenType(uint256 self, uint256 legIndex) internal pure returns (uint256) {
        unchecked {
            return uint256((self >> (64 + legIndex * 48 + 9)) % 2);
        }
    }

    /// @notice Get the associated risk partner of the leg index (generally another leg index in the position).
    /// @notice that returning the riskPartner for any leg is 0 by default, this does not necessarily imply that token 1 (index 0)
    /// @notice is the risk partner of that leg. We are assuming here that the position has been validated before this and that
    /// @notice the risk partner of any leg always makes sense in this way. A leg btw. does not need to have a risk partner.
    /// @notice the point here is that this function is very low level and must be used with utmost care because it comes down
    /// @notice to the caller to interpret whether 00 means "no risk partner" or "risk partner leg index 0".
    /// @notice But in general we can return 00, 01, 10, and 11 meaning the partner is leg 0, 1, 2, or 3.
    /// @param self the tokenId in the SFPM representing an option position
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return the leg index of `legIndex`'s risk partner.
    function riskPartner(uint256 self, uint256 legIndex) internal pure returns (uint256) {
        unchecked {
            return uint256((self >> (64 + legIndex * 48 + 10)) % 4);
        }
    }

    /// @notice Get the strike price tick of the nth leg (with index `legIndex`).
    /// @param self the tokenId in the SFPM representing an option position
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return the strike price (the underlying price of the leg).
    function strike(uint256 self, uint256 legIndex) internal pure returns (int24) {
        unchecked {
            return int24(int256(self >> (64 + legIndex * 48 + 12)));
        }
    }

    /// @notice Get the width of the nth leg (index `legIndex`). This is half the tick-range covered by the leg (tickUpper - tickLower)/2.
    /// @dev return as int24 to be compatible with the strike tick format (they naturally go together)
    /// @param self the tokenId in the SFPM representing an option position
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return the width of the position.
    function width(uint256 self, uint256 legIndex) internal pure returns (int24) {
        unchecked {
            return int24(int256((self >> (64 + legIndex * 48 + 36)) % 4096));
        } // "% 4096" = take last (2 ** 12 = 4096) 12 bits
    }

    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Add the Uniswap v3 Pool pointed to by this option position.
    /// @param self the option position Id.
    /// @return the tokenId with the Uniswap V3 pool added to it.
    function addUniv3pool(uint256 self, uint64 _poolId) internal pure returns (uint256) {
        unchecked {
            return self + uint256(_poolId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Add the asset basis for this position.
    /// @param self the option position Id.
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @dev occupies the leftmost bit of the optionRatio 4 bits slot
    /// @dev The final mod: "% 2" = takes the rightmost bit of the pattern
    /// @return the tokenId with numerarire added to the incoming leg index
    function addAsset(
        uint256 self,
        uint256 _asset,
        uint256 legIndex
    ) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(_asset % 2) << (64 + legIndex * 48));
        }
    }

    /// @notice Add the number of contracts to leg index `legIndex`.
    /// @param self the option position Id
    /// @param legIndex the leg index of the position (in {0,1,2,3})
    /// @dev The final mod: "% 128" = takes the rightmost (2 ** 7 = 128) 7 bits of the pattern.
    /// @return the tokenId with optionRatio added to the incoming leg index
    function addOptionRatio(
        uint256 self,
        uint256 _optionRatio,
        uint256 legIndex
    ) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(_optionRatio % 128) << (64 + legIndex * 48 + 1));
        }
    }

    /// @notice Add "isLong" parameter indicating whether a leg is long (isLong=1) or short (isLong=0)
    /// @notice returns 1 if the nth leg (leg index n-1) is a long position.
    /// @param self the option position Id
    /// @param _isLong whether the leg is long
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return the tokenId with isLong added to its relevant leg
    function addIsLong(
        uint256 self,
        uint256 _isLong,
        uint256 legIndex
    ) internal pure returns (uint256) {
        unchecked {
            return self + ((_isLong % 2) << (64 + legIndex * 48 + 8));
        }
    }

    /// @notice Add the type of token moved for a given leg (implies a call or put). Either Token0 or Token1.
    /// @param self the tokenId in the SFPM representing an option position
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return the tokenId with tokenType added to its relevant leg.
    function addTokenType(
        uint256 self,
        uint256 _tokenType,
        uint256 legIndex
    ) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(_tokenType % 2) << (64 + legIndex * 48 + 9));
        }
    }

    /// @notice Add the associated risk partner of the leg index (generally another leg in the overall position).
    /// @param self the tokenId in the SFPM representing an option position
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return the tokenId with riskPartner added to its relevant leg.
    function addRiskPartner(
        uint256 self,
        uint256 _riskPartner,
        uint256 legIndex
    ) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(_riskPartner % 4) << (64 + legIndex * 48 + 10));
        }
    }

    /// @notice Add the strike price tick of the nth leg (index `legIndex`).
    /// @param self the tokenId in the SFPM representing an option position.
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return the tokenId with strike price tick added to its relevant leg
    function addStrike(
        uint256 self,
        int24 _strike,
        uint256 legIndex
    ) internal pure returns (uint256) {
        unchecked {
            return self + uint256((int256(_strike) & BITMASK_INT24) << (64 + legIndex * 48 + 12));
        }
    }

    /// @notice Add the width of the nth leg (index `legIndex`). This is half the tick-range covered by the leg (tickUpper - tickLower)/2.
    /// @param self the tokenId in the SFPM representing an option position.
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return the tokenId with width added to its relevant leg
    function addWidth(
        uint256 self,
        int24 _width,
        uint256 legIndex
    ) internal pure returns (uint256) {
        // % 4096 -> take 12 bits from the incoming 24 bits (there's no uint12)
        unchecked {
            return self + (uint256(uint24(_width) % 4096) << (64 + legIndex * 48 + 36));
        }
    }

    /// @notice Add a leg to the tokenId.
    /// @param self the tokenId in the SFPM representing an option position.
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @param _optionRatio the relative size of the leg
    /// @param _asset the asset of the leg
    /// @param _isLong whether the leg is long
    /// @param _tokenType the type of token moved for the leg
    /// @param _riskPartner the associated risk partner of the leg
    /// @param _strike the strike price tick of the leg
    /// @param _width the width of the leg
    /// @return tokenId the tokenId with the leg added
    function addLeg(
        uint256 self,
        uint256 legIndex,
        uint256 _optionRatio,
        uint256 _asset,
        uint256 _isLong,
        uint256 _tokenType,
        uint256 _riskPartner,
        int24 _strike,
        int24 _width
    ) internal pure returns (uint256 tokenId) {
        tokenId = addOptionRatio(self, _optionRatio, legIndex);
        tokenId = addAsset(tokenId, _asset, legIndex);
        tokenId = addIsLong(tokenId, _isLong, legIndex);
        tokenId = addTokenType(tokenId, _tokenType, legIndex);
        tokenId = addRiskPartner(tokenId, _riskPartner, legIndex);
        tokenId = addStrike(tokenId, _strike, legIndex);
        tokenId = addWidth(tokenId, _width, legIndex);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Flip all the `isLong` positions in the legs in the `tokenId` option position.
    /// @dev uses XOR on existing isLong bits.
    /// @dev useful during rolling an option position where we need to burn and mint. So we need to take
    /// an existing tokenId but now burn it. The way to do this is to simply flip it to a short instead.
    /// @param self the tokenId in the SFPM representing an option position.
    function flipToBurnToken(uint256 self) internal pure returns (uint256) {
        unchecked {
            // NOTE: This is a hack to avoid blowing up the contract size.
            // We copy the logic from the countLegs function, using it here adds 5K to the contract size with IR for some reason
            // Strip all bits except for the option ratios
            uint256 optionRatios = self & OPTION_RATIO_MASK;

            // The legs are filled in from least to most significant
            // Each comparison here is to the start of the next leg's option ratio
            // Since only the option ratios remain, we can be sure that no bits above the start of the inactive legs will be 1
            if (optionRatios < 2 ** 64) {
                optionRatios = 0;
            } else if (optionRatios < 2 ** 112) {
                optionRatios = 1;
            } else if (optionRatios < 2 ** 160) {
                optionRatios = 2;
            } else if (optionRatios < 2 ** 208) {
                optionRatios = 3;
            } else {
                optionRatios = 4;
            }

            // We need to ensure that only active legs are flipped
            // In order to achieve this, we shift our long bit mask to the right by (4-# active legs)
            // i.e the whole mask is used to flip all legs with 4 legs, but only the first leg is flipped with 1 leg so we shift by 3 legs
            // We also clear the poolId area of the mask to ensure the bits that are shifted right into the area don't flip and cause issues
            return self ^ ((LONG_MASK >> (48 * (4 - optionRatios))) & CLEAR_POOLID_MASK);
        }
    }

    /// @notice Get the number of longs in this option position.
    /// @notice count the number of legs (out of a maximum of 4) that are long positions.
    /// @param self the tokenId in the SFPM representing an option position.
    /// @return the number of long positions (in the range {0,...,4}).
    function countLongs(uint256 self) internal pure returns (uint256) {
        unchecked {
            return self.isLong(0) + self.isLong(1) + self.isLong(2) + self.isLong(3);
        }
    }

    /// @notice Get the option position's nth leg's (index `legIndex`) tick ranges (lower, upper).
    /// @dev NOTE does not extract liquidity which is the third piece of information in a LiquidityChunk.
    /// @param self the option position id.
    /// @param legIndex the leg index of the position (in {0,1,2,3}).
    /// @param tickSpacing the tick spacing of the underlying Univ3 pool.
    /// @return legLowerTick the lower tick of the leg/liquidity chunk.
    /// @return legUpperTick the upper tick of the leg/liquidity chunk.
    function asTicks(
        uint256 self,
        uint256 legIndex,
        int24 tickSpacing
    ) internal pure returns (int24 legLowerTick, int24 legUpperTick) {
        unchecked {
            int24 selfWidth = self.width(legIndex);
            int24 selfStrike = self.strike(legIndex);

            // The max/min ticks that can be initialized are the closest multiple of tickSpacing to the actual max/min tick abs()=887272
            // Dividing and multiplying by tickSpacing rounds down and forces the tick to be a multiple of tickSpacing
            int24 minTick = (Constants.MIN_V3POOL_TICK / tickSpacing) * tickSpacing;
            int24 maxTick = (Constants.MAX_V3POOL_TICK / tickSpacing) * tickSpacing;

            /// The width is from lower to upper tick, the one-sided range is from strike to upper/lower
            /// if (width * tickSpacing) is:
            ///     even: tick range -> (strike - range, strike + range)
            ///     odd: tick range ->  (strike - range rounded down, strike + range rounded up)
            (int24 oneSidedRangeLower, int24 oneSidedRangeUpper) = PanopticMath.mulDivAsTicks(
                selfWidth,
                tickSpacing
            );

            (legLowerTick, legUpperTick) = (
                selfStrike - oneSidedRangeLower,
                selfStrike + oneSidedRangeUpper
            );

            // Revert if the upper/lower ticks are not multiples of tickSpacing
            // Revert if the tick range extends from the strike outside of the valid tick range
            // These are invalid states, and would revert silently later in `univ3Pool.mint`
            if (
                legLowerTick % tickSpacing != 0 ||
                legUpperTick % tickSpacing != 0 ||
                legLowerTick < minTick ||
                legUpperTick > maxTick
            ) revert Errors.TicksNotInitializable();
        }
    }

    /// @notice Return the number of active legs in the option position.
    /// @param self the option position Id (tokenId).
    /// @dev ASSUMPTION: There is at least 1 leg in this option position.
    /// @dev ASSUMPTION: For any leg, the option ratio is always > 0 (the leg always has a number of contracts associated with it).
    /// @return the number of legs in the option position.
    function countLegs(uint256 self) internal pure returns (uint256) {
        // Strip all bits except for the option ratios
        uint256 optionRatios = self & OPTION_RATIO_MASK;

        // The legs are filled in from least to most significant
        // Each comparison here is to the start of the next leg's option ratio section
        // Since only the option ratios remain, we can be sure that no bits above the start of the inactive legs will be 1
        if (optionRatios < 2 ** 64) {
            return 0;
        } else if (optionRatios < 2 ** 112) {
            return 1;
        } else if (optionRatios < 2 ** 160) {
            return 2;
        } else if (optionRatios < 2 ** 208) {
            return 3;
        }
        return 4;
    }

    /*//////////////////////////////////////////////////////////////
                               VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Validate an option position and all its active legs; return the underlying AMM address.
    /// @dev used to validate a position tokenId and its legs.
    /// @param self the option position id.
    /// @return the first 64 bits of the underlying Uniswap V3 address.
    function validate(uint256 self) internal pure returns (uint64) {
        if (self.optionRatio(0) == 0) revert Errors.InvalidTokenIdParameter(1);

        // loop through the 4 (possible) legs in the tokenId `self`
        unchecked {
            for (uint256 i = 0; i < 4; ++i) {
                if (self.optionRatio(i) == 0) {
                    // final leg in this position identified;
                    // make sure any leg above this are zero as well
                    // (we don't allow gaps eg having legs 1 and 4 active without 2 and 3 is not allowed)
                    if ((self >> (64 + 48 * i)) != 0) revert Errors.InvalidTokenIdParameter(1);

                    break; // we are done iterating over potential legs
                }
                // now validate this ith leg in the position:

                // The width cannot be 0; the minimum is 1
                if ((self.width(i) == 0)) revert Errors.InvalidTokenIdParameter(5);
                // Strike cannot be MIN_TICK or MAX_TICK
                if (
                    (self.strike(i) == Constants.MIN_V3POOL_TICK) ||
                    (self.strike(i) == Constants.MAX_V3POOL_TICK)
                ) revert Errors.InvalidTokenIdParameter(4);

                // In the following, we check whether the risk partner of this leg is itself
                // or another leg in this position.
                // Handles case where riskPartner(i) != i ==> leg i has a risk partner that is another leg
                uint256 riskPartnerIndex = self.riskPartner(i);
                if (riskPartnerIndex != i) {
                    // Ensures that risk partners are mutual
                    if (self.riskPartner(riskPartnerIndex) != i)
                        revert Errors.InvalidTokenIdParameter(3);

                    // Ensures that risk partners have 1) the same asset, and 2) the same ratio
                    if (
                        (self.asset(riskPartnerIndex) != self.asset(i)) ||
                        (self.optionRatio(riskPartnerIndex) != self.optionRatio(i))
                    ) revert Errors.InvalidTokenIdParameter(3);

                    // long/short status of associated legs
                    uint256 isLong = self.isLong(i);
                    uint256 isLongP = self.isLong(riskPartnerIndex);

                    // token type status of associated legs (call/put)
                    uint256 tokenType = self.tokenType(i);
                    uint256 tokenTypeP = self.tokenType(riskPartnerIndex);

                    // if the position is the same i.e both long calls, short put's etc.
                    // then this is a regular position, not a defined risk position
                    if ((isLong == isLongP) && (tokenType == tokenTypeP))
                        revert Errors.InvalidTokenIdParameter(4);

                    // if the two token long-types and the tokenTypes are both different (one is a short call, the other a long put, e.g.), this is a synthetic position
                    // A synthetic long or short is more capital efficient than each leg separated because the long+short premia accumulate proportionally
                    if ((isLong != isLongP) && (tokenType != tokenTypeP))
                        revert Errors.InvalidTokenIdParameter(5);
                }
            } // end for loop over legs
        }

        return self.univ3pool();
    }

    /// @notice Make sure that an option position `self`'s all active legs are out-of-the-money (OTM). Revert if not.
    /// @dev OTMness depends on where the current price tick is in the AMM relative to the tick bounds of the leg.
    /// @param self the option position Id (tokenId)
    /// @param currentTick the current tick corresponding to the current price in the Univ3 pool.
    /// @param tickSpacing the tick spacing of the Univ3 pool.
    function ensureIsOTM(uint256 self, int24 currentTick, int24 tickSpacing) internal pure {
        unchecked {
            uint256 numLegs = self.countLegs();
            for (uint256 i = 0; i < numLegs; ++i) {
                int24 optionStrike = self.strike(i);
                int24 range = (self.width(i) * tickSpacing) / 2;

                uint256 optionTokenType = self.tokenType(i);

                if (
                    ((optionTokenType == 1) && currentTick < (optionStrike + range)) ||
                    ((optionTokenType == 0) && currentTick >= (optionStrike - range))
                ) {
                    revert Errors.OptionsNotOTM();
                }
            }
        }
    }

    /// @notice Validate that a position `self` and its legs/chunks are exercisable.
    /// @dev At least one long leg must be far-out-of-the-money (i.e. price is outside its range).
    /// @param self the option position Id (tokenId)
    /// @param currentTick the current tick corresponding to the current price in the Univ3 pool.
    /// @param tickSpacing the tick spacing of the Univ3 pool used to compute the width of the chunks.
    function validateIsExercisable(
        uint256 self,
        int24 currentTick,
        int24 tickSpacing
    ) internal pure {
        unchecked {
            uint256 numLegs = self.countLegs();
            for (uint256 i = 0; i < numLegs; ++i) {
                // compute the range of this leg/chunk
                int24 range = (self.width(i) * tickSpacing) / 2;
                // check if the price is outside this chunk
                if (
                    (currentTick >= (self.strike(i) + range)) ||
                    (currentTick < (self.strike(i) - range))
                ) {
                    // if this leg is long and the price beyond the leg's range:
                    // this exercised ID, `self`, appears valid
                    if (self.isLong(i) == 1) return; // validated
                }
            }
        }

        // Fail if position has no legs that is far-out-of-the-money
        revert Errors.NoLegsExercisable();
    }

    /*//////////////////////////////////////////////////////////////
                             OPTION ROLLING
    //////////////////////////////////////////////////////////////*/

    /// @notice Validate that a roll didn't change unexpected parameters.
    /// @notice Does NOT revert if invalid; returns the validation check as a boolean.
    /// @dev Call this on an old tokenId when rolling into a new TokenId.
    /// this checks that the new tokenId is valid in structure.
    /// @param oldTokenId the old tokenId that is being rolled into a new position.
    /// @param newTokenId the new tokenId that the old position is being rolled into.
    /// @return true of the rolled token (newTokenId) is valid in structure.
    function rolledTokenIsValid(
        uint256 oldTokenId,
        uint256 newTokenId
    ) internal pure returns (bool) {
        // tokenIds (option positions) are identical except in strike and/or width
        return ((oldTokenId & ROLL_MASK) == (newTokenId & ROLL_MASK));
    }

    /// @notice Roll an option position from an old TokenId to a position with parameters from the newTokenId.
    /// @dev a roll in general burns existing legs and re-mints the legs.
    /// @param oldTokenId the old option position that we are rolling into a new position.
    /// @param newTokenId the new option position that we are rolling into.
    /// @return burnTokenId the details of the legs to burn as part of the roll.
    /// @return mintTokenId the details of the legs to mint as part of the roll.
    function constructRollTokenIdWith(
        uint256 oldTokenId,
        uint256 newTokenId
    ) internal pure returns (uint256 burnTokenId, uint256 mintTokenId) {
        // take the bitwise XOR between old and new token to identify modified parameters
        uint256 XORtokenId = oldTokenId ^ newTokenId;

        uint64 poolId = uint64(oldTokenId);

        uint256 j = 0;
        burnTokenId = uint256(poolId);
        mintTokenId = uint256(poolId);
        // construct mint and burn tokenIds so that only the legs that are different are touched

        for (uint256 i = 0; i < 4; ) {
            // Checks that the strike or width is finite
            // @dev the strike and the width will in general differ when rolling by definition
            //      if they don't we simply leave one leg untouched as part of the roll
            if ((XORtokenId.strike(i) != 0) || (XORtokenId.width(i) != 0)) {
                // Ensures that all other leg parameters are the same
                // @dev for example: the asset shouldn't change during a roll
                // First, shift the tokenId so that the least significant bit is the first bit of the sequence
                // asset(i), optionRatio(i), isLong(i), tokenType(i), riskPartner(i)
                // Then mask with 12 "1" bits to isolate that 12 bit sequence (0xFFF = 111111111111)
                // Finally, check that the masked sequence is zero. If it is not, one of the properties has changed
                if ((((XORtokenId) >> (64 + 48 * i)) & (0xFFF)) != 0) revert Errors.NotATokenRoll();

                burnTokenId = burnTokenId.rollTokenInfo(oldTokenId, i, j);
                mintTokenId = mintTokenId.rollTokenInfo(newTokenId, i, j);

                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Clear a leg in an option position with index `i`.
    /// @dev set bits of the leg to zero. Also sets the optionRatio and asset to zero of that leg.
    /// @dev NOTE it's important that the caller fills in the leg details after.
    /// @dev  - optionRatio is zeroed
    /// @dev  - asset is zeroed
    /// @dev  - width is zeroed
    /// @dev  - strike is zeroed
    /// @dev  - tokenType is zeroed
    /// @dev  - isLong is zeroed
    /// @dev  - riskPartner is zeroed
    /// @param self the tokenId to reset the leg of
    /// @param i the leg index to reset, in {0,1,2,3}
    /// @return `self` with the `i`th leg zeroed including optionRatio and asset.
    function clearLeg(uint256 self, uint256 i) internal pure returns (uint256) {
        if (i == 0)
            return self & 0xFFFFFFFFFFFF_FFFFFFFFFFFF_FFFFFFFFFFFF_000000000000_FFFFFFFFFFFFFFFF;
        if (i == 1)
            return self & 0xFFFFFFFFFFFF_FFFFFFFFFFFF_000000000000_FFFFFFFFFFFF_FFFFFFFFFFFFFFFF;
        if (i == 2)
            return self & 0xFFFFFFFFFFFF_000000000000_FFFFFFFFFFFF_FFFFFFFFFFFF_FFFFFFFFFFFFFFFF;
        if (i == 3)
            return self & 0x000000000000_FFFFFFFFFFFF_FFFFFFFFFFFF_FFFFFFFFFFFF_FFFFFFFFFFFFFFFF;

        return self;
    }

    /// @notice Roll (by copying) over the information from `other`'s leg index `src` to `self`'s leg index `dst`.
    /// @notice to leg index `dst` in `self`.
    /// @param self the destination tokenId of the roll
    /// @param other the source tokenId of the roll
    /// @param src the leg index in `other` we are rolling/copying over to `self`s `dst` leg index
    /// @param dst the leg index in `self` we are rolling/copying into from `other`s `src` leg index
    /// @return `self` with its `dst` leg index overwritten by the `src` leg index of `other`
    function rollTokenInfo(
        uint256 self,
        uint256 other,
        uint256 src,
        uint256 dst
    ) internal pure returns (uint256) {
        unchecked {
            // clear the destination leg details
            self = self.clearLeg(dst);

            // copy over details from `other`s `src` leg into `self`s `dst` leg:
            self = self.addWidth(other.width(src), dst);
            self = self.addStrike(other.strike(src), dst);
            self = self.addOptionRatio(other.optionRatio(src), dst);
            self = self.addTokenType(other.tokenType(src), dst);
            self = self.addIsLong(other.isLong(src), dst);
            self = self.addAsset(other.asset(src), dst);
            self = self.addRiskPartner(dst, dst);

            return self;
        }
    }
}
