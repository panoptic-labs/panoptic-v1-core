// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Custom Errors library.
/// @author Axicon Labs Limited
/// @notice Contains all custom error messages used in Panoptic.
library Errors {
    /// @notice PanopticPool: The account is not solvent enough to perform the desired action
    error AccountInsolvent();

    /// @notice Casting error
    /// @dev e.g. uint128(uint256(a)) fails
    error CastingError();

    /// @notice CollateralTracker: Collateral token has already been initialized
    error CollateralTokenAlreadyInitialized();

    /// @notice CollateralTracker: The amount of shares (or assets) deposited is larger than the maximum permitted
    error DepositTooLarge();

    /// @notice PanopticPool: The effective liquidity (X32) is greater than min(`MAX_SPREAD`, `USER_PROVIDED_THRESHOLD`) during a long mint or short burn
    /// @dev Effective liquidity measures how much new liquidity is minted relative to how much is already in the pool
    error EffectiveLiquidityAboveThreshold();

    /// @notice CollateralTracker: Attempted to withdraw/redeem more than available liquidity, owned shares, or open positions would allow for
    error ExceedsMaximumRedemption();

    /// @notice PanopticPool: The provided list of option positions is incorrect or invalid
    error InputListFail();

    /// @notice Tick is not between `MIN_TICK` and `MAX_TICK`
    error InvalidTick();

    /// @notice The result of a notional value conversion is too small (=0) or too large (>2^128-1)
    error InvalidNotionalValue();

    /// @notice The TokenId provided by the user is malformed or invalid
    /// @param parameterType poolId=0, ratio=1, tokenType=2, risk_partner=3, strike=4, width=5, two identical strike/width/tokenType chunks=6
    error InvalidTokenIdParameter(uint256 parameterType);

    /// @notice An unlock callback was attempted from an address other than the canonical Uniswap V4 pool manager
    error UnauthorizedUniswapCallback();

    /// @notice PanopticPool: None of the legs in a position are force-exercisable (they are all either short or ATM long)
    error NoLegsExercisable();

    /// @notice PanopticPool: The leg is not long, so premium cannot be settled through `settleLongPremium`
    error NotALongLeg();

    /// @notice PanopticPool: There is not enough available liquidity in the chunk for one of the long legs to be created (or for one of the short legs to be closed)
    error NotEnoughLiquidity();

    /// @notice PanopticPool: Position is still solvent and cannot be liquidated
    error NotMarginCalled();

    /// @notice CollateralTracker: The caller for a permissioned function is not the Panoptic Pool
    error NotPanopticPool();

    /// @notice Uniswap pool has already been initialized in the SFPM or created in the factory
    error PoolAlreadyInitialized();

    /// @notice PanopticPool: A position with the given token ID has already been minted by the caller and is still open
    error PositionAlreadyMinted();

    /// @notice CollateralTracker: The user has open/active option positions, so they cannot transfer collateral shares
    error PositionCountNotZero();

    /// @notice SFPM: The maximum token deltas (excluding swaps) for a position exceed (2^127 - 5) at some valid price
    error PositionTooLarge();

    /// @notice The current tick in the pool (post-ITM-swap) has fallen outside a user-defined open interval slippage range
    error PriceBoundFail();

    /// @notice An oracle price is too far away from another oracle price or the current tick
    /// @dev This is a safeguard against price manipulation during option mints, burns, and liquidations
    error StaleTWAP();

    /// @notice PanopticPool: An account has reached the maximum number of open positions and cannnot mint another
    error TooManyPositionsOpen();

    /// @notice ERC20 or SFPM (ERC1155) token transfer did not complete successfully
    error TransferFailed();

    /// @notice The tick range given by the strike price and width is invalid
    /// because the upper and lower ticks are not multiples of `tickSpacing`
    error TicksNotInitializable();

    /// @notice An operation in a library has failed due to an underflow or overflow
    error UnderOverFlow();

    /// @notice The Uniswap Pool has not been created, so it cannot be used in the SFPM or have a PanopticPool created for it by the factory
    error UniswapPoolNotInitialized();

    /// @notice SFPM: Mints/burns of zero-liquidity chunks in Uniswap are not supported
    error ZeroLiquidity();
}
