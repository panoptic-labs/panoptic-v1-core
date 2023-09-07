// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *
 * WARNING: TEST CONTRACT - NOT TO BE DEPLOYED INTO PRODUCTION
 *
 */
pragma solidity =0.8.18;

// Internal
import {LiquidityChunk} from "../contracts/types/LiquidityChunk.sol";
import {Utils} from "./Utils.sol";

/*
 * @title Test That the Liquidity Chunk library works as expected
 * @author Axicon Labs Limited
 * @notice
 * @notice ***** NOT TO BE DEPLOYED INTO PRODUCTION *****
 * @notice
 * @notice you can run the tests by calling `runAll()` which will print "PASS" to the console or fail in a `require()` statement if any issue.
 */
contract TestLiquidityChunk is Utils {
    using LiquidityChunk for uint256;

    /// @notice Call this function to run all tests
    function runAll() external {
        testPositive();
        testNegative();
    }

    /****************************************************
     * PASSING TESTS - CALLED VIA runAll() ABOVE
     ****************************************************/

    /// @dev test that it works for positive numbers
    function testPositive() private printStatus {
        uint256 liquidityChunk;

        // layout: (lower <24 bits>) (upper <24>) (empty <80>) (liquidity <128>)
        liquidityChunk = liquidityChunk.addTickLower(24);
        liquidityChunk = liquidityChunk.addTickUpper(201);
        liquidityChunk = liquidityChunk.addLiquidity(1000);

        require(liquidityChunk.tickLower() == 24, "FF1");
        require(liquidityChunk.tickUpper() == 201, "FF2");
        require(liquidityChunk.liquidity() == 1000, "FF3");

        // spot test some bits
        // the liquidity, binary of decimal 1000: 1111101000 (goes right to left below)
        require(bit(liquidityChunk, 0) == 0);
        require(bit(liquidityChunk, 1) == 0);
        require(bit(liquidityChunk, 2) == 0);
        require(bit(liquidityChunk, 3) == 1);
        require(bit(liquidityChunk, 4) == 0);
        require(bit(liquidityChunk, 5) == 1);
        require(bit(liquidityChunk, 6) == 1);
        require(bit(liquidityChunk, 7) == 1);
        require(bit(liquidityChunk, 8) == 1);
        require(bit(liquidityChunk, 9) == 1);
        require(bit(liquidityChunk, 10) == 0);
        require(bit(liquidityChunk, 11) == 0);
        require(bit(liquidityChunk, 12) == 0);
        require(bit(liquidityChunk, 13) == 0);
        require(bit(liquidityChunk, 14) == 0);
        require(bit(liquidityChunk, 15) == 0);
        require(bit(liquidityChunk, 16) == 0);
        require(bit(liquidityChunk, 17) == 0);
        require(bit(liquidityChunk, 18) == 0);
        require(bit(liquidityChunk, 19) == 0);
        require(bit(liquidityChunk, 20) == 0);
        require(bit(liquidityChunk, 21) == 0);
        require(bit(liquidityChunk, 22) == 0);
        require(bit(liquidityChunk, 23) == 0);

        // the empty range
        require(bit(liquidityChunk, 140) == 0);
        require(bit(liquidityChunk, 160) == 0);
        require(bit(liquidityChunk, 180) == 0);
        require(bit(liquidityChunk, 200) == 0);
    }

    function testNegative() private printStatus {
        uint256 liquidityChunk;

        // layout: (lower <24 bits>) (upper <24>) (empty <80>) (liquidity <128>)
        liquidityChunk = liquidityChunk.addTickLower(-24);
        liquidityChunk = liquidityChunk.addTickUpper(-201);
        liquidityChunk = liquidityChunk.addLiquidity(1000);

        require(liquidityChunk.tickLower() == int24(-24), "FF1");
        require(liquidityChunk.tickUpper() == int24(-201), "FF2");
        require(liquidityChunk.liquidity() == uint128(1000), "FF3");

        // spot test some bits
        // the liquidity, binary of decimal 1000: 1111101000
        require(bit(liquidityChunk, 0) == 0);
        require(bit(liquidityChunk, 1) == 0);
        require(bit(liquidityChunk, 2) == 0);
        require(bit(liquidityChunk, 3) == 1);
        require(bit(liquidityChunk, 4) == 0);
        require(bit(liquidityChunk, 5) == 1);
        require(bit(liquidityChunk, 6) == 1);
        require(bit(liquidityChunk, 7) == 1);
        require(bit(liquidityChunk, 8) == 1);
        require(bit(liquidityChunk, 9) == 1);
        require(bit(liquidityChunk, 10) == 0);
        require(bit(liquidityChunk, 11) == 0);
        require(bit(liquidityChunk, 12) == 0);
        require(bit(liquidityChunk, 13) == 0);
        require(bit(liquidityChunk, 14) == 0);
        require(bit(liquidityChunk, 15) == 0);
        require(bit(liquidityChunk, 16) == 0);
        require(bit(liquidityChunk, 17) == 0);
        require(bit(liquidityChunk, 18) == 0);
        require(bit(liquidityChunk, 19) == 0);
        require(bit(liquidityChunk, 20) == 0);
        require(bit(liquidityChunk, 21) == 0);
        require(bit(liquidityChunk, 22) == 0);
        require(bit(liquidityChunk, 23) == 0);

        // tick upper is -201: 1111111100110111
        require(bit(liquidityChunk, 208) == 1); // start of -201
        require(bit(liquidityChunk, 209) == 1);
        require(bit(liquidityChunk, 210) == 1);
        require(bit(liquidityChunk, 211) == 0);
        require(bit(liquidityChunk, 212) == 1);
        require(bit(liquidityChunk, 213) == 1);
        require(bit(liquidityChunk, 214) == 0);
        require(bit(liquidityChunk, 215) == 0);
        require(bit(liquidityChunk, 216) == 1);
        require(bit(liquidityChunk, 217) == 1);
        require(bit(liquidityChunk, 218) == 1);
        require(bit(liquidityChunk, 219) == 1);
        require(bit(liquidityChunk, 220) == 1);
        require(bit(liquidityChunk, 221) == 1);
        require(bit(liquidityChunk, 222) == 1);
        require(bit(liquidityChunk, 223) == 1);
        require(bit(liquidityChunk, 224) == 1);
        require(bit(liquidityChunk, 225) == 1);
        require(bit(liquidityChunk, 226) == 1);
        require(bit(liquidityChunk, 227) == 1);
        require(bit(liquidityChunk, 228) == 1);
        require(bit(liquidityChunk, 229) == 1);
        require(bit(liquidityChunk, 230) == 1);
        require(bit(liquidityChunk, 231) == 1);
        require(bit(liquidityChunk, 232) == 0); // start of -24: 1111111111101000
        require(bit(liquidityChunk, 233) == 0);
        require(bit(liquidityChunk, 234) == 0);
        require(bit(liquidityChunk, 235) == 1);
        require(bit(liquidityChunk, 236) == 0);
        require(bit(liquidityChunk, 237) == 1);
        require(bit(liquidityChunk, 238) == 1);
        require(bit(liquidityChunk, 239) == 1);
        require(bit(liquidityChunk, 240) == 1);
        require(bit(liquidityChunk, 241) == 1);
        require(bit(liquidityChunk, 242) == 1);
        require(bit(liquidityChunk, 243) == 1);
        require(bit(liquidityChunk, 244) == 1);
        require(bit(liquidityChunk, 245) == 1);
        require(bit(liquidityChunk, 246) == 1);
        require(bit(liquidityChunk, 247) == 1);
        require(bit(liquidityChunk, 248) == 1);
        require(bit(liquidityChunk, 249) == 1);
        require(bit(liquidityChunk, 250) == 1);
        require(bit(liquidityChunk, 251) == 1);
        require(bit(liquidityChunk, 252) == 1);
        require(bit(liquidityChunk, 253) == 1);
        require(bit(liquidityChunk, 254) == 1);
        require(bit(liquidityChunk, 255) == 1);

        // the empty range
        require(bit(liquidityChunk, 80) == 0);
        require(bit(liquidityChunk, 140) == 0);
        require(bit(liquidityChunk, 160) == 0);
        require(bit(liquidityChunk, 180) == 0);
        require(bit(liquidityChunk, 200) == 0);
        require(bit(liquidityChunk, 207) == 0);

        liquidityChunk = 0;
        liquidityChunk = liquidityChunk.addTickLower(24);
        liquidityChunk = liquidityChunk.addTickUpper(-201);
        liquidityChunk = liquidityChunk.addLiquidity(1000);

        require(liquidityChunk.tickLower() == 24, "FF1");
        require(liquidityChunk.tickUpper() == -201, "FF2");
        require(liquidityChunk.liquidity() == 1000, "FF3");

        liquidityChunk = 0;
        liquidityChunk = liquidityChunk.addTickUpper(-201);
        liquidityChunk = liquidityChunk.addTickLower(24);
        liquidityChunk = liquidityChunk.addLiquidity(1000);

        require(liquidityChunk.tickLower() == 24, "FF1");
        require(liquidityChunk.tickUpper() == -201, "FF2");
        require(liquidityChunk.liquidity() == 1000, "FF3");

        liquidityChunk = 0;
        liquidityChunk = liquidityChunk.addTickLower(-24);
        liquidityChunk = liquidityChunk.addTickUpper(201);
        liquidityChunk = liquidityChunk.addLiquidity(1000);

        require(liquidityChunk.tickLower() == -24, "FF1");
        require(liquidityChunk.tickUpper() == 201, "FF2");
        require(liquidityChunk.liquidity() == 1000, "FF3");

        liquidityChunk = 0;
        liquidityChunk = liquidityChunk.addTickUpper(201);
        liquidityChunk = liquidityChunk.addTickLower(-24);
        liquidityChunk = liquidityChunk.addLiquidity(1000);

        require(liquidityChunk.tickLower() == -24, "FF1");
        require(liquidityChunk.tickUpper() == 201, "FF2");
        require(liquidityChunk.liquidity() == 1000, "FF3");

        liquidityChunk = 0;
        liquidityChunk = liquidityChunk.addTickLower(0);
        liquidityChunk = liquidityChunk.addTickUpper(0);
        liquidityChunk = liquidityChunk.addLiquidity(0);

        require(liquidityChunk.tickLower() == 0, "FF1");
        require(liquidityChunk.tickUpper() == 0, "FF2");
        require(liquidityChunk.liquidity() == 0, "FF3");
    }
}
