// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../../contracts/ChainLinkToV3Oracle.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

contract ChainLinkToV3OracleTest is Test {
    ChainLinkToV3Oracle oracle;
    AggregatorV3Interface aggregator = AggregatorV3Interface(
        0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 // ETH/USD aggregator on mainnet
    );

    function setUp() public {
        uint256 forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(forkId);

        oracle = new ChainLinkToV3Oracle(
            aggregator
        );
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

        // Basic sanity
        assertGt(uint256(sqrtPriceX96), 0, "sqrtPriceX96 should be > 0");
        assertGt(int256(tick), 0, "tick should be > 0");
        assertEq(feeProtocol, 0, "feeProtocol always 0");
        assertTrue(unlocked, "unlocked always true");

        uint160 sqrtPriceFromTick = TickMath.getSqrtRatioAtTick(tick);
        uint256 diff = sqrtPriceX96 > sqrtPriceFromTick ? sqrtPriceX96 - sqrtPriceFromTick : sqrtPriceFromTick - sqrtPriceX96;
        assertTrue(diff * 1e5 / fromTick <= 1 || diff <= 1, "sqrtPrice vs TickMath mismatch >0.1% & > 1 whole unit");
    }
}
