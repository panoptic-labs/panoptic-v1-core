// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";
import {SFPMActions} from "./SFPMActions.sol";

contract CollateralActions is SFPMActions {
    /*//////////////////////////////////////////////////////////////
                          POSITIVE FUNCTIONAL
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-DEP-001 The Panoptic pool balance must increase by the deposited amount when a deposit is made (or the corresponding amount of assets for a given share value when a mint is made)
    /// @custom:property PANO-DEP-002 The user balance must decrease by the deposited amount when a deposit is made (or the corresponding amount of assets for a given share value when a mint is made)
    /// @custom:property PANO-DEP-003 A user's share balance must increase by the amount of shares previewMint returns
    function deposit_to_ct(bool token0, uint256 assets, bool viaMint) public canonicalTimeState {
        if (token0) {
            emit LogString("Attempting to deposit/mint token0");
            _deposit_and_check(collToken0, viaMint, assets, msg.sender);
        } else {
            emit LogString("Attempting to deposit/mint token1");
            _deposit_and_check(collToken1, viaMint, assets, msg.sender);
        }
    }

    function deposit_agnostic(bool token, uint256 assets) public canonicalTimeState {
        assets = boundLog(assets, 1, 100 ether);

        hevm.prank(msg.sender);
        if (!token) {
            collToken0.deposit(assets, msg.sender);
        } else {
            collToken1.deposit(assets, msg.sender);
        }
    }

    function _deposit_and_check(
        CollateralTrackerWrapper collToken,
        bool viaMint,
        uint256 assets,
        address depositor
    ) internal {
        uint256 depositorBalBefore = IERC20(collToken.asset()).balanceOf(depositor);
        uint256 poolBalBefore = manager.balanceOf(
            address(panopticPool),
            uint160(collToken.asset())
        );
        uint256 sharesBefore = collToken.balanceOf(depositor);

        assets = bound(assets, 1, MAX_DEPOSIT);

        // Limit the maximum amount of collateral to deposit
        if (collToken.convertToAssets(collToken.balanceOf(depositor)) > 10 * MAX_DEPOSIT) {
            return;
        }

        require(depositorBalBefore / 10 >= MIN_DEPOSIT);
        assets = bound(assets, MIN_DEPOSIT, min(MAX_DEPOSIT, depositorBalBefore / 10));
        uint256 shares = collToken.previewDeposit(assets);

        hevm.prank(depositor);
        if (viaMint) {
            collToken.mint(shares, depositor);
        } else {
            collToken.deposit(assets, depositor);
        }

        uint256 poolBalAfter = manager.balanceOf(address(panopticPool), uint160(collToken.asset()));
        assertWithMsg(
            poolBalAfter - poolBalBefore == assets,
            "Pool token balance incorrect after deposit"
        );
        uint256 depositorBalAfter = IERC20(collToken.asset()).balanceOf(depositor);
        assertWithMsg(
            depositorBalBefore - depositorBalAfter == assets,
            "User token balance incorrect after deposit"
        );
        uint256 sharesAfter = collToken.balanceOf(depositor);
        assertWithMsg(
            sharesAfter - sharesBefore == shares,
            "User shares balance incorrect after deposit"
        );
    }

    /// @custom:property PANO-WIT-001 The Panoptic pool balance must decrease by the withdrawn amount when a withdrawal is made
    /// @custom:property PANO-WIT-002 The user balance must increase by the withdrawn amount when a withdrawal is made
    function withdraw_from_ct(
        bool token0,
        bool viaRedeem,
        uint256 assets,
        address owner,
        bool toSelf,
        address receiver
    ) public canonicalTimeState {
        require(receiver != address(panopticPool));
        require(receiver != address(manager));
        uint256 numberOfLegs = panopticPool.numberOfLegs(owner);
        if (numberOfLegs > 0) {
            if (token0) {
                emit LogString("Attempting to withdraw token0 with open positions");
                _withdraw_with_open_positions_and_check(
                    collToken0,
                    assets,
                    owner,
                    toSelf,
                    receiver
                );
            } else {
                emit LogString("Attempting to withdraw token1 with open positions");
                _withdraw_with_open_positions_and_check(
                    collToken1,
                    assets,
                    owner,
                    toSelf,
                    receiver
                );
            }
        } else {
            if (token0) {
                emit LogString("Attempting to withdraw/redeem token0 without open positions");
                _regular_withdraw_and_check(collToken0, viaRedeem, assets, owner, toSelf, receiver);
            } else {
                emit LogString("Attempting to withdraw/redeem token1 without open positions");
                _regular_withdraw_and_check(collToken1, viaRedeem, assets, owner, toSelf, receiver);
            }
        }
    }

    function _regular_withdraw_and_check(
        CollateralTrackerWrapper collToken,
        bool viaRedeem,
        uint256 assetsToWithdraw,
        address owner,
        bool toSelf,
        address receiver
    ) internal {
        if (toSelf) {
            receiver = owner;
        }

        uint256 receiverAssetsBefore = IERC20(collToken.asset()).balanceOf(receiver);
        uint256 poolAssetsBefore = manager.balanceOf(
            address(panopticPool),
            uint160(collToken.asset())
        );
        uint256 ownerSharesBefore = collToken.balanceOf(owner);

        require(_max_assets_withdrawable(collToken, collToken.balanceOf(owner)) > 0);

        assetsToWithdraw = bound(
            assetsToWithdraw,
            1,
            _max_assets_withdrawable(collToken, collToken.balanceOf(owner))
        );

        uint256 sharesToWithdraw = collToken.previewWithdraw(assetsToWithdraw);

        hevm.prank(owner);
        if (!toSelf) {
            collToken.approve(receiver, sharesToWithdraw);
            hevm.prank(receiver);
        }

        if (viaRedeem) {
            try collToken.redeem(sharesToWithdraw, receiver, owner) {
                uint256 poolAssetsAfter = manager.balanceOf(
                    address(panopticPool),
                    uint160(collToken.asset())
                );
                uint256 receiverAssetsAfter = IERC20(collToken.asset()).balanceOf(receiver);
                uint256 ownerSharesAfter = collToken.balanceOf(owner);
                assertWithMsg(
                    poolAssetsBefore - poolAssetsAfter == assetsToWithdraw,
                    "Pool asset balance incorrect after redemption"
                );
                assertWithMsg(
                    receiverAssetsAfter - receiverAssetsBefore == assetsToWithdraw,
                    "User balance incorrect after redemption"
                );
                assertWithMsg(
                    ownerSharesBefore - ownerSharesAfter == sharesToWithdraw,
                    "User share balance incorrect after redemption"
                );
            } catch {
                assertWithMsg(false, "Failed to redeem for unknown reason");
            }
        } else {
            try collToken.withdraw(assetsToWithdraw, receiver, owner) {
                uint256 poolAssetsAfter = manager.balanceOf(
                    address(panopticPool),
                    uint160(collToken.asset())
                );
                uint256 receiverAssetsAfter = IERC20(collToken.asset()).balanceOf(receiver);
                uint256 ownerSharesAfter = collToken.balanceOf(owner);
                assertWithMsg(
                    poolAssetsBefore - poolAssetsAfter == assetsToWithdraw,
                    "Pool asset balance incorrect after withdrawal"
                );
                assertWithMsg(
                    receiverAssetsAfter - receiverAssetsBefore == assetsToWithdraw,
                    "User balance incorrect after withdrawal"
                );
                assertWithMsg(
                    ownerSharesBefore - ownerSharesAfter == sharesToWithdraw,
                    "User share balance incorrect after withdrawal"
                );
            } catch {
                assertWithMsg(false, "Failed to withdraw for unknown reason");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          NEGATIVE FUNCTIONAL
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-SYS-001 The max withdrawal or redemption amount of users with open positions is zero, excluding the overloaded withdraw that takes in a positionId list
    /// @custom:property PANO-SYS-002 Users can't withdraw or redeem collateral with open positions, excluding the overloaded withdraw that takes in a positionId list
    /// @custom:precondition The user has a position open
    function assertion_invariant_collateral_removal_via_withdrawal_or_redemption(
        uint256 fuzzNumerator,
        uint256 fuzzDenominator,
        address recipient,
        uint256 fullOrSelfFuzz
    ) public canonicalTimeState {
        uint256 numberOfLegs = panopticPool.numberOfLegs(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Legs opened for user", numberOfLegs);

        if (numberOfLegs > 0) {
            uint256 shareBal0 = collToken0.balanceOf(msg.sender);
            uint256 shareBal1 = collToken1.balanceOf(msg.sender);
            uint assetBal0 = collToken0.convertToAssets(shareBal0);
            uint assetBal1 = collToken1.convertToAssets(shareBal1);

            assertWithMsg(
                collToken0.maxWithdraw(msg.sender) == 0 && collToken1.maxWithdraw(msg.sender) == 0,
                "It is possible to withdraw assets when the user has open positions"
            );
            assertWithMsg(
                collToken0.maxRedeem(msg.sender) == 0 && collToken1.maxRedeem(msg.sender) == 0,
                "It is possible to redeem assets when the user has open positions"
            );

            // fuzz a fraction of the total balance to try and withdraw
            if (fuzzNumerator > fuzzDenominator)
                (fuzzNumerator, fuzzDenominator) = (fuzzDenominator, fuzzNumerator);

            // attempt a full withdrawal every 3rd attempt, and a self-withdrawal every 5th attempt, to ensure we're testing those cases
            if (fullOrSelfFuzz % 3 == 0) fuzzNumerator = fuzzDenominator;
            if (fullOrSelfFuzz % 5 == 0) recipient = msg.sender;

            require(fuzzDenominator > 0);

            uint256 fuzzedSharesToRedeem0 = Math.mulDiv(shareBal0, fuzzNumerator, fuzzDenominator);
            uint256 fuzzedSharesToRedeem1 = Math.mulDiv(shareBal1, fuzzNumerator, fuzzDenominator);

            uint256 fuzzedAssetsToWithdraw0 = Math.mulDiv(
                assetBal0,
                fuzzNumerator,
                fuzzDenominator
            );
            uint256 fuzzedAssetsToWithdraw1 = Math.mulDiv(
                assetBal1,
                fuzzNumerator,
                fuzzDenominator
            );

            if (fuzzedAssetsToWithdraw0 > 0) {
                hevm.prank(msg.sender);
                try collToken0.redeem(fuzzedSharesToRedeem0, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}

                hevm.prank(msg.sender);
                try collToken0.withdraw(fuzzedAssetsToWithdraw0, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}
            }

            if (fuzzedAssetsToWithdraw1 > 0) {
                hevm.prank(msg.sender);
                try collToken1.redeem(fuzzedSharesToRedeem1, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}

                hevm.prank(msg.sender);
                try collToken1.withdraw(fuzzedAssetsToWithdraw1, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}
            }
        }
    }

    /// @custom:property PANO-SYS-003 The max transfer amount of users with open positions is zero
    /// @custom:property PANO-SYS-004 Users can't transfer collateral with open positions
    /// @custom:precondition The user has a position open
    function assertion_invariant_collateral_removal_via_transfer(
        uint256 fuzzNumerator,
        uint256 fuzzDenominator,
        address recipient,
        uint256 fullOrNotFuzz
    ) public canonicalTimeState {
        uint256 numberOfLegs = panopticPool.numberOfLegs(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Legs opened for user", numberOfLegs);

        if (numberOfLegs > 0) {
            uint256 bal0 = collToken0.balanceOf(msg.sender);
            uint256 bal1 = collToken1.balanceOf(msg.sender);

            if (fuzzNumerator > fuzzDenominator)
                (fuzzNumerator, fuzzDenominator) = (fuzzDenominator, fuzzNumerator);

            require(fuzzDenominator > 0);

            uint256 fuzzedAmtToTransfer0 = Math.mulDiv(bal0, fuzzNumerator, fuzzDenominator);
            uint256 fuzzedAmtToTransfer1 = Math.mulDiv(bal1, fuzzNumerator, fuzzDenominator);

            // attempt a full withdrawal every 4th attempt, to ensure we're testing that case too
            if (fullOrNotFuzz % 4 == 0) (fuzzedAmtToTransfer0, fuzzedAmtToTransfer1) = (bal0, bal1);

            if (fuzzedAmtToTransfer0 > 0) {
                hevm.prank(msg.sender);
                try collToken0.transfer(recipient, fuzzedAmtToTransfer0) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transfer with open positions"
                    );
                } catch {}

                hevm.prank(msg.sender);
                collToken0.approve(recipient, fuzzedAmtToTransfer0);

                hevm.prank(recipient);
                try collToken0.transferFrom(msg.sender, recipient, fuzzedAmtToTransfer0) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transferFrom with open positions"
                    );
                } catch {}
            }
            if (fuzzedAmtToTransfer1 > 0) {
                hevm.prank(msg.sender);
                try collToken1.transfer(recipient, fuzzedAmtToTransfer1) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transfer with open positions"
                    );
                } catch {}

                hevm.prank(msg.sender);
                collToken1.approve(recipient, fuzzedAmtToTransfer1);

                hevm.prank(recipient);
                try collToken1.transferFrom(msg.sender, recipient, fuzzedAmtToTransfer1) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transferFrom with open positions"
                    );
                } catch {}
            }
        }
    }

    /// @custom:property PANO-SYS-005 Users can't use the overloaded withdraw to withdraw so much that it makes their open positions insolvent
    function assertion_invariant_collateral_overremoval_with_open_positions(
        uint256 amountToWithdraw
    ) public canonicalTimeState {
        _attempt_collateral_overremoval(collToken0, msg.sender, amountToWithdraw);
        _attempt_collateral_overremoval(collToken1, msg.sender, amountToWithdraw);
    }

    function _attempt_collateral_overremoval(
        CollateralTrackerWrapper collToken,
        address withdrawer,
        uint256 amountToWithdraw
    ) internal {
        TokenId[] memory withdrawersOpenPositions = userPositions[withdrawer];
        // return early if user has no open positions
        if (withdrawersOpenPositions.length == 0) return;

        require(_max_assets_withdrawable(collToken, collToken.balanceOf(withdrawer)) > 0);

        amountToWithdraw = bound(
            amountToWithdraw,
            1,
            _max_assets_withdrawable(collToken, collToken.balanceOf(withdrawer))
        );
        try
            panopticPool.validateCollateralWithdrawable(withdrawer, withdrawersOpenPositions, true)
        {
            // Do nothing: the user _can_ withdraw their collateral, so there's nothing to test
        } catch {
            // if validateCollateralWithdrawable says we should not be able to withdraw,
            // then we should fail here:
            hevm.prank(withdrawer);
            try
                collToken.withdraw(
                    amountToWithdraw,
                    withdrawer,
                    withdrawer,
                    withdrawersOpenPositions,
                    true
                )
            {
                assertWithMsg(
                    false,
                    "User was able to withdraw despite validateCollateralWithdrawable saying they could not"
                );
            } catch {}
        }
    }

    /// @custom:property PANO-SYS-009 No user can ever withdraw greater than the Collateral Tracker's internally-accounted poolAssets
    function assertion_invariant_no_withdrawal_gt_pool_assets(
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) public canonicalTimeState {
        _attempt_withdrawal_gt_pool_assets_via_withdraw(
            collToken0,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
        _attempt_withdrawal_gt_pool_assets_via_withdraw(
            collToken1,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );

        _attempt_withdrawal_gt_pool_assets_via_redeem(
            collToken0,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
        _attempt_withdrawal_gt_pool_assets_via_redeem(
            collToken1,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
    }

    function _attempt_withdrawal_gt_pool_assets_via_withdraw(
        CollateralTrackerWrapper collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        amountOver = bound(amountOver, 1, type(uint256).max - ct_s_poolAssets);
        uint256 numberOfLegs = panopticPool.numberOfLegs(owner);
        TokenId[] memory withdrawersOpenPositions = userPositions[owner];

        hevm.prank(owner);
        if (nonOwnerCall) {
            collToken.approve(recipient, collToken.convertToShares(ct_s_poolAssets + amountOver));
            hevm.prank(recipient);
        }

        if (numberOfLegs == 0) {
            try collToken.withdraw(ct_s_poolAssets + amountOver, recipient, owner) {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "assertion_invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "assertion_invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max withdrawal of ct_s_poolAssets"
                    );
                }
            }

            nonOwnerCall ? hevm.prank(recipient) : hevm.prank(owner);
            try
                collToken.withdraw(
                    ct_s_poolAssets + amountOver,
                    recipient,
                    owner,
                    new TokenId[](0),
                    true
                )
            {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "assertion_invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "assertion_invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max withdrawal of ct_s_poolAssets"
                    );
                }
            }
        } else {
            try
                collToken.withdraw(
                    ct_s_poolAssets + amountOver,
                    recipient,
                    owner,
                    withdrawersOpenPositions,
                    true
                )
            {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "assertion_invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "assertion_invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max withdrawal of ct_s_poolAssets"
                    );
                }
            }
        }
    }

    function _attempt_withdrawal_gt_pool_assets_via_redeem(
        CollateralTrackerWrapper collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        amountOver = bound(amountOver, 1, type(uint256).max - ct_s_poolAssets);

        uint256 numberOfLegs = panopticPool.numberOfLegs(owner);
        if (numberOfLegs == 0) {
            hevm.prank(owner);
            if (nonOwnerCall) {
                collToken.approve(
                    recipient,
                    collToken.convertToShares(ct_s_poolAssets) + amountOver
                );
                hevm.prank(recipient);
            }

            try
                collToken.redeem(
                    collToken.convertToShares(ct_s_poolAssets) + amountOver,
                    recipient,
                    owner
                )
            {
                assertWithMsg(false, "User redeemed > the poolAssets of collToken");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "assertion_invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "assertion_invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max redemption of convertToShares(ct_s_poolAssets)"
                    );
                }
            }
        }
    }

    /// @custom:property PANO-SYS-010 No user can ever withdraw, redeem, nor transfer an amount greater than their own balance
    function assertion_invariant_never_allow_overremoval(
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) public canonicalTimeState {
        _attempt_overwithdrawal_via_withdraw(
            collToken0,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
        _attempt_overwithdrawal_via_withdraw(
            collToken1,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );

        uint256 numberOfLegs = panopticPool.numberOfLegs(owner);
        if (numberOfLegs == 0) {
            _attempt_overwithdrawal_via_redeem(
                collToken0,
                owner,
                recipient,
                amountOver,
                nonOwnerCall
            );
            _attempt_overwithdrawal_via_redeem(
                collToken1,
                owner,
                recipient,
                amountOver,
                nonOwnerCall
            );

            _attempt_overtransfer(collToken0, owner, recipient, amountOver, nonOwnerCall);
            _attempt_overtransfer(collToken1, owner, recipient, amountOver, nonOwnerCall);
        }
    }

    function _attempt_overwithdrawal_via_withdraw(
        CollateralTrackerWrapper collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        uint256 ownersAssets = collToken.convertToAssets(collToken.balanceOf(owner));
        amountOver = bound(
            amountOver,
            1,
            type(uint256).max - collToken.convertToShares(ownersAssets)
        );
        uint256 numberOfLegs = panopticPool.numberOfLegs(owner);
        TokenId[] memory withdrawersOpenPositions = userPositions[owner];

        hevm.prank(owner);
        // every other attempt, make it a non-owner call:
        if (nonOwnerCall) {
            collToken.approve(recipient, collToken.convertToShares(ownersAssets) + amountOver);
            hevm.prank(recipient);
        }

        if (numberOfLegs == 0) {
            try collToken.withdraw(ownersAssets + amountOver, recipient, owner) {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}

            nonOwnerCall ? hevm.prank(recipient) : hevm.prank(owner);
            try
                collToken.withdraw(
                    ownersAssets + amountOver,
                    recipient,
                    owner,
                    new TokenId[](0),
                    true
                )
            {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}
        } else {
            try
                collToken.withdraw(
                    ownersAssets + amountOver,
                    recipient,
                    owner,
                    withdrawersOpenPositions,
                    true
                )
            {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}
        }
    }

    function _attempt_overwithdrawal_via_redeem(
        CollateralTrackerWrapper collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        uint256 ownersShares = collToken.balanceOf(owner);
        amountOver = bound(amountOver, 1, type(uint256).max - ownersShares);

        hevm.prank(owner);
        if (nonOwnerCall) {
            collToken.approve(recipient, ownersShares + amountOver);
            hevm.prank(recipient);
        }

        try collToken.redeem(ownersShares + amountOver, recipient, owner) {
            assertWithMsg(false, "User redeemed > their balance");
        } catch {}
    }

    function _attempt_overtransfer(
        CollateralTrackerWrapper collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        uint256 ownersShares = collToken.balanceOf(owner);
        amountOver = bound(amountOver, 1, type(uint256).max - ownersShares);
        hevm.prank(owner);
        if (nonOwnerCall) {
            try collToken.transfer(recipient, ownersShares + amountOver) {
                assertWithMsg(false, "User transferred > their balance");
            } catch {}
        } else {
            collToken.approve(recipient, ownersShares + amountOver);
            hevm.prank(recipient);
            try collToken.transferFrom(owner, recipient, ownersShares + amountOver) {
                assertWithMsg(false, "User transferFromed > their balance");
            } catch {}
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 GLOBAL
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-SYS-008 The Collateral Tracker's internal accounting always shows it has less than or equal to its true balance of the underlying token
    function assertion_invariant_never_overcount_underlying_token() public canonicalTimeState {
        (uint256 ct0_s_poolAssets, , ) = collToken0.getPoolData();
        assertWithMsg(
            ct0_s_poolAssets <=
                manager.balanceOf(address(panopticPool), uint160(collToken0.asset())) + 1,
            "CollateralTrackerWrapper0 has overcounted its token0 assets"
        );

        (uint256 ct1_s_poolAssets, , ) = collToken1.getPoolData();
        assertWithMsg(
            ct1_s_poolAssets <=
                manager.balanceOf(address(panopticPool), uint160(collToken1.asset())) + 1,
            "CollateralTrackerWrapper1 has overcounted its token1 assets"
        );
    }

    /// @custom:property PANO-SYS-011 The pool can never have a utilisation over 100%
    function assertion_invariant_never_allow_pool_utilisation_over_100p()
        public
        canonicalTimeState
    {
        (, , uint256 collToken0PU) = collToken0.getPoolData();
        assertWithMsg(
            collToken0PU <= 10000,
            "collToken0 pool utilisation exceeded 10k bps <=> 100%"
        );

        (, , uint256 collToken1PU) = collToken1.getPoolData();
        assertWithMsg(
            collToken1PU <= 10000,
            "collToken1 pool utilisation exceeded 10k bps <=> 100%"
        );
    }

    /// @custom:property PANO-SYS-012 Users can't deposit more than the maximum allowed amount, 2^104
    function assertion_invariant_never_allow_overdeposit(
        address receiver,
        uint256 tooLargeDepositAmount,
        bool depositToSelf
    ) public canonicalTimeState {
        require(receiver != address(panopticPool));
        require(receiver != address(manager));

        _attempt_overdeposit(true, msg.sender, receiver, tooLargeDepositAmount, depositToSelf);
        _attempt_overdeposit(false, msg.sender, receiver, tooLargeDepositAmount, depositToSelf);
    }

    function _attempt_overdeposit(
        bool isToken0,
        address depositor,
        address receiver,
        uint256 tooLargeDepositAmount,
        bool depositToSelf
    ) internal {
        require(receiver != address(panopticPool));
        require(receiver != address(manager));

        CollateralTrackerWrapper collToken = isToken0 ? collToken0 : collToken1;
        uint256 maxDeposit = type(uint104).max;
        tooLargeDepositAmount = bound(tooLargeDepositAmount, maxDeposit + 1, type(uint256).max);

        if (depositToSelf) {
            receiver = depositor;
        }

        isToken0
            ? deal_USDC(depositor, type(uint128).max)
            : deal_WETH(depositor, type(uint128).max);
        hevm.prank(depositor);
        IERC20(collToken.asset()).approve(address(collToken), type(uint256).max);

        hevm.prank(depositor);
        try collToken.deposit(tooLargeDepositAmount, receiver) {
            assertWithMsg(false, "Deposit over maximum allowed did not revert");
        } catch {
            emit LogString(
                "Invariant succeeded, likely because we enforced the max deposit amount correctly"
            );
        }
    }

    /// @custom:property PANO-SYS-013 Users can't mint more than the maximum allowed amount, 2^104
    function assertion_invariant_never_allow_overmint(
        address minter,
        address receiver,
        uint256 tooLargeMintAmount,
        bool mintToSelf
    ) public canonicalTimeState {
        require(receiver != address(panopticPool));
        require(receiver != address(manager));

        _attempt_overmint(true, minter, receiver, tooLargeMintAmount, mintToSelf);
        _attempt_overmint(false, minter, receiver, tooLargeMintAmount, mintToSelf);
    }

    function _attempt_overmint(
        bool isToken0,
        address minter,
        address receiver,
        uint256 tooLargeMintAmount,
        bool mintToSelf
    ) internal {
        CollateralTrackerWrapper collToken = isToken0 ? collToken0 : collToken1;
        uint256 maxMint = collToken.previewDeposit(type(uint104).max);
        require(maxMint < type(uint256).max);
        tooLargeMintAmount = bound(tooLargeMintAmount, maxMint + 1, type(uint256).max);

        if (mintToSelf) {
            receiver = minter;
        }

        isToken0 ? deal_USDC(minter, type(uint128).max) : deal_WETH(minter, type(uint128).max);

        hevm.prank(minter);
        IERC20(collToken.asset()).approve(address(collToken), type(uint256).max);
        hevm.prank(minter);
        try collToken.mint(tooLargeMintAmount, receiver) {
            assertWithMsg(false, "Mint over maximum allowed did not revert");
        } catch {
            emit LogString(
                "Invariant succeeded, likely because we enforced the max mint amount correctly"
            );
        }
    }

    /// @custom:property PANO-SYS-014 Users can't deposit/mint more than their balance
    function assertion_invariant_no_mint_nor_deposit_over_balance(
        address receiver,
        uint256 amountOver,
        bool viaMint
    ) public canonicalTimeState {
        require(receiver != address(panopticPool));
        require(receiver != address(manager));

        _attempt_deposit_over_balance(collToken0, msg.sender, receiver, amountOver, viaMint);
        _attempt_deposit_over_balance(collToken1, msg.sender, receiver, amountOver, viaMint);
    }

    function _attempt_deposit_over_balance(
        CollateralTrackerWrapper collToken,
        address depositor,
        address receiver,
        uint256 amountOver,
        bool viaMint
    ) internal {
        uint256 depositorBalance = IERC20(collToken.asset()).balanceOf(depositor);
        amountOver = bound(amountOver, 1, type(uint256).max - depositorBalance);
        uint256 tooLargeAmount = depositorBalance + amountOver;
        uint256 tooLargeShares = collToken.convertToShares(tooLargeAmount);

        hevm.prank(depositor);
        if (viaMint) {
            try collToken.mint(tooLargeShares, receiver) {
                assertWithMsg(
                    false,
                    "User minted an amount of shares greater than their balance of the asset"
                );
            } catch {}
        } else {
            try collToken.deposit(tooLargeAmount, receiver) {
                assertWithMsg(
                    false,
                    "User deposited an amount greater than their balance of the asset"
                );
            } catch {}
        }
    }

    function _withdraw_with_open_positions_and_check(
        CollateralTrackerWrapper collToken,
        uint256 assetsToWithdraw,
        address owner,
        bool toSelf,
        address receiver
    ) internal {
        if (toSelf) {
            receiver = owner;
        }

        // check whether current positions are solvent; revert if not
        TokenId[] memory ownersOpenPositions = userPositions[owner];

        panopticPool.validateCollateralWithdrawable(owner, ownersOpenPositions, true);

        // attempt withdrawal, and assert assets & shares were deducted/incremented appropriately
        uint256 receiverAssetsBefore = IERC20(collToken.asset()).balanceOf(receiver);
        uint256 poolAssetsBefore = manager.balanceOf(
            address(panopticPool),
            uint160(collToken.asset())
        );
        uint256 ownerSharesBefore = collToken.balanceOf(owner);

        require(_max_assets_withdrawable(collToken, ownerSharesBefore) > 0);

        // Bound the fuzzed assets-to-withdraw to max assets withdrawable:
        // the smaller of the s_poolAssets and the user's assets in the CT
        assetsToWithdraw = bound(
            assetsToWithdraw,
            1,
            _max_assets_withdrawable(collToken, ownerSharesBefore)
        );
        // Figure out how many shares we expect to see burnt:
        uint256 expectedSharesBurnt = collToken.previewWithdraw(assetsToWithdraw);

        hevm.prank(owner);
        if (!toSelf) {
            collToken.approve(receiver, expectedSharesBurnt);
            hevm.prank(receiver);
        }

        try collToken.withdraw(assetsToWithdraw, receiver, owner, ownersOpenPositions, true) {
            // assert assets & shares were deducted/incremented appropriately:
            uint256 poolAssetsAfter = manager.balanceOf(
                address(panopticPool),
                uint160(collToken.asset())
            );
            uint256 receiverAssetsAfter = IERC20(collToken.asset()).balanceOf(receiver);
            uint256 ownerSharesAfter = collToken.balanceOf(owner);
            assertWithMsg(
                poolAssetsBefore - poolAssetsAfter == assetsToWithdraw,
                "Pool asset balance incorrect after withdrawal"
            );
            assertWithMsg(
                receiverAssetsAfter - receiverAssetsBefore == assetsToWithdraw,
                "User balance incorrect after deposit"
            );
            assertWithMsg(
                ownerSharesBefore - ownerSharesAfter == expectedSharesBurnt,
                "User share balance incorrect after withdrawal"
            );

            // show we are still solvent:
            try
                panopticPool.validateCollateralWithdrawable(owner, ownersOpenPositions, true)
            {} catch {
                assertWithMsg(
                    false,
                    "User not solvent after seemingly legal withdrawal-with-open-positions"
                );
            }
        } catch {
            hevm.prank(address(panopticPool));
            collToken.decreaseBalance(owner, expectedSharesBurnt);

            try panopticPool.validateCollateralWithdrawable(owner, ownersOpenPositions, true) {
                assertWithMsg(
                    false,
                    "Withdrawal reverted for reason other than causing insolvency"
                );
            } catch {}
        }
    }

    function _max_assets_withdrawable(
        CollateralTrackerWrapper collToken,
        uint256 withdrawerSharesBefore
    ) internal view returns (uint256 maxAssetsWithdrawable) {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        uint256 withdrawersAssetsInCT = collToken.convertToAssets(withdrawerSharesBefore);
        maxAssetsWithdrawable = ct_s_poolAssets - 1 < withdrawersAssetsInCT
            ? ct_s_poolAssets - 1
            : withdrawersAssetsInCT;
    }
}
