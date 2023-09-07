// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.18;

// Foundry
import "forge-std/Script.sol";
// Uniswap - Panoptic's version 0.8
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
// Internal
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {ERC20S} from "./tokens/ERC20S.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

/**
 * @title Deployment script that deploys two tokens, a Uniswap V3 pool, and a Panoptic Pool on top of that.
 * @author Axicon Labs Limited
 */
contract DeployTestPool is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        IUniswapV3Factory UNISWAP_V3_FACTORY = IUniswapV3Factory(
            vm.envAddress("UNISWAP_V3_FACTORY")
        );
        address SFPM = vm.envAddress("SFPM");
        PanopticFactory PANOPTIC_FACTORY = PanopticFactory(vm.envAddress("PANOPTIC_FACTORY"));

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        ERC20S token0 = new ERC20S("Token0", "T0", 18);
        ERC20S token1 = new ERC20S("Token1", "T1", 18);

        token0.mint(vm.addr(DEPLOYER_PRIVATE_KEY), 100000e18);
        token1.mint(vm.addr(DEPLOYER_PRIVATE_KEY), 100000e18);

        token0.approve(address(PANOPTIC_FACTORY), type(uint256).max);
        token1.approve(address(PANOPTIC_FACTORY), type(uint256).max);

        address unipool = UNISWAP_V3_FACTORY.createPool(address(token0), address(token1), 500);

        //initialize at tick 0
        IUniswapV3Pool(unipool).initialize(0x1000000000000000000000000);

        PANOPTIC_FACTORY.deployNewPool(address(token0), address(token1), 500, 1337);

        vm.stopBroadcast();
    }
}
