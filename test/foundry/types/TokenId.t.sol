// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry
import "forge-std/Test.sol";
// Uniswap - Panoptic's version 0.8
import {TickMath} from "v3-core/libraries/TickMath.sol";
// Internal
import {Errors} from "@libraries/Errors.sol";
import {TokenIdHarness} from "./harnesses/TokenIdHarness.sol";
// Test util
import "../testUtils/PositionUtils.sol";

/**
 * Test the TokenId functionality with Foundry and Fuzzing.
 *
 * @author Axicon Labs Limited
 */
contract TokenIdTest is Test, PositionUtils {
    TokenIdHarness harness;

    // mask to clear all width bits (12 bits, offset of 36 bits)
    uint256 internal constant CLEAR_WIDTH_MASK =
        0xFFFFFFFFFFFF_000FFFFFFFFF_000FFFFFFFFF_000FFFFFFFFF_FFFFFFFFFFFFFFFF;

    // mask to clear all strike bits (24 bits, starting offset of 12 bits)
    uint256 internal constant CLEAR_STRIKE_MASK =
        0xFFF000000FFF_FFF000000FFF_FFF000000FFF_FFF000000FFF_FFFFFFFFFFFFFFFF;

    // mask to clear all riskPartner bits (2 bits, starting offset of 10 bits)
    uint256 internal constant CLEAR_RISK_PARTNER_MASK =
        0xFFFFFFFFF3FF_FFFFFFFFF3FF_FFFFFFFFF3FF_FFFFFFFFF3FF_FFFFFFFFFFFFFFFF;

    // mask to clear all asset bits (1 bits, starting offset of 0 bits)
    uint256 internal constant CLEAR_NUMERAIRE_MASK =
        0xFFFFFFFFFFFE_FFFFFFFFFFFE_FFFFFFFFFFFE_FFFFFFFFFFFE_FFFFFFFFFFFFFFFF;

    // mask to clear all option ratio bits (7 bits, starting offset of 8 bits)
    uint256 internal constant CLEAR_OPTION_RATIO_MASK =
        0xFFFFFFFFFF01_FFFFFFFFFF01_FFFFFFFFFF01_FFFFFFFFFF01_FFFFFFFFFFFFFFFF;

    // mask to clear all is long bits (7 bits, starting offset of 1 bits)
    uint256 internal constant CLEAR_IS_LONG_MASK =
        0xFFFFFFFFFEFF_FFFFFFFFFEFF_FFFFFFFFFEFF_FFFFFFFFFEFF_FFFFFFFFFFFFFFFF;

    // mask to clear all is long bits (1 bits, starting offset of 9 bits)
    uint256 internal constant CLEAR_TOKEN_TYPE_MASK =
        0xFFFFFFFFFDFF_FFFFFFFFFDFF_FFFFFFFFFDFF_FFFFFFFFFDFF_FFFFFFFFFFFFFFFF;

    // cache tick data
    int24 tickSpacing;
    int24 minTick;
    int24 maxTick;
    int24 currentTick;

    function setUp() public {
        harness = new TokenIdHarness();
    }

    function test_Success_AddUniv3Pool(address y) public {
        uint256 tokenId;

        tokenId = harness.addUniv3pool(tokenId, uint64(uint160(y)));

        assertEq(harness.univ3pool(tokenId), uint64(uint160(y)));
    }

    /*//////////////////////////////////////////////////////////////
                            ADD WIDTH
    //////////////////////////////////////////////////////////////*/
    function test_Success_AddWidth(int24 y, int24 z, int24 u, int24 v) public {
        uint256 tokenId;

        unchecked {
            if (y < 0) y = -y;
            if (z < 0) z = -z;
            if (u < 0) u = -u;
            if (v < 0) v = -v;

            // the width is 12 bits so mask it:
            int16 MASK = 0xFFF; // takes first 12 bits of the int24
            y = int24(int16(y) & MASK);
            z = int24(int16(z) & MASK);
            u = int24(int16(u) & MASK);
            v = int24(int16(v) & MASK);
        }

        tokenId = harness.addWidth(tokenId, y, 0);
        assertEq(harness.width(tokenId, 0), y);
        assertEq(harness.width(tokenId, 1), 0);
        assertEq(harness.width(tokenId, 2), 0);
        assertEq(harness.width(tokenId, 3), 0);

        tokenId = harness.addWidth(tokenId, z, 1);
        assertEq(harness.width(tokenId, 0), y);
        assertEq(harness.width(tokenId, 1), z);
        assertEq(harness.width(tokenId, 2), 0);
        assertEq(harness.width(tokenId, 3), 0);

        tokenId = harness.addWidth(tokenId, u, 2);
        assertEq(harness.width(tokenId, 0), y);
        assertEq(harness.width(tokenId, 1), z);
        assertEq(harness.width(tokenId, 2), u);
        assertEq(harness.width(tokenId, 3), 0);

        tokenId = harness.addWidth(tokenId, v, 3);
        assertEq(harness.width(tokenId, 0), y);
        assertEq(harness.width(tokenId, 1), z);
        assertEq(harness.width(tokenId, 2), u);
        assertEq(harness.width(tokenId, 3), v);
    }

    /*//////////////////////////////////////////////////////////////
                            ADD OPTION RATIO
    //////////////////////////////////////////////////////////////*/
    function test_Success_AddOptionRatio(uint16 y, uint16 z, uint16 u, uint16 v) public {
        uint256 tokenId;

        // the optionRatio is 7 bits so mask it:
        uint16 MASK = 0x7F; // takes first 7 bits of the uint16
        y = y & MASK;
        z = z & MASK;
        u = u & MASK;
        v = v & MASK;

        tokenId = harness.addOptionRatio(tokenId, y, 0);
        assertEq(harness.optionRatio(tokenId, 0), y);
        assertEq(harness.optionRatio(tokenId, 1), 0);
        assertEq(harness.optionRatio(tokenId, 2), 0);
        assertEq(harness.optionRatio(tokenId, 3), 0);

        tokenId = harness.addOptionRatio(tokenId, z, 1);
        assertEq(harness.optionRatio(tokenId, 0), y);
        assertEq(harness.optionRatio(tokenId, 1), z);
        assertEq(harness.optionRatio(tokenId, 2), 0);
        assertEq(harness.optionRatio(tokenId, 3), 0);

        tokenId = harness.addOptionRatio(tokenId, u, 2);
        assertEq(harness.optionRatio(tokenId, 0), y);
        assertEq(harness.optionRatio(tokenId, 1), z);
        assertEq(harness.optionRatio(tokenId, 2), u);
        assertEq(harness.optionRatio(tokenId, 3), 0);

        tokenId = harness.addOptionRatio(tokenId, v, 3);
        assertEq(harness.optionRatio(tokenId, 0), y);
        assertEq(harness.optionRatio(tokenId, 1), z);
        assertEq(harness.optionRatio(tokenId, 2), u);
        assertEq(harness.optionRatio(tokenId, 3), v);
    }

    /*//////////////////////////////////////////////////////////////
                            ADD NUMERAIRE
    //////////////////////////////////////////////////////////////*/
    function test_Success_AddAsset(uint16 y, uint16 z, uint16 u, uint16 v) public {
        uint256 tokenId;

        // the asset is 1 bit so mask it:
        uint16 MASK = 0x1; // takes first 1 bit of the uint16
        y = y & MASK;
        z = z & MASK;
        u = u & MASK;
        v = v & MASK;

        tokenId = harness.addAsset(tokenId, y, 0);
        assertEq(harness.asset(tokenId, 0), y);
        assertEq(harness.asset(tokenId, 1), 0);
        assertEq(harness.asset(tokenId, 2), 0);
        assertEq(harness.asset(tokenId, 3), 0);

        tokenId = harness.addAsset(tokenId, z, 1);
        assertEq(harness.asset(tokenId, 0), y);
        assertEq(harness.asset(tokenId, 1), z);
        assertEq(harness.asset(tokenId, 2), 0);
        assertEq(harness.asset(tokenId, 3), 0);

        tokenId = harness.addAsset(tokenId, u, 2);
        assertEq(harness.asset(tokenId, 0), y);
        assertEq(harness.asset(tokenId, 1), z);
        assertEq(harness.asset(tokenId, 2), u);
        assertEq(harness.asset(tokenId, 3), 0);

        tokenId = harness.addAsset(tokenId, v, 3);
        assertEq(harness.asset(tokenId, 0), y);
        assertEq(harness.asset(tokenId, 1), z);
        assertEq(harness.asset(tokenId, 2), u);
        assertEq(harness.asset(tokenId, 3), v);
    }

    /*//////////////////////////////////////////////////////////////
                            ADD STRIKE
    //////////////////////////////////////////////////////////////*/
    function test_Success_AddStrike(int24 y, int24 z, int24 u, int24 v) public {
        uint256 tokenId;

        tokenId = harness.addStrike(tokenId, y, 0);
        assertEq(harness.strike(tokenId, 0), y);
        assertEq(harness.strike(tokenId, 1), 0);
        assertEq(harness.strike(tokenId, 2), 0);
        assertEq(harness.strike(tokenId, 3), 0);

        tokenId = harness.addStrike(tokenId, z, 1);
        assertEq(harness.strike(tokenId, 0), y);
        assertEq(harness.strike(tokenId, 1), z);
        assertEq(harness.strike(tokenId, 2), 0);
        assertEq(harness.strike(tokenId, 3), 0);

        tokenId = harness.addStrike(tokenId, u, 2);
        assertEq(harness.strike(tokenId, 0), y);
        assertEq(harness.strike(tokenId, 1), z);
        assertEq(harness.strike(tokenId, 2), u);
        assertEq(harness.strike(tokenId, 3), 0);

        tokenId = harness.addStrike(tokenId, v, 3);
        assertEq(harness.strike(tokenId, 0), y);
        assertEq(harness.strike(tokenId, 1), z);
        assertEq(harness.strike(tokenId, 2), u);
        assertEq(harness.strike(tokenId, 3), v);
    }

    /*//////////////////////////////////////////////////////////////
                            ADD IS LONG
    //////////////////////////////////////////////////////////////*/

    function test_Success_AddIsLong(uint16 y, uint16 z, uint16 u, uint16 v) public {
        uint256 tokenId;

        uint256 numLongs; // also test the long counter

        // the isLong is 1 bit so mask it:
        uint16 MASK = 0x1; // takes first 1 bit of the uint16
        y = y & MASK;
        z = z & MASK;
        u = u & MASK;
        v = v & MASK;

        assertEq(harness.countLongs(tokenId), 0);

        tokenId = harness.addIsLong(tokenId, y, 0);
        assertEq(harness.isLong(tokenId, 0), y);
        assertEq(harness.isLong(tokenId, 1), 0);
        assertEq(harness.isLong(tokenId, 2), 0);
        assertEq(harness.isLong(tokenId, 3), 0);

        numLongs += harness.isLong(tokenId, 0);
        assertEq(harness.countLongs(tokenId), numLongs);

        tokenId = harness.addIsLong(tokenId, z, 1);
        assertEq(harness.isLong(tokenId, 0), y);
        assertEq(harness.isLong(tokenId, 1), z);
        assertEq(harness.isLong(tokenId, 2), 0);
        assertEq(harness.isLong(tokenId, 3), 0);

        numLongs += harness.isLong(tokenId, 1);
        assertEq(harness.countLongs(tokenId), numLongs);

        tokenId = harness.addIsLong(tokenId, u, 2);
        assertEq(harness.isLong(tokenId, 0), y);
        assertEq(harness.isLong(tokenId, 1), z);
        assertEq(harness.isLong(tokenId, 2), u);
        assertEq(harness.isLong(tokenId, 3), 0);

        numLongs += harness.isLong(tokenId, 2);
        assertEq(harness.countLongs(tokenId), numLongs);

        tokenId = harness.addIsLong(tokenId, v, 3);
        assertEq(harness.isLong(tokenId, 0), y);
        assertEq(harness.isLong(tokenId, 1), z);
        assertEq(harness.isLong(tokenId, 2), u);
        assertEq(harness.isLong(tokenId, 3), v);

        numLongs += harness.isLong(tokenId, 3);
        assertEq(harness.countLongs(tokenId), numLongs);
    }

    /*//////////////////////////////////////////////////////////////
                            ADD RISK PARTNER
    //////////////////////////////////////////////////////////////*/
    function test_Success_AddRiskPartner(uint16 y, uint16 z, uint16 u, uint16 v) public {
        uint256 tokenId;

        // the riskPartner is 2 bits so mask it:
        uint16 MASK = 0x2; // takes first 2 bits of the uint16
        y = y & MASK;
        z = z & MASK;
        u = u & MASK;
        v = v & MASK;

        tokenId = harness.addRiskPartner(tokenId, y, 0);
        assertEq(harness.riskPartner(tokenId, 0), y);
        assertEq(harness.riskPartner(tokenId, 1), 0);
        assertEq(harness.riskPartner(tokenId, 2), 0);
        assertEq(harness.riskPartner(tokenId, 3), 0);

        tokenId = harness.addRiskPartner(tokenId, z, 1);
        assertEq(harness.riskPartner(tokenId, 0), y);
        assertEq(harness.riskPartner(tokenId, 1), z);
        assertEq(harness.riskPartner(tokenId, 2), 0);
        assertEq(harness.riskPartner(tokenId, 3), 0);

        tokenId = harness.addRiskPartner(tokenId, u, 2);
        assertEq(harness.riskPartner(tokenId, 0), y);
        assertEq(harness.riskPartner(tokenId, 1), z);
        assertEq(harness.riskPartner(tokenId, 2), u);
        assertEq(harness.riskPartner(tokenId, 3), 0);

        tokenId = harness.addRiskPartner(tokenId, v, 3);
        assertEq(harness.riskPartner(tokenId, 0), y);
        assertEq(harness.riskPartner(tokenId, 1), z);
        assertEq(harness.riskPartner(tokenId, 2), u);
        assertEq(harness.riskPartner(tokenId, 3), v);
    }

    /*//////////////////////////////////////////////////////////////
                            ADD TOKEN TYPE
    //////////////////////////////////////////////////////////////*/
    function test_Success_AddTokenType(uint16 y, uint16 z, uint16 u, uint16 v) public {
        uint256 tokenId;

        // the tokenType is 1 bit so mask it:
        uint16 MASK = 0x1; // takes first 1 bit of the uint16
        y = y & MASK;
        z = z & MASK;
        u = u & MASK;
        v = v & MASK;

        tokenId = harness.addTokenType(tokenId, y, 0);
        assertEq(harness.tokenType(tokenId, 0), y);
        assertEq(harness.tokenType(tokenId, 1), 0);
        assertEq(harness.tokenType(tokenId, 2), 0);
        assertEq(harness.tokenType(tokenId, 3), 0);

        tokenId = harness.addTokenType(tokenId, z, 1);
        assertEq(harness.tokenType(tokenId, 0), y);
        assertEq(harness.tokenType(tokenId, 1), z);
        assertEq(harness.tokenType(tokenId, 2), 0);
        assertEq(harness.tokenType(tokenId, 3), 0);

        tokenId = harness.addTokenType(tokenId, u, 2);
        assertEq(harness.tokenType(tokenId, 0), y);
        assertEq(harness.tokenType(tokenId, 1), z);
        assertEq(harness.tokenType(tokenId, 2), u);
        assertEq(harness.tokenType(tokenId, 3), 0);

        tokenId = harness.addTokenType(tokenId, v, 3);
        assertEq(harness.tokenType(tokenId, 0), y);
        assertEq(harness.tokenType(tokenId, 1), z);
        assertEq(harness.tokenType(tokenId, 2), u);
        assertEq(harness.tokenType(tokenId, 3), v);
    }

    /*//////////////////////////////////////////////////////////////
                                ADD LEG
    //////////////////////////////////////////////////////////////*/
    function test_Success_AddLeg(
        uint256 legIndex,
        uint16 optionRatio,
        uint16 asset,
        uint16 isLong,
        uint16 tokenType,
        uint16 riskPartner,
        int24 strike,
        int24 width
    ) public {
        uint256 tokenId;

        /// do validations
        {
            // the optionRatio is 7 bits so mask it:
            uint16 MASK = 0x7F; // takes first 7 bits of the uint16
            optionRatio = optionRatio & MASK;

            // the following are all 1 bit so mask them:
            MASK = 0x1; // takes first 1 bit of the uint16
            asset = asset & MASK;
            isLong = isLong & MASK;
            tokenType = tokenType & MASK;

            // the riskPartner is 2 bits so mask it:
            MASK = 0x2; // takes first 2 bits of the uint16
            riskPartner = riskPartner & MASK;

            strike = int24(bound(strike, TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 1));
            width = int24(bound(width, 1, 4094));

            // gaps are not allowed, however this is permissible as we are testing this functionality directly
            legIndex = bound(legIndex, 0, 3);
            tokenId = harness.addLeg(
                tokenId,
                legIndex,
                optionRatio,
                asset,
                isLong,
                tokenType,
                riskPartner,
                strike,
                width
            );
        }

        // option ratio
        assertEq(harness.optionRatio(tokenId, legIndex), optionRatio, "optionRatio");
        // asset
        assertEq(harness.asset(tokenId, legIndex), asset, "asset");
        // is Long
        assertEq(harness.isLong(tokenId, legIndex), isLong, "isLong");
        // token type
        assertEq(harness.tokenType(tokenId, legIndex), tokenType, "tokenType");
        // risk partner
        assertEq(harness.riskPartner(tokenId, legIndex), riskPartner, "riskPartner");
        // strike
        assertEq(harness.strike(tokenId, legIndex), strike, "strike");
        // width
        assertEq(harness.width(tokenId, legIndex), width, "width");
    }

    /*//////////////////////////////////////////////////////////////
                          FLIP TO BURN TOKEN
    //////////////////////////////////////////////////////////////*/
    function test_Success_flipToBurnToken_fourLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 4 leg position
        tokenId = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // expected data
        uint256 optionRatios = harness.countLegs(tokenId);
        uint256 expectedToken = tokenId ^
            ((harness.LONG_MASK() >> (48 * (4 - optionRatios))) & harness.CLEAR_POOLID_MASK());

        uint256 returnedToken = harness.flipToBurnToken(tokenId);

        // expected data should be equivalent to returned data
        assertEq(expectedToken, returnedToken);
    }

    function test_Success_flipToBurnToken_threeLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 3 leg position
        tokenId = fuzzedPosition(
            3,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // expected data
        uint256 optionRatios = harness.countLegs(tokenId);
        uint256 expectedToken = tokenId ^
            ((harness.LONG_MASK() >> (48 * (4 - optionRatios))) & harness.CLEAR_POOLID_MASK());

        // returned data
        uint256 returnedToken = harness.flipToBurnToken(tokenId);

        // expected data should be equivalent to returned data
        assertEq(expectedToken, returnedToken);
    }

    function test_Success_flipToBurnToken_twoLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 2 leg position
        tokenId = fuzzedPosition(
            2,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // expected data
        uint256 optionRatios = harness.countLegs(tokenId);
        uint256 expectedToken = tokenId ^
            ((harness.LONG_MASK() >> (48 * (4 - optionRatios))) & harness.CLEAR_POOLID_MASK());

        // returned data
        uint256 returnedToken = harness.flipToBurnToken(tokenId);

        // expected data should be equivalent to returned data
        assertEq(expectedToken, returnedToken);
    }

    function test_Success_flipToBurnToken_OneLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 1 leg position
        tokenId = fuzzedPosition(
            1,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // expected data
        uint256 optionRatios = harness.countLegs(tokenId);
        uint256 expectedToken = tokenId ^
            ((harness.LONG_MASK() >> (48 * (4 - optionRatios))) & harness.CLEAR_POOLID_MASK());

        // returned data
        uint256 returnedToken = harness.flipToBurnToken(tokenId);

        // expected data should be equivalent to returned data
        assertEq(expectedToken, returnedToken);
    }

    function test_Success_flipToBurnToken_emptyLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // expected data
        uint256 optionRatios = harness.countLegs(tokenId);
        uint256 expectedToken = tokenId ^
            ((harness.LONG_MASK() >> (48 * (4 - optionRatios))) & harness.CLEAR_POOLID_MASK());

        // returned data
        uint256 returnedToken = harness.flipToBurnToken(tokenId);

        // expected data should be equivalent to returned data
        assertEq(expectedToken, returnedToken);
    }

    // countLongs
    function test_Success_countLongs(
        uint256 totalLegs,
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 4 leg position
        totalLegs = bound(totalLegs, 1, 4);
        tokenId = fuzzedPosition(
            totalLegs,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // add up the total amount of long positions for the given legs
        uint256 expectedLongs = harness.isLong(tokenId, 0) +
            harness.isLong(tokenId, 1) +
            harness.isLong(tokenId, 2) +
            harness.isLong(tokenId, 3);
        uint256 returnedLongs = harness.countLongs(tokenId);

        // expected data should be equivalent to returned data
        assertEq(expectedLongs, returnedLongs);
    }

    /*//////////////////////////////////////////////////////////////
                                AS TICKS
    //////////////////////////////////////////////////////////////*/
    function test_Success_asTicks_normalTickRange(
        uint16 width,
        int24 strike,
        int24 poolStatusSeed
    ) public {
        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        // Width must be > 0 < 4096
        int24 width = int24(uint24(bound(width, 1, 4095)));

        // The position must not extend outside of the max/min tick
        int24 strike = int24(
            bound(strike, minTick + (width * tickSpacing) / 2, maxTick - (width * tickSpacing) / 2)
        );

        vm.assume(strike + (((width * tickSpacing) / 2) % tickSpacing) == 0);
        vm.assume(strike - (((width * tickSpacing) / 2) % tickSpacing) == 0);

        // We now construct the tokenId with properly bounded fuzz values
        uint256 tokenId = harness.addWidth(0, width, 0);
        tokenId = harness.addStrike(tokenId, strike, 0);

        // Test the asTicks function
        (int24 tickLower, int24 tickUpper) = harness.asTicks(tokenId, 0, tickSpacing);

        // Ensure tick values returned are correct
        assertEq(tickLower, strike - (width * tickSpacing) / 2);
        assertEq(tickUpper, strike + (width * tickSpacing) / 2);
    }

    function test_Fail_asTicks_TicksNotInitializable(
        uint16 width,
        int24 strike,
        int24 poolStatusSeed
    ) public {
        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        // Width must be > 0 < 4096
        int24 width = int24(uint24(bound(width, 1, 4095)));

        // The position must not extend outside of the max/min tick
        int24 strike = int24(
            bound(strike, minTick + (width * tickSpacing) / 2, maxTick - (width * tickSpacing) / 2)
        );

        vm.assume(
            (strike + (width * tickSpacing) / 2) % tickSpacing != 0 ||
                (strike - (width * tickSpacing) / 2) % tickSpacing != 0
        );

        // We now construct the tokenId with properly bounded fuzz values
        uint256 tokenId;
        tokenId = harness.addWidth(0, width, 0); // width
        tokenId = harness.addStrike(tokenId, strike, 0); // strike

        vm.expectRevert(Errors.TicksNotInitializable.selector);
        // Test the asTicks function
        (int24 tickLower, int24 tickUpper) = harness.asTicks(tokenId, 0, tickSpacing);
    }

    function test_Fail_asTicks_belowMinTick(
        uint16 width,
        int24 strike,
        int24 poolStatusSeed
    ) public {
        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        // Width must be > 0 < 4096
        int24 width = int24(uint24(bound(width, 1, 4095)));
        int24 oneSidedRange = (width * tickSpacing) / 2;

        // The position must extend beyond the min tick
        int24 strike = int24(
            bound(strike, TickMath.MIN_TICK, minTick + (width * tickSpacing) / 2 - 1)
        );

        // assume for now
        vm.assume(
            (strike - oneSidedRange) % tickSpacing == 0 ||
                (strike + oneSidedRange) % tickSpacing == 0
        );

        // We now construct the tokenId with properly bounded fuzz values
        uint256 tokenId;
        tokenId = harness.addWidth(0, width, 0); // width
        tokenId = harness.addStrike(tokenId, strike, 0); // strike

        // Test the asTicks function
        vm.expectRevert(Errors.TicksNotInitializable.selector);
        harness.asTicks(tokenId, 0, tickSpacing);
    }

    function test_Fail_asTicks_aboveMinTick(
        uint16 width,
        int24 strike,
        int24 poolStatusSeed
    ) public {
        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        // Width must be > 0 < 4095 (4095 is full range)
        int24 width = int24(int256(bound(width, 1, 4094)));
        int24 oneSidedRange = (width * tickSpacing) / 2;

        // The position must extend beyond the max tick
        int24 strike = int24(
            bound(strike, maxTick - (width * tickSpacing) / 2 + 1, TickMath.MAX_TICK)
        );

        // assume for now
        vm.assume(
            (strike - oneSidedRange) % tickSpacing == 0 ||
                (strike + oneSidedRange) % tickSpacing == 0
        );

        // We now construct the tokenId with properly bounded fuzz values
        uint256 tokenId;
        tokenId = harness.addWidth(0, width, 0); // width
        tokenId = harness.addStrike(tokenId, strike, 0); // strike

        // Test the asTicks function
        vm.expectRevert(Errors.TicksNotInitializable.selector);
        harness.asTicks(tokenId, 0, tickSpacing);
    }

    /*//////////////////////////////////////////////////////////////
                            COUNT LEGS
    //////////////////////////////////////////////////////////////*/
    function test_Success_countLegs_fourLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 4 leg position
        tokenId = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // countLegs
        uint256 returnedLegs = harness.countLegs(tokenId);

        assertEq(4, returnedLegs);
    }

    function test_Success_countLegs_threeLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 3 leg position
        tokenId = fuzzedPosition(
            3,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // countLegs
        uint256 returnedLegs = harness.countLegs(tokenId);

        assertEq(3, returnedLegs);
    }

    function test_Success_countLegs_twoLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 2 leg position
        tokenId = fuzzedPosition(
            2,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // countLegs
        uint256 returnedLegs = harness.countLegs(tokenId);

        assertEq(2, returnedLegs);
    }

    function test_Success_countLegs_oneLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 1 leg position
        tokenId = fuzzedPosition(
            1,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // countLegs
        uint256 returnedLegs = harness.countLegs(tokenId);

        assertEq(1, returnedLegs);
    }

    function test_Success_countLegs_emptyLegs(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        // countLegs
        uint256 returnedLegs = harness.countLegs(tokenId);

        assertEq(0, returnedLegs);
    }

    /*//////////////////////////////////////////////////////////////
                            VALIDATE
    //////////////////////////////////////////////////////////////*/

    function test_Success_validate(
        uint256 totalLegs,
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a tokenId
        totalLegs = bound(totalLegs, 1, 4);
        tokenId = fuzzedPosition(
            totalLegs,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        uint64 expectedData = harness.univ3pool(tokenId);
        uint64 returnedData = harness.validate(tokenId);

        assertEq(expectedData, returnedData);
    }

    function test_Fail_validate_emptyLegIndexZero(
        uint256 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed
    ) public {
        vm.assume(poolId != 0);
        uint256 tokenId;

        setPoolStatus(strikeSeed);

        // add uni pool to tokenId
        tokenId = harness.addUniv3pool(tokenId, uint64(poolId));

        // will fail as there are no valid legs
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 1));
        harness.validate(tokenId);
    }

    function test_Fail_validate_legsWithGaps(
        uint256 indexToClear,
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a token with a full 4 legs
        tokenId = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        /// clear a random leg to produce a gap
        /// (avoid clearing leg indetokenId 3 as 0-2 would be valid)
        indexToClear = bound(indexToClear, 0, 2);
        tokenId = harness.clearLeg(tokenId, indexToClear);

        /// will fail as tokenId's cannot have legs with gaps
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 1));
        harness.validate(tokenId);
    }

    function test_Fail_validate_invalidWidth(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        // construct single leg token
        tokenId = fuzzedPosition(
            1, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear all width bits
        tokenId = tokenId & CLEAR_WIDTH_MASK;

        /// will fail as tokenId's cannot have legs with width of zero
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 5));
        harness.validate(tokenId);
    }

    function test_Fail_validate_invalidStrikeMin(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct single leg token
        tokenId = fuzzedPosition(
            1, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        //clear all strike bits
        tokenId = tokenId & CLEAR_STRIKE_MASK;

        // add invalid strike
        tokenId = harness.addStrike(tokenId, TickMath.MIN_TICK, 0);

        // will fail as legs can't have strike = TickMath.MAX_TICK
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 4));
        harness.validate(tokenId);
    }

    function test_Fail_validate_invalidStrikeMax(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct single leg token
        tokenId = fuzzedPosition(
            1, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        //clear all strike bits
        tokenId = tokenId & CLEAR_STRIKE_MASK;

        // add invalid strike
        tokenId = harness.addStrike(tokenId, TickMath.MAX_TICK, 0);

        // will fail as legs can't have strike = TickMath.MAX_TICK
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 4));
        harness.validate(tokenId);
    }

    function test_Fail_validate_invalidRiskPartner(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct two leg token
        tokenId = fuzzedPosition(
            2, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        {
            //clear all risk partner bits
            tokenId = tokenId & CLEAR_RISK_PARTNER_MASK;

            // leg 1 will have risk partner as itself
            tokenId = harness.addRiskPartner(tokenId, 0, 0);
            // leg 2 will have risk partner as leg 1
            tokenId = harness.addRiskPartner(tokenId, 0, 1);
        }

        // will fail as risk partners are not mutual
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 3));
        harness.validate(tokenId);
    }

    function test_Fail_validate_riskRegularPos(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct two leg token
        tokenId = fuzzedPosition(
            2, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        /// create defined risk position
        {
            //clear all risk partner bits
            tokenId = tokenId & CLEAR_RISK_PARTNER_MASK;

            // leg 1 will have risk partner as leg 2
            tokenId = harness.addRiskPartner(tokenId, 1, 0);

            // leg 2 will have risk partner as leg 1
            tokenId = harness.addRiskPartner(tokenId, 0, 1);
        }

        {
            // clear all asset bits
            tokenId = tokenId & CLEAR_NUMERAIRE_MASK;

            // leg 1 asset 0
            tokenId = harness.addAsset(tokenId, 0, 1);

            // leg 2 asset 1
            tokenId = harness.addAsset(tokenId, 0, 1);
        }

        /// create legs with differing option ratios
        {
            //clear all option ratio bits
            tokenId = tokenId & CLEAR_OPTION_RATIO_MASK;

            // leg 1 option pseudorandom option ratio
            tokenId = harness.addOptionRatio(tokenId, 10, 0); // hardcode for now

            // leg 2 option pseudorandom option ratio
            tokenId = harness.addOptionRatio(tokenId, 1, 1);
        }

        /// create legs with same option ratio
        {
            //clear all option ratio bits
            tokenId = tokenId & CLEAR_OPTION_RATIO_MASK;

            // leg 1 option pseudorandom option ratio
            tokenId = harness.addOptionRatio(tokenId, 1, 0); // hardcode for now

            // leg 2 option pseudorandom option ratio
            tokenId = harness.addOptionRatio(tokenId, 1, 1);
        }

        {
            //clear all is long bits
            tokenId = tokenId & CLEAR_IS_LONG_MASK;

            // leg 1 will be short
            tokenId = harness.addIsLong(tokenId, 0, 0);

            // leg 2 will be short
            tokenId = harness.addIsLong(tokenId, 0, 1);
        }

        {
            //clear all risk partner bits
            tokenId = tokenId & CLEAR_TOKEN_TYPE_MASK;

            // leg 1 will be asset 1
            tokenId = harness.addTokenType(tokenId, 1, 0);

            // leg 2 will be asset 1
            tokenId = harness.addTokenType(tokenId, 1, 1);
        }

        // will fail as risk partners must have the same asset
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 4));
        harness.validate(tokenId);
    }

    function test_Fail_validate_synthPos(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct two leg token
        tokenId = fuzzedPosition(
            2, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        /// create defined risk position
        {
            //clear all risk partner bits
            tokenId = tokenId & CLEAR_RISK_PARTNER_MASK;

            // leg 1 will have risk partner as leg 2
            tokenId = harness.addRiskPartner(tokenId, 1, 0);

            // leg 2 will have risk partner as leg 1
            tokenId = harness.addRiskPartner(tokenId, 0, 1);
        }

        {
            // clear all asset bits
            tokenId = tokenId & CLEAR_NUMERAIRE_MASK;

            // leg 1 asset 0
            tokenId = harness.addAsset(tokenId, 0, 1);

            // leg 2 asset 1
            tokenId = harness.addAsset(tokenId, 0, 1);
        }

        /// create legs with same option ratio
        {
            //clear all option ratio bits
            tokenId = tokenId & CLEAR_OPTION_RATIO_MASK;

            // leg 1 option pseudorandom option ratio
            tokenId = harness.addOptionRatio(tokenId, 1, 0); // hardcode for now

            // leg 2 option pseudorandom option ratio
            tokenId = harness.addOptionRatio(tokenId, 1, 1);
        }

        {
            //clear all is long bits
            tokenId = tokenId & CLEAR_IS_LONG_MASK;

            // leg 1 will be short
            tokenId = harness.addIsLong(tokenId, 0, 0);

            // leg 2 will be long
            tokenId = harness.addIsLong(tokenId, 1, 1);
        }

        {
            //clear all risk partner bits
            tokenId = tokenId & CLEAR_TOKEN_TYPE_MASK;

            // leg 1 will be asset 0
            tokenId = harness.addTokenType(tokenId, 0, 0);

            // leg 2 will be asset 1
            tokenId = harness.addTokenType(tokenId, 1, 1);
        }

        // will fail as risk partners must have the same asset
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 5));
        harness.validate(tokenId);
    }

    function test_Fail_validate_invalidPartnerAsset(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct two leg token
        tokenId = fuzzedPosition(
            2, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        /// create defined risk position
        {
            //clear all risk partner bits
            tokenId = tokenId & CLEAR_RISK_PARTNER_MASK;

            // leg 1 will have risk partner as leg 2
            tokenId = harness.addRiskPartner(tokenId, 1, 0);

            // leg 2 will have risk partner as leg 1
            tokenId = harness.addRiskPartner(tokenId, 0, 1);
        }

        {
            // clear all asset bits
            tokenId = tokenId & CLEAR_NUMERAIRE_MASK;

            // leg 1 asset 0
            tokenId = harness.addAsset(tokenId, 0, 1);

            // leg 2 asset 1
            tokenId = harness.addAsset(tokenId, 1, 1);
        }

        // will fail as risk partners must have the same asset
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 3));
        harness.validate(tokenId);
    }

    function test_Fail_validate_invalidPartnerRatio(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct two leg token
        tokenId = fuzzedPosition(
            2, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        /// create defined risk position
        {
            //clear all risk partner bits
            tokenId = tokenId & CLEAR_RISK_PARTNER_MASK;

            // leg 1 will have risk partner as leg 2
            tokenId = harness.addRiskPartner(tokenId, 1, 0);

            // leg 2 will have risk partner as leg 1
            tokenId = harness.addRiskPartner(tokenId, 0, 1);
        }

        /// create legs with the same asset
        {
            // clear all asset bits
            tokenId = tokenId & CLEAR_NUMERAIRE_MASK;

            // leg 1 asset 1
            tokenId = harness.addAsset(tokenId, 1, 0);

            // leg 2 asset 1
            tokenId = harness.addAsset(tokenId, 1, 1);
        }

        /// create legs with differing option ratios
        {
            //clear all option ratio bits
            tokenId = tokenId & CLEAR_OPTION_RATIO_MASK;

            // leg 1 option pseudorandom option ratio
            tokenId = harness.addOptionRatio(tokenId, 10, 0); // hardcode for now

            // leg 2 option pseudorandom option ratio
            tokenId = harness.addOptionRatio(tokenId, 1, 1);
        }

        // will fail as risk partners must have the same option ratio
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 3));
        harness.validate(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                          ENSURE IS OTM
    //////////////////////////////////////////////////////////////*/
    function test_Success_ensureIsOTM(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct one leg token
        tokenId = fuzzedPosition(
            4, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear strike
        tokenId = tokenId & CLEAR_STRIKE_MASK;

        for (uint256 i; i < 4; i++) {
            // get this legs width and range
            int24 width = harness.width(tokenId, i);
            int24 range = (width * tickSpacing) / 2;

            // direction to check range in
            uint256 optionTokenType = harness.tokenType(tokenId, i);

            int24 newStrike;
            // moneyness check
            if (optionTokenType == 1) {
                // set strike + range to gte current tick - range
                newStrike = currentTick - (2 * range);
            } else {
                // set strike - range to lte current tick
                newStrike = currentTick + (2 * range);
            }
            tokenId = harness.addStrike(tokenId, newStrike, i);
        }

        harness.ensureIsOTM(tokenId, currentTick, tickSpacing);
    }

    function test_Fail_ensureIsOTM_optionsNotOTM(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct one leg token
        tokenId = fuzzedPosition(
            4, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear strike
        tokenId = tokenId & CLEAR_STRIKE_MASK;

        for (uint256 i; i < 4; i++) {
            // get this legs width and range
            int24 width = harness.width(tokenId, i);
            int24 range = (width * tickSpacing) / 2;

            // direction to check range in
            uint256 optionTokenType = harness.tokenType(tokenId, i);

            int24 newStrike;
            // moneyness check
            if (optionTokenType == 1) {
                // set strike + range to gte current tick
                newStrike = int24(currentTick + 2 * range);
            } else {
                // set strike - range to lte current tick
                newStrike = int24(currentTick - 2 * range);
            }
            tokenId = harness.addStrike(tokenId, newStrike, i);
        }

        vm.expectRevert(Errors.OptionsNotOTM.selector);
        harness.ensureIsOTM(tokenId, currentTick, tickSpacing);
    }

    /*//////////////////////////////////////////////////////////////
                        VALIDATE IS EXERCISABLE
    //////////////////////////////////////////////////////////////*/

    function test_Success_validateIsExercisable_belowTick(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct one leg token
        tokenId = fuzzedPosition(
            4, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear strike
        tokenId = tokenId & CLEAR_STRIKE_MASK;
        // clear isLong
        tokenId = tokenId & CLEAR_IS_LONG_MASK;

        for (uint256 i; i < 4; i++) {
            // get this legs width and range
            int24 width = harness.width(tokenId, i);
            int24 range = (width * tickSpacing) / 2;

            // The position must
            vm.assume(minTick < (currentTick - range) - 1);
            int24 strike = int24(bound(strikeSeed, minTick, (currentTick - range) - 1));

            tokenId = harness.addStrike(tokenId, strike, i);
            tokenId = harness.addIsLong(tokenId, 1, i);
        }

        harness.validateIsExercisable(tokenId, currentTick, tickSpacing);
    }

    function test_Success_validateIsExercisable_aboveTick(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct one leg token
        tokenId = fuzzedPosition(
            4, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear strike
        tokenId = tokenId & CLEAR_STRIKE_MASK;
        // clear isLong
        tokenId = tokenId & CLEAR_IS_LONG_MASK;

        for (uint256 i; i < 4; i++) {
            // get this legs width and range
            int24 width = harness.width(tokenId, i);
            int24 range = (width * tickSpacing) / 2;

            // The position must
            int24 minTick = (currentTick + range) + 1;
            vm.assume(minTick < maxTick);
            int24 strike = int24(bound(strikeSeed, (currentTick + range) + 1, maxTick));

            tokenId = harness.addStrike(tokenId, strike, i);
            tokenId = harness.addIsLong(tokenId, 1, i);
        }

        harness.validateIsExercisable(tokenId, currentTick, tickSpacing);
    }

    function test_Fail_validateIsExercisable_shortPos(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct one leg token
        tokenId = fuzzedPosition(
            4, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear isLong
        tokenId = tokenId & CLEAR_IS_LONG_MASK;

        vm.expectRevert(Errors.NoLegsExercisable.selector);
        harness.validateIsExercisable(tokenId, currentTick, tickSpacing);
    }

    function test_Fail_validateIsExercisable_inRange(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct one leg token
        tokenId = fuzzedPosition(
            4, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear strike
        tokenId = tokenId & CLEAR_STRIKE_MASK;
        // clear isLong
        tokenId = tokenId & CLEAR_IS_LONG_MASK;

        for (uint256 i; i < 4; i++) {
            // get this legs width and range
            int24 width = harness.width(tokenId, i);
            int24 range = (width * tickSpacing) / 2;

            // The position must
            int24 strike = int24(
                bound(strikeSeed, currentTick - range + 1, currentTick + range - 1)
            );

            tokenId = harness.addStrike(tokenId, strike, i);
            tokenId = harness.addIsLong(tokenId, 1, i);
        }

        vm.expectRevert(Errors.NoLegsExercisable.selector);
        harness.validateIsExercisable(tokenId, currentTick, tickSpacing);
    }

    /*//////////////////////////////////////////////////////////////
                      ROLLED TOKEN IS VALID
    //////////////////////////////////////////////////////////////*/

    // rolledTokenIsValid
    // when mask is applied both tokens should be the same
    // differing strike and width
    function test_Success_rolledTokenIsValid(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 oldTokenId;
        uint256 newTokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct two leg token
        oldTokenId = fuzzedPosition(
            1, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        newTokenId = oldTokenId;

        // set differing strike and width
        {
            // clear all strike
            newTokenId = oldTokenId & CLEAR_STRIKE_MASK;

            // clear all width
            newTokenId = oldTokenId & CLEAR_WIDTH_MASK;

            /// strike
            newTokenId = harness.addStrike(newTokenId, TickMath.MAX_TICK - 1, 0);
            newTokenId = harness.addStrike(newTokenId, TickMath.MIN_TICK + 1, 1);

            /// width
            newTokenId = harness.addWidth(newTokenId, 4094, 0);
            newTokenId = harness.addWidth(newTokenId, 1, 1);
        }

        assertTrue(harness.rolledTokenIsValid(oldTokenId, newTokenId));
    }

    /*//////////////////////////////////////////////////////////////
                      CONSTRUCT ROLL TOKEN ID WITH
    //////////////////////////////////////////////////////////////*/

    function test_Success_constructRollTokenIdWith(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 oldTokenId;
        uint256 newTokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct two leg token
        oldTokenId = fuzzedPosition(
            1, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        newTokenId = oldTokenId;

        // set differing strike and width
        {
            // clear all strike
            newTokenId = oldTokenId & CLEAR_STRIKE_MASK;

            // clear all width
            oldTokenId = oldTokenId & CLEAR_WIDTH_MASK;

            /// strike
            newTokenId = harness.addStrike(newTokenId, TickMath.MAX_TICK - 1, 0);
            oldTokenId = harness.addStrike(newTokenId, TickMath.MIN_TICK + 1, 0);

            /// width
            newTokenId = harness.addWidth(newTokenId, 4094, 0);
            oldTokenId = harness.addWidth(newTokenId, 1, 0);
        }

        harness.constructRollTokenIdWith(oldTokenId, newTokenId);
    }

    function test_Fail_constructRollTokenIdWith(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 oldTokenId;
        uint256 newTokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        //construct two leg token
        oldTokenId = fuzzedPosition(
            4, // total amount of legs
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        newTokenId = oldTokenId;

        // set differing strike and width
        {
            // clear all strike
            newTokenId = oldTokenId & CLEAR_STRIKE_MASK;

            // clear all width
            oldTokenId = oldTokenId & CLEAR_WIDTH_MASK;

            /// strike
            newTokenId = harness.addStrike(newTokenId, TickMath.MAX_TICK - 1, 0);
            oldTokenId = harness.addStrike(newTokenId, TickMath.MIN_TICK + 1, 0);

            /// width
            newTokenId = harness.addWidth(newTokenId, 4094, 0);
            oldTokenId = harness.addWidth(newTokenId, 1, 0);
        }

        /// change position direction
        {
            newTokenId = newTokenId & CLEAR_IS_LONG_MASK;
            oldTokenId = oldTokenId & CLEAR_IS_LONG_MASK;

            newTokenId = harness.addIsLong(newTokenId, 1, 0);
            oldTokenId = harness.addIsLong(oldTokenId, 0, 0);
        }

        vm.expectRevert(Errors.NotATokenRoll.selector);
        harness.constructRollTokenIdWith(oldTokenId, newTokenId);
    }

    /*//////////////////////////////////////////////////////////////
                              CLEAR LEG
    //////////////////////////////////////////////////////////////*/

    // clearLeg
    // call on each leg of a full tokenId
    // then eval that each has been cleared
    function test_Success_clearLeg_Four(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 4 leg position
        tokenId = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear leg four
        tokenId = harness.clearLeg(tokenId, 3);

        assertEq(0, harness.optionRatio(tokenId, 3));
    }

    function test_Success_clearLeg_Three(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 4 leg position
        tokenId = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear leg three
        tokenId = harness.clearLeg(tokenId, 2);

        assertEq(0, harness.optionRatio(tokenId, 2));
    }

    function test_Success_clearLeg_Two(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 4 leg position
        tokenId = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear leg two
        tokenId = harness.clearLeg(tokenId, 1);

        assertEq(0, harness.optionRatio(tokenId, 1));
    }

    function test_Success_clearLeg_One(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 4 leg position
        tokenId = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear leg one
        tokenId = harness.clearLeg(tokenId, 0);

        assertEq(0, harness.optionRatio(tokenId, 0));
    }

    function test_Success_clearLeg_Null(
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 4 leg position
        tokenId = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // clear leg 4 (non-existent)
        uint256 returnedToken = harness.clearLeg(tokenId, 4);

        assertEq(tokenId, returnedToken);
    }

    /*//////////////////////////////////////////////////////////////
                              ROLL TOKEN INFO
    //////////////////////////////////////////////////////////////*/

    // rollTokenInfo
    // constructed other is rolled into self
    // all parameters should be the same
    function test_Success_rollTokenInfo(
        uint256 src,
        uint256 dst,
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed,
        int24 poolStatusSeed
    ) public {
        uint256 tokenId1;
        uint256 tokenId2;

        // fuzzes a valid currentTick
        setPoolStatus(poolStatusSeed);

        /// fuzz a 4 leg position
        tokenId1 = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        tokenId2 = fuzzedPosition(
            4,
            poolId,
            optionRatioSeed,
            assetSeed,
            isLongSeed,
            tokenTypeSeed,
            strikeSeed,
            widthSeed
        );

        // roll a random leg from tokenId1 into tokenId2
        src = bound(src, 0, 3);
        dst = bound(dst, 0, 3);

        tokenId2 = harness.rollTokenInfo(tokenId2, tokenId1, src, dst);

        // option ratio
        assertEq(
            harness.optionRatio(tokenId1, src),
            harness.optionRatio(tokenId2, dst),
            "optionRatio"
        );
        // asset
        assertEq(harness.asset(tokenId1, src), harness.asset(tokenId2, dst), "asset");
        // is Long
        assertEq(harness.isLong(tokenId1, src), harness.isLong(tokenId2, dst), "isLong");
        // token type
        assertEq(harness.tokenType(tokenId1, src), harness.tokenType(tokenId2, dst), "tokenType");
        // risk partner
        assertEq(dst, harness.riskPartner(tokenId2, dst), "riskPartner");
        // strike
        assertEq(harness.strike(tokenId1, src), harness.strike(tokenId2, dst), "strike");
        // width
        assertEq(harness.width(tokenId1, src), harness.width(tokenId2, dst), "width");
    }

    /*//////////////////////////////////////////////////////////////
                         DYNAMIC TOKEN GENERATION
    //////////////////////////////////////////////////////////////*/

    // returns token containing 'totalLegs' amount of legs
    // i.e totalLegs of 1 has a tokenId with 1 legs
    // uses a seed to fuzz data so that there is different data for each leg
    function fuzzedPosition(
        uint256 totalLegs,
        uint64 poolId,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int24 strikeSeed,
        int256 widthSeed
    ) internal returns (uint256) {
        uint256 tokenId;

        for (uint256 legIndex; legIndex < totalLegs; legIndex++) {
            // We don't want the same data for each leg
            // int divide each seed by the current legIndex
            // gives us a pseudorandom seed
            // forge bound does not randomize the output
            {
                uint256 randomizer = legIndex + 1;

                optionRatioSeed = optionRatioSeed / randomizer;
                assetSeed = assetSeed / randomizer;
                isLongSeed = isLongSeed / randomizer;
                tokenTypeSeed = tokenTypeSeed / randomizer;
                strikeSeed = strikeSeed / int24(int256(randomizer));
                widthSeed = widthSeed / int24(int256(randomizer));
            }

            {
                // the following are all 1 bit so mask them:
                uint16 MASK = 0x1; // takes first 1 bit of the uint16
                assetSeed = assetSeed & MASK;
                isLongSeed = isLongSeed & MASK;
                tokenTypeSeed = tokenTypeSeed & MASK;
            }

            /// bound inputs
            int24 strike;
            int24 width;
            uint64 poolId;

            {
                // the following must be at least 1
                poolId = uint64(bound(poolId, 1, type(uint64).max));
                optionRatioSeed = bound(optionRatioSeed, 1, 127);

                width = int24(bound(widthSeed, 1, 4094));
                int24 oneSidedRange = (width * tickSpacing) / 2;

                (int24 strikeOffset, int24 minStrikeTick, int24 maxStrikeTick) = PositionUtils
                    .getContext(uint256(uint24(tickSpacing)), currentTick, width);

                int24 lowerBound = int24(minStrikeTick + oneSidedRange - strikeOffset);
                int24 upperBound = int24(maxStrikeTick - oneSidedRange - strikeOffset);

                // bound strike
                strike = int24(
                    bound(strikeSeed, lowerBound / tickSpacing, upperBound / tickSpacing)
                );
                strike = int24(strike * tickSpacing + strikeOffset);
            }

            {
                // add univ3pool to token
                tokenId = harness.addUniv3pool(tokenId, poolId);

                // add a leg
                // no risk partner by default (will reference its own leg index)
                tokenId = harness.addLeg(
                    tokenId,
                    legIndex,
                    optionRatioSeed,
                    assetSeed,
                    isLongSeed,
                    tokenTypeSeed,
                    legIndex,
                    strike,
                    width
                );
            }
        }

        return tokenId;
    }

    // Mimicks Uniswapv3 pool possible states
    function setPoolStatus(int24 seed) internal {
        // bound fuzzed tick
        tickSpacing = int8([30, 60, 100][uint24(seed) % 3]);
        maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        currentTick = int24(bound(seed, minTick, maxTick));
    }
}
