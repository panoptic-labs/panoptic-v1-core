// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.18;

// Foundry
import "forge-std/Script.sol";
// Interfaces
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Core contracts
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Types
import {TokenId} from "@types/TokenId.sol";

/**
 * @title Minting your first Panoption!
 * @notice Follow along and mint your first Panoption: https://panoptic.xyz/research/introducing-panoptics-smart-contracts
 * @author Axicon Labs Limited
 */
contract FirstPanoption is Script {
    using TokenId for uint256;

    function run() public {
        IUniswapV3Factory UNISWAP_V3_FACTORY = IUniswapV3Factory(
            vm.envAddress("UNISWAP_V3_FACTORY")
        );

        SemiFungiblePositionManager SFPM = SemiFungiblePositionManager(
            0x0000000000000000000000000000000000000000
        );

        PanopticFactory PANOPTIC_FACTORY = PanopticFactory(
            0x0000000000000000000000000000000000000000
        );

        IERC20Partial WBTC = IERC20Partial(0x29f2D40B0605204364af54EC677bD022dA425d03);
        IERC20Partial DAI = IERC20Partial(0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        WBTC.approve({spender: address(PANOPTIC_FACTORY), amount: type(uint256).max});
        DAI.approve({spender: address(PANOPTIC_FACTORY), amount: type(uint256).max});

        PanopticPool pp = PANOPTIC_FACTORY.deployNewPool({
            token0: address(WBTC),
            token1: address(DAI),
            fee: 500,
            salt: 1337
        });

        WBTC.approve({spender: address(pp.collateralToken0()), amount: type(uint256).max});
        DAI.approve({spender: address(pp.collateralToken1()), amount: type(uint256).max});

        pp.collateralToken0().deposit({
            assets: 10 ** 8,
            receiver: vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"))
        });

        pp.collateralToken1().deposit({
            assets: 100 * 10 ** 18,
            receiver: vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"))
        });

        uint256[] memory positionIdList = new uint256[](1);
        positionIdList[0] = uint256(0)
            .addUniv3pool(SFPM.getPoolId(address(pp.univ3pool())))
            .addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 0,
                _tokenType: 1,
                _riskPartner: 0,
                _strike: -5000,
                _width: 2
            });

        pp.mintOptions({
            positionIdList: positionIdList,
            positionSize: 10 * 10 ** 18,
            effectiveLiquidityLimitX32: 0,
            tickLimitLow: 0,
            tickLimitHigh: 0
        });

        vm.stopBroadcast();
    }
}
