// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;
// V4 types
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract V4RouterSimple {
    IPoolManager immutable POOL_MANAGER_V4;

    constructor(IPoolManager _manager) {
        POOL_MANAGER_V4 = _manager;
    }

    function unlockCallback(bytes calldata data) public returns (bytes memory) {
        (uint256 action, bytes memory _data) = abi.decode(data, (uint256, bytes));

        if (action == 0) {
            (
                address caller,
                PoolKey memory key,
                int24 tickLower,
                int24 tickUpper,
                int256 liquidity
            ) = abi.decode(_data, (address, PoolKey, int24, int24, int256));
            (int256 delta0, int256 delta1) = modifyLiquidity(
                caller,
                key,
                tickLower,
                tickUpper,
                liquidity
            );
            return abi.encode(delta0, delta1);
        } else if (action == 1) {
            (address caller, PoolKey memory key, uint160 sqrtPriceX96) = abi.decode(
                _data,
                (address, PoolKey, uint160)
            );
            swapTo(caller, key, sqrtPriceX96);
            return "";
        } else if (action == 2) {
            (address caller, PoolKey memory key, int256 amountSpecified, bool zeroForOne) = abi
                .decode(_data, (address, PoolKey, int256, bool));
            (int256 delta0, int256 delta1) = swap(caller, key, amountSpecified, zeroForOne);
            return abi.encode(delta0, delta1);
        } else if (action == 3) {
            (
                address caller,
                PoolKey memory key,
                int24 tickLower,
                int24 tickUpper,
                int256 liquidity,
                bytes32 salt
            ) = abi.decode(_data, (address, PoolKey, int24, int24, int256, bytes32));
            modifyLiquidityWithSalt(caller, key, tickLower, tickUpper, liquidity, salt);
            return "";
        } else if (action == 4) {
            (address caller, Currency currency, uint256 amount) = abi.decode(
                _data,
                (address, Currency, uint256)
            );
            mintCurrency(caller, currency, amount);
            return "";
        } else if (action == 5) {
            (address caller, Currency currency, uint256 amount) = abi.decode(
                _data,
                (address, Currency, uint256)
            );
            burnCurrency(caller, currency, amount);
            return "";
        }

        return "";
    }

    function mintCurrency(address caller, Currency currency, uint256 amount) public {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            POOL_MANAGER_V4.unlock(abi.encode(4, abi.encode(msg.sender, currency, amount)));
            return;
        }
        POOL_MANAGER_V4.sync(currency);
        SafeTransferLib.safeTransferFrom(
            Currency.unwrap(currency),
            caller,
            address(POOL_MANAGER_V4),
            amount
        );
        POOL_MANAGER_V4.settle();
        POOL_MANAGER_V4.mint(caller, uint160(Currency.unwrap(currency)), amount);
    }

    function burnCurrency(address caller, Currency currency, uint256 amount) public {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            POOL_MANAGER_V4.unlock(abi.encode(5, abi.encode(msg.sender, currency, amount)));
            return;
        }
        POOL_MANAGER_V4.burn(caller, uint160(Currency.unwrap(currency)), amount);
        POOL_MANAGER_V4.take(currency, caller, uint128(amount));
    }

    function modifyLiquidity(
        address caller,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity
    ) public returns (int256, int256) {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            bytes memory res = POOL_MANAGER_V4.unlock(
                abi.encode(0, abi.encode(msg.sender, key, tickLower, tickUpper, liquidity))
            );
            return abi.decode(res, (int256, int256));
        }

        (BalanceDelta delta, ) = POOL_MANAGER_V4.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, liquidity, bytes32(0)),
            ""
        );

        if (delta.amount0() < 0) {
            POOL_MANAGER_V4.sync(key.currency0);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency0),
                caller,
                address(POOL_MANAGER_V4),
                uint128(-delta.amount0())
            );
            POOL_MANAGER_V4.settle();
        } else if (delta.amount0() > 0) {
            POOL_MANAGER_V4.take(key.currency0, caller, uint128(delta.amount0()));
        }

        if (delta.amount1() < 0) {
            POOL_MANAGER_V4.sync(key.currency1);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency1),
                caller,
                address(POOL_MANAGER_V4),
                uint128(-delta.amount1())
            );
            POOL_MANAGER_V4.settle();
        } else if (delta.amount1() > 0) {
            POOL_MANAGER_V4.take(key.currency1, caller, uint128(delta.amount1()));
        }

        return (delta.amount0(), delta.amount1());
    }

    function modifyLiquidityWithSalt(
        address caller,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity,
        bytes32 salt
    ) public {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            POOL_MANAGER_V4.unlock(
                abi.encode(3, abi.encode(msg.sender, key, tickLower, tickUpper, liquidity, salt))
            );
            return;
        }

        (BalanceDelta delta, ) = POOL_MANAGER_V4.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, liquidity, salt),
            ""
        );

        if (delta.amount0() < 0) {
            POOL_MANAGER_V4.sync(key.currency0);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency0),
                caller,
                address(POOL_MANAGER_V4),
                uint128(-delta.amount0())
            );
            POOL_MANAGER_V4.settle();
        } else if (delta.amount0() > 0) {
            POOL_MANAGER_V4.take(key.currency0, caller, uint128(delta.amount0()));
        }

        if (delta.amount1() < 0) {
            POOL_MANAGER_V4.sync(key.currency1);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency1),
                caller,
                address(POOL_MANAGER_V4),
                uint128(-delta.amount1())
            );
            POOL_MANAGER_V4.settle();
        } else if (delta.amount1() > 0) {
            POOL_MANAGER_V4.take(key.currency1, caller, uint128(delta.amount1()));
        }
    }

    function swap(
        address caller,
        PoolKey memory key,
        int256 amountSpecified,
        bool zeroForOne
    ) public returns (int256, int256) {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            bytes memory res = POOL_MANAGER_V4.unlock(
                abi.encode(2, abi.encode(msg.sender, key, amountSpecified, zeroForOne))
            );
            return abi.decode(res, (int256, int256));
        }

        BalanceDelta swapDelta = POOL_MANAGER_V4.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                -amountSpecified,
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );

        if (swapDelta.amount0() < 0) {
            POOL_MANAGER_V4.sync(key.currency0);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency0),
                caller,
                address(POOL_MANAGER_V4),
                uint256(-int256(swapDelta.amount0()))
            );
            POOL_MANAGER_V4.settle();
        } else if (swapDelta.amount0() > 0) {
            POOL_MANAGER_V4.take(key.currency0, caller, uint128(swapDelta.amount0()));
        }

        if (swapDelta.amount1() < 0) {
            POOL_MANAGER_V4.sync(key.currency1);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency1),
                caller,
                address(POOL_MANAGER_V4),
                uint256(-int256(swapDelta.amount1()))
            );
            POOL_MANAGER_V4.settle();
        } else if (swapDelta.amount1() > 0) {
            POOL_MANAGER_V4.take(key.currency1, caller, uint128(swapDelta.amount1()));
        }

        return (swapDelta.amount0(), swapDelta.amount1());
    }

    function swapTo(address caller, PoolKey memory key, uint160 sqrtPriceX96) public {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            bool done;
            // we can only swap type(int128).max tokens at one time, so we need to loop until the price is set
            while (!done) {
                POOL_MANAGER_V4.unlock(abi.encode(1, abi.encode(msg.sender, key, sqrtPriceX96)));
                done = V4StateReader.getSqrtPriceX96(POOL_MANAGER_V4, key.toId()) == sqrtPriceX96;
            }
            return;
        }
        uint160 sqrtPriceX96Before = V4StateReader.getSqrtPriceX96(POOL_MANAGER_V4, key.toId());

        if (sqrtPriceX96Before == sqrtPriceX96) return;

        BalanceDelta swapDelta = POOL_MANAGER_V4.swap(
            key,
            IPoolManager.SwapParams(
                sqrtPriceX96Before > sqrtPriceX96 ? true : false,
                type(int128).min + 1,
                sqrtPriceX96
            ),
            ""
        );

        if (swapDelta.amount0() < 0) {
            POOL_MANAGER_V4.sync(key.currency0);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency0),
                caller,
                address(POOL_MANAGER_V4),
                uint256(-int256(swapDelta.amount0()))
            );
            POOL_MANAGER_V4.settle();
        } else if (swapDelta.amount0() > 0) {
            POOL_MANAGER_V4.take(key.currency0, caller, uint128(swapDelta.amount0()));
        }

        if (swapDelta.amount1() < 0) {
            POOL_MANAGER_V4.sync(key.currency1);
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(key.currency1),
                caller,
                address(POOL_MANAGER_V4),
                uint256(-int256(swapDelta.amount1()))
            );
            POOL_MANAGER_V4.settle();
        } else if (swapDelta.amount1() > 0) {
            POOL_MANAGER_V4.take(key.currency1, caller, uint128(swapDelta.amount1()));
        }
    }
}
