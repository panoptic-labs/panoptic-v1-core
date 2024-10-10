// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {PoolAddress} from "v3-periphery/libraries/PoolAddress.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TransferHelper} from "v3-periphery/libraries/TransferHelper.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {Math} from "@libraries/Math.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {V4RouterSimple} from "../testUtils/V4RouterSimple.sol";

contract MiniPositionManager {
    struct CallbackData {
        PoolAddress.PoolKey univ3poolKey;
        address payer;
    }

    /// @notice Called after minting liquidity to a position from IUniswapV3Pool#mint.
    /// @dev Pays the pool tokens owed for the minted liquidity from the payer (always the caller)
    /// @param amount0Owed The amount of token0 due to the pool for the minted liquidity
    /// @param amount1Owed The amount of token1 due to the pool for the minted liquidity
    /// @param data Contains the payer address and the poolkey required to validate the callback
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        // Decode the mint callback data
        CallbackData memory decoded = abi.decode(data, (CallbackData));

        // Sends the amount0Owed and amount1Owed quantities provided
        if (amount0Owed > 0)
            TransferHelper.safeTransferFrom(
                decoded.univ3poolKey.token0,
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            TransferHelper.safeTransferFrom(
                decoded.univ3poolKey.token1,
                decoded.payer,
                msg.sender,
                amount1Owed
            );
    }

    /// @notice Called after executing a swap via IUniswapV3Pool#swap during an ITM option mint/burn.
    /// @dev Pays the pool tokens owed for the swap from the payer (always the caller)
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Contains the payer address and the poolkey required to validate the callback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode the swap callback data, checks that the UniswapV3Pool has the correct address.
        CallbackData memory decoded = abi.decode(data, (CallbackData));

        // Extract the address of the token to be sent (amount0 -> token0, amount1 -> token1)
        address token = amount0Delta >= 0
            ? address(decoded.univ3poolKey.token0)
            : address(decoded.univ3poolKey.token1);

        // Transform the amount to pay to uint256 (take positive one from amount0 and amount1)
        uint256 amountToPay = amount0Delta >= 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        // Pay the required token from the payer to the caller of this contract
        TransferHelper.safeTransferFrom(token, decoded.payer, msg.sender, amountToPay);
    }

    function mintLiquidity(
        IUniswapV3Pool uniPool,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        address payer
    ) public {
        uniPool.mint(
            address(this),
            tickLower,
            tickUpper,
            amount,
            abi.encode(
                CallbackData({
                    univ3poolKey: PoolAddress.PoolKey({
                        token0: uniPool.token0(),
                        token1: uniPool.token1(),
                        fee: uniPool.fee()
                    }),
                    payer: payer
                })
            )
        );
    }

    function burnLiquidity(
        IUniswapV3Pool uniPool,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) public returns (uint256, uint256) {
        return uniPool.burn(tickLower, tickUpper, amount);
    }

    function approve(address token0, address token1, address uniPool) public {
        IERC20Partial(token0).approve(uniPool, type(uint256).max);
        IERC20Partial(token1).approve(uniPool, type(uint256).max);
    }

    function collect(
        IUniswapV3Pool uniPool,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) public {
        uniPool.collect(address(this), tickLower, tickUpper, uint128(amount0), uint128(amount1));
    }
}

contract PositionUtils is Test {
    // current pranked caller for swap simulation
    address caller;
    // current snapshot index
    uint256 snap;

    function getContext(
        uint256 ts_,
        int24 currentTick,
        int24 width
    ) public pure returns (int24 strikeOffset, int24 minTick, int24 maxTick) {
        int256 ts = int256(ts_);

        strikeOffset = int24(width % 2 == 0 ? int256(0) : ts / 2);

        minTick = int24(((currentTick - 4096 * 10) / ts) * ts);
        maxTick = int24(((currentTick + 4096 * 10) / ts) * ts);
    }

    function getContextFull(
        uint256 ts_,
        int24 currentTick,
        int24 width
    ) public pure returns (int24 strikeOffset, int24 minTick, int24 maxTick) {
        int256 ts = int256(ts_);

        strikeOffset = int24(width % 2 == 0 ? int256(0) : ts / 2);

        minTick = int24(((currentTick - 4096 * ts) / ts) * ts);
        maxTick = int24(((currentTick + 4096 * ts) / ts) * ts);
    }

    function getValidSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick
    ) public pure returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 2048)))
            : int24(int256(bound(widthSeed, 1, 2048)));

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = ts == 1
            ? getContextFull(ts_, currentTick, width)
            : getContext(ts_, currentTick, width);

        int24 lowerBound = int24(minTick + rangeDown - strikeOffset);
        int24 upperBound = int24(maxTick - rangeUp - strikeOffset);

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    function getInRangeSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick
    ) public pure returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 1024)))
            : int24(int256(bound(widthSeed, 1, (1024 * 10) / uint256(ts))));

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = ts == 1
            ? getContextFull(ts_, currentTick, width)
            : getContext(ts_, currentTick, width);

        // add (1 * ts) to minimum because range is exclusive of upper tick in UniV3
        // i.e TL <= CT < TU
        // so ensuring that TU is never included in the range
        int24 lowerBound = int24(
            currentTick - rangeUp < minTick + rangeDown
                ? minTick + rangeDown
                : currentTick - rangeUp
        ) +
            int24(ts) -
            strikeOffset;

        int24 upperBound = int24(
            currentTick + rangeDown > maxTick - rangeUp
                ? maxTick - rangeUp
                : currentTick + rangeDown
        ) - strikeOffset;

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    function getMinWidthInRangeSW(
        uint256 ts_,
        int24 currentTick
    ) public pure returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);
        // round current tick down to closest initializable tick, then add ts/2 to get strike
        strike = int24((currentTick / ts) * ts + ts / 2);
        width = 1;
    }

    function getOutOfRangeSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick
    ) public pure returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 1024)))
            : int24(int256(bound(widthSeed, 1, (1024 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        (int24 strikeOffset, int24 minTick, int24 maxTick) = ts == 1
            ? getContextFull(ts_, currentTick, width)
            : getContext(ts_, currentTick, width);

        // add (1 * ts) to minimum because range is exclusive of upper tick in UniV3
        // i.e TL <= CT < TU
        // so ensuring that TU is never included in the range
        // also, steal last bit of randomness (mod 2^1) in width seed to determine which side of the range we want the position to be on
        int24 lowerBound = int24(
            (currentTick - oneSidedRange < minTick + oneSidedRange || widthSeed % 2 == 0)
                ? minTick + oneSidedRange
                : currentTick - oneSidedRange
        ) +
            int24(ts) -
            strikeOffset;

        int24 upperBound = int24(
            (currentTick + oneSidedRange > maxTick - oneSidedRange || widthSeed % 2 == 1)
                ? maxTick - oneSidedRange
                : currentTick + oneSidedRange
        ) - strikeOffset;

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    function getOTMSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick,
        uint256 tokenType
    ) public pure returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 2048)))
            : int24(int256(bound(widthSeed, 1, (2048 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = ts == 1
            ? getContextFull(ts_, currentTick, width)
            : getContext(ts_, currentTick, width);

        int24 lowerBound = tokenType == 0
            ? int24(currentTick + ts + oneSidedRange - strikeOffset)
            : int24(minTick + oneSidedRange - strikeOffset);
        int24 upperBound = tokenType == 0
            ? int24(maxTick - oneSidedRange - strikeOffset)
            : int24(currentTick - oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = tokenType == 0
                ? int24(currentTick + ts + rangeDown - strikeOffset)
                : int24(minTick + rangeDown - strikeOffset);
            upperBound = tokenType == 0
                ? int24(maxTick - rangeUp - strikeOffset)
                : int24(currentTick - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    function getITMSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick,
        uint256 tokenType
    ) public pure returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 2048)))
            : int24(int256(bound(widthSeed, 1, (2048 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = ts == 1
            ? getContextFull(ts_, currentTick, width)
            : getContext(ts_, currentTick, width);

        int24 lowerBound = tokenType == 0
            ? int24(minTick + oneSidedRange - strikeOffset)
            : int24(currentTick + oneSidedRange - strikeOffset);
        int24 upperBound = tokenType == 0
            ? int24(currentTick + ts - oneSidedRange - strikeOffset)
            : int24(maxTick - oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = tokenType == 0
                ? int24(minTick + rangeDown - strikeOffset)
                : int24(currentTick + rangeDown - strikeOffset);
            upperBound = tokenType == 0
                ? int24(currentTick + ts - rangeUp - strikeOffset)
                : int24(maxTick - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    // above or below current tick
    function getAboveRangeSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick
    ) public pure returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 2048)))
            : int24(int256(bound(widthSeed, 1, (2048 * 10) / uint256(ts))));

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, , int24 maxTick) = ts == 1
            ? getContextFull(ts_, currentTick, width)
            : getContext(ts_, currentTick, width);

        // add ts(1) because range is inclusive of lower tick in UniV3
        int24 lowerBound = int24(currentTick + ts + rangeDown - strikeOffset);
        int24 upperBound = int24(maxTick - rangeUp - strikeOffset);

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    function getBelowRangeSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick
    ) public pure returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 2048)))
            : int24(int256(bound(widthSeed, 1, (2048 * 10) / uint256(ts))));

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, ) = ts == 1
            ? getContextFull(ts_, currentTick, width)
            : getContext(ts_, currentTick, width);

        // add ts(1) because range is inclusive of lower tick in UniV3
        int24 lowerBound = int24(minTick + rangeDown - strikeOffset);
        int24 upperBound = int24(currentTick - rangeUp - strikeOffset);

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    function getOTMOutOfRangeSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick,
        uint256 tokenType
    ) public pure returns (int24 width, int24 strike) {
        return
            tokenType == 1
                ? getBelowRangeSW(widthSeed, strikeSeed, ts_, currentTick)
                : getAboveRangeSW(widthSeed, strikeSeed, ts_, currentTick);
    }

    function getLiquidityForAmountAtRatio(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 token,
        uint256 amountToken
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        uint256 priceX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 2 ** 64);

        uint256 amount0 = token == 0
            ? amountToken
            : FullMath.mulDiv(amountToken, 2 ** 128, priceX128);
        uint256 amount1 = token == 1
            ? amountToken
            : FullMath.mulDiv(amountToken, priceX128, 2 ** 128);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            // position is already fully token0, so the amount of tokens to the left is the same as the value
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount0
            );
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            // first, find ratio x/y: token0/token1
            // use decomposed form to avoid overflows
            // s_A: lower sqrt ratio (X96)
            // s_B: upper sqrt ratio (X96)
            // s_C: current sqrt ratio (X96)
            // x: quantity token0
            // y: quantity token1
            // L: liquidity
            // r: x/y
            // y = L * (s_C - s_A) / 2^96
            // x = 2^96 * L * (s_B - s_C) / (s_C*s_B)
            // r = 2^192 * (s_B - s_C) / (s_C * s_B * (s_C - s_A))
            // = (2^192 * s_B - 2^192 * s_C) / (s_C * s_B * (s_C - s_A))
            // = 2^192 / (s_C * (s_C - s_A)) - 2^192 / (s_B * (s_C - s_A))

            // r * 2^96 (needed to preserve precision)
            uint256 rX96 = FullMath.mulDiv(
                2 ** 96,
                2 ** 192,
                (uint256(sqrtRatioX96) * (sqrtRatioX96 - sqrtRatioAX96))
            ) -
                FullMath.mulDiv(
                    2 ** 96,
                    2 ** 192,
                    (uint256(sqrtRatioBX96) * (sqrtRatioX96 - sqrtRatioAX96))
                );

            // then, multiply r by current price to find ratio y_right/y_left
            // p_C: current price (X128)
            // yL: amount of token1 to the left of the current price
            // yR: (equiv) amount of token1 to the right of the current price
            // x: amount of token0 to the right of the current price
            // r = x/yL
            // given amount yL, xR = yL * r, and yR = xR * p_C
            // so yR = yL * r * p_C
            // also, where rRL = yR/yL, yL * rRL = yR
            // yL * RL = yL * r * p_C, therefore, rRL = r * p_C
            uint256 rRLX96 = FullMath.mulDiv(rX96, priceX128, 2 ** 128);

            // finally, solve for x and y given the yR/yL, p_C, and the specified value in terms of token1
            // rRL: yR/yL
            // yS: specified amount of token1
            // yR + yL = yS
            // yR = rRL * yL
            // yS = rRL * yL + yL
            // yS = yL * (rRL + 1)
            // yL = yS / (rRL + 1)
            // yR = rRL * yS / (rRL + 1)
            uint256 yL = FullMath.mulDiv(amount1, 2 ** 96, rRLX96 + 2 ** 96);
            uint256 yR = FullMath.mulDiv(
                FullMath.mulDiv(amount1, rRLX96, 2 ** 96),
                2 ** 96,
                rRLX96 + 2 ** 96
            );
            uint256 x = FullMath.mulDiv(yR, 2 ** 128, priceX128);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                x,
                yL // y(token1) is always to the left of the current price
            );
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount1
            );
        }
    }

    function getContractsForAmountAtTick(
        int24 tick,
        int24 tickLower,
        int24 tickUpper,
        uint256 token,
        uint256 amountToken
    ) internal pure returns (uint256 contractAmount) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        uint128 liquidity = getLiquidityForAmountAtRatio(
            sqrtRatioX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            token,
            amountToken
        );

        contractAmount = token == 0
            ? LiquidityAmounts.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity)
            : LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }

    function simulateSwap(
        ISwapRouter router,
        address token0,
        address token1,
        uint24 fee,
        bool zeroForOne,
        int256 amountSpecified
    ) public returns (uint256 amount0, uint256 amount1) {
        uint256 snapshot = vm.snapshot();
        deal(token0, address(0x123456), type(uint128).max);
        deal(token1, address(0x123456), type(uint128).max);
        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);
        if (amountSpecified > 0) {
            uint256 amountOut = router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: zeroForOne ? token0 : token1,
                    tokenOut: zeroForOne ? token1 : token0,
                    fee: fee,
                    recipient: address(0x123456),
                    deadline: block.timestamp,
                    amountIn: uint256(amountSpecified),
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            (amount0, amount1) = zeroForOne
                ? (uint256(amountSpecified), amountOut)
                : (amountOut, uint256(amountSpecified));
        } else {
            uint256 amountIn = router.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: zeroForOne ? token0 : token1,
                    tokenOut: zeroForOne ? token1 : token0,
                    fee: fee,
                    recipient: address(0x123456),
                    deadline: block.timestamp,
                    amountOut: uint256(-amountSpecified),
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: 0
                })
            );
            (amount0, amount1) = zeroForOne
                ? (amountIn, uint256(-amountSpecified))
                : (uint256(-amountSpecified), amountIn);
        }
        vm.revertTo(snapshot);
    }

    function simulateSwap(
        ISwapRouter router,
        address token0,
        address token1,
        uint24 fee,
        bool[2] memory zeroForOne,
        int256[2] memory amountSpecified
    ) public returns (uint256[2] memory amount0, uint256[2] memory amount1) {
        uint256 snapshot = vm.snapshot();
        deal(token0, address(0x123456), type(uint128).max);
        deal(token1, address(0x123456), type(uint128).max);
        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        for (uint256 i = 0; i < amountSpecified.length; i++) {
            if (amountSpecified[i] > 0) {
                uint256 amountOut = router.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: zeroForOne[i] ? token0 : token1,
                        tokenOut: zeroForOne[i] ? token1 : token0,
                        fee: fee,
                        recipient: address(0x123456),
                        deadline: block.timestamp,
                        amountIn: uint256(amountSpecified[i]),
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    })
                );
                (amount0[i], amount1[i]) = zeroForOne[i]
                    ? (uint256(amountSpecified[i]), amountOut)
                    : (amountOut, uint256(amountSpecified[i]));
            } else {
                uint256 amountIn = router.exactOutputSingle(
                    ISwapRouter.ExactOutputSingleParams({
                        tokenIn: zeroForOne[i] ? token0 : token1,
                        tokenOut: zeroForOne[i] ? token1 : token0,
                        fee: fee,
                        recipient: address(0x123456),
                        deadline: block.timestamp,
                        amountOut: uint256(-amountSpecified[i]),
                        amountInMaximum: type(uint256).max,
                        sqrtPriceLimitX96: 0
                    })
                );
                (amount0[i], amount1[i]) = zeroForOne[i]
                    ? (amountIn, uint256(-amountSpecified[i]))
                    : (uint256(-amountSpecified[i]), amountIn);
            }
        }
        vm.revertTo(snapshot);
    }

    // UPD
    function simulateSwap(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        V4RouterSimple routerV4,
        bool zeroForOne,
        int256 amountSpecified
    ) public returns (uint256, uint256) {
        vm.snapshot();

        vm.startPrank(address(0x123456789));

        routerV4.modifyLiquidity(address(0), key, tickLower, tickUpper, int128(liquidity));

        (int256 delta0, int256 delta1) = routerV4.swap(
            address(0),
            key,
            amountSpecified,
            zeroForOne
        );

        vm.revertTo(0);
        return (uint256(Math.abs(delta0)), uint256(Math.abs(delta1)));
    }

    // UPD
    function simulateSwap(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidity,
        bytes32 positionKey,
        V4RouterSimple routerV4,
        bool zeroForOne,
        int256 amountSpecified
    ) external returns (uint256, uint256) {
        snap = vm.snapshot();

        vm.startPrank(address(0x123456789));

        // make it so we can burn existing liq from caller
        vm.etch(msg.sender, address(routerV4).code);

        IERC20Partial(Currency.unwrap(key.currency0)).approve(msg.sender, type(uint256).max);
        IERC20Partial(Currency.unwrap(key.currency1)).approve(msg.sender, type(uint256).max);

        V4RouterSimple(msg.sender).modifyLiquidityWithSalt(
            address(0),
            key,
            tickLower,
            tickUpper,
            liquidity,
            positionKey
        );

        (int256 delta0, int256 delta1) = routerV4.swap(
            address(0),
            key,
            amountSpecified,
            zeroForOne
        );

        vm.revertTo(snap);

        return (uint256(Math.abs(delta0)), uint256(Math.abs(delta1)));
    }

    function simulateSwap(
        PoolKey memory key,
        int24[2] memory tickLower,
        int24[2] memory tickUpper,
        uint128[2] memory liquidity,
        V4RouterSimple routerV4,
        bool zeroForOne,
        int256 amountSpecified
    ) public returns (int256, int256) {
        vm.snapshot();

        vm.startPrank(address(0x123456789));

        routerV4.modifyLiquidity(address(0), key, tickLower[0], tickUpper[0], int128(liquidity[0]));
        routerV4.modifyLiquidity(address(0), key, tickLower[1], tickUpper[1], int128(liquidity[1]));

        (int256 delta0, int256 delta1) = routerV4.swap(
            address(0),
            key,
            amountSpecified,
            zeroForOne
        );

        vm.revertTo(0);

        return (-delta0, -delta1);
    }

    function simulateSwapLong(
        PoolKey memory key,
        int24[2] memory tickLower,
        int24[2] memory tickUpper,
        int128[2] memory liquidity,
        bytes32[2] memory positionKeys,
        V4RouterSimple routerV4,
        bool zeroForOne,
        int256 amountSpecified
    ) external returns (int256, int256) {
        vm.snapshot();

        vm.startPrank(address(0x123456789));

        IERC20Partial(Currency.unwrap(key.currency0)).approve(msg.sender, type(uint256).max);
        IERC20Partial(Currency.unwrap(key.currency1)).approve(msg.sender, type(uint256).max);

        // make it so we can burn existing liq from caller
        vm.etch(msg.sender, address(routerV4).code);

        V4RouterSimple(msg.sender).modifyLiquidityWithSalt(
            address(0),
            key,
            tickLower[0],
            tickUpper[0],
            liquidity[0],
            positionKeys[0]
        );

        V4RouterSimple(msg.sender).modifyLiquidityWithSalt(
            address(0),
            key,
            tickLower[1],
            tickUpper[1],
            liquidity[1],
            positionKeys[1]
        );

        (int256 delta0, int256 delta1) = V4RouterSimple(msg.sender).swap(
            address(0),
            key,
            amountSpecified,
            zeroForOne
        );

        vm.revertTo(0);

        return (-delta0, -delta1);
    }

    function simulateSwapSingleBurn(
        IUniswapV3Pool uniPool,
        int24[] memory tickLower,
        int24[] memory tickUpper,
        int128[] memory liquidity,
        ISwapRouter router,
        address token0,
        address token1,
        uint24 fee,
        bool zeroForOne,
        int256 amountSpecified
    ) public returns (int256, int256) {
        vm.snapshot();

        (, caller, ) = vm.readCallers();

        deal(token0, address(caller), type(uint128).max);
        deal(token1, address(caller), type(uint128).max);

        MiniPositionManager pm = new MiniPositionManager();

        // make it so we can burn existing liq from caller
        vm.etch(caller, address(pm).code);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);
        IERC20Partial(token0).approve(address(caller), type(uint256).max);
        IERC20Partial(token1).approve(address(caller), type(uint256).max);

        // i has to be an int so the last decrement doesn't overflow
        for (int i = int(liquidity.length - 1); i >= 0; i--) {
            if (liquidity[uint(i)] > 0) {
                MiniPositionManager(caller).mintLiquidity(
                    uniPool,
                    tickLower[uint(i)],
                    tickUpper[uint(i)],
                    uint128(liquidity[uint(i)]),
                    caller
                );
            } else {
                MiniPositionManager(caller).burnLiquidity(
                    uniPool,
                    tickLower[uint(i)],
                    tickUpper[uint(i)],
                    uint128(-liquidity[uint(i)])
                );
            }
        }
        if (amountSpecified > 0) {
            int256 amountOut = int256(
                router.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: zeroForOne ? token0 : token1,
                        tokenOut: zeroForOne ? token1 : token0,
                        fee: fee,
                        recipient: caller,
                        deadline: block.timestamp,
                        amountIn: uint256(amountSpecified),
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    })
                )
            );

            vm.revertTo(0);

            return zeroForOne ? (amountSpecified, -amountOut) : (-amountOut, amountSpecified);
        } else {
            int256 amountIn;
            try
                router.exactOutputSingle(
                    ISwapRouter.ExactOutputSingleParams({
                        tokenIn: zeroForOne ? token0 : token1,
                        tokenOut: zeroForOne ? token1 : token0,
                        fee: fee,
                        recipient: caller,
                        deadline: block.timestamp,
                        amountOut: uint256(-amountSpecified),
                        amountInMaximum: type(uint256).max,
                        sqrtPriceLimitX96: 0
                    })
                )
            returns (uint256 _amountIn) {
                amountIn = int256(_amountIn);
            } catch {
                vm.assume(false);
            }
            vm.revertTo(0);

            return zeroForOne ? (amountIn, amountSpecified) : (amountSpecified, amountIn);
        }
    }

    // UPD
    function simulateSwap(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        V4RouterSimple routerV4,
        bool[2] memory zeroForOne,
        int256[2] memory amountSpecified
    ) public returns (uint256[2] memory amount0, uint256[2] memory amount1) {
        vm.startPrank(address(0x123456789));

        routerV4.modifyLiquidity(address(0), key, tickLower, tickUpper, int128(liquidity));

        (int256 delta0, int256 delta1) = routerV4.swap(
            address(0),
            key,
            amountSpecified[0],
            zeroForOne[0]
        );

        amount0[0] = uint256(Math.abs(delta0));
        amount1[0] = uint256(Math.abs(delta1));

        routerV4.modifyLiquidity(address(0), key, tickLower, tickUpper, -int128(liquidity));

        (delta0, delta1) = routerV4.swap(address(0), key, amountSpecified[1], zeroForOne[1]);

        amount0[1] = uint256(Math.abs(delta0));
        amount1[1] = uint256(Math.abs(delta1));
    }

    // UPD
    function simulateSwap(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128[2] memory liquidity,
        V4RouterSimple routerV4,
        bool[2] memory zeroForOne,
        int256[2] memory amountSpecified
    ) public returns (uint256[2] memory amount0, uint256[2] memory amount1) {
        vm.startPrank(address(0x123456789));

        routerV4.modifyLiquidity(address(0), key, tickLower, tickUpper, int128(liquidity[0]));

        (int256 delta0, int256 delta1) = routerV4.swap(
            address(0),
            key,
            amountSpecified[0],
            zeroForOne[0]
        );

        amount0[0] = uint256(Math.abs(delta0));
        amount1[0] = uint256(Math.abs(delta1));

        routerV4.modifyLiquidity(address(0), key, tickLower, tickUpper, -int128(liquidity[1]));

        (delta0, delta1) = routerV4.swap(address(0), key, amountSpecified[1], zeroForOne[1]);

        amount0[1] = uint256(Math.abs(delta0));
        amount1[1] = uint256(Math.abs(delta1));
    }

    // this only works if the position is in-range
    function accruePoolFeesInRange(
        IPoolManager manager,
        PoolKey memory key,
        uint256 posLiq,
        uint256 posFees0,
        uint256 posFees1
    ) public {
        uint256 feeGrowthAdd0X128 = FullMath.mulDiv(posFees0, 2 ** 128, posLiq);
        uint256 feeGrowthAdd1X128 = FullMath.mulDiv(posFees1, 2 ** 128, posLiq);

        uint128 _liquidity = StateLibrary.getLiquidity(manager, key.toId());
        // distribute accrued fee amount to Uniswap pool
        deal(
            Currency.unwrap(key.currency0),
            address(manager),
            IERC20Partial(Currency.unwrap(key.currency0)).balanceOf(address(manager)) +
                (_liquidity * posFees0) /
                posLiq
        );
        deal(
            Currency.unwrap(key.currency1),
            address(manager),
            IERC20Partial(Currency.unwrap(key.currency1)).balanceOf(address(manager)) +
                (_liquidity * posFees1) /
                posLiq
        );

        PoolId poolId = key.toId();
        // update global fees
        vm.store(
            address(manager),
            bytes32(
                uint256(StateLibrary._getPoolStateSlot(poolId)) +
                    StateLibrary.FEE_GROWTH_GLOBAL0_OFFSET
            ),
            bytes32(
                uint256(
                    vm.load(
                        address(manager),
                        bytes32(
                            uint256(StateLibrary._getPoolStateSlot(poolId)) +
                                StateLibrary.FEE_GROWTH_GLOBAL0_OFFSET
                        )
                    )
                ) + feeGrowthAdd0X128
            )
        );

        vm.store(
            address(manager),
            bytes32(
                uint256(StateLibrary._getPoolStateSlot(poolId)) +
                    StateLibrary.FEE_GROWTH_GLOBAL0_OFFSET +
                    1
            ),
            bytes32(
                uint256(
                    vm.load(
                        address(manager),
                        bytes32(
                            uint256(StateLibrary._getPoolStateSlot(poolId)) +
                                StateLibrary.FEE_GROWTH_GLOBAL0_OFFSET +
                                1
                        )
                    )
                ) + feeGrowthAdd1X128
            )
        );
    }

    function extractCalldata(
        bytes memory calldataWithSelector
    ) internal pure returns (bytes memory) {
        bytes memory calldataWithoutSelector;

        require(calldataWithSelector.length >= 4);

        assembly {
            let totalLength := mload(calldataWithSelector)
            let targetLength := sub(totalLength, 4)
            calldataWithoutSelector := mload(0x40)

            // Set the length of callDataWithoutSelector (initial length - 4)
            mstore(calldataWithoutSelector, targetLength)

            // Mark the memory space taken for callDataWithoutSelector as allocated
            mstore(0x40, add(0x20, targetLength))

            // Process first 32 bytes (we only take the last 28 bytes)
            mstore(
                add(calldataWithoutSelector, 0x20),
                shl(0x20, mload(add(calldataWithSelector, 0x20)))
            )

            // Process all other data by chunks of 32 bytes
            for {
                let i := 0x1C
            } lt(i, targetLength) {
                i := add(i, 0x20)
            } {
                mstore(
                    add(add(calldataWithoutSelector, 0x20), i),
                    mload(add(add(calldataWithSelector, 0x20), add(i, 0x04)))
                )
            }
        }

        return calldataWithoutSelector;
    }

    function getSCR(int256 utilization) internal pure returns (uint256 sellCollateralRatio) {
        // the sell ratio is on a straight line defined between two points (x0,y0) and (x1,y1):
        //   (x0,y0) = (targetPoolUtilization,min_sell_ratio) and
        //   (x1,y1) = (saturatedPoolUtilization,max_sell_ratio)
        // the line's formula: y = a * (x - x0) + y0, where a = (y1 - y0) / (x1 - x0)
        /**
            SELL
            COLLATERAL
            RATIO
                          ^
                          |                  max ratio = 100%
                   100% - |                _------
                          |             _-¯
                          |          _-¯
                    20% - |---------¯
                          |         .       . .
                          +---------+-------+-+--->   POOL_
                                   50%    90% 100%     UTILIZATION
        */

        uint256 min_sell_ratio = 2000;
        /// if utilization is less than zero, this is the calculation for a strangle, which gets 2x the capital efficiency at low pool utilization
        /// at 0% utilization, strangle legs do not compound efficiency
        if (utilization < 0) {
            unchecked {
                min_sell_ratio /= 2;
                utilization = -utilization;
            }
        }

        // return the basal sell ratio if pool utilization is lower than target
        if (uint256(utilization) < 5000) {
            return min_sell_ratio;
        }

        // return 100% collateral ratio if utilization is above saturated pool utilization
        // this means all new positions are fully collateralized, which reduces risks of insolvency at high pool utilization
        if (uint256(utilization) > 9000) {
            return 10000;
        }

        unchecked {
            return
                min_sell_ratio +
                ((10000 - min_sell_ratio) * (uint256(utilization) - 5000)) /
                (9000 - 5000);
        }
    }

    // convert signed int to assets
    function convertToAssets(CollateralTracker ct, int256 amount) internal view returns (int256) {
        return (amount > 0 ? int8(1) : -1) * int256(ct.convertToAssets(uint256(Math.abs(amount))));
    }

    // "virtual" deposit or withdrawal from an account without changing the share price
    function editCollateral(CollateralTracker ct, address owner, uint256 newShares) internal {
        int256 shareDelta = int256(newShares) - int256(ct.balanceOf(owner));
        int256 assetDelta = convertToAssets(ct, shareDelta);
        vm.store(
            address(ct),
            bytes32(uint256(3)),
            bytes32(
                uint256(
                    LeftRightSigned.unwrap(
                        LeftRightSigned
                            .wrap(int256(uint256(vm.load(address(ct), bytes32(uint256(3))))))
                            .add(LeftRightSigned.wrap(int256(uint256(uint128(int128(assetDelta))))))
                    )
                )
            )
        );

        deal(
            ct.asset(),
            address(ct),
            uint256(int256(IERC20Partial(ct.asset()).balanceOf(address(ct))) + assetDelta)
        );

        deal(address(ct), owner, newShares, true);
    }
}
