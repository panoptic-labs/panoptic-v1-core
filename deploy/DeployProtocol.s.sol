// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.18;

// Foundry
import "forge-std/Script.sol";
// Uniswap - Panoptic's version 0.8
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
// Internal
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";

/**
 * @title Deployment script that deploys PanopticFactory, SFPM, and dependencies
 * @author Axicon Labs Limited
 */
contract DeployProtocol is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        IUniswapV3Factory UNISWAP_V3_FACTORY = IUniswapV3Factory(
            vm.envAddress("UNISWAP_V3_FACTORY")
        );
        address WETH9 = vm.envAddress("WETH9");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        SemiFungiblePositionManager SFPM = new SemiFungiblePositionManager(UNISWAP_V3_FACTORY);

        // Import the Panoptic Pool reference (for cloning)
        address poolReference = address(new PanopticPool(SFPM));

        // Import the Collateral Tracker reference (for cloning)
        address collateralReference = address(new CollateralTracker());

        PanopticFactory factory = new PanopticFactory(
            WETH9,
            SFPM,
            UNISWAP_V3_FACTORY,
            poolReference,
            collateralReference
        );

        vm.stopBroadcast();
    }
}
