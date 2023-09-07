// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *
 * WARNING: MOCK CONTRACT - NOT TO BE DEPLOYED INTO PRODUCTION
 *
 */
pragma solidity =0.8.18;

/*
 * @title Mock a Uniswap v3 Pool.
 * @author Axicon Labs Limited
 * @notice
 * @notice ***** NOT TO BE DEPLOYED INTO PRODUCTION *****
 * @notice
 */
contract MockUniswapV3Pool {
    struct Info {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // the fees owed to the position owner in token0/token1
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    address public immutable token0;

    address public immutable token1;

    uint24 public immutable fee;

    mapping(bytes32 => Info) public positions;

    int24 public tick;

    constructor(address _token0, address _token1, uint24 _fee, int24 _tick) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tick = _tick;
    }

    function feeGrowthGlobal0X128() external view returns (uint256) {
        return uint256(0);
    }

    function feeGrowthGlobal1X128() external view returns (uint256) {
        return uint256(0);
    }

    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {}

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1) {}

    function tickSpacing() public view returns (uint256) {
        return 10;
    }

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1) {}

    function slot0()
        external
        view
        returns (
            uint160,
            int24,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (1, tick, uint16(0), uint16(0), uint16(0), uint8(0), false);
    }

    function ticks(
        int24 tick
    )
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        )
    {
        return (
            uint128(0),
            int128(0),
            uint256(0),
            uint256(0),
            int56(0),
            uint160(0),
            uint32(0),
            false
        );
    }

    /// @dev god mode - can set the tick price at will
    function setCurrentTick(int24 _tick) public returns (int24) {
        tick = _tick;
        return _tick;
    }
}
