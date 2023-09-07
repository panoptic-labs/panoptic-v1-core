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
/// @TODO link to blog post/video when live
contract FirstPanoption is Script {
    using TokenId for uint256;

    function run() public {
        IUniswapV3Factory UNISWAP_V3_FACTORY = IUniswapV3Factory(
            vm.envAddress("UNISWAP_V3_FACTORY")
        );

        SemiFungiblePositionManager SFPM = SemiFungiblePositionManager();

        PanopticFactory PANOPTIC_FACTORY = PanopticFactory();

        IERC20Partial WBTC = IERC20Partial(0x29f2D40B0605204364af54EC677bD022dA425d03);
        IERC20Partial DAI = IERC20Partial(0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        vm.stopBroadcast();
    }
}
