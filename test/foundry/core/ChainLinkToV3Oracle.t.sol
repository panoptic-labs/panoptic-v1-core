// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../../contracts/ChainLinkToV3Oracle.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

contract ChainLinkToV3OracleTest is Test {
    ChainLinkToV3Oracle oracle;
    AggregatorV3Interface aggregator =
        AggregatorV3Interface(
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 // ETH/USD aggregator on mainnet
        );

    function setUp() public {
        uint256 forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(forkId);
        oracle = new ChainLinkToV3Oracle(aggregator);
    }

    function testSlot0ReturnsValidPrice() public {
        (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 obsIdx,
            uint16 obsCard,
            uint16 obsCardNext,
            uint8 feeProtocol,
            bool unlocked
        ) = oracle.slot0();

        // Basic sanity checks
        assertGt(uint256(sqrtPriceX96), 0, "sqrtPriceX96 should be > 0");
        assertGt(int256(tick), 0, "tick should be > 0");
        assertEq(feeProtocol, 0, "feeProtocol always 0");
        assertTrue(unlocked, "unlocked always true");
        assertEq(obsCard, 8, "observationCardinality should be 8");
        assertEq(obsCardNext, 8, "observationCardinalityNext should be 8");

        // Verify tick and sqrtPrice are consistent
        uint160 sqrtPriceFromTick = TickMath.getSqrtRatioAtTick(tick);
        uint256 diff = sqrtPriceX96 > sqrtPriceFromTick
            ? sqrtPriceX96 - sqrtPriceFromTick
            : sqrtPriceFromTick - sqrtPriceX96;
        assertTrue(
            (diff * 1e5) / sqrtPriceFromTick <= 1 || diff <= 1,
            "sqrtPrice vs TickMath mismatch >0.1% & > 1 whole unit"
        );
    }

    function testSlot0ConsistentWithChainlink() public {
        (, int256 chainlinkPrice, , , ) = aggregator.latestRoundData();
        (, int24 oracleTick, , , , , ) = oracle.slot0();

        // Convert chainlink price to expected tick
        uint256 uPrice = uint256(chainlinkPrice);
        uint256 priceQ128 = (uPrice << 128) / (10 ** 8); // DECIMALS = 8
        uint160 expectedSqrtPriceX96 = uint160(uint256(priceQ128)) << 32;
        int24 expectedTick = TickMath.getTickAtSqrtRatio(expectedSqrtPriceX96);

        assertEq(oracleTick, expectedTick, "Oracle tick should match chainlink-derived tick");
    }

    function testObservationsReturnsValidData() public {
        for (uint256 i = 0; i < 10; i++) {
            (
                uint32 blockTimestamp,
                int56 tickCumulative,
                uint160 secondsPerLiquidityX128,
                bool initialized
            ) = oracle.observations(i);

            // Basic checks
            assertTrue(initialized, "All observations should be initialized");
            assertEq(secondsPerLiquidityX128, 0, "secondsPerLiquidity always 0 in V4");
            assertLe(blockTimestamp, block.timestamp, "blockTimestamp shouldn't be in future");
            assertEq(
                blockTimestamp,
                uint32(block.timestamp - i),
                "blockTimestamp should be now - index"
            );

            // tickCumulative should be reasonable
            assertGt(int256(tickCumulative), 0, "tickCumulative should be positive for ETH/USD");
        }
    }

    function testObservationsConsistency() public {
        // Get two consecutive observations
        (uint32 ts0, int56 cum0, , ) = oracle.observations(0);
        (uint32 ts1, int56 cum1, , ) = oracle.observations(1);

        // Calculate the tick from cumulative difference
        int24 derivedTick = int24((cum0 - cum1) / int56(uint56(ts0 - ts1)));

        // Should match current tick from slot0
        (, int24 currentTick, , , , , ) = oracle.slot0();
        assertEq(
            derivedTick,
            currentTick,
            "Derived tick from observations should match slot0 tick"
        );
    }

    function testObserveReturnsValidData() public {
        uint32[] memory secondsAgos = new uint32[](5);
        secondsAgos[0] = 0; // now
        secondsAgos[1] = 60; // 1 minute ago
        secondsAgos[2] = 300; // 5 minutes ago
        secondsAgos[3] = 600; // 10 minutes ago
        secondsAgos[4] = 1800; // 30 minutes ago

        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = oracle.observe(
            secondsAgos
        );

        assertEq(tickCumulatives.length, secondsAgos.length, "Should return same length arrays");
        assertEq(
            liquidityCumulatives.length,
            secondsAgos.length,
            "Should return same length arrays"
        );

        // All liquidity cumulatives should be 0
        for (uint256 i = 0; i < liquidityCumulatives.length; i++) {
            assertEq(liquidityCumulatives[i], 0, "liquidityCumulatives always 0");
        }

        // Tick cumulatives should be decreasing (older timestamps = smaller cumulatives)
        for (uint256 i = 0; i < tickCumulatives.length - 1; i++) {
            assertGt(
                tickCumulatives[i],
                tickCumulatives[i + 1],
                "Newer observations should have larger cumulatives"
            );
        }

        // TODO: Test that the TWAP = chainlink price
    }

    function testObserveTWAPCalculation() public {
        uint32[] memory secondsAgos = new uint32[](2);
        // TODO: Fuzz this - all possible combinations of secondsAgos should still result in TWAP equaling current price.
        secondsAgos[0] = 0; // now
        secondsAgos[1] = 600; // 10 minutes ago

        (int56[] memory tickCumulatives, ) = oracle.observe(secondsAgos);

        // Calculate TWAP manually
        int24 twap = int24((tickCumulatives[0] - tickCumulatives[1]) / int56(600));

        // Should equal current tick since we use same tick for all observations
        (, int24 currentTick, , , , , ) = oracle.slot0();
        assertEq(twap, currentTick, "TWAP should equal current tick");
    }

    function testObserveEmptyArray() public {
        uint32[] memory emptyArray = new uint32[](0);
        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = oracle.observe(
            emptyArray
        );

        assertEq(tickCumulatives.length, 0, "Should return empty array");
        assertEq(liquidityCumulatives.length, 0, "Should return empty array");
    }

    function testObserveLargeArray() public {
        uint32[] memory largeArray = new uint32[](100);
        for (uint256 i = 0; i < largeArray.length; i++) {
            largeArray[i] = uint32(i * 60); // Every minute for 100 minutes
        }

        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = oracle.observe(
            largeArray
        );

        assertEq(tickCumulatives.length, 100, "Should handle large arrays");
        assertEq(liquidityCumulatives.length, 100, "Should handle large arrays");
    }

    function testIncreaseObservationCardinalityNext() public {
        // Should not revert
        oracle.increaseObservationCardinalityNext(16);
        oracle.increaseObservationCardinalityNext(1);
        oracle.increaseObservationCardinalityNext(type(uint16).max);

        // Values shouldn't change since it's a no-op
        (, , , uint16 obsCard, uint16 obsCardNext, , ) = oracle.slot0();
        assertEq(obsCard, 8, "observationCardinality unchanged");
        assertEq(obsCardNext, 8, "observationCardinalityNext unchanged");
    }

    function testPriceConsistencyAcrossTime() public {
        // Record initial values
        (, int24 initialTick, , , , , ) = oracle.slot0();

        // Fast forward time
        vm.warp(block.timestamp + 1000);

        // Values should be the same (since we use current chainlink price)
        (, int24 laterTick, , , , , ) = oracle.slot0();
        assertEq(
            laterTick,
            initialTick,
            "Tick should be consistent across time (same chainlink round)"
        );
    }

    // TODO: Also pull the ETH/USD price from a big mainnet pool and test that its price is within 1% of what your oracle says

    function testRevertOnBadChainlinkPrice() public {
        // This test would require mocking the aggregator to return bad data
        // For now, we trust that the mainnet ETH/USD feed returns valid data
        // In a more comprehensive test suite, you'd mock this
    }
}
