// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";
import {CollateralActions} from "./CollateralActions.sol";

contract PanopticPoolActions is CollateralActions {
    function mint_option(
        uint256[4] memory isLongs,
        uint256[4] memory tokenTypes,
        uint256[4] memory widthSeeds,
        int256[4] memory strikeSeeds,
        uint256[4] memory ratioSeeds,
        uint256[4] memory riskPartnerSeeds,
        uint256[4] memory assets,
        bool[5] memory distributions,
        int24[2] memory tickLimitSeeds,
        uint256 positionSize,
        uint256 numLegs
    ) public canonicalTimeState {
        emit LogAddress("actor", msg.sender);

        ($tickLimitLow, $tickLimitHigh) = (tickLimitSeeds[0], tickLimitSeeds[1]);

        $numLegs = bound(numLegs, 1, 4);

        $posIdListOld = userPositions[msg.sender];

        userPositions[msg.sender].push(TokenId.wrap(poolId));

        (, , observationIndex, observationCardinality, , , ) = pool.slot0();

        currentTick = V4StateReader.getTick(manager, poolKey.toId());

        ($slowOracleTick, ) = panopticHelper.computeInternalMedian(
            60,
            uint256(hevm.load(address(panopticPool), bytes32(uint256(0)))),
            IV3CompatibleOracle(address(pool))
        );

        $fastOracleTick = panopticHelper.computeMedianObservedPrice(
            IV3CompatibleOracle(address(pool)),
            Constants.FAST_ORACLE_CARDINALITY,
            Constants.FAST_ORACLE_PERIOD
        );

        $safeMode = Math.abs($slowOracleTick - currentTick) > 953;

        if ($safeMode) {
            if ($tickLimitLow > $tickLimitHigh) {
                ($tickLimitLow, $tickLimitHigh) = ($tickLimitHigh, $tickLimitLow);
            }
        }

        $found = false;
        for (uint256 i = 0; i < $numLegs; ++i) {
            $tokenTypes[i] = bound(tokenTypes[i], 0, 1);
            $isLongs[i] = bound(isLongs[i], 0, 4);
            $isLongs[i] = $isLongs[i] > 1 ? 0 : $isLongs[i];
            $assets[i] = bound(assets[i], 0, 1);
            $ratios[i] = distributions[4] ? 1 : bound(ratioSeeds[i], 1, 127);
            $riskPartners[i] = distributions[2] ? i : bound(riskPartnerSeeds[i], 0, $numLegs - 1);

            if ($isLongs[i] == 0) {
                ($widths[i], $strikes[i]) = getValidSW(
                    widthSeeds[i],
                    strikeSeeds[i],
                    uint24(poolTickSpacing),
                    currentTick,
                    distributions[0]
                );

                touchedPanopticChunks.push(
                    ChunkWithTokenType($strikes[i], $widths[i], $tokenTypes[i])
                );
            } else {
                // pick a random chunk -- very likely to fail due to no liquidity
                if (touchedPanopticChunks.length == 0) {
                    ($widths[i], $strikes[i]) = getValidSW(
                        widthSeeds[i],
                        strikeSeeds[i],
                        uint24(poolTickSpacing),
                        currentTick,
                        distributions[0]
                    );
                }
                // pick a chunk that has already been interacted with before -- reasonable probability of success
                else if (distributions[3]) {
                    ChunkWithTokenType memory __chunk = touchedPanopticChunks[
                        bound(
                            uint256(keccak256(abi.encodePacked(positionSize))),
                            0,
                            touchedPanopticChunks.length - 1
                        )
                    ];

                    $widths[i] = __chunk.width;
                    $strikes[i] = __chunk.strike;
                }
                // pick a chunk with some liquidity and reverse the position size to it
                else {
                    bool found;
                    // look through all chunks starting at a random index until one with liquidity is found
                    for (
                        uint256 j = bound(
                            uint256(keccak256(abi.encodePacked(positionSize))),
                            0,
                            touchedPanopticChunks.length - 1
                        );
                        j < touchedPanopticChunks.length;
                        j++
                    ) {
                        ChunkWithTokenType memory __chunk = touchedPanopticChunks[j];

                        emit LogInt256("chunk strike", __chunk.strike);
                        emit LogInt256("chunk width", __chunk.width);
                        emit LogUint256("chunk token type", __chunk.tokenType);
                        ($tickLower, $tickUpper) = PanopticMath.getTicks(
                            __chunk.strike,
                            __chunk.width,
                            poolTickSpacing
                        );

                        if (
                            sfpm
                                .getAccountLiquidity(
                                    poolKey.toId(),
                                    address(panopticPool),
                                    __chunk.tokenType,
                                    $tickLower,
                                    $tickUpper
                                )
                                .rightSlot() > 0
                        ) {
                            $widths[i] = __chunk.width;
                            $strikes[i] = __chunk.strike;
                            found = true;
                            $found = true;
                            break;
                        }
                    }

                    if (!found) {
                        ($widths[i], $strikes[i]) = getValidSW(
                            widthSeeds[i],
                            strikeSeeds[i],
                            uint24(poolTickSpacing),
                            currentTick,
                            distributions[0]
                        );
                    }
                }
            }

            userPositions[msg.sender][userPositions[msg.sender].length - 1] = userPositions[
                msg.sender
            ][userPositions[msg.sender].length - 1].addLeg(
                    i,
                    $ratios[i],
                    $assets[i],
                    $isLongs[i],
                    $tokenTypes[i],
                    $riskPartners[i],
                    $strikes[i],
                    $widths[i]
                );

            // cache premium settlement info to check later
            (
                $settledToken0[i],
                $settledToken1[i],
                $grossPremiaLast0,
                $grossPremiaLast1
            ) = panopticPool.premiaSettlementData(
                userPositions[msg.sender][userPositions[msg.sender].length - 1],
                i
            );

            emit LogInt256("$strikes[i]", $strikes[i]);
            emit LogInt256("$widths[i]", $widths[i]);
            emit LogInt256("$poolTickSpacing", poolTickSpacing);
            emit LogInt256(
                "userPositions[msg.sender][userPositions[msg.sender].length - 1].strike(i)",
                userPositions[msg.sender][userPositions[msg.sender].length - 1].strike(i)
            );
            emit LogInt256(
                "userPositions[msg.sender][userPositions[msg.sender].length - 1].width(i)",
                userPositions[msg.sender][userPositions[msg.sender].length - 1].width(i)
            );
            assert($widths[i] < 4096);
            assertWithMsg(poolTickSpacing == 1, "pts1");

            ($tickLower, $tickUpper) = PanopticMath.getTicks(
                $strikes[i],
                $widths[i],
                poolTickSpacing
            );

            ($grossPremia0, $grossPremia1) = sfpm.getAccountPremium(
                poolKey.toId(),
                address(panopticPool),
                $tokenTypes[i],
                $tickLower,
                $tickUpper,
                currentTick,
                0
            );

            LeftRightUnsigned liquidities = sfpm.getAccountLiquidity(
                poolKey.toId(),
                address(panopticPool),
                $tokenTypes[i],
                $tickLower,
                $tickUpper
            );

            $shortLiquidity = uint256(liquidities.rightSlot()) + liquidities.leftSlot();

            $grossPremiaTotal0[i] = Math.mulDiv64(
                $grossPremia0 - $grossPremiaLast0,
                $shortLiquidity
            );
            $grossPremiaTotal1[i] = Math.mulDiv64(
                $grossPremia1 - $grossPremiaLast1,
                $shortLiquidity
            );

            emit LogUint256("grossPremiaTotal0[i]", $grossPremiaTotal0[i]);
            emit LogUint256("$grossPremia0", $grossPremia0);
            emit LogUint256("$grossPremiaLast0", $grossPremiaLast0);
            emit LogUint256("$shortLiquidity", $shortLiquidity);
        }

        uint256 userCollateral0 = collToken0.convertToAssets(collToken0.balanceOf(msg.sender));
        uint256 userCollateral1 = collToken1.convertToAssets(collToken1.balanceOf(msg.sender));

        positionSize = uint128(
            distributions[1]
                ? boundLog(positionSize, 0, 1_000_000_000 * 2 ** 64)
                : boundLog(positionSize, 0, 2 * 2 ** 64)
        );

        try this.size_for_collateral_solo(positionSize, userCollateral0, userCollateral1) {} catch (
            bytes memory reason
        ) {
            emit LogBytes("Reason", reason);
        }

        positionSize = uint128(
            size_for_collateral_solo(positionSize, userCollateral0, userCollateral1)
        );

        $positionSizeActive = uint128(positionSize);

        $tokenIdActive = userPositions[msg.sender][userPositions[msg.sender].length - 1];

        $sfpmBal = sfpm.balanceOf(address(panopticPool), TokenId.unwrap($tokenIdActive));

        $maxTransfer0 = 0;
        $maxTransfer1 = 0;

        $netTokenTransfers0 = 0;
        $netTokenTransfers1 = 0;

        $shouldRevert = false;

        $shouldRevert = userPositions[msg.sender].length > 32 ? true : $shouldRevert;

        // spread limit checks
        $isBurn = false;
        write_mintburn_transfer_amts();

        emit LogUint256("maxTransfer0", uint256($maxTransfer0));
        emit LogUint256("maxTransfer1", uint256($maxTransfer1));
        emit LogInt256("pool balance 0", int256(USDC.balanceOf(address(panopticPool))));
        emit LogInt256("pool balance 1", int256(WETH.balanceOf(address(panopticPool))));
        emit LogBool("should revert due to insufficient pool tokens", $shouldRevert);

        // position has already been minted
        for (uint256 i = 0; i < userPositions[msg.sender].length - 1; ++i) {
            $shouldRevert = $shouldRevert
                ? $shouldRevert
                : TokenId.unwrap($tokenIdActive) == TokenId.unwrap(userPositions[msg.sender][i]);
            emit LogBool("should revert due to position already minted", $shouldRevert);
        }

        emit LogInt256("Net token transfers 0", $maxTransfer0);
        emit LogInt256("Net token transfers 1", $maxTransfer1);
        emit LogInt256("pool balance 0", int256(USDC.balanceOf(address(panopticPool))));
        emit LogInt256("pool balance 1", int256(WETH.balanceOf(address(panopticPool))));

        // get SFPM swapped/premium collect amounts and expected fast/slow oracle ticks post-mint
        quote_sfpm_mint();
        emit LogInt256("$totalSwapped.rs", $totalSwapped.rightSlot());
        emit LogInt256("$totalSwapped.ls", $totalSwapped.leftSlot());

        if (!$shouldRevert) {
            ($longAmounts, $shortAmounts) = PanopticMath.computeExercisedAmounts(
                $tokenIdActive,
                $positionSizeActive
            );
        } else {
            ($longAmounts, $shortAmounts) = (LeftRightSigned.wrap(0), LeftRightSigned.wrap(0));
        }

        // intrinsic val
        $colDelta0 = -($totalSwapped.rightSlot() -
            ($shortAmounts.rightSlot() - $longAmounts.rightSlot()));
        emit LogInt256("intrinsicDelta0", $colDelta0);
        $colDelta1 = -($totalSwapped.leftSlot() -
            ($shortAmounts.leftSlot() - $longAmounts.leftSlot()));
        emit LogInt256("intrinsicDelta1", $colDelta1);

        // ITM spread + commission
        $commission0 = int256(
            (
                $tickLimitLow > $tickLimitHigh
                    ? Math.unsafeDivRoundingUp((uint256(Math.abs($colDelta0)) * 20), (10_000))
                    : 0
            ) +
                Math.unsafeDivRoundingUp(
                    (uint256(uint128($shortAmounts.rightSlot())) +
                        uint128($longAmounts.rightSlot())) * 10,
                    10_000
                )
        );
        $commission1 = int256(
            (
                $tickLimitLow > $tickLimitHigh
                    ? Math.unsafeDivRoundingUp((uint256(Math.abs($colDelta1)) * 20), (10_000))
                    : 0
            ) +
                Math.unsafeDivRoundingUp(
                    (uint256(uint128($shortAmounts.leftSlot())) +
                        uint128($longAmounts.leftSlot())) * 10,
                    10_000
                )
        );

        $colDelta0 -= $commission0;
        $colDelta1 -= $commission1;

        quote_ppfees_includecollectedbyleg(
            msg.sender,
            $collectedByLeg,
            $tokenIdActive,
            $posIdListOld
        );

        ($poolAssets0, $inAMM0, ) = collToken0.getPoolData();
        ($poolAssets1, $inAMM1, ) = collToken1.getPoolData();

        if (int256($poolAssets0) - $totalSwapped.rightSlot() >= 0) {
            $poolAssets0 = uint256(int256($poolAssets0) - $totalSwapped.rightSlot());
        } else {
            $shouldRevert = true;
        }

        if (int256($poolAssets1) - $totalSwapped.leftSlot() >= 0) {
            $poolAssets1 = uint256(int256($poolAssets1) - $totalSwapped.leftSlot());
        } else {
            $shouldRevert = true;
        }

        if (int256($inAMM0) + $shortAmounts.rightSlot() - $longAmounts.rightSlot() >= 0) {
            $inAMM0 = uint256(
                int256($inAMM0) + $shortAmounts.rightSlot() - $longAmounts.rightSlot()
            );
        } else {
            $shouldRevert = true;
        }

        if (int256($inAMM1) + $shortAmounts.leftSlot() - $longAmounts.leftSlot() >= 0) {
            $inAMM1 = uint256(int256($inAMM1) + $shortAmounts.leftSlot() - $longAmounts.leftSlot());
        } else {
            $shouldRevert = true;
        }

        $poolUtil0 = ($inAMM0 * 10_000) / ($poolAssets0 + $inAMM0);
        $poolUtil1 = ($inAMM1 * 10_000) / ($poolAssets1 + $inAMM1);

        if ($safeMode) ($poolUtil0, $poolUtil1) = (10_000, 10_000);

        emit LogUint256("poolUtil1", $poolUtil1);

        unchecked {
            $posBalanceArray.push(
                [
                    TokenId.unwrap($tokenIdActive),
                    LeftRightUnsigned.unwrap(
                        LeftRightUnsigned.wrap(0).toRightSlot($positionSizeActive).toLeftSlot(
                            uint128(uint32($poolUtil0) + uint32($poolUtil1 << 16))
                        )
                    )
                ]
            );
        }

        $totalAssets0 = collToken0.totalAssets();
        $totalAssets1 = collToken1.totalAssets();
        $totalSupply0 = collToken0.totalSupply();
        $totalSupply1 = collToken1.totalSupply();

        if (
            !(-(($colDelta0 > 0 ? int8(1) : -1) *
                int256(
                    Math.mulDivRoundingUp(
                        uint256(Math.abs($colDelta0)),
                        $totalSupply0,
                        $totalAssets0
                    )
                )) >
                int256(collToken0.balanceOf(msg.sender)) ||
                -(($colDelta1 > 0 ? int8(1) : -1) *
                    int256(
                        Math.mulDivRoundingUp(
                            uint256(Math.abs($colDelta1)),
                            $totalSupply1,
                            $totalAssets1
                        )
                    )) >
                int256(collToken1.balanceOf(msg.sender)))
        ) {
            $balance0ExpectedP = Math.mulDiv(
                uint256(
                    int256(collToken0.balanceOf(msg.sender)) +
                        ($colDelta0 > 0 ? int8(1) : -1) *
                        int256(collToken0.convertToShares(uint256(Math.abs($colDelta0))))
                ),
                uint256(int256($totalAssets0) + $colDelta0 + $commission0),
                uint256(
                    int256($totalSupply0) +
                        ($colDelta0 > 0 ? int8(1) : -1) *
                        int256(collToken0.convertToShares(uint256(Math.abs($colDelta0))))
                )
            );
            $balance1ExpectedP = Math.mulDiv(
                uint256(
                    int256(collToken1.balanceOf(msg.sender)) +
                        ($colDelta1 > 0 ? int8(1) : -1) *
                        int256(collToken1.convertToShares(uint256(Math.abs($colDelta1))))
                ),
                uint256(int256($totalAssets1) + $colDelta1 + $commission1),
                uint256(
                    int256($totalSupply1) +
                        ($colDelta1 > 0 ? int8(1) : -1) *
                        int256(collToken1.convertToShares(uint256(Math.abs($colDelta1))))
                )
            );

            if (!$shouldRevert) {
                _write_revert_due_solvency(msg.sender, 13_333);
            }

            emit LogInt256("colDelta0", $colDelta0);
            emit LogInt256("colDelta1", $colDelta1);
            emit LogUint256("bal0", $balance0ExpectedP);
            emit LogUint256("bal1", $balance1ExpectedP);
            emit LogUint256("balCross", $balanceCross);
            emit LogUint256("thresholdCross", $thresholdCross);
            emit LogInt256("fast tick", $fastOracleTick);
            emit LogBool("revert due to collateral shortfall", $shouldRevert);
        } else {
            $shouldRevert = true;

            emit LogUint256("$tokenData0.rightSlot()", $tokenData0.rightSlot());
            emit LogUint256("$tokenData1.rightSlot()", $tokenData1.rightSlot());
            emit LogInt256("$colDelta0", $colDelta0);
            emit LogInt256("$colDelta1", $colDelta1);
            emit LogBool("revert due to insufficient collateral to cover delta", $shouldRevert);
        }

        $balance0Origin = int256(collToken0.convertToAssets(collToken0.balanceOf(msg.sender)));
        $balance1Origin = int256(collToken1.convertToAssets(collToken1.balanceOf(msg.sender)));

        hevm.prank(msg.sender);
        try
            panopticPool.mintOptions(
                userPositions[msg.sender],
                uint128($positionSizeActive),
                type(uint64).max,
                $tickLimitLow,
                $tickLimitHigh,
                true
            )
        {
            $allPositionCount++;
            assertWithMsg(!$shouldRevert, "mintOptions: missing revert");
        } catch (bytes memory reason) {
            emit LogBytes("Reason", reason);

            assertWithMsg($shouldRevert, "mintOptions: unexpected revert");
            $failedPositionCount++;
            // reverse test state changes (i.e. positionidlist)
            revert();
        }

        assertWithMsg(
            int256(sfpm.balanceOf(address(panopticPool), TokenId.unwrap($tokenIdActive))) -
                int256($sfpmBal) ==
                int256(uint256($positionSizeActive)),
            "mintOptions: incorrect amount of SFPM tokens minted"
        );

        $balance0Final = int256(
            Math.mulDiv(collToken0.balanceOf(msg.sender), $totalAssets0, $totalSupply0)
        );
        $balance1Final = int256(
            Math.mulDiv(collToken1.balanceOf(msg.sender), $totalAssets1, $totalSupply1)
        );

        emit LogInt256("Balance 0 expected", $balance0Origin + $colDelta0);
        emit LogInt256("deltaE0", $colDelta0);
        emit LogInt256("Balance 0", $balance0Final);
        assertWithMsg(
            Math.abs(int256($balance0Final) - int256($balance0Origin + $colDelta0)) <= 1,
            "mintOptions: Balance 0 mismatch"
        );

        emit LogInt256("Balance 1 expected", $balance1Origin + $colDelta1);
        emit LogInt256("deltaE1", $colDelta1);
        emit LogInt256("Balance 1", $balance1Final);
        assertWithMsg(
            Math.abs(int256($balance1Final) - int256($balance1Origin + $colDelta1)) <= 1,
            "mintOptions: Balance 1 mismatch"
        );

        for (uint256 i = 0; i < $numLegs; ++i) {
            (
                $settledToken0Post,
                $settledToken1Post,
                $grossPremiaLast0,
                $grossPremiaLast1
            ) = panopticPool.premiaSettlementData($tokenIdActive, i);

            assertWithMsg(
                int256($settledToken0Post) ==
                    int256($settledToken0[i]) + int256(uint256($collectedByLeg[i].rightSlot())),
                "mintOptions: Settled token0 did not increase by the amount collected in the SFPM"
            );

            assertWithMsg(
                int256($settledToken1Post) ==
                    int256($settledToken1[i]) + int256(uint256($collectedByLeg[i].leftSlot())),
                "mintOptions: Settled token1 did not increase by the amount collected in the SFPM"
            );

            ($tickLower, $tickUpper) = PanopticMath.getTicks(
                $tokenIdActive.strike(i),
                $tokenIdActive.width(i),
                poolTickSpacing
            );

            ($grossPremia0, $grossPremia1) = sfpm.getAccountPremium(
                poolKey.toId(),
                address(panopticPool),
                $tokenIdActive.tokenType(i),
                $tickLower,
                $tickUpper,
                type(int24).max,
                0
            );

            LeftRightUnsigned liquidities = sfpm.getAccountLiquidity(
                poolKey.toId(),
                address(panopticPool),
                $tokenIdActive.tokenType(i),
                $tickLower,
                $tickUpper
            );

            $shortLiquidity = uint256(liquidities.rightSlot()) + liquidities.leftSlot();

            emit LogUint256("$grossPremiaTotal0[i]", $grossPremiaTotal0[i]);
            emit LogUint256("$grossPremia0", $grossPremia0);
            emit LogUint256("$grossPremiaLast0", $grossPremiaLast0);
            emit LogUint256("$shortLiquidity", $shortLiquidity);
            emit LogUint256(
                "Math.mulDiv64($grossPremia0 - $grossPremiaLast0, $shortLiquidity)",
                Math.mulDiv64($grossPremia0 - $grossPremiaLast0, $shortLiquidity)
            );
            assertWithMsg(
                int256(Math.mulDiv64($grossPremia0 - $grossPremiaLast0, $shortLiquidity)) -
                    int256($grossPremiaTotal0[i]) >=
                    0 &&
                    int256(Math.mulDiv64($grossPremia0 - $grossPremiaLast0, $shortLiquidity)) -
                        int256($grossPremiaTotal0[i]) <=
                    2 + int256($shortLiquidity / 2 ** 64),
                "mintOptions: Calculated total gross premium for token0 changed beyond the acceptable threshold during an option mint"
            );

            assertWithMsg(
                int256(Math.mulDiv64($grossPremia1 - $grossPremiaLast1, $shortLiquidity)) -
                    int256($grossPremiaTotal1[i]) >=
                    0 &&
                    int256(Math.mulDiv64($grossPremia1 - $grossPremiaLast1, $shortLiquidity)) -
                        int256($grossPremiaTotal1[i]) <=
                    2 + int256($shortLiquidity / 2 ** 64),
                "mintOptions: Calculated total gross premium for token1 changed beyond the acceptable threshold during an option mint"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                             OPTION BURNING
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-BURN-001 Zero sized positions can not be burned
    /// @custom:property PANO-BURN-002 Current liquidity must be greater than the liquidity in the chunk for the position
    /// @custom:property PANO-BURN-002 Position opened counter must decrease when a position is burned
    /// @custom:precondition The user has a position open
    function burn_one_option(
        uint256 positionSeed,
        int24[2] memory tickLimitSeeds
    ) public canonicalTimeState {
        require(panopticPool.numberOfLegs(msg.sender) > 0);

        $tokenIdActive = userPositions[msg.sender][
            bound(positionSeed, 0, userPositions[msg.sender].length - 1)
        ];

        $sfpmBal = sfpm.balanceOf(address(panopticPool), TokenId.unwrap($tokenIdActive));

        userPositions[msg.sender] = _get_list_without_tokenid(
            userPositions[msg.sender],
            $tokenIdActive
        );

        ($positionSizeActive, , ) = panopticHelper.optionPositionInfo(
            panopticPool,
            msg.sender,
            $tokenIdActive
        );

        ($tickLimitLow, $tickLimitHigh) = (tickLimitSeeds[0], tickLimitSeeds[1]);

        (, , observationIndex, observationCardinality, , , ) = pool.slot0();

        currentTick = V4StateReader.getTick(manager, poolKey.toId());

        ($slowOracleTick, ) = panopticHelper.computeInternalMedian(
            60,
            uint256(hevm.load(address(panopticPool), bytes32(uint256(0)))),
            IV3CompatibleOracle(address(pool))
        );

        $safeMode = Math.abs($slowOracleTick - currentTick) > 953;

        if ($safeMode) {
            if ($tickLimitLow > $tickLimitHigh) {
                ($tickLimitLow, $tickLimitHigh) = ($tickLimitHigh, $tickLimitLow);
            }
        }

        $shouldRevert = false;

        quote_sfpm_burn();

        $premiumDelta0Net = 0;
        $premiumDelta1Net = 0;
        for (uint256 i = 0; i < $tokenIdActive.countLegs(); i++) {
            // cache premium settlement info to check later
            (
                $settledToken0[i],
                $settledToken1[i],
                $grossPremiaLast0,
                $grossPremiaLast1
            ) = panopticPool.premiaSettlementData($tokenIdActive, i);

            ($premiumGrowth0[i], $premiumGrowth1[i]) = panopticPool.optionData(
                $tokenIdActive,
                msg.sender,
                i
            );

            ($tickLower, $tickUpper) = PanopticMath.getTicks(
                $tokenIdActive.strike(i),
                $tokenIdActive.width(i),
                poolTickSpacing
            );

            ($grossPremia0, $grossPremia1) = sfpm.getAccountPremium(
                poolKey.toId(),
                address(panopticPool),
                $tokenIdActive.tokenType(i),
                $tickLower,
                $tickUpper,
                currentTick,
                0
            );

            ($owedPremia0, $owedPremia1) = sfpm.getAccountPremium(
                poolKey.toId(),
                address(panopticPool),
                $tokenIdActive.tokenType(i),
                $tickLower,
                $tickUpper,
                currentTick,
                1
            );

            LeftRightUnsigned liquidities = sfpm.getAccountLiquidity(
                poolKey.toId(),
                address(panopticPool),
                $tokenIdActive.tokenType(i),
                $tickLower,
                $tickUpper
            );

            $shortLiquidity = uint256(liquidities.rightSlot()) + liquidities.leftSlot();

            $grossPremiaTotal0[i] = Math.mulDiv64(
                $grossPremia0 - $grossPremiaLast0,
                $shortLiquidity
            );
            $grossPremiaTotal1[i] = Math.mulDiv64(
                $grossPremia1 - $grossPremiaLast1,
                $shortLiquidity
            );

            $legLiquidity = PanopticMath
                .getLiquidityChunk($tokenIdActive, i, $positionSizeActive)
                .liquidity();

            $idealPremium0[i] = Math.mulDiv64(
                ($tokenIdActive.isLong(i) == 1 ? $owedPremia0 : $grossPremia0) - $premiumGrowth0[i],
                $legLiquidity
            );
            $idealPremium1[i] = Math.mulDiv64(
                ($tokenIdActive.isLong(i) == 1 ? $owedPremia1 : $grossPremia1) - $premiumGrowth1[i],
                $legLiquidity
            );
            emit LogUint256("idealPremium0", $idealPremium0[i]);
            emit LogUint256("idealPremium1", $idealPremium1[i]);
            $proratedPremium0[i] = $grossPremiaTotal0[i] == 0 || $tokenIdActive.isLong(i) != 0
                ? 0
                : Math.min(
                    Math.mulDiv(
                        $idealPremium0[i],
                        $settledToken0[i] + $collectedByLeg[i].rightSlot(),
                        $grossPremiaTotal0[i]
                    ),
                    $idealPremium0[i]
                );
            $proratedPremium1[i] = $grossPremiaTotal1[i] == 0 || $tokenIdActive.isLong(i) != 0
                ? 0
                : Math.min(
                    Math.mulDiv(
                        $idealPremium1[i],
                        $settledToken1[i] + $collectedByLeg[i].leftSlot(),
                        $grossPremiaTotal1[i]
                    ),
                    $idealPremium1[i]
                );

            emit LogUint256("settled0", $settledToken0[i] + $collectedByLeg[i].rightSlot());
            emit LogUint256("settled1", $settledToken1[i] + $collectedByLeg[i].leftSlot());

            emit LogUint256("grossPremiaTotal0", $grossPremiaTotal0[i]);
            emit LogUint256("grossPremiaTotal1", $grossPremiaTotal1[i]);

            emit LogUint256("proratedPremium0", $proratedPremium0[i]);
            emit LogUint256("proratedPremium1", $proratedPremium1[i]);

            $premiumDelta0Net += $tokenIdActive.isLong(i) == 0
                ? int256($proratedPremium0[i])
                : -int256($idealPremium0[i]);
            $premiumDelta1Net += $tokenIdActive.isLong(i) == 0
                ? int256($proratedPremium1[i])
                : -int256($idealPremium1[i]);
        }

        $tokenIdBkp = $tokenIdActive;

        $tokenIdActive = $tokenIdActive.flipToBurnToken();

        // spread limit checks
        $isBurn = true;
        write_mintburn_transfer_amts();

        $tokenIdActive = $tokenIdBkp;

        ($longAmounts, $shortAmounts) = PanopticMath.computeExercisedAmounts(
            $tokenIdActive.flipToBurnToken(),
            $positionSizeActive
        );

        // intrinsic val
        $colDelta0 = -($totalSwapped.rightSlot() -
            ($shortAmounts.rightSlot() - $longAmounts.rightSlot()));
        emit LogInt256("intrinsicDelta0", $colDelta0);
        $colDelta1 = -($totalSwapped.leftSlot() -
            ($shortAmounts.leftSlot() - $longAmounts.leftSlot()));
        emit LogInt256("intrinsicDelta1", $colDelta1);

        $colDelta0 += $premiumDelta0Net;
        $colDelta1 += $premiumDelta1Net;

        emit LogInt256("premiumDelta0Net", $premiumDelta0Net);
        emit LogInt256("premiumDelta1Net", $premiumDelta1Net);

        // gets shortpremium/longpremium/posBalanceArray with post-burn premium accum values
        quote_fees_postburn();

        ($poolAssets0, $inAMM0, ) = collToken0.getPoolData();
        ($poolAssets1, $inAMM1, ) = collToken1.getPoolData();

        if (int256($poolAssets0) - $totalSwapped.rightSlot() + $premiumDelta0Net >= 0) {
            $poolAssets0 = uint256(int256($poolAssets0) - $totalSwapped.rightSlot());
        } else {
            $shouldRevert = true;
        }

        if (int256($poolAssets1) - $totalSwapped.leftSlot() + $premiumDelta1Net >= 0) {
            $poolAssets1 = uint256(int256($poolAssets1) - $totalSwapped.leftSlot());
        } else {
            $shouldRevert = true;
        }

        if (int256($inAMM0) + $shortAmounts.rightSlot() - $longAmounts.rightSlot() >= 0) {
            $inAMM0 = uint256(
                int256($inAMM0) + $shortAmounts.rightSlot() - $longAmounts.rightSlot()
            );
        } else {
            $shouldRevert = true;
        }

        if (int256($inAMM1) + $shortAmounts.leftSlot() - $longAmounts.leftSlot() >= 0) {
            $inAMM1 = uint256(int256($inAMM1) + $shortAmounts.leftSlot() - $longAmounts.leftSlot());
        } else {
            $shouldRevert = true;
        }

        $poolUtil0 = ($poolAssets0 + $inAMM0) > 0
            ? ($inAMM0 * 10_000) / ($poolAssets0 + $inAMM0)
            : 0;
        $poolUtil1 = ($poolAssets1 + $inAMM1) > 0
            ? ($inAMM1 * 10_000) / ($poolAssets1 + $inAMM1)
            : 0;

        if ($safeMode) ($poolUtil0, $poolUtil1) = (10_000, 10_000);
        emit LogUint256("poolUtil0", $poolUtil0);

        emit LogUint256("poolUtil1", $poolUtil1);

        $totalAssets0 = collToken0.totalAssets();
        $totalAssets1 = collToken1.totalAssets();
        $totalSupply0 = collToken0.totalSupply();
        $totalSupply1 = collToken1.totalSupply();

        int256 shareDelta0 = ($colDelta0 > 0 ? int8(1) : -1) *
            int256(
                Math.mulDivRoundingUp(uint256(Math.abs($colDelta0)), $totalSupply0, $totalAssets0)
            );

        int256 shareDelta1 = ($colDelta1 > 0 ? int8(1) : -1) *
            int256(
                Math.mulDivRoundingUp(uint256(Math.abs($colDelta1)), $totalSupply1, $totalAssets1)
            );

        if (
            !(-shareDelta0 > int256(collToken0.balanceOf(msg.sender)) ||
                -shareDelta1 > int256(collToken1.balanceOf(msg.sender)))
        ) {
            $balance0ExpectedP = Math.mulDiv(
                uint256(int256(collToken0.balanceOf(msg.sender)) + shareDelta0),
                uint256(int256($totalAssets0) + $colDelta0),
                uint256(int256($totalSupply0) + shareDelta0)
            );
            $balance1ExpectedP = Math.mulDiv(
                uint256(int256(collToken1.balanceOf(msg.sender)) + shareDelta1),
                uint256(int256($totalAssets1) + $colDelta1),
                uint256(int256($totalSupply1) + shareDelta1)
            );

            _write_revert_due_solvency(msg.sender, 10_000);

            emit LogInt256("colDelta0", $colDelta0);
            emit LogInt256("colDelta1", $colDelta1);
            emit LogUint256("bal0", $balance0ExpectedP);
            emit LogUint256("bal1", $balance1ExpectedP);
            emit LogUint256("balCross", $balanceCross);
            emit LogUint256("thresholdCross", $thresholdCross);
            emit LogInt256("fast tick", $fastOracleTick);
            emit LogBool("revert due to collateral shortfall", $shouldRevert);
        } else {
            $shouldRevert = true;

            emit LogUint256("$tokenData0.rightSlot()", $tokenData0.rightSlot());
            emit LogUint256("$tokenData1.rightSlot()", $tokenData1.rightSlot());
            emit LogInt256("$colDelta0", $colDelta0);
            emit LogInt256("$colDelta1", $colDelta1);
            emit LogBool("revert due to insufficient collateral to cover delta", $shouldRevert);
        }

        $balance0Origin = int256(collToken0.convertToAssets(collToken0.balanceOf(msg.sender)));
        $balance1Origin = int256(collToken1.convertToAssets(collToken1.balanceOf(msg.sender)));

        hevm.prank(msg.sender);
        try
            panopticPool.burnOptions(
                $tokenIdActive,
                userPositions[msg.sender],
                $tickLimitLow,
                $tickLimitHigh,
                true
            )
        {
            unchecked {
                $allPositionCount--;
            }
            assertWithMsg(!$shouldRevert, "burnOptions: missing revert");
        } catch {
            assertWithMsg($shouldRevert, "burnOptions: unexpected revert");
            // reverse test state changes (i.e. positionidlist)
            revert();
        }

        assertWithMsg(
            int256($sfpmBal) -
                int256(sfpm.balanceOf(address(panopticPool), TokenId.unwrap($tokenIdActive))) ==
                int256(uint256($positionSizeActive)),
            "burnOptions: incorrect amount of SFPM tokens burned"
        );

        $balance0Final = int256(
            Math.mulDiv(collToken0.balanceOf(msg.sender), $totalAssets0, $totalSupply0)
        );
        $balance1Final = int256(
            Math.mulDiv(collToken1.balanceOf(msg.sender), $totalAssets1, $totalSupply1)
        );

        emit LogInt256("Balance 0 expected", $balance0Origin + $colDelta0);
        emit LogInt256("deltaE0", $colDelta0);
        emit LogInt256("Balance 0", $balance0Final);
        assertWithMsg(
            Math.abs(int256($balance0Final) - int256($balance0Origin + $colDelta0)) <= 1,
            "burnOptions: Balance 0 mismatch"
        );

        emit LogInt256("Balance 1 expected", $balance1Origin + $colDelta1);
        emit LogInt256("deltaE1", $colDelta1);
        emit LogInt256("Balance 1", $balance1Final);
        assertWithMsg(
            Math.abs(int256($balance1Final) - int256($balance1Origin + $colDelta1)) <= 1,
            "burnOptions 1 mismatch"
        );

        for (uint256 i = 0; i < $tokenIdActive.countLegs(); ++i) {
            (
                $settledToken0Post,
                $settledToken1Post,
                $grossPremiaLast0,
                $grossPremiaLast1
            ) = panopticPool.premiaSettlementData($tokenIdActive, i);

            assertWithMsg(
                int256($settledToken0Post) ==
                    int256($settledToken0[i]) +
                        int256(uint256($collectedByLeg[i].rightSlot())) +
                        (
                            $tokenIdActive.isLong(i) == 1
                                ? int256($idealPremium0[i])
                                : -int256($proratedPremium0[i])
                        ),
                "burnOptions: Settled token0 did not change by the amount collected in the SFPM + premium paid by long leg - premium collected by short leg"
            );

            assertWithMsg(
                int256($settledToken1Post) ==
                    int256($settledToken1[i]) +
                        int256(uint256($collectedByLeg[i].leftSlot())) +
                        (
                            $tokenIdActive.isLong(i) == 1
                                ? int256($idealPremium1[i])
                                : -int256($proratedPremium1[i])
                        ),
                "burnOptions: Settled token1 did not change by the amount collected in the SFPM + premium paid by long leg - premium collected by short leg"
            );

            ($tickLower, $tickUpper) = PanopticMath.getTicks(
                $tokenIdActive.strike(i),
                $tokenIdActive.width(i),
                poolTickSpacing
            );

            ($grossPremia0, $grossPremia1) = sfpm.getAccountPremium(
                poolKey.toId(),
                address(panopticPool),
                $tokenIdActive.tokenType(i),
                $tickLower,
                $tickUpper,
                type(int24).max,
                0
            );

            LeftRightUnsigned liquidities = sfpm.getAccountLiquidity(
                poolKey.toId(),
                address(panopticPool),
                $tokenIdActive.tokenType(i),
                $tickLower,
                $tickUpper
            );

            $shortLiquidity = uint256(liquidities.rightSlot()) + liquidities.leftSlot();

            $gross0Correct =
                (int256(Math.mulDiv64($grossPremia0 - $grossPremiaLast0, $shortLiquidity)) -
                    (int256($grossPremiaTotal0[i]) -
                        int256($tokenIdActive.isLong(i) == 0 ? $idealPremium0[i] : 0)) >=
                    0 &&
                    int256(Math.mulDiv64($grossPremia0 - $grossPremiaLast0, $shortLiquidity)) -
                        (int256($grossPremiaTotal0[i]) -
                            int256($tokenIdActive.isLong(i) == 0 ? $idealPremium0[i] : 0)) <=
                    2 + int256($shortLiquidity / 2 ** 64)) ||
                ($shortLiquidity == 0 && $grossPremiaLast0 == $grossPremia0);

            $gross1Correct =
                (int256(Math.mulDiv64($grossPremia1 - $grossPremiaLast1, $shortLiquidity)) -
                    (int256($grossPremiaTotal1[i]) -
                        int256($tokenIdActive.isLong(i) == 0 ? $idealPremium1[i] : 0)) >=
                    0 &&
                    int256(Math.mulDiv64($grossPremia1 - $grossPremiaLast1, $shortLiquidity)) -
                        (int256($grossPremiaTotal1[i]) -
                            int256($tokenIdActive.isLong(i) == 0 ? $idealPremium1[i] : 0)) <=
                    2 + int256($shortLiquidity / 2 ** 64)) ||
                ($shortLiquidity == 0 && $grossPremiaLast1 == $grossPremia1);

            // total gross can round down relative to the amount held by the previous gPL if grossPremiumLast hits 0 threshold due to rectification,
            // *but* cannot go below the *true* gross premium threshold (not inclusive of accumulated (upward) rounding errors in grossPremiumLast)
            if (
                (!$gross0Correct && $grossPremiaLast0 == 0) ||
                (!$gross1Correct && $grossPremiaLast1 == 0)
            ) {
                $grossPremiumTotalSumLegs0 = 0;
                $grossPremiumTotalSumLegs1 = 0;

                for (uint256 actorIndex = 0; actorIndex < actors.length; actorIndex++) {
                    address actor = actors[actorIndex];
                    for (
                        uint256 positionIndex = 0;
                        positionIndex < userPositions[actor].length;
                        positionIndex++
                    ) {
                        TokenId position = userPositions[actor][positionIndex];
                        for (uint256 legIndex = 0; legIndex < position.countLegs(); legIndex++) {
                            if (
                                position.isLong(legIndex) == 0 &&
                                keccak256(
                                    abi.encodePacked(
                                        position.strike(legIndex),
                                        position.width(legIndex),
                                        position.tokenType(legIndex)
                                    )
                                ) ==
                                keccak256(
                                    abi.encodePacked(
                                        $tokenIdActive.strike(i),
                                        $tokenIdActive.width(i),
                                        $tokenIdActive.tokenType(i)
                                    )
                                )
                            ) {
                                ($premiumGrowthLeg0, $premiumGrowthLeg1) = panopticPool.optionData(
                                    position,
                                    actor,
                                    legIndex
                                );

                                ($positionSizeBkp, , ) = panopticHelper.optionPositionInfo(
                                    panopticPool,
                                    actor,
                                    position
                                );

                                $legLiquidity = PanopticMath
                                    .getLiquidityChunk(position, i, $positionSizeBkp)
                                    .liquidity();
                                $grossPremiumTotalSumLegs0 += Math.mulDiv64(
                                    $grossPremia0 - $premiumGrowthLeg0,
                                    $legLiquidity
                                );
                                emit LogUint256(
                                    "grossPremiaTotalSumLegs0",
                                    $grossPremiumTotalSumLegs0
                                );
                                emit LogUint256(
                                    "$Math.mulDiv64($grossPremia0 - $premiumGrowthLeg0, $legLiquidity)",
                                    Math.mulDiv64($grossPremia0 - $premiumGrowthLeg0, $legLiquidity)
                                );
                                emit LogUint256("$grossPremia0", $grossPremia0);
                                emit LogUint256("$premiumGrowthLeg0", $premiumGrowthLeg0);
                                emit LogUint256("$legLiquidity", $legLiquidity);
                                $grossPremiumTotalSumLegs1 += Math.mulDiv64(
                                    $grossPremia1 - $premiumGrowthLeg1,
                                    $legLiquidity
                                );
                            }
                        }
                    }
                }
                if (!$gross0Correct && $grossPremiaLast0 == 0) {
                    emit LogUint256("grossPremiaTotalSumLegs0", $grossPremiumTotalSumLegs0);
                    emit LogUint256(
                        "$Math.mulDiv64($grossPremia0 - $grossPremiaLast0, $shortLiquidity)",
                        Math.mulDiv64($grossPremia0 - $grossPremiaLast0, $shortLiquidity)
                    );
                    emit LogUint256("$grossPremia0", $grossPremia0);
                    emit LogUint256("$grossPremiaLast0", $grossPremiaLast0);
                    emit LogUint256("$shortLiquidity", $shortLiquidity);
                    assertWithMsg(
                        Math.mulDiv64($grossPremia0 - $grossPremiaLast0, $shortLiquidity) >=
                            $grossPremiumTotalSumLegs0,
                        "burnOptions: Calculated total gross premium for token0 fell below summed gross premium for all legs in the chunk"
                    );
                } else {
                    assertWithMsg(
                        $gross0Correct,
                        "burnOptions: Calculated total gross premium for token0 changed beyond the acceptable threshold during an option mint"
                    );
                }

                if (!$gross1Correct && $grossPremiaLast1 == 0) {
                    assertWithMsg(
                        Math.mulDiv64($grossPremia1 - $grossPremiaLast1, $shortLiquidity) >=
                            $grossPremiumTotalSumLegs1,
                        "burnOptions: Calculated total gross premium for token1 fell below summed gross premium for all legs in the chunk"
                    );
                } else {
                    assertWithMsg(
                        $gross1Correct,
                        "burnOptions: Calculated total gross premium for token1 changed beyond the acceptable threshold during an option mint"
                    );
                }
            } else {
                assertWithMsg(
                    $gross0Correct,
                    "burnOptions: Calculated total gross premium for token0 changed beyond the acceptable threshold during an option mint"
                );
                assertWithMsg(
                    $gross1Correct,
                    "burnOptions: Calculated total gross premium for token1 changed beyond the acceptable threshold during an option mint"
                );
            }
        }
    }

    function burn_many_options(
        uint256 numOptions,
        int24[2] memory tickLimitSeeds
    ) public canonicalTimeState {
        require(panopticPool.numberOfLegs(msg.sender) > 0);

        $numOptions = bound(numOptions, 1, userPositions[msg.sender].length);

        (, , observationIndex, observationCardinality, , , ) = pool.slot0();

        currentTick = V4StateReader.getTick(manager, poolKey.toId());

        ($slowOracleTick, ) = panopticHelper.computeInternalMedian(
            60,
            uint256(hevm.load(address(panopticPool), bytes32(uint256(0)))),
            IV3CompatibleOracle(address(pool))
        );

        $safeMode = Math.abs($slowOracleTick - currentTick) > 953;

        $tickLimitLow = tickLimitSeeds[0];
        $tickLimitHigh = tickLimitSeeds[1];

        if ($safeMode) {
            if ($tickLimitLow > $tickLimitHigh) {
                ($tickLimitLow, $tickLimitHigh) = ($tickLimitHigh, $tickLimitLow);
            }
        }

        panopticPool.pokeMedian();

        $posIdListOld = userPositions[msg.sender];

        quote_pp_burn_many();

        for (uint256 i = $numOptions; i < userPositions[msg.sender].length; i++) {
            $posIdListOld.pop();
        }

        for (uint256 i = 0; i < $numOptions; ++i) {
            userPositions[msg.sender] = _get_list_without_tokenid(
                userPositions[msg.sender],
                userPositions[msg.sender][0]
            );
        }

        hevm.prank(msg.sender);
        try
            panopticPool.burnOptions(
                $posIdListOld,
                userPositions[msg.sender],
                $tickLimitLow,
                $tickLimitHigh,
                true
            )
        {
            // intermediate collateral checks may revert
            if ($shouldRevert) revert();
        } catch {
            assertWithMsg($shouldRevert, "burnManyOptions: unexpected revert");
            // reverse test state changes (i.e. positionidlist)
            revert();
        }

        for (uint256 i = 0; i < $numOptions; ++i) {
            assertWithMsg(
                sfpm.balanceOf(address(panopticPool), TokenId.unwrap($posIdListOld[i])) ==
                    $burnManySimResults.sfpmBals[i],
                "burnManyOptions: incorrect amount of SFPM tokens burned"
            );

            for (uint256 j = 0; j < $posIdListOld[i].countLegs(); ++j) {
                (
                    $settledToken0Post,
                    $settledToken1Post,
                    $grossPremiaLast0,
                    $grossPremiaLast1
                ) = panopticPool.premiaSettlementData($posIdListOld[i], j);

                assertWithMsg(
                    $burnManySimResults.settledTokens0Portfolio[i][j] == $settledToken0Post,
                    "burnManyOptions: settledToken0 diverged from burn_one"
                );
                assertWithMsg(
                    $burnManySimResults.settledTokens1Portfolio[i][j] == $settledToken1Post,
                    "burnManyOptions: settledToken1 diverged from burn_one"
                );

                assertWithMsg(
                    $burnManySimResults.grossPremiaL0Portfolio[i][j] == $grossPremiaLast0,
                    "burnManyOptions: grossPremiaLast0 diverged from burn_one"
                );
                assertWithMsg(
                    $burnManySimResults.grossPremiaL1Portfolio[i][j] == $grossPremiaLast1,
                    "burnManyOptions: grossPremiaLast1 diverged from burn_one"
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLE LONG PREMIUM
    //////////////////////////////////////////////////////////////*/

    function try_settle_long(uint256 position, bool search) public canonicalTimeState {
        $allPositionOwners = new address[](0);
        $allPositions = new TokenId[](0);
        for (uint256 i = 0; i < actors.length; ++i) {
            for (uint256 j = 0; j < userPositions[actors[i]].length; ++j) {
                $allPositionOwners.push(actors[i]);
                $allPositions.push(userPositions[actors[i]][j]);
            }
        }

        require($allPositions.length > 0);

        // find a position with at least one long leg
        if (search) {
            bool isLong;
            for (
                uint256 i = bound(position, 0, $allPositions.length - 1);
                i < $allPositions.length;
                ++i
            ) {
                for (uint256 j = 0; j < $allPositions[i].countLegs(); ++j) {
                    if ($allPositions[i].isLong(j) == 1) {
                        $tokenIdActive = $allPositions[i];
                        $settlee = $allPositionOwners[i];

                        // pick a random leg
                        $settleIndex = bound(position, 0, $allPositions[i].countLegs() - 1);
                        isLong = true;
                        break;
                    }
                }
            }
            if (!isLong) {
                ($settlee, $tokenIdActive, $settleIndex) = (
                    $allPositionOwners[bound(position, 0, $allPositions.length - 1)],
                    $allPositions[bound(position, 0, $allPositions.length - 1)],
                    bound(
                        position,
                        0,
                        $allPositions[bound(position, 0, $allPositions.length - 1)].countLegs() - 1
                    )
                );
            }
        } else {
            ($settlee, $tokenIdActive, $settleIndex) = (
                $allPositionOwners[bound(position, 0, $allPositions.length - 1)],
                $allPositions[bound(position, 0, $allPositions.length - 1)],
                bound(
                    position,
                    0,
                    $allPositions[bound(position, 0, $allPositions.length - 1)].countLegs() - 1
                )
            );
        }
        $shouldRevert = false;

        if ($tokenIdActive.isLong($settleIndex) != 1) $shouldRevert = true;
        emit LogBool(
            "revert due to position not being long",
            $tokenIdActive.isLong($settleIndex) != 1
        );

        // 1. calculate what the premium settled out to settlee _should_ be
        // NOTE: this is basically trying to get re-calc a value in s_options -
        //       probably derived from logic in closePosition / getPremium
        (uint128 premium0, uint128 premium1) = _calc_premium_for_each_token(
            $settlee,
            $tokenIdActive,
            $settleIndex
        );

        ($poolAssets0, , ) = collToken0.getPoolData();
        ($poolAssets1, , ) = collToken1.getPoolData();

        if ($poolAssets0 < premium0) $shouldRevert = true;
        emit LogBool("revert due to poolAssets0 < premium0", $poolAssets0 < premium0);
        if ($poolAssets1 < premium1) $shouldRevert = true;
        emit LogBool("revert due to poolAssets1 < premium1", $poolAssets1 < premium1);

        $totalAssets0 = collToken0.totalAssets();
        $totalAssets1 = collToken1.totalAssets();
        $totalSupply0 = collToken0.totalSupply();
        $totalSupply1 = collToken1.totalSupply();
        if (
            !(Math.mulDivRoundingUp(premium0, $totalSupply0, $totalAssets0) >
                collToken0.balanceOf($settlee) ||
                Math.mulDivRoundingUp(premium1, $totalSupply1, $totalAssets1) >
                collToken1.balanceOf($settlee))
        ) {
            (, $colTicks[1], $colTicks[2], $colTicks[3], ) = panopticPool.getOracleTicks();

            $colTicks[0] = V4StateReader.getTick(manager, poolKey.toId());

            $balance0ExpectedP = collToken0.convertToAssets(collToken0.balanceOf($settlee));
            $balance1ExpectedP = collToken1.convertToAssets(collToken1.balanceOf($settlee));

            ($shortPremium, $longPremium, $posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData($settlee, false, userPositions[$settlee]);

            _write_revert_due_solvency($settlee, 10_000);

            emit LogBool("revert due to collateral shortfall", $shouldRevert);
        } else {
            $shouldRevert = true;

            emit LogBool("revert due to insufficient collateral to cover delta", true);
        }

        // 2. get users balance in CT before any settling occurs
        $balance0Origin = int256(collToken0.convertToAssets(collToken0.balanceOf($settlee)));
        $balance1Origin = int256(collToken1.convertToAssets(collToken1.balanceOf($settlee)));

        (uint128 settledForChunkBefore0, uint128 settledForChunkBefore1, , ) = panopticPool
            .premiaSettlementData($tokenIdActive, $settleIndex);

        // 3. trigger a settlement of long premium
        hevm.prank(msg.sender);
        try
            panopticPool.settleLongPremium(
                _move_tokenid_to_end(userPositions[$settlee], $tokenIdActive),
                $settlee,
                $settleIndex,
                true
            )
        {
            assertWithMsg(!$shouldRevert, "SettleLongPremium: missing revert");
        } catch {
            assertWithMsg($shouldRevert, "SettleLongPremium: unexpected revert");
            revert();
        }

        // 4. get accumulated settledTokens for each CT and ensure it increased by calc'ed premium amount
        (uint128 settledForChunkAfter0, uint128 settledForChunkAfter1, , ) = panopticPool
            .premiaSettlementData($tokenIdActive, $settleIndex);

        assertWithMsg(
            settledForChunkAfter0 == (settledForChunkBefore0 + premium0) &&
                settledForChunkAfter1 == (settledForChunkBefore1 + premium1),
            "Settled tokens for chunk recorded in CT did not increase by calculated premium"
        );

        // 5. get users balance in CT after, and assert it reduced by appropriate amounts
        assertWithMsg(
            ($balance0Origin - int256(collToken0.convertToAssets(collToken0.balanceOf($settlee))) ==
                int256(uint256(premium0))) &&
                ($balance1Origin -
                    int256(collToken1.convertToAssets(collToken1.balanceOf($settlee))) ==
                    int256(uint256(premium1))),
            "User receiving settled long premia had their assets in the CT decrease by an amount other than the calculated premiums"
        );
    }

    function _calc_premium_for_each_token(
        address settlee,
        TokenId position,
        uint256 longIndex
    ) internal returns (uint128 premium0, uint128 premium1) {
        (uint128 numContractsOfPosition, , ) = panopticHelper.optionPositionInfo(
            panopticPool,
            settlee,
            position
        );
        uint128 liquidity = PanopticMath
            .getLiquidityChunk(position, longIndex, numContractsOfPosition)
            .liquidity();

        (uint128 optionData0, uint128 optionData1) = panopticPool.optionData(
            position,
            settlee,
            longIndex
        );

        currentTick = V4StateReader.getTick(manager, poolKey.toId());

        uint256 tokenType = position.tokenType(longIndex);
        (int24 tickLower, int24 tickUpper) = position.asTicks(longIndex);
        (uint128 premiumAccumulator0, uint128 premiumAccumulator1) = sfpm.getAccountPremium(
            poolKey.toId(),
            address(panopticPool),
            tokenType,
            tickLower,
            tickUpper,
            currentTick,
            1
        );
        premium0 = uint128(Math.mulDiv64(premiumAccumulator0 - optionData0, liquidity));
        premium1 = uint128(Math.mulDiv64(premiumAccumulator1 - optionData1, liquidity));
        emit LogUint256("premium0-calc", premium0);
        emit LogUint256("premium1-calc", premium1);
    }

    /*//////////////////////////////////////////////////////////////
                             FORCE EXERCISE
    //////////////////////////////////////////////////////////////*/

    function force_exercise(uint256 position, bool search) public canonicalTimeState {
        $allPositionOwners = new address[](0);
        $allPositions = new TokenId[](0);
        for (uint256 i = 0; i < actors.length; ++i) {
            for (uint256 j = 0; j < userPositions[actors[i]].length; ++j) {
                $allPositionOwners.push(actors[i]);
                $allPositions.push(userPositions[actors[i]][j]);
            }
        }

        require($allPositions.length > 0);

        // find a position with at least one long leg - reasonably high probability of being exercisable
        if (search) {
            bool isLong;
            for (
                uint256 i = bound(position, 0, $allPositions.length - 1);
                i < $allPositions.length;
                ++i
            ) {
                for (uint256 j = 0; j < $allPositions[i].countLegs(); ++j) {
                    if ($allPositions[i].isLong(j) == 1) {
                        $tokenIdActive = $allPositions[i];
                        $exercisee = $allPositionOwners[i];
                        isLong = true;
                        break;
                    }
                }
                if (isLong) break;
            }
            if (!isLong) {
                ($exercisee, $tokenIdActive) = (
                    $allPositionOwners[bound(position, 0, $allPositions.length - 1)],
                    $allPositions[bound(position, 0, $allPositions.length - 1)]
                );
            }
        } else {
            ($exercisee, $tokenIdActive) = (
                $allPositionOwners[bound(position, 0, $allPositions.length - 1)],
                $allPositions[bound(position, 0, $allPositions.length - 1)]
            );
        }

        ($positionSizeActive, , ) = panopticHelper.optionPositionInfo(
            panopticPool,
            $exercisee,
            $tokenIdActive
        );

        $positionListExercisor = userPositions[msg.sender];
        $positionListExercisee = _get_list_without_tokenid(
            userPositions[$exercisee],
            $tokenIdActive
        );

        userPositions[$exercisee] = $positionListExercisee;

        currentTick = V4StateReader.getTick(manager, poolKey.toId());

        $twapTick = PanopticMath.twapFilter(IV3CompatibleOracle(address(pool)), 600);

        $shouldRevert = false;

        try this.validate_exercisable_ext($tokenIdActive, $twapTick) {
            $shouldRevert = $shouldRevert ? $shouldRevert : false;
        } catch {
            $shouldRevert = $shouldRevert ? $shouldRevert : true;
        }

        $balance0Origin = int256(collToken0.balanceOf(msg.sender));
        $balance1Origin = int256(collToken1.balanceOf(msg.sender));

        $balance0Exercisee = int256(collToken0.balanceOf($exercisee));
        $balance1Exercisee = int256(collToken1.balanceOf($exercisee));

        quote_pp_burn();

        // it is impossible for a user to force exercise themselves - position list validation will fail
        if (msg.sender == $exercisee) $shouldRevert = true;

        hevm.prank(msg.sender);
        try
            panopticPool.forceExercise(
                $exercisee,
                $tokenIdActive,
                $positionListExercisee,
                $positionListExercisor,
                LeftRightUnsigned.wrap(1).toLeftSlot(1)
            )
        {
            assertWithMsg(!$shouldRevert, "ForceExercise: missing revert");
        } catch (bytes memory reason) {
            emit LogBytes("Reason", reason);
            // check if the revert is due to an insufficient amount of tokens from the exercisor or the exercisor is insolvent
            if (
                keccak256(reason) == keccak256(abi.encodeWithSignature("Panic(uint256)", 0x11)) ||
                bytes4(reason) == Errors.AccountInsolvent.selector
            ) {
                // if exercisor was insolvent beforehand, it's fine to revert
                try
                    panopticPool.validateCollateralWithdrawable(
                        $exercisee,
                        $positionListExercisee,
                        true
                    )
                {} catch {
                    revert();
                }

                hevm.prank(address(panopticPool));
                collToken0.increaseBalanceByAssets(msg.sender, (2 ** 104 - 1) * 10_000);
                hevm.prank(address(panopticPool));
                collToken1.increaseBalanceByAssets(msg.sender, (2 ** 104 - 1) * 10_000);

                $balance0Origin = int256(collToken0.balanceOf(msg.sender));
                $balance1Origin = int256(collToken1.balanceOf(msg.sender));

                hevm.prank(msg.sender);
                try
                    panopticPool.forceExercise(
                        $exercisee,
                        $tokenIdActive,
                        $positionListExercisee,
                        $positionListExercisor,
                        LeftRightUnsigned.wrap(1).toLeftSlot(1)
                    )
                {
                    assertWithMsg(!$shouldRevert, "ForceExercise: missing revert");
                    revert();
                } catch {
                    assertWithMsg($shouldRevert, "ForceExercise: unexpected revert");
                    revert();
                }
            } else {
                assertWithMsg($shouldRevert, "ForceExercise: unexpected revert");
                revert();
            }
        }

        try panopticPool.validateSolvency(msg.sender, $positionListExercisor, 10_000) {} catch {
            assertWithMsg(false, "ForceExercise: Exercisor left insolvent after force exercise");
        }

        ($longAmounts, $shortAmounts) = PanopticMath.computeExercisedAmounts(
            $tokenIdActive,
            $positionSizeActive
        );

        LeftRightSigned exerciseCost = collToken0.exerciseCost(
            currentTick,
            $twapTick,
            $tokenIdActive,
            $positionSizeActive,
            $longAmounts
        );

        // exercise cost (in terms of token0)
        int256 exerciseCostToken0 = exerciseCost.rightSlot() +
            PanopticMath.convert1to0(
                exerciseCost.leftSlot(),
                TickMath.getSqrtRatioAtTick($twapTick)
            );

        // token0 - diff from burn
        int256 cDelta0 = (
            int256(collToken0.balanceOf($exercisee)) - $balance0Exercisee - $colDelta0 > 0
                ? int8(1)
                : -1
        ) *
            int256(
                collToken0.convertToAssets(
                    uint256(
                        Math.abs(
                            int256(collToken0.balanceOf($exercisee)) -
                                $balance0Exercisee -
                                $colDelta0
                        )
                    )
                )
            );
        // token1 - diff from burn
        cDelta0 += PanopticMath.convert1to0(
            (
                int256(collToken1.balanceOf($exercisee)) - $balance1Exercisee - $colDelta1 > 0
                    ? int8(1)
                    : -1
            ) *
                int256(
                    collToken1.convertToAssets(
                        uint256(
                            Math.abs(
                                int256(collToken1.balanceOf($exercisee)) -
                                    $balance1Exercisee -
                                    $colDelta1
                            )
                        )
                    )
                ),
            TickMath.getSqrtRatioAtTick($twapTick)
        );

        emit LogInt256(
            "exercisor delegation",
            int256(collToken0.balanceOf(msg.sender)) - $balance0Origin
        );
        emit LogInt256("exercisor balance", int256(collToken0.balanceOf(msg.sender)));
        emit LogInt256("exercisor origin", $balance0Origin);
        emit LogInt256(
            "exercisee delegation",
            int256(collToken0.balanceOf($exercisee)) - $balance0Exercisee - $colDelta0
        );
        emit LogInt256("exercisee balance", int256(collToken0.balanceOf($exercisee)));
        emit LogInt256("exercisee origin", $balance0Exercisee);
        emit LogInt256("$colDelta0", $colDelta0);
        // ensure that any differences from post-burn balances in the exercisee are:
        // a) matched exactly by a change in the exercisor's balance
        // b) roughly equivalent in value to the force exercise fee
        assertWithMsg(
            (int256(collToken0.balanceOf($exercisee)) - $balance0Exercisee) - $colDelta0 ==
                -(int256(collToken0.balanceOf(msg.sender)) - $balance0Origin),
            "ForceExercise: Exercisor delegation does not match exercisee's token0 delta compared to burn"
        );
        assertWithMsg(
            (int256(collToken1.balanceOf($exercisee)) - $balance1Exercisee) - $colDelta1 ==
                -(int256(collToken1.balanceOf(msg.sender)) - $balance1Origin),
            "ForceExercise: Exercisor delegation does not match exercisee's token1 delta compared to burn"
        );

        emit LogInt256("cDelta0", cDelta0);

        emit LogInt256(
            "cDeltaToken0",
            (
                int256(collToken0.balanceOf($exercisee)) - $balance0Exercisee - $colDelta0 > 0
                    ? int8(1)
                    : -1
            ) *
                int256(
                    collToken0.convertToAssets(
                        uint256(
                            Math.abs(
                                int256(collToken0.balanceOf($exercisee)) -
                                    $balance0Exercisee -
                                    $colDelta0
                            )
                        )
                    )
                )
        );
        emit LogInt256(
            "cDeltaToken1",
            (
                int256(collToken1.balanceOf($exercisee)) - $balance1Exercisee - $colDelta1 > 0
                    ? int8(1)
                    : -1
            ) *
                int256(
                    collToken1.convertToAssets(
                        uint256(
                            Math.abs(
                                int256(collToken1.balanceOf($exercisee)) -
                                    $balance1Exercisee -
                                    $colDelta1
                            )
                        )
                    )
                )
        );
        assertWithMsg(
            cDelta0 >=
                -int256(
                    2 + PanopticMath.convert1to0(uint256(2), TickMath.getSqrtRatioAtTick($twapTick))
                ),
            "ForceExercise: Sanity check - Exercisee token value is lower than before"
        );

        emit LogInt256("exerciseCostToken0", exerciseCostToken0);

        assertWithMsg(
            Math.abs(-cDelta0 - exerciseCostToken0) <=
                int256(
                    2 + PanopticMath.convert1to0(uint256(2), TickMath.getSqrtRatioAtTick($twapTick))
                ),
            "ForceExercise: Token deltas do not match exercise cost"
        );
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-LIQ-001 The position to liquidate must have a balance below the threshold
    /// @custom:property PANO-LIQ-002 After liquidation, user must have zero open positions
    /// @custom:precondition The liquidatee has a liquidatable position open
    function try_liquidate_option(uint256 i_liquidated) public canonicalTimeState {
        i_liquidated = bound(i_liquidated, 0, actors.length - 1);
        address liquidatee = actors[i_liquidated];
        address liquidator = msg.sender;

        $shouldRevert = false;

        if (userPositions[liquidatee].length < 1) $shouldRevert = true;
        emit LogBool("revert due to no open positions", userPositions[liquidatee].length < 1);

        TokenId[] memory liquidated_positions = userPositions[liquidatee];
        TokenId[] memory liquidator_positions = liquidatee != liquidator
            ? userPositions[liquidator]
            : new TokenId[](0);

        emit LogUint256("liquidator positions length", liquidator_positions.length);
        emit LogUint256("liquidated positions length", liquidated_positions.length);
        emit LogAddress("liquidator", liquidator);
        emit LogAddress("liquidated", liquidatee);

        int24 TWAPtick = PanopticMath.twapFilter(IV3CompatibleOracle(address(pool)), 600);
        $twapTick = TWAPtick;
        currentTick = V4StateReader.getTick(manager, poolKey.toId());

        if (Math.abs(TWAPtick - currentTick) > 513) $shouldRevert = true;
        emit LogBool("revert due to TWAP tick divergence", Math.abs(TWAPtick - currentTick) > 513);

        emit LogInt256("TWAP tick", TWAPtick);
        emit LogInt256("Current tick", currentTick);

        // log_account_collaterals(liquidator);
        // log_account_collaterals(liquidatee);
        // log_trackers_status();
        $colTicks[0] = V4StateReader.getTick(manager, poolKey.toId());
        (, $colTicks[1], $colTicks[2], $colTicks[3], ) = panopticPool.getOracleTicks();

        // replace slow oracle tick with TWAP tick
        $colTicks[2] = TWAPtick;
        _write_liquidation_solvency_revert(liquidatee);

        _calculate_margins_and_premia(liquidatee, TWAPtick);

        liqResults.sharesD0 = int256(collToken0.balanceOf(liquidatee));
        liqResults.sharesD1 = int256(collToken1.balanceOf(liquidatee));

        emit LogBool("revert due to non-burn simulation", $shouldRevert);
        _execute_burn_simulation(liquidatee, liquidator);
        emit LogBool("revert due to burn simulation", $shouldRevert);

        liqResults.liquidatorValueBefore0 = _get_assets_in_token0(liquidator, TWAPtick);
        $totalSupply0 = collToken0.totalSupply();
        $totalSupply1 = collToken1.totalSupply();

        $TSSubliquidateeBalancePre0 = $totalSupply0 - collToken0.balanceOf(liquidatee);
        $TSSubliquidateeBalancePre1 = $totalSupply1 - collToken1.balanceOf(liquidatee);

        $undelegatedShares0 = collToken0.balanceOf(liquidator);
        $undelegatedShares1 = collToken1.balanceOf(liquidator);

        $undelegatedValue0T =
            collToken0.convertToAssets($undelegatedShares0) +
            PanopticMath.convert1to0(
                collToken1.convertToAssets($undelegatedShares1),
                TickMath.getSqrtRatioAtTick(TWAPtick)
            );

        (liqResults.shortPremium, , ) = panopticPool.getAccumulatedFeesAndPositionsData(
            liquidatee,
            false,
            liquidated_positions
        );

        try this._calculate_liquidation_bonus(TWAPtick) {} catch {
            (liqResults.bonus0, liqResults.bonus1) = (0, 0);
        }

        emit LogUint256("total supply 0 pre-liquidation", collToken0.totalSupply());
        emit LogUint256("total supply 1 pre-liquidation", collToken1.totalSupply());
        emit LogUint256("total assets 0 pre-liquidation", collToken0.totalAssets());
        emit LogUint256("total assets 1 pre-liquidation", collToken1.totalAssets());

        emit LogUint256("liquidator balance pre-liq 0", collToken0.balanceOf(liquidator));
        emit LogUint256("liquidator balance pre-liq 1", collToken1.balanceOf(liquidator));

        hevm.prank(liquidator);
        try panopticPool.liquidate(liquidator_positions, liquidatee, liquidated_positions) {
            assertWithMsg(!$shouldRevert, "Liquidate: missing revert");
        } catch (bytes memory reason) {
            emit LogBytes("Reason", reason);
            // check if the revert is due to an insufficient amount of underlying tokens from the exercisor or the exercisor is insolvent
            if (
                keccak256(reason) == keccak256(abi.encodeWithSignature("Panic(uint256)", 0x11)) ||
                bytes4(reason) == Errors.AccountInsolvent.selector
            ) {
                collToken0.credit(msg.sender, (2 ** 104 - 1) * 10_000);
                collToken1.credit(msg.sender, (2 ** 104 - 1) * 10_000);

                deal_USDC(liquidator, (2 ** 104 - 1) * 10_000);
                deal_WETH(liquidator, (2 ** 104 - 1) * 10_000);

                hevm.prank(liquidator);
                IERC20(token0).approve(address(collToken0), (2 ** 104 - 1) * 10_000);
                hevm.prank(liquidator);
                IERC20(token1).approve(address(collToken1), (2 ** 104 - 1) * 10_000);

                hevm.prank(msg.sender);
                try panopticPool.liquidate(liquidator_positions, liquidatee, liquidated_positions) {
                    assertWithMsg(!$shouldRevert, "Liquidate: missing revert");
                    revert();
                } catch {
                    assertWithMsg($shouldRevert, "Liquidate: unexpected revert");
                    revert();
                }
            } else {
                assertWithMsg($shouldRevert, "Liquidate: unexpected revert");
                revert();
            }
        }

        emit LogUint256("total supply 0 post-liquidation", collToken0.totalSupply());
        emit LogUint256("total supply 1 post-liquidation", collToken1.totalSupply());
        emit LogUint256("total assets 0 post-liquidation", collToken0.totalAssets());
        emit LogUint256("total assets 1 post-liquidation", collToken1.totalAssets());
        emit LogUint256("liquidator balance post-liq 0", collToken0.balanceOf(liquidator));
        emit LogUint256("liquidator balance post-liq 1", collToken1.balanceOf(liquidator));

        log_burn_simulation_results();
        log_liquidation_results();

        liqResults.sharesD0 =
            burnSimResults.shareDelta0 -
            (int256(collToken0.balanceOf(liquidatee)) - liqResults.sharesD0);
        liqResults.sharesD1 =
            burnSimResults.shareDelta1 -
            (int256(collToken1.balanceOf(liquidatee)) - liqResults.sharesD1);

        liqResults.liquidatorValueAfter0 =
            int256(_get_assets_in_token0(liquidator, TWAPtick)) +
            int256($undelegatedValue0T) -
            int256(
                collToken0.convertToAssets($undelegatedShares0) +
                    PanopticMath.convert1to0(
                        collToken1.convertToAssets($undelegatedShares1),
                        TickMath.getSqrtRatioAtTick(TWAPtick)
                    )
            );

        emit LogInt256(
            "liquidator value 0 correction",
            int256($undelegatedValue0T) -
                int256(
                    collToken0.convertToAssets($undelegatedShares0) +
                        PanopticMath.convert1to0(
                            collToken1.convertToAssets($undelegatedShares1),
                            TickMath.getSqrtRatioAtTick(TWAPtick)
                        )
                )
        );

        _calculate_bonus(TWAPtick);
        _calculate_protocol_loss_0(TWAPtick);
        _calculate_protocol_loss_expected_0(TWAPtick);

        bytes memory settledLiq;
        (liqResults.settledTokens0, settledLiq) = _calculate_settled_tokens(
            userPositions[liquidatee],
            TWAPtick
        );
        liqResults.settledTokens = abi.decode(settledLiq, (uint256[2][4][32]));

        delete userPositions[liquidatee];

        log_burn_simulation_results();
        log_liquidation_results();

        try panopticPool.validateSolvency(msg.sender, userPositions[liquidator], 10_000) {} catch {
            assertWithMsg(false, "Liquidate: Liquidator left insolvent after liquidation");
        }

        emit LogUint256("Number of legs", panopticPool.numberOfLegs(liquidatee));

        assertWithMsg(
            panopticPool.numberOfLegs(liquidatee) == 0,
            "Liquidation did not close all positions"
        );

        uint256 ts0PostCorrection = burnSimResults.totalSupply0 +
            uint256(Math.max(0, int256(2 ** 248 - 1) - int256(burnSimResults.delegateeBalance0)));
        uint256 ts1PostCorrection = burnSimResults.totalSupply1 +
            uint256(Math.max(0, int256(2 ** 248 - 1) - int256(burnSimResults.delegateeBalance1)));
        burnSimResults.delegateeBalance0 = uint256(
            Math.max(0, int256(burnSimResults.delegateeBalance0) - int256(2 ** 248 - 1))
        );
        burnSimResults.delegateeBalance1 = uint256(
            Math.max(0, int256(burnSimResults.delegateeBalance1) - int256(2 ** 248 - 1))
        );

        if (
            (collToken0.totalSupply() - burnSimResults.totalSupply0 <= 1) &&
            (collToken1.totalSupply() - burnSimResults.totalSupply1 <= 1)
        ) {
            int256 assets = (liqResults.sharesD0 > 0 ? int8(1) : -1) *
                int256(
                    Math.mulDiv(
                        abs(liqResults.sharesD0),
                        burnSimResults.totalAssets0,
                        burnSimResults.totalSupply0
                    )
                ) +
                PanopticMath.convert1to0(
                    (liqResults.sharesD1 > 0 ? int8(1) : -1) *
                        int256(
                            Math.mulDiv(
                                abs(liqResults.sharesD1),
                                burnSimResults.totalAssets1,
                                burnSimResults.totalSupply1
                            )
                        ),
                    TickMath.getSqrtRatioAtTick(TWAPtick)
                );
            emit LogInt256("Assets", assets);
            emit LogInt256("Bonus combined", liqResults.bonusCombined0);

            assertLte(
                liquidatee == liquidator
                    ? abs(assets)
                    : abs(int256(assets) - int256(liqResults.bonusCombined0)),
                2 + PanopticMath.convert1to0(uint256(2), TickMath.getSqrtRatioAtTick(TWAPtick)),
                "Liquidatee was debited incorrect bonus value (funds leftover)"
            );
        } else {
            int256 assets = (liqResults.sharesD0 > 0 ? int8(1) : -1) *
                int256(
                    Math.mulDiv(
                        abs(liqResults.sharesD0),
                        burnSimResults.totalAssets0,
                        burnSimResults.totalSupply0
                    )
                ) +
                PanopticMath.convert1to0(
                    (liqResults.sharesD1 > 0 ? int8(1) : -1) *
                        int256(
                            Math.mulDiv(
                                abs(liqResults.sharesD1),
                                burnSimResults.totalAssets1,
                                burnSimResults.totalSupply1
                            )
                        ),
                    TickMath.getSqrtRatioAtTick(TWAPtick)
                );
            emit LogInt256("Assets", assets);
            emit LogInt256("Bonus combined", liqResults.bonusCombined0);

            // both positive *and* negative bonuses are rounded down, so if one of the bonuses are negative we need to add a tolerance of token0(negativeBonusAmount)
            int256 negBonusTol = 0;
            if (liqResults.bonus0 < 0) negBonusTol += 1;
            if (liqResults.bonus1 < 0)
                negBonusTol += int256(
                    PanopticMath.convert1to0RoundingUp(1, TickMath.getSqrtRatioAtTick(TWAPtick))
                );

            if (liquidatee != liquidator)
                assertWithMsg(
                    assets <= liqResults.bonusCombined0 + negBonusTol,
                    "Liquidatee was debited incorrectly high bonus value (no funds leftover)"
                );

            if (liquidatee == liquidator) {
                assertLte(
                    int256(collToken0.totalSupply()) - int256(ts0PostCorrection),
                    int256(collToken0.balanceOf(liquidatee)),
                    "liquidator == liquidatee balance delta 0"
                );
                assertLte(
                    int256(collToken1.totalSupply()) - int256(ts1PostCorrection),
                    int256(collToken1.balanceOf(liquidatee)),
                    "liquidator == liquidatee balance delta 0"
                );
            }
        }

        emit LogInt256(
            "Delta liquidator value",
            liqResults.liquidatorValueAfter0 - int256(liqResults.liquidatorValueBefore0)
        );
        emit LogInt256("Bonus combined", liqResults.bonusCombined0);

        // if protocol loss exceeds total assets the full bonus cannot be distributed to the liquidator and they can be left at a loss
        if (
            !(collToken0.totalSupply() /
                (ts0PostCorrection - burnSimResults.delegateeBalance0) +
                burnSimResults.delegateeBalance0 >=
                collToken0.totalAssets() ||
                int256(collToken0.totalSupply()) - int256(ts0PostCorrection) ==
                int256(ts0PostCorrection * 10_000) ||
                collToken1.totalSupply() /
                    (ts1PostCorrection - burnSimResults.delegateeBalance1) +
                    burnSimResults.delegateeBalance1 >=
                collToken1.totalAssets() ||
                int256(collToken1.totalSupply()) - int256(ts1PostCorrection) ==
                int256(ts1PostCorrection * 10_000))
        ) {
            if (liquidatee != liquidator)
                assertLte(
                    abs(
                        (liqResults.liquidatorValueAfter0 -
                            int256(liqResults.liquidatorValueBefore0)) - liqResults.bonusCombined0
                    ),
                    2 + PanopticMath.convert1to0(uint256(2), TickMath.getSqrtRatioAtTick(TWAPtick)),
                    "Liquidator did not receive correct bonus"
                );

            emit LogInt256("Protocol loss actual", liqResults.protocolLoss0Actual);
            emit LogInt256(
                "Expected value",
                liqResults.protocolLoss0Expected -
                    Math.min(burnSimResults.longPremium0, liqResults.protocolLoss0Expected)
            );
            assertLte(
                abs(
                    liqResults.protocolLoss0Actual -
                        (liqResults.protocolLoss0Expected -
                            Math.min(burnSimResults.longPremium0, liqResults.protocolLoss0Expected))
                ),
                2 + PanopticMath.convert1to0(uint256(2), TickMath.getSqrtRatioAtTick(TWAPtick)),
                "Not all premium was haircut during protocol loss"
            );
        }

        emit LogInt256(
            "Delta settled tokens",
            int256(burnSimResults.settledTokens0) - int256(liqResults.settledTokens0)
        );
        emit LogInt256(
            "Expected value",
            Math.min(burnSimResults.longPremium0, liqResults.protocolLoss0Expected)
        );
        assertLte(
            abs(
                (int256(burnSimResults.settledTokens0) - int256(liqResults.settledTokens0)) -
                    Math.min(burnSimResults.longPremium0, liqResults.protocolLoss0Expected)
            ),
            2 + PanopticMath.convert1to0(uint256(2), TickMath.getSqrtRatioAtTick(TWAPtick)),
            "Incorrect amount of premium was haircut"
        );

        log_account_collaterals(liquidator);
        log_account_collaterals(liquidatee);
        log_trackers_status();
    }

    function poke_pool_median_oracle() public canonicalTimeState {
        panopticPool.pokeMedian();
    }

    /*//////////////////////////////////////////////////////////////
                                GLOBAL
    //////////////////////////////////////////////////////////////*/

    function assertion_invariant_pools_gross_premia_is_less_than_sfpms_gross_premia(
        uint256 chunkIndex
    ) public canonicalTimeState {
        if (userPositions[msg.sender].length == 0) revert();

        ChunkWithTokenType memory __chunk = touchedPanopticChunks[
            bound(chunkIndex, 0, touchedPanopticChunks.length - 1)
        ];

        emit LogUint256("tokenIdActive", TokenId.unwrap($tokenIdActive));

        for (uint legIndex = 0; legIndex < $tokenIdActive.countLegs(); legIndex++) {
            ($tickLower, $tickUpper) = PanopticMath.getTicks(
                __chunk.strike,
                __chunk.width,
                poolTickSpacing
            );

            (, , $grossPremiaLast0, $grossPremiaLast1) = panopticPool.premiaSettlementData(__chunk);

            ($grossPremia0, $grossPremia1) = sfpm.getAccountPremium(
                poolKey.toId(),
                address(panopticPool),
                __chunk.tokenType,
                $tickLower,
                $tickUpper,
                type(int24).max,
                0
            );

            assertWithMsg(
                $grossPremiaLast0 <= $grossPremia0,
                "Pools grossPremiaLastToken0 is greater than SFPMs grossPremiaToken0"
            );

            assertWithMsg(
                $grossPremiaLast1 <= $grossPremia1,
                "Pools grossPremiaLastToken1 is greater than SFPMs grossPremiaToken1"
            );
        }
    }

    /// @custom:property PANO-SYS-006 Users can't have an open position but no collateral
    /// @custom:precondition The user has a position open
    function assertion_invariant_collateral_for_positions() public canonicalTimeState {
        // If user has positions open, the collateral must be greater than zero
        uint256 numberOfLegs = panopticPool.numberOfLegs(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Legs opened for user", numberOfLegs);

        if (numberOfLegs > 0) {
            uint256 bal0 = collToken0.balanceOf(msg.sender);
            uint256 bal1 = collToken1.balanceOf(msg.sender);
            emit LogUint256("Balance in token0", bal0);
            emit LogUint256("Balance in token1", bal1);

            bal0 = collToken0.convertToAssets(bal0);
            bal1 = collToken1.convertToAssets(bal1);
            emit LogUint256("Balance in token0 to assets", bal0);
            emit LogUint256("Balance in token1 to assets", bal1);

            ($shortPremium, , ) = panopticPool.getAccumulatedFeesAndPositionsData(
                msg.sender,
                true,
                userPositions[msg.sender]
            );

            assertWithMsg(
                ((int256(bal0) + int256(uint256($shortPremium.rightSlot()))) > 0) ||
                    ((int256(bal1) + int256(uint256($shortPremium.leftSlot()))) > 0),
                "User has open positions but zero collateral"
            );
        }
    }

    /// @custom:property PANO-SYS-007 The owed premia is not less than the available premia
    /// @custom:precondition The user has a position open
    function assertion_invariant_unsettled_premium() public canonicalTimeState {
        // Owed premia
        ($shortPremiumIdeal, , ) = panopticPool.getAccumulatedFeesAndPositionsData(
            msg.sender,
            true,
            userPositions[msg.sender]
        );
        // Available premia
        ($shortPremium, , ) = panopticPool.getAccumulatedFeesAndPositionsData(
            msg.sender,
            false,
            userPositions[msg.sender]
        );

        emit LogAddress("Sender:", msg.sender);
        assertWithMsg(
            $shortPremiumIdeal.rightSlot() >= $shortPremium.rightSlot(),
            "Token 0 owed premia is less than available premia"
        );
        assertWithMsg(
            $shortPremiumIdeal.leftSlot() >= $shortPremium.leftSlot(),
            "Token 1 owed premia is less than available premia"
        );
    }
}
