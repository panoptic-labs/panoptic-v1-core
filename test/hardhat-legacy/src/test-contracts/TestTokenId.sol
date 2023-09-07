// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *
 * WARNING: TEST CONTRACT - NOT TO BE DEPLOYED INTO PRODUCTION
 *
 */
pragma solidity =0.8.18;

// Uniswap - Panoptic's version 0.8
import {TickMath} from "v3-core/libraries/TickMath.sol";
// Internal
import {TokenId} from "../contracts/types/TokenId.sol";
import {Utils} from "./Utils.sol";

/*
 * @title Test The Library Contract `TokenId.sol` - the Core Option Position in Panoptic.
 * @author Axicon Labs Limited
 * @notice
 * @notice ***** NOT TO BE DEPLOYED INTO PRODUCTION *****
 * @notice
 * @notice This contract tests the TokenId.sol library in Panoptic.
 * @notice you can run the tests by calling `runAll()` which will print "PASS" to the console or fail in a `require()` statement if any issue.
 * @notice To test the tokenId many of our tests will focus on the bit pattern underlying a uint256. Thus, we have some helper functions to
 * @notice write, read, and print bits. Specifically, we are testing that the exact bits are set in the right way when adding underlying bits
 * @notice to the uint256, e.g.: When adding "isLong" to a leg in an option position, we check that the general methods work (addIsLong and isLong)
 * @notice but we also double check this by checking the *actual* underlying bits. So you will see repeated require() statements that specific bits
 * @notice are set as expected.
 */
contract TestTokenId is Utils {
    using TokenId for uint256; // the Panoptic TokenId (Option Position) library

    /// @notice Call this function to run all tests
    function runAll() external {
        // test general constructors/regular queries
        testStructureAndQueries();

        // test special constructors and queries
        testCountLegs();
        testOptionRoll();
        testValidateExercisedId();
        testAsTicksWithinRange();
        testValidate();
        testIsLong1();
        testIsLong2();
        testClearLeg();
    }

    function testStructureAndQueries() public {
        uint256 id;
        uint256 pid;
        require(id.univ3pool() == 0, "univ3pool should be 0");
        id = id.addUniv3pool(type(uint64).max);
        validatePreviousAndNewBits(pid, id, 0, type(uint64).max);
        require(id.univ3pool() == type(uint64).max, "univ3pool should be max");
        pid = id;
        for (uint256 i = 0; i < 3; ++i) {
            uint8 offset = uint8(48 * i + 64);
            require(id.asset(i) == 0, "asset should be 0");
            id = id.addAsset(1, i);
            validatePreviousAndNewBits(pid, id, offset, 1);
            require(id.asset(i) == 1, "asset should be 1");
            pid = id;
            require(id.optionRatio(i) == 0, "optionRatio should be 0");
            id = id.addOptionRatio(0x7F, i);
            validatePreviousAndNewBits(pid, id, offset + 1, 0x7F);
            require(id.optionRatio(i) == 0x7F, "optionRatio should be 0x7F");
            pid = id;
            id = id.addIsLong(1, i);
            validatePreviousAndNewBits(pid, id, offset + 8, 1);
            require(id.isLong(i) == 1, "isLong should be 1");
            pid = id;
            require(id.tokenType(i) == 0, "tokenType should be 0");
            id = id.addTokenType(1, i);
            validatePreviousAndNewBits(pid, id, offset + 9, 1);
            require(id.tokenType(i) == 1, "tokenType should be 1");
            pid = id;
            require(id.riskPartner(i) == 0, "riskPartner should be 0");
            id = id.addRiskPartner(0x3, i);
            validatePreviousAndNewBits(pid, id, offset + 10, 0x3);
            require(id.riskPartner(i) == 0x3, "riskPartner should be 0x3");
            pid = id;
            require(uint24(id.strike(i)) == 0, "strike should be 0");
            id = id.addStrike(int24(type(uint24).max), i);
            validatePreviousAndNewBits(pid, id, offset + 12, type(uint24).max);
            require(uint24(id.strike(i)) == type(uint24).max, "strike should be max");
            pid = id;
            require(uint24(id.width(i)) == 0, "width should be 0");
            id = id.addWidth(int24(0xFFF), i);
            validatePreviousAndNewBits(pid, id, offset + 36, 0xFFF);
            require(uint24(id.width(i)) == 0xFFF, "width should be max");
            pid = id;
        }
    }

    /****************************************************
     * FAILING TESTS - CALLED FROM EXTERNAL JAVASCRIPT
     ****************************************************/

    function testValidateExercisedIdFail_part1() external printStatus {
        uint256 theid;

        theid = theid.addUniv3pool(uint64(uint160(address(this))));
        theid = theid.addStrike(10, 0);
        theid = theid.addWidth(1, 0);
        theid = theid.addOptionRatio(1, 0);
        theid = theid.addAsset(0, 0);
        theid = theid.addIsLong(0, 0); // force fail - dont make it long
        theid = theid.addTokenType(0, 0);
        theid = theid.addRiskPartner(0, 0);

        theid.validateIsExercisable(1000, 1);
    }

    function testValidateExercisedIdFail_part2() external printStatus {
        uint256 theid;

        theid = theid.addUniv3pool(uint64(uint160(address(this))));
        theid = theid.addStrike(1000, 0);
        theid = theid.addWidth(10, 0);
        theid = theid.addOptionRatio(1, 0);
        theid = theid.addAsset(0, 0);
        theid = theid.addIsLong(1, 0);
        theid = theid.addTokenType(0, 0);
        theid = theid.addRiskPartner(0, 0);

        theid.validateIsExercisable(1000, 1); // fail because the option is in range
    }

    function testOptionRollFail() external printStatus {
        uint256 _old;
        uint256 _new;

        _old = _old.addUniv3pool(uint64(uint160(address(this))));
        _old = _old.addStrike(100, 0);
        _old = _old.addWidth(10, 0);
        _old = _old.addOptionRatio(1, 0);
        _old = _old.addAsset(0, 0);
        _old = _old.addIsLong(1, 0);
        _old = _old.addTokenType(0, 0);
        _old = _old.addRiskPartner(0, 0);

        _new = _new.addUniv3pool(uint64(uint160(address(this))));
        _new = _new.addStrike(101, 0); // different than old
        _new = _new.addWidth(10, 0);
        _new = _new.addOptionRatio(1, 0);
        _new = _new.addAsset(1, 0); // different so fails
        _new = _new.addIsLong(1, 0);
        _new = _new.addTokenType(0, 0);
        _new = _new.addRiskPartner(0, 0);

        (uint256 burn, uint256 mint) = _old.constructRollTokenIdWith(_new);
    }

    /// @notice will fail because it extends beyond the MIN value
    /// @notice will revert
    function testAsTicksMIN() external printStatus returns (int24, int24) {
        uint256 newInt;

        // create a case where the range goes below the MIN_TICK
        newInt = newInt.addWidth(4095, 0); // the width is as wide as can be
        newInt = newInt.addStrike(TickMath.MIN_TICK + 1000, 0); // min tick is only 1000 away from the strike

        return newInt.asTicks(0, 1);
    }

    /// @notice will fail because it extends beyond the MAX value
    /// @notice will revert
    function testAsTicksMAX() external printStatus returns (int24, int24) {
        uint256 newInt;

        // create a case where the range goes below the MIN_TICK
        newInt = newInt.addWidth(4095, 0); // the width is as wide as can be
        newInt = newInt.addStrike(TickMath.MAX_TICK - 1000, 0); // min tick is only 1000 away from the strike

        return newInt.asTicks(0, 1);
    }

    function testValidateFail_part1() external printStatus {
        // tokenId.riskPartner(riskPartnerIndex) != i
        uint256 newInt;

        newInt = newInt.addWidth(1000, 0);
        newInt = newInt.addStrike(10, 0);
        newInt = newInt.addUniv3pool(uint64(uint256(uint160(address(this)))));
        newInt = newInt.addOptionRatio(1, 0);
        newInt = newInt.addTokenType(1, 0);
        newInt = newInt.addIsLong(1, 0);
        newInt = newInt.addAsset(1, 0);
        // point to leg ix 1 as risk partner
        newInt = newInt.addRiskPartner(1, 0); // risk partner of leg ix 0 is leg ix 1

        // define the risk partner
        newInt = newInt.addWidth(1000, 1);
        newInt = newInt.addStrike(10, 1);
        newInt = newInt.addUniv3pool(uint64(uint256(uint160(address(this)))));
        newInt = newInt.addOptionRatio(1, 1);
        newInt = newInt.addTokenType(1, 1);
        newInt = newInt.addIsLong(1, 1);
        newInt = newInt.addAsset(1, 1);
        newInt = newInt.addRiskPartner(2, 1); // tokenId.riskPartner(riskPartnerIndex) != i

        // validate will return the univ3pool address, which here is just address(this)
        require(newInt.validate() == uint64(uint256(uint160(address(this)))));
    }

    function testValidateFail_part2() external printStatus {
        uint256 newInt;

        newInt = newInt.addWidth(1000, 0);
        newInt = newInt.addStrike(10, 0);
        newInt = newInt.addUniv3pool(uint64(uint256(uint160(address(this)))));
        newInt = newInt.addOptionRatio(1, 0);
        newInt = newInt.addTokenType(1, 0);
        newInt = newInt.addIsLong(1, 0);
        newInt = newInt.addAsset(1, 0);
        // point to leg ix 1 as risk partner
        newInt = newInt.addRiskPartner(1, 0); // risk partner of leg ix 0 is leg ix 1

        // define the risk partner - same strike and width should fail
        newInt = newInt.addWidth(1000, 1);
        newInt = newInt.addStrike(10, 1);
        newInt = newInt.addOptionRatio(1, 1);
        newInt = newInt.addTokenType(1, 1);
        newInt = newInt.addIsLong(1, 1);
        newInt = newInt.addAsset(1, 1);
        newInt = newInt.addRiskPartner(0, 1);

        // validate will return the univ3pool address, which here is just address(this)
        require(newInt.validate() == uint64(uint256(uint160(address(this)))));
    }

    function testValidateFail_part3() external printStatus {
        // fail on
        // (tokenId.asset(riskPartnerIndex) != tokenId.asset(i)) ||
        // (tokenId.optionRatio(riskPartnerIndex) != tokenId.optionRatio(i))
        uint256 newInt;

        newInt = newInt.addWidth(1000, 0);
        newInt = newInt.addStrike(10, 0);
        newInt = newInt.addUniv3pool(uint64(uint256(uint160(address(this)))));
        newInt = newInt.addOptionRatio(1, 0);
        newInt = newInt.addTokenType(1, 0);
        newInt = newInt.addIsLong(1, 0);
        newInt = newInt.addAsset(1, 0);
        // point to leg ix 1 as risk partner
        newInt = newInt.addRiskPartner(1, 0); // risk partner of leg ix 0 is leg ix 1

        // define the risk partner - same strike and width should fail
        newInt = newInt.addWidth(1000, 1);
        newInt = newInt.addStrike(10, 1);
        newInt = newInt.addOptionRatio(1, 1);
        newInt = newInt.addTokenType(1, 1);
        newInt = newInt.addIsLong(1, 1);
        newInt = newInt.addAsset(0, 1); // diff assets
        newInt = newInt.addRiskPartner(0, 1);

        // validate will return the univ3pool address, which here is just address(this)
        require(newInt.validate() == uint64(uint256(uint160(address(this)))));
    }

    function testValidateFail_part4() external printStatus {
        // fail on
        // !((tokenId.tokenType(riskPartnerIndex) == tokenId.tokenType(i) &&
        //  (tokenId.isLong(riskPartnerIndex) != tokenId.isLong(i)))) &&
        // !((tokenId.tokenType(riskPartnerIndex) != tokenId.tokenType(i)) &&
        // (tokenId.isLong(riskPartnerIndex) == tokenId.isLong(i)))
        uint256 newInt;

        newInt = newInt.addWidth(1000, 0);
        newInt = newInt.addStrike(10, 0);
        newInt = newInt.addUniv3pool(uint64(uint256(uint160(address(this)))));
        newInt = newInt.addOptionRatio(1, 0);
        newInt = newInt.addTokenType(1, 0);
        newInt = newInt.addIsLong(1, 0);
        newInt = newInt.addAsset(1, 0);
        // point to leg ix 1 as risk partner
        newInt = newInt.addRiskPartner(1, 0); // risk partner of leg ix 0 is leg ix 1

        // define the risk partner - same strike and width should fail
        newInt = newInt.addWidth(1000, 1);
        newInt = newInt.addStrike(10, 1);
        newInt = newInt.addOptionRatio(1, 1);
        newInt = newInt.addTokenType(1, 1);
        newInt = newInt.addIsLong(0, 1);
        newInt = newInt.addAsset(1, 1);
        newInt = newInt.addRiskPartner(0, 1);

        // validate will return the univ3pool address, which here is just address(this)
        require(newInt.validate() == uint64(uint256(uint160(address(this)))));
    }

    function testFailExpectEqual() external printStatus {
        expectEqual(2, 4, "failed"); // this should fail
    }

    /****************************************************
     * PASSING TESTS - CALLED VIA runAll() ABOVE
     * PUBLIC TESTS ARE CALLED EXTERNALLY FROM JAVASCRIPT
     ****************************************************/

    function testClearLeg() private printStatus {}

    function testValidateExercisedId() private printStatus {
        uint256 theid;

        theid = theid.addUniv3pool(uint64(uint160(address(this))));
        theid = theid.addStrike(10, 0);
        theid = theid.addWidth(1, 0);
        theid = theid.addOptionRatio(1, 0);
        theid = theid.addAsset(0, 0);
        theid = theid.addIsLong(1, 0);
        theid = theid.addTokenType(0, 0);
        theid = theid.addRiskPartner(0, 0);

        theid.validateIsExercisable(1000, 1);
    }

    function testCountLegs() private printStatus {
        uint256 newInt;

        newInt = newInt.addOptionRatio(1, 0); // makes leg 1 long
        require(newInt.countLegs() == 1);

        newInt = newInt.addOptionRatio(1, 1);
        require(newInt.countLegs() == 2);

        newInt = newInt.addOptionRatio(1, 2);
        require(newInt.countLegs() == 3);

        newInt = newInt.addOptionRatio(1, 3);
        require(newInt.countLegs() == 4);
    }

    function testOptionRoll() private printStatus {
        uint256 _old;
        uint256 _new;

        _old.addOptionRatio(1, 0);
        _old.addStrike(100, 0);
        _old.addWidth(10, 0);
        _old.addUniv3pool(uint64(uint160(address(this))));
        _old.addAsset(0, 0);
        _old.addIsLong(1, 0);
        _old.addTokenType(0, 0);
        _old.addRiskPartner(0, 0);

        _new.addOptionRatio(1, 0);
        _new.addStrike(100, 0);
        _new.addWidth(10, 0);
        _new.addUniv3pool(uint64(uint160(address(this))));
        _new.addAsset(0, 0);
        _new.addIsLong(1, 0);
        _new.addTokenType(0, 0);
        _new.addRiskPartner(0, 0);

        (uint256 burn, uint256 mint) = _old.constructRollTokenIdWith(_new);
    }

    /// @notice test that asTicks works within range
    /// @notice we have tests following this which tests reverts
    function testAsTicksWithinRange() private printStatus {
        uint256 newInt;

        // create a case where the range goes below the MIN_TICK
        newInt = newInt.addWidth(100, 0); // the width is as wide as can be
        newInt = newInt.addStrike(500, 0); // min tick is only 1000 away from the strike

        (int24 legLowerTick, int24 legUpperTick) = newInt.asTicks(0, 1);
        require(legLowerTick == 450);
        require(legUpperTick == 550);

        // twice the distance between the ticks means that a width of "100 ticks"
        // brings us twice as far and thus the entire interval is 200, meaning
        // half is 100, above the tick spacing was 1 and thus interval 100 was
        // 100 ticks:
        (legLowerTick, legUpperTick) = newInt.asTicks(0, 2);
        require(legLowerTick == 400);
        require(legUpperTick == 600);
    }

    /// @notice test the validate functionality
    function testValidate() private printStatus {
        uint256 newInt;

        newInt = newInt.addWidth(10, 0);
        newInt = newInt.addStrike(10, 0);
        newInt = newInt.addOptionRatio(1, 0);
        newInt = newInt.addUniv3pool(uint64(uint256(uint160(address(this)))));

        uint64 res = newInt.validate();
        require(res == uint64(uint256(uint160(address(this)))));
    }

    /// @notice Test the isLong for 2 legs
    function testIsLong1() private printStatus {
        uint256 newInt;
        // sets the first and fourth legs' `isLong` bit to 1, the rest of the legs remain at 0
        uint256 theInt = setAllIsLongBits(newInt, [uint256(1), 0, 0, 1]);
        theInt = setAllOptionRatioBits(theInt, [uint256(1), 1, 1, 1]);
        // now run against long mask to flip the longs to shorts and also the shorts to longs:
        theInt = theInt.flipToBurnToken();

        // we now expect a bit pattern with a "1" for legs 2 and 3:
        // isLong for leg 2 = 72 + 48 = 120
        // isLong for leg 3 = 72 + 48*2 = 168
        // so what's the uin256 decimal that has those two bits flipped?
        expectEqual(
            theInt,
            0x20000000001020000000001020000000000020000000000000000,
            "IsLong 1: Long bits not set correctly"
        );
    }

    /// @notice Test the isLong for 1 leg
    function testIsLong2() private printStatus {
        uint256 newInt;
        // sets the first and fourth legs' `isLong` bit to 1, the rest of the legs remain at 0
        uint256 theInt = setAllIsLongBits(newInt, [uint256(1), 0, 0, 0]);
        theInt = setAllOptionRatioBits(theInt, [uint256(1), 1, 1, 1]);
        // now run against long mask to flip the longs to shorts and also the shorts to longs:
        theInt = theInt.flipToBurnToken();

        // legs 2, 3, and 4 are active:
        expectEqual(
            theInt,
            0x1020000000001020000000001020000000000020000000000000000,
            "IsLong 2: Long bits not set correctly"
        );
    }
}
