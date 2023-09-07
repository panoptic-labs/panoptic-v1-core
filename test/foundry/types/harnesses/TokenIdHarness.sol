// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@types/TokenId.sol";

/// @title TokenIdHarness: A harness to expose the TokenId library for code coverage analysis.
/// @notice Replicates the interface of the TokenId library, passing through any function calls
/// @author Axicon Labs Limited
contract TokenIdHarness {
    // this mask in hex has a 1 bit in each location of the "isLong" of the tokenId:
    uint256 public constant LONG_MASK =
        0x100_000000000100_000000000100_000000000100_0000000000000000;
    // This mask contains zero bits where the poolId is. It is used via & to strip the poolId section from a number, leaving the rest.
    uint256 public constant CLEAR_POOLID_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF_0000000000000000;
    // This mask is used to clear all bits except for the option ratios
    uint256 public constant OPTION_RATIO_MASK =
        0x0000000000FE_0000000000FE_0000000000FE_0000000000FE_0000000000000000;
    int256 public constant BITMASK_INT24 = 0xFFFFFF;
    // Setting the width to its max possible value (2**12-1) indicates a full-range liquidity chunk and not a width of 4095 ticks
    int24 public constant MAX_LEG_WIDTH = 4095; // int24 because that's the strike and width formats
    // this mask in hex has a 1 bit in each location except in the strike+width of the tokenId:
    // this ROLL_MASK will make sure that two tokens will have the exact same parameters
    uint256 public constant ROLL_MASK =
        0xFFF_000000000FFF_000000000FFF_000000000FFF_FFFFFFFFFFFFFFFF;
    // this mask in hex has a 1 bit in each location except in the riskPartner of the 48bits on a position's tokenId:
    // this RISK_PARTNER_MASK will make sure that two tokens will have the exact same parameters
    uint256 public constant RISK_PARTNER_MASK = 0xFFFFFFFFF3FF;

    /*****************************************************************/
    /*
    /* READ: GLOBAL OPTION POSITION ID (tokenID) UNPACKING METHODS
    /*
    /*****************************************************************/

    /**
     * @notice The Uniswap v3 Pool pointed to by this option position.
     * @param self the option position Id.
     * @return the poolId (Panoptic's uni v3 pool fingerprint) of the Uniswap v3 pool
     */
    function univ3pool(uint256 self) public view returns (uint64) {
        uint64 r = TokenId.univ3pool(self);
        return r;
    }

    /// NOW WE MOVE THROUGH THE BIT PATTERN BEYOND THE FIRST 96 BITS INTO EACH LEG (EACH OF SIZE 48)
    /// @notice our terminology: "leg n" or "nth leg" (in {1,2,3,4}) corresponds to "leg index n-1" or `legIndex` (in {0,1,2,3})

    /**
     * @notice Get the asset basis for this position.
     * @dev which token is the asset - can be token0 (return 0) or token1 (return 1)
     * @param self the option position Id.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @dev occupies the leftmost bit of the optionRatio 4 bits slot.
     * @dev The final mod: "% 2" = takes the leftmost bit of the pattern.
     * @return 0 if asset is token0, 1 if asset is token1
     */
    function asset(uint256 self, uint256 legIndex) public view returns (uint256) {
        uint256 r = TokenId.asset(self, legIndex);
        return r;
    }

    /**
     * @notice Get the number of contracts per leg.
     * @param self the option position Id.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @dev The final mod: "% 2**7" = takes the rightmost (2 ** 7 = 128) 7 bits of the pattern.
     */
    function optionRatio(uint256 self, uint256 legIndex) public view returns (uint256) {
        uint256 r = TokenId.optionRatio(self, legIndex);
        return r;
    }

    /**
     * @notice Return 1 if the nth leg (leg index `legIndex`) is a long position.
     * @param self the option position Id.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return 1 if long; 0 if not long.
     */
    function isLong(uint256 self, uint256 legIndex) public view returns (uint256) {
        uint256 r = TokenId.isLong(self, legIndex);
        return r;
    }

    /**
     * @notice Get the type of token moved for a given leg (implies a call or put). Either Token0 or Token1.
     * @param self the tokenId in the SFPM representing an option position.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return 1 if the token moved is token1 or 0 if the token moved is token0
     */
    function tokenType(uint256 self, uint256 legIndex) public view returns (uint256) {
        uint256 r = TokenId.tokenType(self, legIndex);
        return r;
    }

    /**
     * @notice Get the associated risk partner of the leg index (generally another leg index in the position).
     * @notice that returning the riskPartner for any leg is 0 by default, this does not necessarily imply that token 1 (index 0)
     * @notice is the risk partner of that leg. We are assuming here that the position has been validated before this and that
     * @notice the risk partner of any leg always makes sense in this way. A leg btw. does not need to have a risk partner.
     * @notice the point here is that this function is very low level and must be used with utmost care because it comes down
     * @notice to the caller to interpret whether 00 means "no risk partner" or "risk partner leg index 0".
     * @notice But in general we can return 00, 01, 10, and 11 meaning the partner is leg 0, 1, 2, or 3.
     * @param self the tokenId in the SFPM representing an option position.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return the leg index of `legIndex`'s risk partner.
     */
    function riskPartner(uint256 self, uint256 legIndex) public view returns (uint256) {
        uint256 r = TokenId.riskPartner(self, legIndex);
        return r;
    }

    /**
     * @notice Get the strike price tick of the nth leg (with index `legIndex`).
     * @param self the tokenId in the SFPM representing an option position.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return the strike price (the underlying price of the leg).
     */
    function strike(uint256 self, uint256 legIndex) public view returns (int24) {
        int24 r = TokenId.strike(self, legIndex);
        return r;
    }

    /**
     * @notice Get the width of the nth leg (index `legIndex`). This is half the tick-range covered by the leg (tickUpper - tickLower)/2.
     * @dev return as int24 to be compatible with the strike tick format (they naturally go together)
     * @param self the tokenId in the SFPM representing an option position.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return the width of the position.
     */
    function width(uint256 self, uint256 legIndex) public view returns (int24) {
        int24 r = TokenId.width(self, legIndex);
        return r;
    }

    /**
     *
     */
    /*
    /* WRITE: GLOBAL OPTION POSITION ID (tokenID) PACKING METHODS
    /*
    /*****************************************************************/

    /**
     * @notice Add the Uniswap v3 Pool pointed to by this option position.
     * @param self the option position Id.
     * @return the tokenId with the Uniswap V3 pool added to it.
     */
    function addUniv3pool(uint256 self, uint64 _poolId) public view returns (uint256) {
        uint256 r = TokenId.addUniv3pool(self, _poolId);
        return r;
    }

    /// NOW WE MOVE THROUGH THE BIT PATTERN BEYOND THE FIRST 96 BITS INTO EACH LEG (EACH OF SIZE 40)
    /// @notice our terminology: "leg n" or "nth leg" (in {1,2,3,4}) corresponds to "leg index n-1" (in {0,1,2,3})

    /**
     * @notice Add the asset basis for this position.
     * @param self the option position Id.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @dev occupies the leftmost bit of the optionRatio 4 bits slot.
     * @dev The final mod: "% 2" = takes the rightmost bit of the pattern.
     * @return the tokenId with numerarire added to the incoming leg index
     */
    function addAsset(
        uint256 self,
        uint256 _asset,
        uint256 legIndex
    ) public view returns (uint256) {
        uint256 r = TokenId.addAsset(self, _asset, legIndex);
        return r;
    }

    /**
     * @notice Add the number of contracts to leg index `legIndex`.
     * @param self the option position Id.
     * @param legIndex the leg index of the position (in {0,1,2,3}).
     * @dev The final mod: "% 128" = takes the rightmost (2 ** 7 = 128) 7 bits of the pattern.
     * @return the tokenId with optionRatio added to the incoming leg index
     */
    function addOptionRatio(
        uint256 self,
        uint256 _optionRatio,
        uint256 legIndex
    ) public view returns (uint256) {
        uint256 r = TokenId.addOptionRatio(self, _optionRatio, legIndex);
        return r;
    }

    /**
     * @notice Add "isLong" parameter indicating whether a leg is long (isLong=1) or short (isLong=0)
     * @notice returns 1 if the nth leg (leg index n-1) is a long position.
     * @param self the option position Id.
     * @param _isLong whether the leg is long
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return the tokenId with isLong added to its relevant leg
     */
    function addIsLong(
        uint256 self,
        uint256 _isLong,
        uint256 legIndex
    ) public view returns (uint256) {
        uint256 r = TokenId.addIsLong(self, _isLong, legIndex);
        return r;
    }

    /**
     * @notice Add the type of token moved for a given leg (implies a call or put). Either Token0 or Token1.
     * @param self the tokenId in the SFPM representing an option position.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return the tokenId with tokenType added to its relevant leg.
     */
    function addTokenType(
        uint256 self,
        uint256 _tokenType,
        uint256 legIndex
    ) public view returns (uint256) {
        uint256 r = TokenId.addTokenType(self, _tokenType, legIndex);
        return r;
    }

    /**
     * @notice Add the associated risk partner of the leg index (generally another leg in the overall position).
     * @param self the tokenId in the SFPM representing an option position.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return the tokenId with riskPartner added to its relevant leg.
     */
    function addRiskPartner(
        uint256 self,
        uint256 _riskPartner,
        uint256 legIndex
    ) public view returns (uint256) {
        uint256 r = TokenId.addRiskPartner(self, _riskPartner, legIndex);
        return r;
    }

    /**
     * @notice Add the strike price tick of the nth leg (index `legIndex`).
     * @param self the tokenId in the SFPM representing an option position.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return the tokenId with strike price tick added to its relevant leg
     */
    function addStrike(
        uint256 self,
        int24 _strike,
        uint256 legIndex
    ) public view returns (uint256) {
        uint256 r = TokenId.addStrike(self, _strike, legIndex);
        return r;
    }

    /**
     * @notice Add the width of the nth leg (index `legIndex`). This is half the tick-range covered by the leg (tickUpper - tickLower)/2.
     * @param self the tokenId in the SFPM representing an option position.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @return the tokenId with width added to its relevant leg
     */
    function addWidth(uint256 self, int24 _width, uint256 legIndex) public view returns (uint256) {
        // % 4096 -> take 12 bits from the incoming 16 bits (there's no uint12)
        uint256 r = TokenId.addWidth(self, _width, legIndex);
        return r;
    }

    /**
     * @notice Add a leg to the tokenId.
     * @param self the tokenId in the SFPM representing an option position.
     * @param legIndex the leg index of this position (in {0,1,2,3}).
     * @param _optionRatio the relative size of the leg.
     * @param _asset the asset of the leg.
     * @param _isLong whether the leg is long.
     * @param _tokenType the type of token moved for the leg.
     * @param _riskPartner the associated risk partner of the leg.
     * @param _strike the strike price tick of the leg.
     * @param _width the width of the leg.
     * @return tokenId the tokenId with the leg added
     */
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
    ) public view returns (uint256 tokenId) {
        uint256 r = TokenId.addLeg(
            self,
            legIndex,
            _optionRatio,
            _asset,
            _isLong,
            _tokenType,
            _riskPartner,
            _strike,
            _width
        );
        return r;
    }

    /**
     *
     */
    /*
    /* HELPER METHODS TO INTERACT WITH LEGS IN THE OPTION POSITION
    /*
    /*****************************************************************/

    /**
     * @notice Flip all the `isLong` positions in the legs in the `tokenId` option position.
     * @dev uses XOR on existing isLong bits.
     * @dev useful during rolling an option position where we need to burn and mint. So we need to take
     * an existing tokenId but now burn it. The way to do this is to simply flip it to a short instead.
     * @param self the tokenId in the SFPM representing an option position.
     */
    function flipToBurnToken(uint256 self) public view returns (uint256) {
        uint256 r = TokenId.flipToBurnToken(self);
        return r;
    }

    /**
     * @notice Get the number of longs in this option position.
     * @notice count the number of legs (out of a maximum of 4) that are long positions.
     * @param self the tokenId in the SFPM representing an option position.
     * @return the number of long positions (in the range {0,...,4}).
     */
    function countLongs(uint256 self) public view returns (uint256) {
        uint256 r = TokenId.countLongs(self);
        return r;
    }

    /**
     * @notice Get the option position's nth leg's (index `legIndex`) tick ranges (lower, upper).
     * @dev NOTE does not extract liquidity which is the third piece of information in a LiquidityChunk.
     * @param self the option position id.
     * @param legIndex the leg index of the position (in {0,1,2,3}).
     * @param tickSpacing the tick spacing of the underlying Univ3 pool.
     * @return legLowerTick the lower tick of the leg/liquidity chunk.
     * @return legUpperTick the upper tick of the leg/liquidity chunk.
     */
    function asTicks(
        uint256 self,
        uint256 legIndex,
        int24 tickSpacing
    ) public view returns (int24 legLowerTick, int24 legUpperTick) {
        (legLowerTick, legUpperTick) = TokenId.asTicks(self, legIndex, tickSpacing);
    }

    /**
     * @notice Return the number of active legs in the option position.
     * @param self the option position Id (tokenId).
     * @dev ASSUMPTION: There is at least 1 leg in this option position.
     * @dev ASSUMPTION: For any leg, the option ratio is always > 0 (the leg always has a number of contracts associated with it).
     * @return the number of legs in the option position.
     */
    function countLegs(uint256 self) public view returns (uint256) {
        uint256 r = TokenId.countLegs(self);
        return r;
    }

    /**
     * @notice Validate an option position and all its active legs; return the underlying AMM address.
     * @dev used to validate a position tokenId and its legs.
     * @param self the option position id.
     * @return univ3PoolAddressId the first 64 bits of the underlying Uniswap V3 address.
     */
    function validate(uint256 self) public view returns (uint64 univ3PoolAddressId) {
        uint64 r = TokenId.validate(self);
        return r;
    }

    /**
     * @notice Make sure that an option position `self`'s all active legs are out-of-the-money (OTM). Revert if not.
     * @dev OTMness depends on where the current price tick is in the AMM relative to the tick bounds of the leg.
     * @param self the option position Id (tokenId)
     * @param currentTick the current tick corresponding to the current price in the Univ3 pool.
     * @param tickSpacing the tick spacing of the Univ3 pool.
     */
    function ensureIsOTM(uint256 self, int24 currentTick, int24 tickSpacing) public view {
        TokenId.ensureIsOTM(self, currentTick, tickSpacing);
    }

    /**
     * @notice Validate that a position `self` and its legs/chunks are exercisable.
     * @dev At least one long leg must be far-out-of-the-money (i.e. price is outside its range).
     * @param self the option position Id (tokenId)
     * @param currentTick the current tick corresponding to the current price in the Univ3 pool.
     * @param tickSpacing the tick spacing of the Univ3 pool used to compute the width of the chunks.
     */
    function validateIsExercisable(uint256 self, int24 currentTick, int24 tickSpacing) public view {
        TokenId.validateIsExercisable(self, currentTick, tickSpacing);
    }

    /**
     *
     */
    /*
    /* LOGIC FOR ROLLING AN OPTION POSITION.
    /*
    /*****************************************************************/

    /**
     * @notice Validate that a roll didn't change unexpected parameters.
     * @notice Does NOT revert if invalid; returns the validation check as a boolean.
     * @dev Call this on an old tokenId when rolling into a new TokenId.
     *      this checks that the new tokenId is valid in structure.
     * @param oldTokenId the old tokenId that is being rolled into a new position.
     * @param newTokenId the new tokenId that the old position is being rolled into.
     * @return true of the rolled token (newTokenId) is valid in structure.
     */
    function rolledTokenIsValid(uint256 oldTokenId, uint256 newTokenId) public view returns (bool) {
        bool r = TokenId.rolledTokenIsValid(oldTokenId, newTokenId);
        return r;
    }

    /**
     * @notice Roll an option position from an old TokenId to a position with parameters from the newTokenId.
     * @dev a roll in general burns existing legs and re-mints the legs.
     * @param oldTokenId the old option position that we are rolling into a new position.
     * @param newTokenId the new option position that we are rolling into.
     * @return burnTokenId the details of the legs to burn as part of the roll.
     * @return mintTokenId the details of the legs to mint as part of the roll.
     */
    function constructRollTokenIdWith(
        uint256 oldTokenId,
        uint256 newTokenId
    ) public view returns (uint256 burnTokenId, uint256 mintTokenId) {
        (burnTokenId, mintTokenId) = TokenId.constructRollTokenIdWith(oldTokenId, newTokenId);
    }

    /**
     * @notice Clear a leg in an option position with index `i`.
     * @dev set bits of the leg to zero. Also sets the optionRatio and asset to zero of that leg.
     * @dev NOTE it's important that the caller fills in the leg details after.
     * @dev  - optionRatio is zeroed
     * @dev  - asset is zeroed
     * @dev  - width is zeroed
     * @dev  - strike is zeroed
     * @dev  - tokenType is zeroed
     * @dev  - isLong is zeroed
     * @dev  - riskPartner is zeroed
     * @param self the tokenId to reset the leg of
     * @param i the leg index to reset, in {0,1,2,3}
     * @return `self` with the `i`th leg zeroed including optionRatio and asset.
     */
    function clearLeg(uint256 self, uint256 i) public view returns (uint256) {
        uint256 r = TokenId.clearLeg(self, i);
        return r;
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
    ) public view returns (uint256) {
        uint256 r = TokenId.rollTokenInfo(self, other, src, dst);
        return r;
    }
}
