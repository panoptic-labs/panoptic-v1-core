// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *
 * WARNING: TEST CONTRACT - NOT TO BE DEPLOYED INTO PRODUCTION
 *
 */
pragma solidity =0.8.18;

// Internal
import {LiquidityChunk} from "../contracts/types/LiquidityChunk.sol";
import {PanopticMath} from "../contracts/libraries/PanopticMath.sol";
import {TokenId} from "../contracts/types/TokenId.sol";
import {Utils} from "./Utils.sol";

/*
 * @title Test That the Panoptic Math library is working.
 * @author Axicon Labs Limited
 * @notice
 * @notice ***** NOT TO BE DEPLOYED INTO PRODUCTION *****
 * @notice
 * @notice you can run the tests by calling `runAll()` which will print "PASS" to the console or fail in a `require()` statement if any issue.
 */
contract TestPanopticMath is Utils {
    using LiquidityChunk for uint256;
    using TokenId for uint256;

    /// @notice Call this function to run all tests
    function runAll() external {
        testPoolId();
        testLiquidityChunk();
        testCreateChunk();
        testGetNumberOfZeroHexChars();
    }

    /****************************************************
     * PASSING TESTS - RUN WITH runAll() ABOVE
     ****************************************************/

    function testGetNumberOfZeroHexChars() private printStatus {
        address addr = 0x0100000000000000000000000000000000000000;
        require(PanopticMath.numberOfLeadingHexZeros(addr) == 1, "fail in num leading zeros");

        addr = 0x0B00000000000000000000000000000000000000;
        require(PanopticMath.numberOfLeadingHexZeros(addr) == 1, "fail in num leading zeros");

        addr = 0x0b00000000000000000000000000000000000001;
        require(PanopticMath.numberOfLeadingHexZeros(addr) == 1, "fail in num leading zeros");

        addr = 0x0b11110000000000000000001001001000000000;
        require(PanopticMath.numberOfLeadingHexZeros(addr) == 1, "fail in num leading zeros");

        addr = 0x1000000000000000000001000000000000010000;
        require(PanopticMath.numberOfLeadingHexZeros(addr) == 0, "fail in num leading zeros");

        addr = 0xf000000000000000000000000000000000000000;
        require(PanopticMath.numberOfLeadingHexZeros(addr) == 0, "fail in num leading zeros");

        addr = 0x0000010000100000100000000000000000000001;
        require(PanopticMath.numberOfLeadingHexZeros(addr) == 5, "fail in num leading zeros");

        addr = 0x0000000000000000001000000000000000000000;
        require(PanopticMath.numberOfLeadingHexZeros(addr) == 18, "fail in num leading zeros");

        addr = 0x0000000000000000000000000000000000000001;
        require(PanopticMath.numberOfLeadingHexZeros(addr) == 39, "fail in num leading zeros");

        // note: The BitMath function throws an error if calling it with addr=0 (which wouldn't be valid anyway)
    }

    function testLiquidityChunk() private printStatus {
        uint256 theid;

        theid = theid.addUniv3pool(uint64(uint160(address(this))));
        theid = theid.addStrike(10, 0);
        theid = theid.addWidth(2, 0);
        theid = theid.addOptionRatio(1, 0);
        theid = theid.addAsset(0, 0);
        theid = theid.addIsLong(0, 0);
        theid = theid.addTokenType(0, 0);
        theid = theid.addRiskPartner(0, 0);

        // extract the liquidity chunk from leg index 0
        uint256 liquidityChunk = PanopticMath.getLiquidityChunk(theid, 0, 4, 1);

        require(liquidityChunk.tickUpper() == 11); // strike + 1 (1 = width/2)
        require(liquidityChunk.tickLower() == 9); // strike + 1 (1 = width/2)

        // expected:
        // 40022 = (1.0001 ** (11/2) * 1.0001 ** (9 / 2)) / (1.0001 ** (11 / 2) - 1.0001 ** (9 / 2)) * 4
        require(liquidityChunk.liquidity() == 40022);

        liquidityChunk = PanopticMath.getLiquidityChunk(theid, 0, 100, 1);
        // expected:
        // 1000550.1237646247 = (1.0001 ** (11/2) * 1.0001 ** (9 / 2)) / (1.0001 ** (11 / 2) - 1.0001 ** (9 / 2)) * 100

        require(liquidityChunk.tickUpper() == 11); // strike + 1 (1 = width/2)
        require(liquidityChunk.tickLower() == 9); // strike + 1 (1 = width/2)
        require(liquidityChunk.liquidity() == 1000550);

        // let's add another leg
        theid = theid.addStrike(40000, 1);
        theid = theid.addWidth(1000, 1);
        theid = theid.addOptionRatio(1, 1);
        theid = theid.addAsset(0, 1);
        theid = theid.addIsLong(0, 1);
        theid = theid.addTokenType(0, 1);
        theid = theid.addRiskPartner(0, 1);

        liquidityChunk = PanopticMath.getLiquidityChunk(theid, 0, 100, 1);
        // the old leg index 0 should be unchanged:
        require(liquidityChunk.tickUpper() == 11); // strike + 1 (1 = width/2)
        require(liquidityChunk.tickLower() == 9); // strike + 1 (1 = width/2)
        require(liquidityChunk.liquidity() == 1000550);

        // but let's get the info for the new leg index 1:
        liquidityChunk = PanopticMath.getLiquidityChunk(theid, 1, 100, 1);

        require(liquidityChunk.tickUpper() == 40000 + 1000 / 2);
        require(liquidityChunk.tickLower() == 40000 - 1000 / 2);

        // let's negative ticks
        theid = theid.addStrike(-20000, 2);
        theid = theid.addWidth(500, 2);
        theid = theid.addOptionRatio(1, 2);
        theid = theid.addAsset(0, 2);
        theid = theid.addIsLong(0, 2);
        theid = theid.addTokenType(0, 2);
        theid = theid.addRiskPartner(0, 2);

        liquidityChunk = PanopticMath.getLiquidityChunk(theid, 0, 100, 1);
        // the old leg indexes 0 and 1 should be unchanged:
        require(liquidityChunk.tickUpper() == 11); // strike + 1 (1 = width/2)
        require(liquidityChunk.tickLower() == 9); // strike + 1 (1 = width/2)
        require(liquidityChunk.liquidity() == 1000550);

        liquidityChunk = PanopticMath.getLiquidityChunk(theid, 1, 100, 1);
        require(liquidityChunk.tickUpper() == 40000 + 1000 / 2);
        require(liquidityChunk.tickLower() == 40000 - 1000 / 2);

        // but let's get the info for the newest leg index 2:
        liquidityChunk = PanopticMath.getLiquidityChunk(theid, 2, 100, 1);

        require(liquidityChunk.tickUpper() == -20000 + 500 / 2);
        require(liquidityChunk.tickLower() == -20000 - 500 / 2);
    }

    function testCreateChunk() private printStatus {
        uint256 chunk = uint256(0).createChunk(20, 100, 400);
        require(chunk.tickLower() == 20);
        require(chunk.tickUpper() == 100);
        require(chunk.liquidity() == 400);

        chunk = uint256(0).createChunk(20, -80, 10000);
        require(chunk.tickLower() == 20);
        require(chunk.tickUpper() == -80);
        require(chunk.liquidity() == 10000);
    }

    function testPoolId() private printStatus {
        require(
            PanopticMath.getPoolId(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8) ==
                uint64(10004071212772171232)
        );
        require(PanopticMath.getPoolId(address(0)) == uint64(0));
    }
}
