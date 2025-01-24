// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";
import {GeneralActions} from "./GeneralActions.sol";

contract SFPMActions is GeneralActions {
    /// SFPM direct interactions

    ////////////////////////////////////////////////////
    // Mint
    ////////////////////////////////////////////////////

    // mint option sfpm standard mint of full shorts (store this position in mapping)
    // ** add moved amts check
    function mint_option_SFPM_multiShort(
        uint8 numLegs,
        bool[4] calldata asset_in,
        bool[4] calldata is_call_in,
        bool[4] calldata is_otm_in,
        bool[4] calldata is_atm_in,
        uint24[4] memory width_in,
        int256[4] memory strike_in,
        uint128 positionSize,
        bool swapAtMint
    ) public canonicalTimeState {
        $shouldRevertSFPM = false;

        $positionSize = positionSize;

        // store the current actor
        $activeUser = msg.sender;

        // generate a random number of legs
        $activeNumLegs = uint8(bound(uint256(numLegs), 1, 4));

        $activeTokenId = _generate_multiple_leg_tokenid(
            $activeNumLegs,
            asset_in,
            is_call_in,
            [false, false, false, false], // generate short
            is_otm_in,
            is_atm_in,
            width_in,
            strike_in
        );

        $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        uint256 max0Cum;
        uint256 max1Cum;
        // pre-mint calculations/actions for storage
        for (uint i; i < $activeNumLegs; i++) {
            $activeLegIndex = i;

            emit LogUint256("active leg index: ", $activeLegIndex);

            {
                // get the amount of liquidity being deposited
                $liquidityChunk[$activeLegIndex] = PanopticMath.getLiquidityChunk(
                    $activeTokenId,
                    $activeLegIndex,
                    $positionSize
                );

                max0Cum += Math.getAmount0ForLiquidity($liquidityChunk[$activeLegIndex]);
                max1Cum += Math.getAmount1ForLiquidity($liquidityChunk[$activeLegIndex]);

                $sTickLower[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickLower();
                $sTickUpper[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickUpper();
                $sLiqAmounts[$activeLegIndex] = $liquidityChunk[$activeLegIndex].liquidity();

                // *** if liquidity amounts is zero then execution should revert ***
                {
                    if (
                        $sLiqAmounts[$activeLegIndex] == 0 ||
                        $sLiqAmounts[$activeLegIndex] > uint128(type(int128).max)
                    ) $shouldRevertSFPM = true;
                }

                // store the active position details
                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];
                }

                // emit positional bounds and liquidity
                emit LogInt256("tick lower", $tickLowerActive);
                emit LogInt256("tick upper", $tickUpperActive);
                emit LogUint256("liquidity amounts", $LiqAmountActive);
            }

            {
                // get the amount of liquidity within that range present in uniswap already
                $positionKey[$activeLegIndex] = keccak256(
                    abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                );

                (uniLiquidityBefore[$activeLegIndex], , ) = StateLibrary.getPositionInfo(
                    manager,
                    cyclingPoolKey.toId(),
                    address(sfpm),
                    $tickLowerActive,
                    $tickUpperActive,
                    keccak256(
                        abi.encodePacked(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive
                        )
                    )
                );

                // get SFPM stored account liquidity before
                LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive
                );

                // store the removed and net liquidity for the chunk
                //  before mint
                $removedLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.leftSlot();
                $netLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.rightSlot();

                if (
                    $activeTokenId.isLong($activeLegIndex) == 1 &&
                    uniLiquidityBefore[$activeLegIndex] <
                    $liquidityChunk[$activeLegIndex].liquidity()
                ) $shouldRevertSFPM = true;
            }

            // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
            // after check if stored value matches this value
            {
                (
                    $accountPremiumGrossBefore0[$activeLegIndex],
                    $accountPremiumGrossBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    0 // short to check gross
                );

                // get gross premium
                emit LogUint256(
                    "$accountPremiumGrossBefore0",
                    $accountPremiumGrossBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumGrossBefore1",
                    $accountPremiumGrossBefore1[$activeLegIndex]
                );

                // owed premium
                (
                    $accountPremiumOwedBefore0[$activeLegIndex],
                    $accountPremiumOwedBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    1 // long to check owed
                );

                // get owed premium
                emit LogUint256(
                    "$accountPremiumOwedBefore0",
                    $accountPremiumOwedBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumOwedBefore1",
                    $accountPremiumOwedBefore1[$activeLegIndex]
                );
            }
        }

        if (max0Cum > uint128(type(int128).max) - 4 || max1Cum > uint128(type(int128).max) - 4)
            $shouldRevertSFPM = true;

        // reverse tick order if swap at mint
        int24 tickLimitLow = swapAtMint ? int24(887273) : int24(-887273);
        int24 tickLimitHigh = swapAtMint ? int24(-887273) : int24(887273);

        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                $positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            emit LogString("mint was successful");

            // copy return into storage
            $sCollectedByLeg = collectedByLeg;
            $sTotalSwapped = totalSwapped;

            // preform post-mint invariant checks per leg
            for (uint i; i < $activeNumLegs; i++) {
                $activeLegIndex = i;

                emit LogUint256("active leg index: ", $activeLegIndex);

                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];

                    emit LogInt256("$tickLowerActive", $tickLowerActive);
                    emit LogInt256("$tickUpperActive", $tickUpperActive);
                    emit LogUint256("$LiqAmountActive", $LiqAmountActive);
                }

                // check the liquidity deposited within uniswap
                {
                    (uniLiquidityAfter[$activeLegIndex], , ) = StateLibrary.getPositionInfo(
                        manager,
                        cyclingPoolKey.toId(),
                        address(sfpm),
                        $tickLowerActive,
                        $tickUpperActive,
                        keccak256(
                            abi.encodePacked(
                                cyclingPoolKey.toId(),
                                $activeUser,
                                $activeTokenId.tokenType($activeLegIndex),
                                $tickLowerActive,
                                $tickUpperActive
                            )
                        )
                    );

                    emit LogUint256("uni liquidity before", uniLiquidityBefore[$activeLegIndex]);
                    emit LogUint256("$LiqAmountActive", $sLiqAmounts[$activeLegIndex]);
                    emit LogUint256("uni liquidity after", uniLiquidityAfter[$activeLegIndex]);

                    // if multiple chunks touch the same leg the account for this difference
                    // in the final returned amounts
                    assertWithMsg(
                        (
                            $activeTokenId.isLong(i) == 0
                                ? uniLiquidityBefore[$activeLegIndex] +
                                    $sLiqAmounts[$activeLegIndex]
                                : uniLiquidityBefore[$activeLegIndex] -
                                    $sLiqAmounts[$activeLegIndex]
                        ) == uniLiquidityAfter[$activeLegIndex],
                        "invalid uniswap liq"
                    );
                }

                // check the net liquidity added
                {
                    LeftRightUnsigned accountLiquiditiesAfter = sfpm.getAccountLiquidity(
                        cyclingPoolKey.toId(),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive
                    );

                    $removedLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.leftSlot();
                    $netLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.rightSlot();

                    emit LogUint256(
                        "removedLiquidityBefore",
                        $removedLiquidityBefore[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityBefore", $netLiquidityBefore[$activeLegIndex]);

                    emit LogUint256(
                        "removedLiquidityAfter",
                        $removedLiquidityAfter[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityAfter", $netLiquidityAfter[$activeLegIndex]);

                    // check the liquidity tracked is the same as the liquidity computed
                    assertWithMsg(
                        $netLiquidityAfter[$activeLegIndex] ==
                            $sLiqAmounts[$activeLegIndex] + $netLiquidityBefore[$activeLegIndex],
                        "invalid net liquidity"
                    );

                    // ensure the removed liquidity remains the same
                    assertWithMsg(
                        $removedLiquidityBefore[$activeLegIndex] ==
                            $removedLiquidityAfter[$activeLegIndex],
                        "invalid removed liquidity"
                    );
                }

                // check stored fees base for this position
                {
                    {
                        // get premium gross
                        (
                            $accountPremiumGrossAfter0[$activeLegIndex],
                            $accountPremiumGrossAfter1[$activeLegIndex]
                        ) = sfpm.getAccountPremium(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive,
                            type(int24).max,
                            0 // to query gross
                        );

                        // get premium owed
                        (
                            $accountPremiumOwedAfter0[$activeLegIndex],
                            $accountPremiumOwedAfter1[$activeLegIndex]
                        ) = sfpm.getAccountPremium(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive,
                            type(int24).max,
                            1 // to query owed
                        );

                        // gross
                        emit LogUint256(
                            "$accountPremiumGrossAfter0",
                            $accountPremiumGrossAfter0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumGrossAfter1",
                            $accountPremiumGrossAfter1[$activeLegIndex]
                        );
                        // owed
                        emit LogUint256(
                            "$accountPremiumOwedAfter0",
                            $accountPremiumOwedAfter0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumOwedAfter1",
                            $accountPremiumOwedAfter1[$activeLegIndex]
                        );

                        if (
                            collectedByLeg[i].rightSlot() != 0 || collectedByLeg[i].leftSlot() != 0
                        ) {
                            LeftRightUnsigned deltaPremiumOwed;
                            LeftRightUnsigned deltaPremiumGross;

                            /// assert premia values before and after
                            // add previous s_accountPremiumOwed by new amounts (if previously uint128 max ensure it doesn't overflow)
                            try
                                this.getPremiaDeltasChecked(
                                    $netLiquidityBefore[$activeLegIndex],
                                    $removedLiquidityBefore[$activeLegIndex],
                                    collectedByLeg[i].rightSlot(),
                                    collectedByLeg[i].leftSlot()
                                )
                            returns (
                                LeftRightUnsigned deltaPremiumOwedR,
                                LeftRightUnsigned deltaPremiumGrossR
                            ) {
                                // pass
                                deltaPremiumOwed = deltaPremiumOwedR;
                                deltaPremiumGross = deltaPremiumGrossR;
                            } catch {
                                assertWithMsg(false, "fail  in premia calc");
                            }

                            emit LogUint256("deltaPremiumOwed 0", deltaPremiumOwed.rightSlot());
                            emit LogUint256("deltaPremiumOwed 1", deltaPremiumOwed.leftSlot());
                            //
                            emit LogUint256("deltaPremiumGross 0", deltaPremiumGross.rightSlot());
                            emit LogUint256("deltaPremiumGross 1", deltaPremiumGross.leftSlot());

                            // ensure getAccountPremium up to the current touch(max tick) vals match
                            // against the externally computed premia values
                            (
                                $accountPremiumGrossCalculated0[$activeLegIndex],
                                $accountPremiumGrossCalculated1[$activeLegIndex],
                                $accountPremiumOwedCalculated0[$activeLegIndex],
                                $accountPremiumOwedCalculated1[$activeLegIndex]
                            ) = incrementPremiaAccumulator(
                                $accountPremiumGrossBefore0[$activeLegIndex],
                                $accountPremiumGrossBefore1[$activeLegIndex],
                                //
                                deltaPremiumGross.rightSlot(),
                                deltaPremiumGross.leftSlot(),
                                //
                                $accountPremiumOwedBefore0[$activeLegIndex],
                                $accountPremiumOwedBefore1[$activeLegIndex],
                                //
                                deltaPremiumOwed.rightSlot(),
                                deltaPremiumOwed.leftSlot()
                            );

                            emit LogUint256(
                                "$accountPremiumGrossCalculated0",
                                $accountPremiumGrossCalculated0[$activeLegIndex]
                            );
                            emit LogUint256(
                                "$accountPremiumGrossCalculated1",
                                $accountPremiumGrossCalculated1[$activeLegIndex]
                            );
                            //
                            emit LogUint256(
                                "$accountPremiumOwedCalculated0",
                                $accountPremiumOwedCalculated0[$activeLegIndex]
                            );
                            emit LogUint256(
                                "$accountPremiumOwedCalculated1",
                                $accountPremiumOwedCalculated1[$activeLegIndex]
                            );

                            // check calculated gross matches up with stored
                            assertWithMsg(
                                $accountPremiumGrossCalculated0[$activeLegIndex] ==
                                    $accountPremiumGrossAfter0[$activeLegIndex],
                                "invalid gross 0"
                            );
                            assertWithMsg(
                                $accountPremiumGrossCalculated1[$activeLegIndex] ==
                                    $accountPremiumGrossAfter1[$activeLegIndex],
                                "invalid gross 1"
                            );

                            // check owed matches up with stored
                            assertWithMsg(
                                $accountPremiumOwedCalculated0[$activeLegIndex] ==
                                    $accountPremiumOwedAfter0[$activeLegIndex],
                                "invalid owed 0"
                            );
                            assertWithMsg(
                                $accountPremiumOwedCalculated1[$activeLegIndex] ==
                                    $accountPremiumOwedAfter1[$activeLegIndex],
                                "invalid owed 1"
                            );
                        } else {
                            // gross checks
                            assertWithMsg(
                                $accountPremiumGrossBefore0[$activeLegIndex] ==
                                    $accountPremiumGrossAfter0[$activeLegIndex],
                                "invalid gross 0 -> no collect"
                            );
                            assertWithMsg(
                                $accountPremiumGrossBefore1[$activeLegIndex] ==
                                    $accountPremiumGrossAfter1[$activeLegIndex],
                                "invalid gross 1 -> no collect"
                            );

                            // owed checks
                            assertWithMsg(
                                $accountPremiumOwedBefore0[$activeLegIndex] ==
                                    $accountPremiumOwedAfter0[$activeLegIndex],
                                "invalid owed 0 -> no collect"
                            );
                            assertWithMsg(
                                $accountPremiumOwedBefore1[$activeLegIndex] ==
                                    $accountPremiumOwedAfter1[$activeLegIndex],
                                "invalid owed 1 -> no collect"
                            );
                        }
                    }
                }
            }

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[$activeUser].push($activeTokenId);

            _check_tokenBalance(true);

            // reset the activeTokenId for next iteration
            $activeTokenId = TokenId.wrap(uint256(0));

            assertWithMsg(!$shouldRevertSFPM, "sfpm multiShort: missing revert");
        } catch (bytes memory reason) {
            emit LogBool("should revert ?", $shouldRevertSFPM);
            emit LogBytes("reason", reason);

            if (
                bytes4(reason) == Pool.PriceLimitOutOfBounds.selector ||
                bytes4(reason) == Pool.PriceLimitAlreadyExceeded.selector ||
                bytes4(reason) == Pool.TickLiquidityOverflow.selector ||
                bytes4(reason) == SafeCast.SafeCastOverflow.selector
            ) {
                revert();
            }

            deal_USDC(msg.sender, uint128(type(int128).max));
            deal_WETH(msg.sender, uint128(type(int128).max));

            hevm.prank($activeUser);
            USDC.approve(address(routerV4), type(uint256).max);

            hevm.prank($activeUser);
            WETH.approve(address(routerV4), type(uint256).max);

            hevm.prank($activeUser);
            routerV4.mintCurrency(
                address(0),
                Currency.wrap(address(USDC)),
                uint128(type(int128).max)
            );

            hevm.prank($activeUser);
            routerV4.mintCurrency(
                address(0),
                Currency.wrap(address(WETH)),
                uint128(type(int128).max)
            );

            if (bytes4(reason) == Errors.UnderOverFlow.selector && swapAtMint) {
                hevm.prank($activeUser);
                try
                    sfpm.mintTokenizedPosition(
                        cyclingPoolKey,
                        $activeTokenId,
                        $positionSize,
                        tickLimitHigh,
                        tickLimitLow
                    )
                {
                    revert();
                } catch {
                    assertWithMsg($shouldRevertSFPM, "non-expected revert");
                }
            }

            hevm.prank($activeUser);
            try
                sfpm.mintTokenizedPosition(
                    cyclingPoolKey,
                    $activeTokenId,
                    $positionSize,
                    tickLimitLow,
                    tickLimitHigh
                )
            {} catch {
                assertWithMsg($shouldRevertSFPM, "non-expected revert");
            }

            // reverse test state changes
            revert();
        }
    }

    function mint_option_SFPM_multiLong(
        uint256 positionSizeSeed,
        uint256 indexSeed,
        bool swapAtMint
    ) public canonicalTimeState {
        $shouldRevertSFPM = false;

        // store the current actor
        $activeUser = msg.sender;

        {
            // search for a tokenId that the current actor has sold
            uint256 totalPosLen = userPositionsSFPMShort[$activeUser].length;

            if (totalPosLen == 0) {
                // if no short positions exist for the user then pass
                revert();
            }

            // grab the tokenId in reverse order
            $activeTokenId = userPositionsSFPMShort[$activeUser][
                bound(indexSeed, 0, totalPosLen - 1)
            ];

            // bound the positionSize
            uint256 currPosSize = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

            // flip the isLong bit
            $activeTokenId = $activeTokenId.flipToBurnToken();

            $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

            $activeNumLegs = uint8($activeTokenId.countLegs());

            if ($activeNumLegs == 0) {
                revert();
            }

            if (currPosSize < $positionSize) {
                $positionSize = uint128(bound(positionSizeSeed, 0, currPosSize));
            }
        }

        // As pulled from the tokenId
        PoolKey memory originalPoolKey = cyclingPoolKey;
        cyclingPoolKey = sfpm.getUniswapV4PoolKeyFromId($activeTokenId.poolId());

        uint256 max0Cum;
        uint256 max1Cum;
        // pre-mint calculations/actions for storage
        for (uint i; i < $activeNumLegs; i++) {
            $activeLegIndex = i;

            emit LogUint256("active leg index: ", $activeLegIndex);

            {
                // get the amount of liquidity being deposited
                $liquidityChunk[$activeLegIndex] = PanopticMath.getLiquidityChunk(
                    $activeTokenId,
                    $activeLegIndex,
                    $positionSize
                );

                max0Cum += Math.getAmount0ForLiquidity($liquidityChunk[$activeLegIndex]);
                max1Cum += Math.getAmount1ForLiquidity($liquidityChunk[$activeLegIndex]);

                $sTickLower[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickLower();
                $sTickUpper[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickUpper();
                $sLiqAmounts[$activeLegIndex] = $liquidityChunk[$activeLegIndex].liquidity();

                // *** if liquidity amounts is zero then execution should revert ***
                {
                    if (
                        $sLiqAmounts[$activeLegIndex] == 0 ||
                        $sLiqAmounts[$activeLegIndex] > uint128(type(int128).max)
                    ) $shouldRevertSFPM = true;
                }

                // store the active position details
                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];
                }

                // emit positional bounds and liquidity
                emit LogInt256("tick lower", $tickLowerActive);
                emit LogInt256("tick upper", $tickUpperActive);
                emit LogUint256("liquidity amounts", $LiqAmountActive);
            }

            {
                // get the amount of liquidity within that range present in uniswap already
                $positionKey[$activeLegIndex] = keccak256(
                    abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                );
                (uniLiquidityBefore[$activeLegIndex], , ) = StateLibrary.getPositionInfo(
                    manager,
                    cyclingPoolKey.toId(),
                    address(sfpm),
                    $tickLowerActive,
                    $tickUpperActive,
                    keccak256(
                        abi.encodePacked(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive
                        )
                    )
                );

                // get SFPM stored account liquidity before
                LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive
                );

                // store the removed and net liquidity for the chunk
                //  before mint
                $removedLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.leftSlot();
                $netLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.rightSlot();

                if (
                    $activeTokenId.isLong($activeLegIndex) == 1 &&
                    uniLiquidityBefore[$activeLegIndex] <
                    $liquidityChunk[$activeLegIndex].liquidity()
                ) $shouldRevertSFPM = true;
            }

            // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
            // after check if stored value matches this value
            {
                (
                    $accountPremiumGrossBefore0[$activeLegIndex],
                    $accountPremiumGrossBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    0 // short to check gross
                );

                // get gross premium
                emit LogUint256(
                    "$accountPremiumGrossBefore0",
                    $accountPremiumGrossBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumGrossBefore1",
                    $accountPremiumGrossBefore1[$activeLegIndex]
                );

                // owed premium
                (
                    $accountPremiumOwedBefore0[$activeLegIndex],
                    $accountPremiumOwedBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    1 // long to check owed
                );

                // get owed premium
                emit LogUint256(
                    "$accountPremiumOwedBefore0",
                    $accountPremiumOwedBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumOwedBefore1",
                    $accountPremiumOwedBefore1[$activeLegIndex]
                );
            }
        }

        // reverse tick order if swap at mint
        int24 tickLimitLow = swapAtMint ? int24(887273) : int24(-887273);
        int24 tickLimitHigh = swapAtMint ? int24(-887273) : int24(887273);

        if (max0Cum > uint128(type(int128).max) - 4 || max1Cum > uint128(type(int128).max) - 4)
            $shouldRevertSFPM = true;

        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                $positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            emit LogString("mint was successful");

            // copy return into storage
            $sCollectedByLeg = collectedByLeg;
            $sTotalSwapped = totalSwapped;

            // preform post-mint invariant checks per leg
            for (uint i; i < $activeNumLegs; i++) {
                $activeLegIndex = i;

                emit LogUint256("active leg index: ", $activeLegIndex);

                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];

                    emit LogInt256("$tickLowerActive", $tickLowerActive);
                    emit LogInt256("$tickUpperActive", $tickUpperActive);
                    emit LogUint256("$LiqAmountActive", $LiqAmountActive);
                }

                {
                    (uniLiquidityAfter[$activeLegIndex], , ) = StateLibrary.getPositionInfo(
                        manager,
                        cyclingPoolKey.toId(),
                        address(sfpm),
                        $tickLowerActive,
                        $tickUpperActive,
                        keccak256(
                            abi.encodePacked(
                                cyclingPoolKey.toId(),
                                $activeUser,
                                $activeTokenId.tokenType($activeLegIndex),
                                $tickLowerActive,
                                $tickUpperActive
                            )
                        )
                    );

                    emit LogUint256("uni liquidity before", uniLiquidityBefore[$activeLegIndex]);
                    emit LogUint256("$LiqAmountActive", $sLiqAmounts[$activeLegIndex]);
                    emit LogUint256("uni liquidity after", uniLiquidityAfter[$activeLegIndex]);

                    // if multiple chunks touch the same leg the account for this difference
                    // in the final returned amounts
                    assertWithMsg(
                        (
                            $activeTokenId.isLong(i) == 0
                                ? uniLiquidityBefore[$activeLegIndex] +
                                    $sLiqAmounts[$activeLegIndex]
                                : uniLiquidityBefore[$activeLegIndex] -
                                    $sLiqAmounts[$activeLegIndex]
                        ) == uniLiquidityAfter[$activeLegIndex],
                        "invalid uniswap liq"
                    );
                }

                // check the net liquidity added
                {
                    LeftRightUnsigned accountLiquiditiesAfter = sfpm.getAccountLiquidity(
                        cyclingPoolKey.toId(),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive
                    );

                    $removedLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.leftSlot();
                    $netLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.rightSlot();

                    emit LogUint256(
                        "removedLiquidityBefore",
                        $removedLiquidityBefore[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityBefore", $netLiquidityBefore[$activeLegIndex]);

                    emit LogUint256(
                        "removedLiquidityAfter",
                        $removedLiquidityAfter[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityAfter", $netLiquidityAfter[$activeLegIndex]);

                    // check the liquidity tracked is the same as the liquidity computed
                    assertWithMsg(
                        $netLiquidityAfter[$activeLegIndex] ==
                            $netLiquidityBefore[$activeLegIndex] - $sLiqAmounts[$activeLegIndex],
                        "invalid net liquidity"
                    );

                    // ensure the removed liquidity is incremented
                    assertWithMsg(
                        $removedLiquidityBefore[$activeLegIndex] + $sLiqAmounts[$activeLegIndex] ==
                            $removedLiquidityAfter[$activeLegIndex],
                        "invalid removed liquidity"
                    );
                }

                {
                    {
                        // get premium gross
                        (
                            $accountPremiumGrossAfter0[$activeLegIndex],
                            $accountPremiumGrossAfter1[$activeLegIndex]
                        ) = sfpm.getAccountPremium(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive,
                            type(int24).max,
                            0 // to query gross
                        );

                        // get premium owed
                        (
                            $accountPremiumOwedAfter0[$activeLegIndex],
                            $accountPremiumOwedAfter1[$activeLegIndex]
                        ) = sfpm.getAccountPremium(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive,
                            type(int24).max,
                            1 // to query owed
                        );

                        // gross
                        emit LogUint256(
                            "$accountPremiumGrossAfter0",
                            $accountPremiumGrossAfter0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumGrossAfter1",
                            $accountPremiumGrossAfter1[$activeLegIndex]
                        );
                        // owed
                        emit LogUint256(
                            "$accountPremiumOwedAfter0",
                            $accountPremiumOwedAfter0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumOwedAfter1",
                            $accountPremiumOwedAfter1[$activeLegIndex]
                        );

                        if (
                            collectedByLeg[i].rightSlot() != 0 || collectedByLeg[i].leftSlot() != 0
                        ) {
                            LeftRightUnsigned deltaPremiumOwed;
                            LeftRightUnsigned deltaPremiumGross;

                            /// assert premia values before and after
                            // add previous s_accountPremiumOwed by new amounts (if previously uint128 max ensure it doesn't overflow)
                            try
                                this.getPremiaDeltasChecked(
                                    $netLiquidityBefore[$activeLegIndex],
                                    $removedLiquidityBefore[$activeLegIndex],
                                    collectedByLeg[i].rightSlot(),
                                    collectedByLeg[i].leftSlot()
                                )
                            returns (
                                LeftRightUnsigned deltaPremiumOwedR,
                                LeftRightUnsigned deltaPremiumGrossR
                            ) {
                                // pass
                                deltaPremiumOwed = deltaPremiumOwedR;
                                deltaPremiumGross = deltaPremiumGrossR;
                            } catch {
                                assertWithMsg(false, "fail  in premia calc");
                            }

                            emit LogUint256("deltaPremiumOwed 0", deltaPremiumOwed.rightSlot());
                            emit LogUint256("deltaPremiumOwed 1", deltaPremiumOwed.leftSlot());
                            //
                            emit LogUint256("deltaPremiumGross 0", deltaPremiumGross.rightSlot());
                            emit LogUint256("deltaPremiumGross 1", deltaPremiumGross.leftSlot());

                            // ensure getAccountPremium up to the current touch(max tick) vals match
                            // against the externally computed premia values
                            (
                                $accountPremiumGrossCalculated0[$activeLegIndex],
                                $accountPremiumGrossCalculated1[$activeLegIndex],
                                $accountPremiumOwedCalculated0[$activeLegIndex],
                                $accountPremiumOwedCalculated1[$activeLegIndex]
                            ) = incrementPremiaAccumulator(
                                $accountPremiumGrossBefore0[$activeLegIndex],
                                $accountPremiumGrossBefore1[$activeLegIndex],
                                //
                                deltaPremiumGross.rightSlot(),
                                deltaPremiumGross.leftSlot(),
                                //
                                $accountPremiumOwedBefore0[$activeLegIndex],
                                $accountPremiumOwedBefore1[$activeLegIndex],
                                //
                                deltaPremiumOwed.rightSlot(),
                                deltaPremiumOwed.leftSlot()
                            );

                            emit LogUint256(
                                "$accountPremiumGrossCalculated0",
                                $accountPremiumGrossCalculated0[$activeLegIndex]
                            );
                            emit LogUint256(
                                "$accountPremiumGrossCalculated1",
                                $accountPremiumGrossCalculated1[$activeLegIndex]
                            );
                            //
                            emit LogUint256(
                                "$accountPremiumOwedCalculated0",
                                $accountPremiumOwedCalculated0[$activeLegIndex]
                            );
                            emit LogUint256(
                                "$accountPremiumOwedCalculated1",
                                $accountPremiumOwedCalculated1[$activeLegIndex]
                            );

                            // check calculated gross matches up with stored
                            assertWithMsg(
                                $accountPremiumGrossCalculated0[$activeLegIndex] ==
                                    $accountPremiumGrossAfter0[$activeLegIndex],
                                "invalid gross 0"
                            );
                            assertWithMsg(
                                $accountPremiumGrossCalculated1[$activeLegIndex] ==
                                    $accountPremiumGrossAfter1[$activeLegIndex],
                                "invalid gross 1"
                            );

                            // check owed matches up with stored
                            assertWithMsg(
                                $accountPremiumOwedCalculated0[$activeLegIndex] ==
                                    $accountPremiumOwedAfter0[$activeLegIndex],
                                "invalid owed 0"
                            );
                            assertWithMsg(
                                $accountPremiumOwedCalculated1[$activeLegIndex] ==
                                    $accountPremiumOwedAfter1[$activeLegIndex],
                                "invalid owed 1"
                            );
                        } else {
                            // gross checks
                            assertWithMsg(
                                $accountPremiumGrossBefore0[$activeLegIndex] ==
                                    $accountPremiumGrossAfter0[$activeLegIndex],
                                "invalid gross 0 -> no collect"
                            );
                            assertWithMsg(
                                $accountPremiumGrossBefore1[$activeLegIndex] ==
                                    $accountPremiumGrossAfter1[$activeLegIndex],
                                "invalid gross 1 -> no collect"
                            );

                            // owed checks
                            assertWithMsg(
                                $accountPremiumOwedBefore0[$activeLegIndex] ==
                                    $accountPremiumOwedAfter0[$activeLegIndex],
                                "invalid owed 0 -> no collect"
                            );
                            assertWithMsg(
                                $accountPremiumOwedBefore1[$activeLegIndex] ==
                                    $accountPremiumOwedAfter1[$activeLegIndex],
                                "invalid owed 1 -> no collect"
                            );
                        }
                    }
                }
            }

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMLong[msg.sender].push($activeTokenId);

            _check_tokenBalance(true);

            // reset the activeTokenId for next iteration
            $activeTokenId = TokenId.wrap(uint256(0));

            assertWithMsg(!$shouldRevertSFPM, "sfpm multiLong: missing revert");

            // reset the pool
            cyclingPoolKey = originalPoolKey;
        } catch (bytes memory reason) {
            emit LogBool("should revert ?", $shouldRevertSFPM);
            emit LogBytes("reason", reason);

            if (
                bytes4(reason) == Pool.PriceLimitOutOfBounds.selector ||
                bytes4(reason) == Pool.PriceLimitAlreadyExceeded.selector ||
                bytes4(reason) == Pool.TickLiquidityOverflow.selector ||
                bytes4(reason) == SafeCast.SafeCastOverflow.selector
            ) {
                revert();
            }

            deal_USDC(msg.sender, uint128(type(int128).max));
            deal_WETH(msg.sender, uint128(type(int128).max));

            hevm.prank($activeUser);
            USDC.approve(address(routerV4), type(uint256).max);

            hevm.prank($activeUser);
            WETH.approve(address(routerV4), type(uint256).max);

            hevm.prank($activeUser);
            routerV4.mintCurrency(
                address(0),
                Currency.wrap(address(USDC)),
                uint128(type(int128).max)
            );

            hevm.prank($activeUser);
            routerV4.mintCurrency(
                address(0),
                Currency.wrap(address(WETH)),
                uint128(type(int128).max)
            );

            if (bytes4(reason) == Errors.UnderOverFlow.selector && swapAtMint) {
                hevm.prank($activeUser);
                try
                    sfpm.mintTokenizedPosition(
                        cyclingPoolKey,
                        $activeTokenId,
                        $positionSize,
                        tickLimitHigh,
                        tickLimitLow
                    )
                {
                    revert();
                } catch {
                    assertWithMsg($shouldRevertSFPM, "non-expected revert");
                }
            }

            hevm.prank($activeUser);
            try
                sfpm.mintTokenizedPosition(
                    cyclingPoolKey,
                    $activeTokenId,
                    $positionSize,
                    tickLimitLow,
                    tickLimitHigh
                )
            {} catch {
                assertWithMsg($shouldRevertSFPM, "non-expected revert");
            }

            // reverse test state changes
            revert();
        }
    }

    // / *** general multiple mints of longs + shorts
    // check for should revert flag and bound so that it is a valid event
    // looks for chunks minted via the panoptic pool
    function mint_option_SFPM_general(
        uint8 numLegs,
        bool[4] calldata asset_in,
        bool[4] calldata is_call_in,
        bool[4] calldata is_long_in,
        bool[4] calldata is_otm_in,
        bool[4] calldata is_atm_in,
        uint24[4] calldata width_in,
        int256[4] calldata strike_in,
        uint128 positionSize,
        bool swapAtMint,
        uint8 randSeed
    ) public canonicalTimeState {
        emit LogString("start ");

        $shouldRevertSFPM = false;

        $positionSize = positionSize;

        // store the current actor
        $activeUser = msg.sender;

        // generate a random number of legs
        $activeNumLegs = uint8(bound(uint256(numLegs), 1, 4));

        // initialize tokenId
        // ** find matching short chunks for the long legs to increase success rate ??
        $activeTokenId = _generate_multiple_leg_tokenid(
            $activeNumLegs,
            asset_in,
            is_call_in,
            is_long_in,
            is_otm_in,
            is_atm_in,
            width_in,
            strike_in
        );

        $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        emit LogString("after token gen");

        // if the count of legs is less than 4 then add a chunk minted via the panoptic pool
        if ($activeNumLegs < 4 && bound(randSeed, 0, 1) == 1 && touchedPanopticChunks.length > 0) {
            ChunkWithTokenType memory touchedChunk = touchedPanopticChunks[
                bound(randSeed, 0, touchedPanopticChunks.length - 1)
            ];

            // randomly selected chunk
            $activeTokenId = $activeTokenId.addLeg(
                $activeNumLegs - 1,
                1, // option ratio
                uint256(asset_in[0] ? 1 : 0),
                uint256(is_long_in[0] ? 1 : 0),
                touchedChunk.tokenType,
                $activeNumLegs - 1,
                touchedChunk.strike,
                touchedChunk.width
            );

            // increment active number of legs
            $activeNumLegs++;
        }

        $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        uint256 max0Cum;
        uint256 max1Cum;
        // pre-mint calculations/actions for storage
        for (uint i; i < $activeNumLegs; i++) {
            $activeLegIndex = i;

            emit LogUint256("active leg index: ", $activeLegIndex);

            {
                // get the amount of liquidity being deposited
                $liquidityChunk[$activeLegIndex] = PanopticMath.getLiquidityChunk(
                    $activeTokenId,
                    $activeLegIndex,
                    $positionSize
                );

                $sTickLower[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickLower();
                $sTickUpper[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickUpper();
                $sLiqAmounts[$activeLegIndex] = $liquidityChunk[$activeLegIndex].liquidity();

                max0Cum += Math.getAmount0ForLiquidity($liquidityChunk[$activeLegIndex]);
                max1Cum += Math.getAmount1ForLiquidity($liquidityChunk[$activeLegIndex]);

                // *** if liquidity amounts is zero then execution should revert ***
                {
                    if (
                        $sLiqAmounts[$activeLegIndex] == 0 ||
                        $sLiqAmounts[$activeLegIndex] > uint128(type(int128).max)
                    ) $shouldRevertSFPM = true;
                }

                // store the active position details
                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];
                }

                // emit positional bounds and liquidity
                emit LogInt256("tick lower", $tickLowerActive);
                emit LogInt256("tick upper", $tickUpperActive);
                emit LogUint256("liquidity amounts", $LiqAmountActive);
            }

            {
                // get the amount of liquidity within that range present in uniswap already
                $positionKey[$activeLegIndex] = keccak256(
                    abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                );
                (uniLiquidityBefore[$activeLegIndex], , ) = StateLibrary.getPositionInfo(
                    manager,
                    cyclingPoolKey.toId(),
                    address(sfpm),
                    $tickLowerActive,
                    $tickUpperActive,
                    keccak256(
                        abi.encodePacked(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive
                        )
                    )
                );

                // get SFPM stored account liquidity before
                LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive
                );

                // store the removed and net liquidity for the chunk
                //  before mint
                $removedLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.leftSlot();
                $netLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.rightSlot();

                if (
                    $activeTokenId.isLong($activeLegIndex) == 1 &&
                    uniLiquidityBefore[$activeLegIndex] <
                    $liquidityChunk[$activeLegIndex].liquidity()
                ) $shouldRevertSFPM = true;
            }

            {
                (
                    ,
                    $feeGrowthInside0LastX128Before[$activeLegIndex],
                    $feeGrowthInside1LastX128Before[$activeLegIndex]
                ) = StateLibrary.getPositionInfo(
                    manager,
                    cyclingPoolKey.toId(),
                    address(sfpm),
                    $tickLowerActive,
                    $tickUpperActive,
                    keccak256(
                        abi.encodePacked(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive
                        )
                    )
                );

                // after touch
                emit LogUint256(
                    "pre-mint feeGrowthInside0LastX128",
                    $feeGrowthInside0LastX128Before[$activeLegIndex]
                );
                emit LogUint256(
                    "pre-mint feeGrowthInside1LastX128",
                    $feeGrowthInside1LastX128Before[$activeLegIndex]
                );
            }

            emit LogString("midpoint ");

            // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
            // after check if stored value matches this value
            {
                (
                    $accountPremiumGrossBefore0[$activeLegIndex],
                    $accountPremiumGrossBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    0 // short to check gross
                );

                // get gross premium
                emit LogUint256(
                    "$accountPremiumGrossBefore0",
                    $accountPremiumGrossBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumGrossBefore1",
                    $accountPremiumGrossBefore1[$activeLegIndex]
                );

                // owed premium
                (
                    $accountPremiumOwedBefore0[$activeLegIndex],
                    $accountPremiumOwedBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    1 // long to check owed
                );

                // get owed premium
                emit LogUint256(
                    "$accountPremiumOwedBefore0",
                    $accountPremiumOwedBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumOwedBefore1",
                    $accountPremiumOwedBefore1[$activeLegIndex]
                );
            }
        }

        // reverse tick order if swap at mint
        int24 tickLimitLow = swapAtMint ? int24(887273) : int24(-887273);
        int24 tickLimitHigh = swapAtMint ? int24(-887273) : int24(887273);

        if (max0Cum > uint128(type(int128).max) - 4 || max1Cum > uint128(type(int128).max) - 4)
            $shouldRevertSFPM = true;

        emit LogString("reached ??");

        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                $positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            emit LogString("mint was successful");

            // copy return into storage
            $sCollectedByLeg = collectedByLeg;
            $sTotalSwapped = totalSwapped;

            // preform post-mint invariant checks per leg
            for (uint i; i < $activeNumLegs; i++) {
                $activeLegIndex = i;

                emit LogUint256("active leg index: ", $activeLegIndex);

                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];

                    emit LogInt256("$tickLowerActive", $tickLowerActive);
                    emit LogInt256("$tickUpperActive", $tickUpperActive);
                    emit LogUint256("$LiqAmountActive", $LiqAmountActive);
                }

                {
                    (uniLiquidityAfter[$activeLegIndex], , ) = StateLibrary.getPositionInfo(
                        manager,
                        cyclingPoolKey.toId(),
                        address(sfpm),
                        $tickLowerActive,
                        $tickUpperActive,
                        keccak256(
                            abi.encodePacked(
                                cyclingPoolKey.toId(),
                                $activeUser,
                                $activeTokenId.tokenType($activeLegIndex),
                                $tickLowerActive,
                                $tickUpperActive
                            )
                        )
                    );

                    emit LogUint256("uni liquidity before", uniLiquidityBefore[$activeLegIndex]);
                    emit LogUint256("$LiqAmountActive", $sLiqAmounts[$activeLegIndex]);
                    emit LogUint256("uni liquidity after", uniLiquidityAfter[$activeLegIndex]);

                    // if multiple chunks touch the same leg the account for this difference
                    // in the final returned amounts
                    assertWithMsg(
                        (
                            $activeTokenId.isLong(i) == 0
                                ? uniLiquidityBefore[$activeLegIndex] +
                                    $sLiqAmounts[$activeLegIndex]
                                : uniLiquidityBefore[$activeLegIndex] -
                                    $sLiqAmounts[$activeLegIndex]
                        ) == uniLiquidityAfter[$activeLegIndex],
                        "invalid uniswap liq"
                    );
                }

                // check the net liquidity added
                {
                    LeftRightUnsigned accountLiquiditiesAfter = sfpm.getAccountLiquidity(
                        cyclingPoolKey.toId(),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive
                    );

                    $removedLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.leftSlot();
                    $netLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.rightSlot();

                    emit LogUint256(
                        "removedLiquidityBefore",
                        $removedLiquidityBefore[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityBefore", $netLiquidityBefore[$activeLegIndex]);

                    emit LogUint256(
                        "removedLiquidityAfter",
                        $removedLiquidityAfter[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityAfter", $netLiquidityAfter[$activeLegIndex]);

                    if ($activeTokenId.isLong($activeLegIndex) == 1) {
                        // check the liquidity tracked is the same as the liquidity computed
                        assertWithMsg(
                            $netLiquidityAfter[$activeLegIndex] ==
                                $netLiquidityBefore[$activeLegIndex] -
                                    $sLiqAmounts[$activeLegIndex],
                            "invalid net liquidity"
                        );
                    } else {
                        // check the liquidity tracked is the same as the liquidity computed
                        assertWithMsg(
                            $netLiquidityAfter[$activeLegIndex] ==
                                $sLiqAmounts[$activeLegIndex] +
                                    $netLiquidityBefore[$activeLegIndex],
                            "invalid net liquidity"
                        );
                    }
                }

                {
                    // get premium gross
                    (
                        $accountPremiumGrossAfter0[$activeLegIndex],
                        $accountPremiumGrossAfter1[$activeLegIndex]
                    ) = sfpm.getAccountPremium(
                        cyclingPoolKey.toId(),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive,
                        type(int24).max,
                        0 // to query gross
                    );

                    // get premium owed
                    (
                        $accountPremiumOwedAfter0[$activeLegIndex],
                        $accountPremiumOwedAfter1[$activeLegIndex]
                    ) = sfpm.getAccountPremium(
                        cyclingPoolKey.toId(),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive,
                        type(int24).max,
                        1 // to query owed
                    );

                    // gross
                    emit LogUint256(
                        "$accountPremiumGrossAfter0",
                        $accountPremiumGrossAfter0[$activeLegIndex]
                    );
                    emit LogUint256(
                        "$accountPremiumGrossAfter1",
                        $accountPremiumGrossAfter1[$activeLegIndex]
                    );
                    // owed
                    emit LogUint256(
                        "$accountPremiumOwedAfter0",
                        $accountPremiumOwedAfter0[$activeLegIndex]
                    );
                    emit LogUint256(
                        "$accountPremiumOwedAfter1",
                        $accountPremiumOwedAfter1[$activeLegIndex]
                    );

                    if (collectedByLeg[i].rightSlot() != 0 || collectedByLeg[i].leftSlot() != 0) {
                        LeftRightUnsigned deltaPremiumOwed;
                        LeftRightUnsigned deltaPremiumGross;

                        /// assert premia values before and after
                        // add previous s_accountPremiumOwed by new amounts (if previously uint128 max ensure it doesn't overflow)
                        try
                            this.getPremiaDeltasChecked(
                                $netLiquidityBefore[$activeLegIndex],
                                $removedLiquidityBefore[$activeLegIndex],
                                collectedByLeg[i].rightSlot(),
                                collectedByLeg[i].leftSlot()
                            )
                        returns (
                            LeftRightUnsigned deltaPremiumOwedR,
                            LeftRightUnsigned deltaPremiumGrossR
                        ) {
                            // pass
                            deltaPremiumOwed = deltaPremiumOwedR;
                            deltaPremiumGross = deltaPremiumGrossR;
                        } catch {
                            assertWithMsg(false, "fail  in premia calc");
                        }

                        emit LogUint256("deltaPremiumOwed 0", deltaPremiumOwed.rightSlot());
                        emit LogUint256("deltaPremiumOwed 1", deltaPremiumOwed.leftSlot());
                        //
                        emit LogUint256("deltaPremiumGross 0", deltaPremiumGross.rightSlot());
                        emit LogUint256("deltaPremiumGross 1", deltaPremiumGross.leftSlot());

                        // ensure getAccountPremium up to the current touch(max tick) vals match
                        // against the externally computed premia values
                        (
                            $accountPremiumGrossCalculated0[$activeLegIndex],
                            $accountPremiumGrossCalculated1[$activeLegIndex],
                            $accountPremiumOwedCalculated0[$activeLegIndex],
                            $accountPremiumOwedCalculated1[$activeLegIndex]
                        ) = incrementPremiaAccumulator(
                            $accountPremiumGrossBefore0[$activeLegIndex],
                            $accountPremiumGrossBefore1[$activeLegIndex],
                            //
                            deltaPremiumGross.rightSlot(),
                            deltaPremiumGross.leftSlot(),
                            //
                            $accountPremiumOwedBefore0[$activeLegIndex],
                            $accountPremiumOwedBefore1[$activeLegIndex],
                            //
                            deltaPremiumOwed.rightSlot(),
                            deltaPremiumOwed.leftSlot()
                        );

                        emit LogUint256(
                            "$accountPremiumGrossCalculated0",
                            $accountPremiumGrossCalculated0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumGrossCalculated1",
                            $accountPremiumGrossCalculated1[$activeLegIndex]
                        );
                        //
                        emit LogUint256(
                            "$accountPremiumOwedCalculated0",
                            $accountPremiumOwedCalculated0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumOwedCalculated1",
                            $accountPremiumOwedCalculated1[$activeLegIndex]
                        );

                        // check calculated gross matches up with stored
                        assertWithMsg(
                            $accountPremiumGrossCalculated0[$activeLegIndex] ==
                                $accountPremiumGrossAfter0[$activeLegIndex],
                            "invalid gross 0"
                        );
                        assertWithMsg(
                            $accountPremiumGrossCalculated1[$activeLegIndex] ==
                                $accountPremiumGrossAfter1[$activeLegIndex],
                            "invalid gross 1"
                        );

                        // check owed matches up with stored
                        assertWithMsg(
                            $accountPremiumOwedCalculated0[$activeLegIndex] ==
                                $accountPremiumOwedAfter0[$activeLegIndex],
                            "invalid owed 0"
                        );
                        assertWithMsg(
                            $accountPremiumOwedCalculated1[$activeLegIndex] ==
                                $accountPremiumOwedAfter1[$activeLegIndex],
                            "invalid owed 1"
                        );
                    } else {
                        // gross checks
                        assertWithMsg(
                            $accountPremiumGrossBefore0[$activeLegIndex] ==
                                $accountPremiumGrossAfter0[$activeLegIndex],
                            "invalid gross 0 -> no collect"
                        );
                        assertWithMsg(
                            $accountPremiumGrossBefore1[$activeLegIndex] ==
                                $accountPremiumGrossAfter1[$activeLegIndex],
                            "invalid gross 1 -> no collect"
                        );

                        // owed checks
                        assertWithMsg(
                            $accountPremiumOwedBefore0[$activeLegIndex] ==
                                $accountPremiumOwedAfter0[$activeLegIndex],
                            "invalid owed 0 -> no collect"
                        );
                        assertWithMsg(
                            $accountPremiumOwedBefore1[$activeLegIndex] ==
                                $accountPremiumOwedAfter1[$activeLegIndex],
                            "invalid owed 1 -> no collect"
                        );
                    }
                }
            }

            _check_tokenBalance(true);

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMix[msg.sender].push($activeTokenId);

            // reset the activeTokenId for next iteration
            $activeTokenId = TokenId.wrap(uint256(0));

            assertWithMsg(!$shouldRevertSFPM, "sfpm mint general: missing revert");
        } catch (bytes memory reason) {
            emit LogBool("should revert ?", $shouldRevertSFPM);
            emit LogBytes("reason", reason);

            if (
                bytes4(reason) == Pool.PriceLimitOutOfBounds.selector ||
                bytes4(reason) == Pool.PriceLimitAlreadyExceeded.selector ||
                bytes4(reason) == Pool.TickLiquidityOverflow.selector ||
                bytes4(reason) == SafeCast.SafeCastOverflow.selector
            ) {
                revert();
            }

            deal_USDC(msg.sender, uint128(type(int128).max));
            deal_WETH(msg.sender, uint128(type(int128).max));

            hevm.prank($activeUser);
            USDC.approve(address(routerV4), type(uint256).max);

            hevm.prank($activeUser);
            WETH.approve(address(routerV4), type(uint256).max);

            hevm.prank($activeUser);
            routerV4.mintCurrency(
                address(0),
                Currency.wrap(address(USDC)),
                uint128(type(int128).max)
            );

            hevm.prank($activeUser);
            routerV4.mintCurrency(
                address(0),
                Currency.wrap(address(WETH)),
                uint128(type(int128).max)
            );

            if (bytes4(reason) == Errors.UnderOverFlow.selector && swapAtMint) {
                hevm.prank($activeUser);
                try
                    sfpm.mintTokenizedPosition(
                        cyclingPoolKey,
                        $activeTokenId,
                        $positionSize,
                        tickLimitHigh,
                        tickLimitLow
                    )
                {
                    revert();
                } catch {
                    assertWithMsg($shouldRevertSFPM, "non-expected revert");
                }
            }

            hevm.prank($activeUser);
            try
                sfpm.mintTokenizedPosition(
                    cyclingPoolKey,
                    $activeTokenId,
                    $positionSize,
                    tickLimitLow,
                    tickLimitHigh
                )
            {} catch {
                assertWithMsg($shouldRevertSFPM, "non-expected revert");
            }

            // reverse test state changes
            revert();
        }
    }

    // mint SFPM Swap At Mint = true, and ITM = true
    function mint_option_SFPM_swapT_ITMT(
        bool asset,
        bool is_call,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public canonicalTimeState {
        $activeUser = msg.sender;

        $positionSize = positionSize;

        // must be
        $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            false,
            false,
            width,
            strike
        );

        $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        int256 totalMoved0;
        int256 totalMoved1;

        int24 tickLimitLow = int24(887273);
        int24 tickLimitHigh = int24(-887273);

        {
            (int256 moved0, int256 moved1) = _calculate_moved_amounts(
                $activeTokenId,
                $positionSize,
                true
            );

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);

            // get itm amounts
            (int256 itm0, int256 itm1) = _calculate_itm_amounts(
                $activeTokenId.tokenType(0),
                moved0,
                moved1
            );

            emit LogInt256("itm0", itm0);
            emit LogInt256("itm1", itm1);

            (int256 swapAmount, bool zeroForOne) = _compute_swap_amounts(itm0, itm1);

            (int256 swap0, int256 swap1, ) = _execute_swap_simulation(zeroForOne, swapAmount);

            emit LogInt256("swap0", swap0);
            emit LogInt256("swap1", swap1);

            // total moved
            totalMoved0 = moved0 + swap0;
            totalMoved1 = moved1 + swap1;

            emit LogInt256("totalMoved0", totalMoved0);
            emit LogInt256("totalMoved1", totalMoved1);
        }

        // current balances
        int256 balBefore0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
        int256 balBefore1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                $positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned) {
            // check final balances
            int256 balAfter0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
            int256 balAfter1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqAbs(
                balBefore0 -
                    totalMoved0 +
                    int256(
                        uint256(
                            collectedByLeg[0].rightSlot() +
                                collectedByLeg[1].rightSlot() +
                                collectedByLeg[2].rightSlot() +
                                collectedByLeg[3].rightSlot()
                        )
                    ),
                balAfter0,
                1,
                "bal 0 delta invalid"
            );

            assertApproxEqAbs(
                balBefore1 -
                    totalMoved1 +
                    int256(
                        uint256(
                            collectedByLeg[0].leftSlot() +
                                collectedByLeg[1].leftSlot() +
                                collectedByLeg[2].leftSlot() +
                                collectedByLeg[3].leftSlot()
                        )
                    ),
                balAfter1,
                1,
                "bal 1 delta invalid"
            );

            _check_tokenBalance(true);

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[$activeUser].push($activeTokenId);
        } catch {}
    }

    // mint SFPM regular mint Swap At Mint = false, and ITM = false
    function mint_option_SFPM_swapF_ITMF(
        bool asset,
        bool is_call,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public canonicalTimeState {
        $activeUser = msg.sender;

        $positionSize = positionSize;

        $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            true,
            false,
            width,
            strike
        );

        $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        currentTick = V4StateReader.getTick(manager, cyclingPoolKey.toId());

        emit LogInt256("pre-mint Tick", currentTick);

        int256 moved0;
        int256 moved1;

        int24 tickLimitLow = int24(-887273);
        int24 tickLimitHigh = int24(887273);

        {
            // get moved amounts
            // moved amounts is faulty function
            // reverts for some reason
            (moved0, moved1) = _calculate_moved_amounts($activeTokenId, $positionSize, true);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);
        }

        // current balances
        int256 balBefore0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
        int256 balBefore1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                $positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned) {
            // check final balances
            int256 balAfter0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
            int256 balAfter1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqAbs(
                balBefore0 -
                    moved0 +
                    int256(
                        uint256(
                            collectedByLeg[0].rightSlot() +
                                collectedByLeg[1].rightSlot() +
                                collectedByLeg[2].rightSlot() +
                                collectedByLeg[3].rightSlot()
                        )
                    ),
                balAfter0,
                1,
                "bal 0 delta invalid"
            );

            assertApproxEqAbs(
                balBefore1 -
                    moved1 +
                    int256(
                        uint256(
                            collectedByLeg[0].leftSlot() +
                                collectedByLeg[1].leftSlot() +
                                collectedByLeg[2].leftSlot() +
                                collectedByLeg[3].leftSlot()
                        )
                    ),
                balAfter1,
                1,
                "bal 1 delta invalid"
            );

            _check_tokenBalance(true);

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[$activeUser].push($activeTokenId);
        } catch {}
    }

    // swap at mint true, and ITM false
    function mint_option_SFPM_swapT_ITMF(
        bool asset,
        bool is_call,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public canonicalTimeState {
        $activeUser = msg.sender;

        $positionSize = positionSize;

        $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            true,
            false,
            width,
            strike
        );

        $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        int256 moved0;
        int256 moved1;

        int24 tickLimitLow = int24(887273);
        int24 tickLimitHigh = int24(-887273);

        {
            // get moved amounts
            (moved0, moved1) = _calculate_moved_amounts($activeTokenId, positionSize, true);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);
        }

        // current balances
        int256 balBefore0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
        int256 balBefore1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                $positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned) {
            // check final balances
            int256 balAfter0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
            int256 balAfter1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqAbs(
                balBefore0 -
                    moved0 +
                    int256(
                        uint256(
                            collectedByLeg[0].rightSlot() +
                                collectedByLeg[1].rightSlot() +
                                collectedByLeg[2].rightSlot() +
                                collectedByLeg[3].rightSlot()
                        )
                    ),
                balAfter0,
                1,
                "bal 0 delta invalid"
            );

            assertApproxEqAbs(
                balBefore1 -
                    moved1 +
                    int256(
                        uint256(
                            collectedByLeg[0].leftSlot() +
                                collectedByLeg[1].leftSlot() +
                                collectedByLeg[2].leftSlot() +
                                collectedByLeg[3].leftSlot()
                        )
                    ),
                balAfter1,
                1,
                "bal 1 delta invalid"
            );

            _check_tokenBalance(true);

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[$activeUser].push($activeTokenId);
        } catch {}
    }

    // swap at mint false, and itm true
    function mint_option_SFPM_swapF_ITMT(
        bool asset,
        bool is_call,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public canonicalTimeState {
        $activeUser = msg.sender;

        $positionSize = positionSize;

        $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            false,
            false,
            width,
            strike
        );

        $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        int256 moved0;
        int256 moved1;

        int24 tickLimitLow = int24(-887273);
        int24 tickLimitHigh = int24(887273);

        {
            // get moved amounts
            (moved0, moved1) = _calculate_moved_amounts($activeTokenId, $positionSize, true);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);
        }

        // current balances
        int256 balBefore0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
        int256 balBefore1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                $positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned) {
            // check final balances
            int256 balAfter0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
            int256 balAfter1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqAbs(
                balBefore0 -
                    moved0 +
                    int256(
                        uint256(
                            collectedByLeg[0].rightSlot() +
                                collectedByLeg[1].rightSlot() +
                                collectedByLeg[2].rightSlot() +
                                collectedByLeg[3].rightSlot()
                        )
                    ),
                balAfter0,
                1,
                "bal 0 delta invalid"
            );

            assertApproxEqAbs(
                balBefore1 -
                    moved1 +
                    int256(
                        uint256(
                            collectedByLeg[0].leftSlot() +
                                collectedByLeg[1].leftSlot() +
                                collectedByLeg[2].leftSlot() +
                                collectedByLeg[3].leftSlot()
                        )
                    ),
                balAfter1,
                1,
                "bal 1 delta invalid"
            );

            _check_tokenBalance(true);

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[$activeUser].push($activeTokenId);
        } catch {}
    }

    // swap at mint true, and itm true (netting swap 2 legs of differing token type)
    function mint_option_SFPM_nettingSwap(
        bool asset0,
        bool asset1,
        bool isATM0,
        bool isATM1,
        uint24 width0,
        uint24 width1,
        int256 strike0,
        int256 strike1,
        uint128 positionSize
    ) public canonicalTimeState {
        $activeUser = msg.sender;

        $positionSize = positionSize;

        // generate double leg shorts
        // dynamic numeraire and token type
        $activeTokenId = _generate_multiple_leg_tokenid(
            2,
            [asset0, asset1, false, false],
            [true, false, false, false],
            [false, false, false, false],
            [false, false, false, false],
            [isATM0, isATM1, false, false],
            [width0, width1, 0, 0],
            [strike0, strike1, 0, 0]
        );

        $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        int256 totalMoved0;
        int256 totalMoved1;

        int24 tickLimitLow = int24(887273);
        int24 tickLimitHigh = int24(-887273);

        {
            (
                int256 moved0,
                int256 moved1,
                int256 itm0,
                int256 itm1
            ) = _calculate_moved_and_ITM_amounts($activeTokenId, $positionSize);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);
            emit LogInt256("itm0", itm0);
            emit LogInt256("itm1", itm1);

            (int256 swapAmount, bool zeroForOne) = _compute_swap_amounts(itm0, itm1);

            emit LogInt256("swapAmount", swapAmount);
            emit LogBool("zeroForOne", zeroForOne);

            (int256 swap0, int256 swap1, ) = _execute_swap_simulation(zeroForOne, swapAmount);

            emit LogInt256("swap0", swap0);
            emit LogInt256("swap1", swap1);

            // total moved
            totalMoved0 = moved0 + swap0;
            totalMoved1 = moved1 + swap1;

            emit LogInt256("totalMoved0", totalMoved0);
            emit LogInt256("totalMoved1", totalMoved1);
        }

        // current balances
        int256 balBefore0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
        int256 balBefore1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        currentSqrtPriceX96 = V4StateReader.getSqrtPriceX96(manager, cyclingPoolKey.toId());

        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                $positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned) {
            // check final balances
            int256 balAfter0 = int256(manager.balanceOf($activeUser, uint160(address(USDC))));
            int256 balAfter1 = int256(manager.balanceOf($activeUser, uint160(address(WETH))));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqAbs(
                balBefore0 -
                    totalMoved0 +
                    int256(
                        uint256(
                            collectedByLeg[0].rightSlot() +
                                collectedByLeg[1].rightSlot() +
                                collectedByLeg[2].rightSlot() +
                                collectedByLeg[3].rightSlot()
                        )
                    ),
                balAfter0,
                1,
                "bal 0 delta invalid"
            );

            assertApproxEqAbs(
                balBefore1 -
                    totalMoved1 +
                    int256(
                        uint256(
                            collectedByLeg[0].leftSlot() +
                                collectedByLeg[1].leftSlot() +
                                collectedByLeg[2].leftSlot() +
                                collectedByLeg[3].leftSlot()
                        )
                    ),
                balAfter1,
                1,
                "bal 1 delta invalid"
            );

            int256 convertedMoved1to0 = PanopticMath.convert1to0(totalMoved1, currentSqrtPriceX96);
            emit LogInt256("value of total moved 1 to 0", convertedMoved1to0);

            // disabled as on low liq pools the swap won't occur at a single price (tick liquidity will roll over)
            // ensure that only token 0 was moved as this was a netting swap
            // assertWithMsg(totalMoved0 == convertedMoved1to0, "invalid conversion");

            _check_tokenBalance(true);

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[$activeUser].push($activeTokenId);
        } catch {}
    }

    // mint SFPM position size = 0
    function assertion_invariant_mint_option_SFPM_posSize0(
        uint256 minter_index,
        bool asset,
        bool is_call,
        bool is_otm,
        bool is_atm,
        bool swapAtMint,
        uint24 width,
        int256 strike
    ) public canonicalTimeState {
        minter_index = bound(minter_index, 0, 4);
        require(actors[minter_index] != msg.sender);

        address minter = actors[minter_index];

        // pos size 0
        uint128 positionSize = 0;
        TokenId tokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );

        int24 tickLimitLow = swapAtMint ? int24(887273) : int24(-887273);
        int24 tickLimitHigh = swapAtMint ? int24(-887273) : int24(887273);

        // if positionSize == 0 then should fail
        if (positionSize == 0) {
            hevm.prank(minter);
            try
                sfpm.mintTokenizedPosition(
                    cyclingPoolKey,
                    tokenId,
                    positionSize,
                    tickLimitLow,
                    tickLimitHigh
                )
            {
                assertWithMsg(false, "can't mint option with position size of 0");
            } catch {}
        }
    }

    // token composition is over 127 bits on either side should fail
    function assertion_invariant_mint_option_SFPM_PositionTooLarge(
        uint256 minter_index,
        bool asset,
        bool is_call,
        bool is_otm,
        bool is_atm,
        bool swapAtMint,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public canonicalTimeState {
        minter_index = bound(minter_index, 0, 4);
        require(actors[minter_index] != msg.sender);

        address minter = actors[minter_index];

        TokenId tokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );

        int24 tickLimitLow = swapAtMint ? int24(887273) : int24(-887273);
        int24 tickLimitHigh = swapAtMint ? int24(-887273) : int24(887273);

        // current balances
        uint256 balBefore0 = manager.balanceOf(minter, uint160(address(USDC)));
        uint256 balBefore1 = manager.balanceOf(minter, uint160(address(WETH)));

        hevm.prank(minter);
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                tokenId,
                positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned) {
            // if amount moved is greater than 2 ** 127 bits
            // bal before - bal after > 2 ** 127 - 4

            // check final balances
            uint256 balAfter0 = manager.balanceOf(minter, uint160(address(USDC)));
            uint256 balAfter1 = manager.balanceOf(minter, uint160(address(WETH)));

            int256 balDelta0 = int256(balBefore0) - int256(balAfter0);
            int256 balDelta1 = int256(balBefore1) - int256(balAfter1);

            for (uint256 i = 0; i < collectedByLeg.length; i++) {
                balDelta0 += int256(uint256(collectedByLeg[i].rightSlot()));
                balDelta1 += int256(uint256(collectedByLeg[i].leftSlot()));
            }

            //--
            emit LogUint256("balBefore0", balBefore0);
            emit LogUint256("balBefore1", balBefore1);
            //
            emit LogUint256("balAfter0", balAfter0);
            emit LogUint256("balAfter1", balAfter1);
            //
            emit LogInt256("balDelta0", balDelta0);
            emit LogInt256("balDelta1", balDelta1);
            //
            emit LogUint256("max", uint128(type(int128).max - 4));

            assertWithMsg(
                !(balDelta0 > type(int128).max - 4 || balDelta1 > type(int128).max - 4),
                "can't mint a position which exceeds the token limits of 127 bits"
            );
        } catch {}
    }

    // attempt to purchase more liquidity than exists at the chunk
    function assertion_invariant_mint_option_SFPM_NotEnoughLiquidity(
        bool asset,
        bool is_call,
        bool is_otm,
        bool is_atm,
        bool swapAtMint,
        uint24 width,
        int256 strike,
        uint128 positionSize,
        uint128 sizeIncrement
    ) public canonicalTimeState {
        $activeUser = msg.sender;

        $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );
        TokenId tokenIdLong = _generate_single_leg_tokenid(
            asset,
            is_call,
            true,
            is_otm,
            is_atm,
            width,
            strike
        );

        int24 tickLimitLow = swapAtMint ? int24(887273) : int24(-887273);
        int24 tickLimitHigh = swapAtMint ? int24(-887273) : int24(887273);

        (int24 tickLower, int24 tickUpper) = $activeTokenId.asTicks(0);

        // check there is no pre-existing liquidity at this chunk deployed by the minter
        LeftRightUnsigned accountLiquidities = sfpm.getAccountLiquidity(
            cyclingPoolKey.toId(),
            $activeUser,
            $activeTokenId.tokenType(0),
            tickLower,
            tickUpper
        );

        //
        if (accountLiquidities.rightSlot() != 0) {
            // mint a small amount of liquidity at this chunk
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                positionSize,
                tickLimitLow,
                tickLimitHigh
            );
        }

        uint256 newPosSize;
        unchecked {
            newPosSize = positionSize + sizeIncrement;
        }

        if (
            newPosSize < positionSize ||
            newPosSize < sizeIncrement ||
            newPosSize > type(uint128).max
        ) {
            revert();
        }

        // invoke actions as the chosen minter
        hevm.prank($activeUser);
        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                tokenIdLong,
                uint128(newPosSize),
                tickLimitLow,
                tickLimitHigh
            )
        {
            uint256 shortLiq = PanopticMath
                .getLiquidityChunk($activeTokenId, 0, positionSize)
                .liquidity();
            uint256 longLiq = PanopticMath
                .getLiquidityChunk(tokenIdLong, 0, uint128(newPosSize))
                .liquidity();

            emit LogUint256("shortLiq", shortLiq);
            emit LogUint256("longLiq", longLiq);

            // continue because the position size generated is of the same size
            if (shortLiq == longLiq) {
                revert();
            }

            assertWithMsg(false, "Can't purchase more chunk liquidity than is available!");
        } catch {}
    }

    // can't mint a position that defies the slippage bounds
    function assertion_invariant_mint_option_SFPM_PriceBoundFail(
        bool asset,
        bool is_call,
        bool is_otm,
        bool is_atm,
        bool swapAtMint,
        uint24 width,
        int256 strike,
        uint128 positionSize,
        bool slippageDirection,
        int256 randTick
    ) public canonicalTimeState {
        $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );

        // get moved amounts
        // moved amounts is faulty function
        // reverts for some reason
        (int256 moved0, int256 moved1) = _calculate_moved_amounts(
            $activeTokenId,
            positionSize,
            true
        );

        // get itm amounts
        (int256 itm0, int256 itm1) = _calculate_itm_amounts(
            $activeTokenId.tokenType(0),
            moved0,
            moved1
        );

        (int256 swapAmount, bool zeroForOne) = _compute_swap_amounts(itm0, itm1);

        $positionSize = positionSize;

        int24 tickAfterSwap;
        if (swapAtMint) {
            (, , tickAfterSwap) = _execute_swap_simulation(zeroForOne, swapAmount);
        } else {
            tickAfterSwap = V4StateReader.getTick(manager, cyclingPoolKey.toId());
        }

        int24 tickLimitLow;
        int24 tickLimitHigh;

        // get the currentTick after this position would have been minted via sim and
        if (slippageDirection) {
            tickLimitHigh = int24(887273);
            tickLimitLow = int24(bound(randTick, tickAfterSwap, tickLimitHigh - 1));
        } else {
            // set valid tickLow
            tickLimitLow = int24(-887273);

            tickLimitHigh = int24(bound(randTick, tickLimitLow + 1, tickAfterSwap));
        }

        // flip ticks for swap at mint signal
        if (swapAtMint) {
            (tickLimitLow, tickLimitHigh) = (tickLimitHigh, tickLimitLow);
        }

        emit LogString("before mint");

        uint128 _positionSize = positionSize;
        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        try
            sfpm.mintTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                _positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        {
            assertWithMsg(false, "Can't mint an option which defies the slippage bounds");
        } catch {}
    }

    /// burn
    function burn_option_SFPM_general(
        uint128 positionSize,
        bool swapAtMint,
        bool isLong,
        bool isMix,
        uint256 randSeed
    ) public canonicalTimeState {
        $shouldRevertSFPM = false;

        $positionSize = positionSize;

        // store the current actor
        $activeUser = msg.sender;

        // grab a random tokenId owned by the current interactor ***
        if (isMix && userPositionsSFPMix[$activeUser].length != 0) {
            // burn mix
            uint256 randIndex = bound(randSeed, 0, userPositionsSFPMix[$activeUser].length - 1);
            $activeTokenId = userPositionsSFPMix[$activeUser][randIndex];

            // delete from owner
            userPositionsSFPMix[$activeUser][randIndex] = TokenId.wrap(0);
        } else if (isLong && userPositionsSFPMLong[$activeUser].length != 0) {
            // burn a long
            uint256 randIndex = bound(randSeed, 0, userPositionsSFPMLong[$activeUser].length - 1);
            $activeTokenId = userPositionsSFPMLong[$activeUser][randIndex];

            // delete from owner
            userPositionsSFPMLong[$activeUser][randIndex] = TokenId.wrap(0);
        } else {
            if (userPositionsSFPMShort[$activeUser].length == 0) {
                revert();
            }

            // burn a short
            uint256 randIndex = bound(randSeed, 0, userPositionsSFPMShort[$activeUser].length - 1);
            $activeTokenId = userPositionsSFPMShort[$activeUser][randIndex];

            // delete from owner
            userPositionsSFPMShort[$activeUser][randIndex] = TokenId.wrap(0);
        }

        $prevSPFMTokenBal = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));

        // As pulled from the tokenId
        PoolKey memory originalPoolKey = cyclingPoolKey;
        cyclingPoolKey = sfpm.getUniswapV4PoolKeyFromId($activeTokenId.poolId());

        $activeNumLegs = uint8($activeTokenId.countLegs());

        // bound the position size to the amount owned by the user for that tokenId
        if ($positionSize > $prevSPFMTokenBal || TokenId.unwrap($activeTokenId) == uint256(0)) {
            revert();
        }

        uint256 max0Cum;
        uint256 max1Cum;
        // pre-mint calculations/actions for storage
        for (uint i = 0; i < $activeNumLegs; i++) {
            $activeLegIndex = i;

            emit LogUint256("active leg index: ", $activeLegIndex);

            {
                // get the amount of liquidity being deposited
                $liquidityChunk[$activeLegIndex] = PanopticMath.getLiquidityChunk(
                    $activeTokenId,
                    $activeLegIndex,
                    $positionSize
                );

                max0Cum += Math.getAmount0ForLiquidity($liquidityChunk[$activeLegIndex]);
                max1Cum += Math.getAmount1ForLiquidity($liquidityChunk[$activeLegIndex]);

                $sTickLower[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickLower();
                $sTickUpper[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickUpper();
                $sLiqAmounts[$activeLegIndex] = $liquidityChunk[$activeLegIndex].liquidity();

                // *** if liquidity amounts is zero then execution should revert ***
                {
                    if (
                        $sLiqAmounts[$activeLegIndex] == 0 ||
                        $sLiqAmounts[$activeLegIndex] > uint128(type(int128).max)
                    ) $shouldRevertSFPM = true;
                }

                // store the active position details
                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];
                }

                // emit positional bounds and liquidity
                emit LogInt256("tick lower", $tickLowerActive);
                emit LogInt256("tick upper", $tickUpperActive);
                emit LogUint256("liquidity amounts", $LiqAmountActive);
            }

            {
                // get the amount of liquidity within that range present in uniswap already
                $positionKey[$activeLegIndex] = keccak256(
                    abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                );
                (uniLiquidityBefore[$activeLegIndex], , ) = StateLibrary.getPositionInfo(
                    manager,
                    cyclingPoolKey.toId(),
                    address(sfpm),
                    $tickLowerActive,
                    $tickUpperActive,
                    keccak256(
                        abi.encodePacked(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive
                        )
                    )
                );

                // get SFPM stored account liquidity before
                LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive
                );

                // store the removed and net liquidity for the chunk
                //  before mint
                $removedLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.leftSlot();
                $netLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.rightSlot();
                if (
                    ($activeTokenId.isLong($activeLegIndex) == 0 &&
                        uniLiquidityBefore[$activeLegIndex] <
                        $liquidityChunk[$activeLegIndex].liquidity()) ||
                    ($activeTokenId.isLong($activeLegIndex) == 1 &&
                        $removedLiquidityBefore[$activeLegIndex] <
                        $liquidityChunk[$activeLegIndex].liquidity())
                ) $shouldRevertSFPM = true;

                emit LogUint256(
                    "removed liquidity before",
                    $removedLiquidityBefore[$activeLegIndex]
                );
                emit LogUint256("net liquidity before", $netLiquidityBefore[$activeLegIndex]);
            }

            // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
            // after check if stored value matches this value
            {
                (
                    $accountPremiumGrossBefore0[$activeLegIndex],
                    $accountPremiumGrossBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    0 // short to check gross
                );

                // get gross premium
                emit LogUint256(
                    "$accountPremiumGrossBefore0",
                    $accountPremiumGrossBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumGrossBefore1",
                    $accountPremiumGrossBefore1[$activeLegIndex]
                );

                // owed premium
                (
                    $accountPremiumOwedBefore0[$activeLegIndex],
                    $accountPremiumOwedBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    cyclingPoolKey.toId(),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    1 // long to check owed
                );

                // get owed premium
                emit LogUint256(
                    "$accountPremiumOwedBefore0",
                    $accountPremiumOwedBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumOwedBefore1",
                    $accountPremiumOwedBefore1[$activeLegIndex]
                );
            }
        }

        if (max0Cum > uint128(type(int128).max) - 4 || max1Cum > uint128(type(int128).max) - 4)
            $shouldRevertSFPM = true;

        // reverse tick order if swap at mint
        int24 tickLimitLow = swapAtMint ? int24(887273) : int24(-887273);
        int24 tickLimitHigh = swapAtMint ? int24(-887273) : int24(887273);

        hevm.prank($activeUser);
        try
            sfpm.burnTokenizedPosition(
                cyclingPoolKey,
                $activeTokenId,
                $positionSize,
                tickLimitLow,
                tickLimitHigh
            )
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            emit LogString("burn was successful");

            // copy return into storage
            $sCollectedByLeg = collectedByLeg;
            $sTotalSwapped = totalSwapped;

            // preform post-mint invariant checks per leg
            for (uint i = 0; i < $activeNumLegs; i++) {
                $activeLegIndex = i;

                emit LogUint256("active leg index: ", $activeLegIndex);

                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];

                    emit LogInt256("$tickLowerActive", $tickLowerActive);
                    emit LogInt256("$tickUpperActive", $tickUpperActive);
                    emit LogUint256("$LiqAmountActive", $LiqAmountActive);
                }

                {
                    (uniLiquidityAfter[$activeLegIndex], , ) = StateLibrary.getPositionInfo(
                        manager,
                        cyclingPoolKey.toId(),
                        address(sfpm),
                        $tickLowerActive,
                        $tickUpperActive,
                        keccak256(
                            abi.encodePacked(
                                cyclingPoolKey.toId(),
                                $activeUser,
                                $activeTokenId.tokenType($activeLegIndex),
                                $tickLowerActive,
                                $tickUpperActive
                            )
                        )
                    );

                    emit LogUint256("uni liquidity before", uniLiquidityBefore[$activeLegIndex]);
                    emit LogUint256("$LiqAmountActive", $sLiqAmounts[$activeLegIndex]);
                    emit LogUint256("uni liquidity after", uniLiquidityAfter[$activeLegIndex]);

                    assertWithMsg(
                        (
                            $activeTokenId.isLong(i) == 0
                                ? uniLiquidityBefore[$activeLegIndex] -
                                    $sLiqAmounts[$activeLegIndex]
                                : uniLiquidityBefore[$activeLegIndex] +
                                    $sLiqAmounts[$activeLegIndex]
                        ) == uniLiquidityAfter[$activeLegIndex],
                        "invalid uniswap liq"
                    );
                }

                // check the net liquidity added
                {
                    LeftRightUnsigned accountLiquiditiesAfter = sfpm.getAccountLiquidity(
                        cyclingPoolKey.toId(),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive
                    );

                    $removedLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.leftSlot();
                    $netLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.rightSlot();

                    emit LogUint256(
                        "removedLiquidityBefore",
                        $removedLiquidityBefore[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityBefore", $netLiquidityBefore[$activeLegIndex]);

                    emit LogUint256(
                        "removedLiquidityAfter",
                        $removedLiquidityAfter[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityAfter", $netLiquidityAfter[$activeLegIndex]);

                    if ($activeTokenId.isLong($activeLegIndex) == 0) {
                        // check the liquidity tracked is the same as the liquidity computed
                        assertWithMsg(
                            $netLiquidityAfter[$activeLegIndex] ==
                                $netLiquidityBefore[$activeLegIndex] -
                                    $sLiqAmounts[$activeLegIndex],
                            "invalid net liquidity"
                        );

                        // ensure the removed liquidity is incremented
                        assertWithMsg(
                            $removedLiquidityBefore[$activeLegIndex] ==
                                $removedLiquidityAfter[$activeLegIndex],
                            "invalid removed liquidity"
                        );
                    } else {
                        // check the liquidity tracked is the same as the liquidity computed
                        assertWithMsg(
                            $netLiquidityAfter[$activeLegIndex] ==
                                $sLiqAmounts[$activeLegIndex] +
                                    $netLiquidityBefore[$activeLegIndex],
                            "invalid net liquidity"
                        );

                        // ensure the removed liquidity remains the same
                        assertWithMsg(
                            $removedLiquidityBefore[$activeLegIndex] -
                                $sLiqAmounts[$activeLegIndex] ==
                                $removedLiquidityAfter[$activeLegIndex],
                            "invalid removed liquidity"
                        );
                    }
                }

                {
                    {
                        // get premium gross
                        (
                            $accountPremiumGrossAfter0[$activeLegIndex],
                            $accountPremiumGrossAfter1[$activeLegIndex]
                        ) = sfpm.getAccountPremium(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive,
                            type(int24).max,
                            0 // to query gross
                        );

                        // get premium owed
                        (
                            $accountPremiumOwedAfter0[$activeLegIndex],
                            $accountPremiumOwedAfter1[$activeLegIndex]
                        ) = sfpm.getAccountPremium(
                            cyclingPoolKey.toId(),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive,
                            type(int24).max,
                            1 // to query owed
                        );

                        // gross
                        emit LogUint256(
                            "$accountPremiumGrossAfter0",
                            $accountPremiumGrossAfter0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumGrossAfter1",
                            $accountPremiumGrossAfter1[$activeLegIndex]
                        );
                        // owed
                        emit LogUint256(
                            "$accountPremiumOwedAfter0",
                            $accountPremiumOwedAfter0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumOwedAfter1",
                            $accountPremiumOwedAfter1[$activeLegIndex]
                        );

                        if (
                            collectedByLeg[i].rightSlot() != 0 || collectedByLeg[i].leftSlot() != 0
                        ) {
                            LeftRightUnsigned deltaPremiumOwed;
                            LeftRightUnsigned deltaPremiumGross;

                            /// assert premia values before and after
                            // add previous s_accountPremiumOwed by new amounts (if previously uint128 max ensure it doesn't overflow)
                            try
                                this.getPremiaDeltasChecked(
                                    $netLiquidityBefore[$activeLegIndex],
                                    $removedLiquidityBefore[$activeLegIndex],
                                    collectedByLeg[i].rightSlot(),
                                    collectedByLeg[i].leftSlot()
                                )
                            returns (
                                LeftRightUnsigned deltaPremiumOwedR,
                                LeftRightUnsigned deltaPremiumGrossR
                            ) {
                                // pass
                                deltaPremiumOwed = deltaPremiumOwedR;
                                deltaPremiumGross = deltaPremiumGrossR;
                            } catch {
                                assertWithMsg(false, "fail  in premia calc");
                            }

                            emit LogUint256("deltaPremiumOwed 0", deltaPremiumOwed.rightSlot());
                            emit LogUint256("deltaPremiumOwed 1", deltaPremiumOwed.leftSlot());
                            //
                            emit LogUint256("deltaPremiumGross 0", deltaPremiumGross.rightSlot());
                            emit LogUint256("deltaPremiumGross 1", deltaPremiumGross.leftSlot());

                            // ensure getAccountPremium up to the current touch(max tick) vals match
                            // against the externally computed premia values
                            (
                                $accountPremiumGrossCalculated0[$activeLegIndex],
                                $accountPremiumGrossCalculated1[$activeLegIndex],
                                $accountPremiumOwedCalculated0[$activeLegIndex],
                                $accountPremiumOwedCalculated1[$activeLegIndex]
                            ) = incrementPremiaAccumulator(
                                $accountPremiumGrossBefore0[$activeLegIndex],
                                $accountPremiumGrossBefore1[$activeLegIndex],
                                //
                                deltaPremiumGross.rightSlot(),
                                deltaPremiumGross.leftSlot(),
                                //
                                $accountPremiumOwedBefore0[$activeLegIndex],
                                $accountPremiumOwedBefore1[$activeLegIndex],
                                //
                                deltaPremiumOwed.rightSlot(),
                                deltaPremiumOwed.leftSlot()
                            );

                            emit LogUint256(
                                "$accountPremiumGrossCalculated0",
                                $accountPremiumGrossCalculated0[$activeLegIndex]
                            );
                            emit LogUint256(
                                "$accountPremiumGrossCalculated1",
                                $accountPremiumGrossCalculated1[$activeLegIndex]
                            );
                            //
                            emit LogUint256(
                                "$accountPremiumOwedCalculated0",
                                $accountPremiumOwedCalculated0[$activeLegIndex]
                            );
                            emit LogUint256(
                                "$accountPremiumOwedCalculated1",
                                $accountPremiumOwedCalculated1[$activeLegIndex]
                            );

                            // check calculated gross matches up with stored
                            assertWithMsg(
                                $accountPremiumGrossCalculated0[$activeLegIndex] ==
                                    $accountPremiumGrossAfter0[$activeLegIndex],
                                "invalid gross 0"
                            );
                            assertWithMsg(
                                $accountPremiumGrossCalculated1[$activeLegIndex] ==
                                    $accountPremiumGrossAfter1[$activeLegIndex],
                                "invalid gross 1"
                            );

                            // check owed matches up with stored
                            assertWithMsg(
                                $accountPremiumOwedCalculated0[$activeLegIndex] ==
                                    $accountPremiumOwedAfter0[$activeLegIndex],
                                "invalid owed 0"
                            );
                            assertWithMsg(
                                $accountPremiumOwedCalculated1[$activeLegIndex] ==
                                    $accountPremiumOwedAfter1[$activeLegIndex],
                                "invalid owed 1"
                            );
                        } else {
                            // gross checks
                            assertWithMsg(
                                $accountPremiumGrossBefore0[$activeLegIndex] ==
                                    $accountPremiumGrossAfter0[$activeLegIndex],
                                "invalid gross 0 -> no collect"
                            );
                            assertWithMsg(
                                $accountPremiumGrossBefore1[$activeLegIndex] ==
                                    $accountPremiumGrossAfter1[$activeLegIndex],
                                "invalid gross 1 -> no collect"
                            );

                            // owed checks
                            assertWithMsg(
                                $accountPremiumOwedBefore0[$activeLegIndex] ==
                                    $accountPremiumOwedAfter0[$activeLegIndex],
                                "invalid owed 0 -> no collect"
                            );
                            assertWithMsg(
                                $accountPremiumOwedBefore1[$activeLegIndex] ==
                                    $accountPremiumOwedAfter1[$activeLegIndex],
                                "invalid owed 1 -> no collect"
                            );
                        }
                    }
                }
            }

            _check_tokenBalance(false);

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMix[msg.sender].push($activeTokenId);

            // reset the activeTokenId for next iteration
            $activeTokenId = TokenId.wrap(uint256(0));

            // reset the pool
            cyclingPoolKey = originalPoolKey;
        } catch (bytes memory reason) {
            emit LogBool("should revert ?", $shouldRevertSFPM);
            emit LogBytes("reason", reason);

            if (
                bytes4(reason) == Pool.PriceLimitOutOfBounds.selector ||
                bytes4(reason) == Pool.PriceLimitAlreadyExceeded.selector ||
                bytes4(reason) == Pool.TickLiquidityOverflow.selector ||
                bytes4(reason) == SafeCast.SafeCastOverflow.selector
            ) {
                revert();
            }

            deal_USDC(msg.sender, uint128(type(int128).max));
            deal_WETH(msg.sender, uint128(type(int128).max));

            hevm.prank($activeUser);
            USDC.approve(address(routerV4), type(uint256).max);

            hevm.prank($activeUser);
            WETH.approve(address(routerV4), type(uint256).max);

            hevm.prank($activeUser);
            routerV4.mintCurrency(
                address(0),
                Currency.wrap(address(USDC)),
                uint128(type(int128).max)
            );

            hevm.prank($activeUser);
            routerV4.mintCurrency(
                address(0),
                Currency.wrap(address(WETH)),
                uint128(type(int128).max)
            );

            if (bytes4(reason) == Errors.UnderOverFlow.selector && swapAtMint) {
                hevm.prank($activeUser);
                try
                    sfpm.burnTokenizedPosition(
                        cyclingPoolKey,
                        $activeTokenId,
                        $positionSize,
                        tickLimitHigh,
                        tickLimitLow
                    )
                {
                    revert();
                } catch {
                    assertWithMsg($shouldRevertSFPM, "non-expected revert");
                }
            }

            hevm.prank($activeUser);
            try
                sfpm.burnTokenizedPosition(
                    cyclingPoolKey,
                    $activeTokenId,
                    $positionSize,
                    tickLimitLow,
                    tickLimitHigh
                )
            {} catch {
                assertWithMsg($shouldRevertSFPM, "non-expected revert");
            }

            // reverse test state changes
            revert();
        }
    }

    ////////////////////////////////////////////////////
    // General mint functions
    ////////////////////////////////////////////////////
    /// @dev Generate a single leg
    function _generate_single_leg_tokenid(
        bool asset_in,
        bool is_call_in,
        bool is_long_in,
        bool is_otm_in,
        bool is_atm,
        uint24 width_in,
        int256 strike_in
    ) internal returns (TokenId out) {
        out = TokenId.wrap(sfpmPoolId);

        // Rest of the parameters come from the function parameters
        uint256 asset = asset_in == true ? 1 : 0;
        uint256 call_put = is_call_in == true ? 1 - asset : asset;
        uint256 long_short = is_long_in == true ? 1 : 0;

        int24 width;
        int24 strike;

        currentTick = V4StateReader.getTick(manager, cyclingPoolKey.toId());

        if (is_atm) {
            (width, strike) = getATMSW(width_in, strike_in, uint24(sfpmTickSpacing), currentTick);
        } else if (is_otm_in) {
            (width, strike) = getOTMSW(
                width_in,
                strike_in,
                uint24(sfpmTickSpacing),
                currentTick,
                call_put
            );
        } else {
            (width, strike) = getITMSW(
                width_in,
                strike_in,
                uint24(sfpmTickSpacing),
                currentTick,
                call_put
            );
        }

        out = out.addLeg(0, 1, asset, long_short, call_put, 0, strike, width);
        log_tokenid_leg(out, 0);
    }

    function _generate_multiple_leg_tokenid(
        uint8 numLegs,
        bool[4] memory asset_in,
        bool[4] memory is_call_in,
        bool[4] memory is_long_in,
        bool[4] memory is_otm_in,
        bool[4] memory is_atm_in,
        uint24[4] memory width_in,
        int256[4] memory strike_in
    ) internal returns (TokenId out) {
        out = TokenId.wrap(sfpmPoolId);

        currentTick = V4StateReader.getTick(manager, cyclingPoolKey.toId());

        emit LogString("after current tick");

        // The parameters come from the function parameters
        for (uint256 i = 0; i < numLegs; i++) {
            uint256 asset = asset_in[i] == true ? 1 : 0;
            uint256 call_put = is_call_in[i] == true ? 1 - asset : asset;
            uint256 long_short = is_long_in[i] == true ? 1 : 0;

            int24 width;
            int24 strike;

            emit LogString("before selector");

            emit LogUint256("width", width_in[i]);
            emit LogInt256("strike", strike_in[i]);
            emit LogInt256("sfpmTickSpacing", sfpmTickSpacing);

            if (is_atm_in[i]) {
                (width, strike) = getATMSW(
                    width_in[i],
                    strike_in[i],
                    uint24(sfpmTickSpacing),
                    currentTick
                );
            } else if (is_otm_in[i]) {
                (width, strike) = getOTMSW(
                    width_in[i],
                    strike_in[i],
                    uint24(sfpmTickSpacing),
                    currentTick,
                    call_put
                );
            } else {
                (width, strike) = getITMSW(
                    width_in[i],
                    strike_in[i],
                    uint24(sfpmTickSpacing),
                    currentTick,
                    call_put
                );
            }

            emit LogString("before adding leg");

            out = out.addLeg(i, 1, asset, long_short, call_put, i, strike, width);
            log_tokenid_leg(out, i);
        }
        out.validate();
    }

    /////////////////////////////////////////////////////////////
    // Imported functions
    /////////////////////////////////////////////////////////////

    function getContext(
        uint256 ts_,
        int24 _currentTick,
        int24 _width
    ) internal pure returns (int24 strikeOffset, int24 minTick, int24 maxTick) {
        int256 ts = int256(ts_);

        strikeOffset = int24(_width % 2 == 0 ? int256(0) : ts / 2);

        if (ts_ == 1) {
            minTick = int24(((_currentTick - 4096) / ts) * ts);
            maxTick = int24(((_currentTick + 4096) / ts) * ts);
        } else {
            minTick = int24(((_currentTick - 4096 * 10) / ts) * ts);
            maxTick = int24(((_currentTick + 4096 * 10) / ts) * ts);
        }
    }

    function getOTMSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick,
        uint256 _tokenType
    ) internal returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        emit LogString("OTM");

        width = ts == 1
            ? width = int24(int256(bound(_widthSeed, 1, 1000)))
            : int24(int256(bound(_widthSeed, 1, (1000 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(ts_, _currentTick, width);

        int24 lowerBound = _tokenType == 0
            ? int24(_currentTick + 1 + ts + oneSidedRange - strikeOffset)
            : int24(minTick + oneSidedRange - strikeOffset);
        int24 upperBound = _tokenType == 0
            ? int24(maxTick - oneSidedRange - strikeOffset)
            : int24(_currentTick - oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = _tokenType == 0
                ? int24(_currentTick + 1 + ts + rangeDown - strikeOffset)
                : int24(minTick + rangeDown - strikeOffset);
            upperBound = _tokenType == 0
                ? int24(maxTick - rangeUp - strikeOffset)
                : int24(_currentTick - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(
            int256(
                bound(
                    _strikeSeed,
                    lowerBound > 0
                        ? int256(Math.unsafeDivRoundingUp(uint24(lowerBound), uint256(ts)))
                        : lowerBound / ts,
                    upperBound < 0
                        ? -int256(Math.unsafeDivRoundingUp(uint24(-upperBound), uint256(ts)))
                        : upperBound / ts
                )
            )
        );

        strike = int24(strike * ts + strikeOffset);
    }

    function getITMSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick,
        uint256 _tokenType
    ) internal returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        emit LogString("ITM");

        width = ts == 1
            ? width = int24(int256(bound(_widthSeed, 1, 1000)))
            : int24(int256(bound(_widthSeed, 1, (1000 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(ts_, _currentTick, width);

        int24 lowerBound = _tokenType == 0
            ? int24(minTick + oneSidedRange - strikeOffset)
            : int24(_currentTick + 1 + oneSidedRange - strikeOffset);
        int24 upperBound = _tokenType == 0
            ? int24(_currentTick + ts - oneSidedRange - strikeOffset)
            : int24(maxTick - oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = _tokenType == 0
                ? int24(minTick + rangeDown - strikeOffset)
                : int24(_currentTick + 1 + rangeDown - strikeOffset);
            upperBound = _tokenType == 0
                ? int24(_currentTick + ts - rangeUp - strikeOffset)
                : int24(maxTick - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(
            int256(
                bound(
                    _strikeSeed,
                    lowerBound > 0
                        ? int256(Math.unsafeDivRoundingUp(uint24(lowerBound), uint256(ts)))
                        : lowerBound / ts,
                    upperBound < 0
                        ? -int256(Math.unsafeDivRoundingUp(uint24(-upperBound), uint256(ts)))
                        : upperBound / ts
                )
            )
        );

        strike = int24(strike * ts + strikeOffset);
    }

    function getATMSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick
    ) internal returns (int24 width, int24 strike) {
        emit LogString("ATM");

        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(_widthSeed, 1, 1000)))
            : int24(int256(bound(_widthSeed, 1, (1000 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, , ) = getContext(ts_, _currentTick, width);

        int24 lowerBound = int24(_currentTick + ts - oneSidedRange - strikeOffset);
        int24 upperBound = int24(_currentTick + oneSidedRange - strikeOffset);

        if (ts == 1) {
            upperBound = int24(_currentTick + rangeDown - strikeOffset);
            lowerBound = int24(_currentTick + ts - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(int256(bound(_strikeSeed, lowerBound / ts, upperBound / ts)));

        strike = int24(strike * ts + strikeOffset);
    }

    function getValidSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick
    ) internal pure returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(_widthSeed, 1, 1000)))
            : int24(int256(bound(_widthSeed, 1, 1000)));

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(ts_, _currentTick, width);

        int24 lowerBound = int24(minTick + rangeDown - strikeOffset);
        int24 upperBound = int24(maxTick - rangeUp - strikeOffset);

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(_strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }
}
