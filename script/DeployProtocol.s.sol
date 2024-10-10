// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import "forge-std/Script.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {Pointer, PointerLibrary} from "@types/Pointer.sol";
import {PanopticHelper} from "@test_periphery/PanopticHelper.sol";

contract DeployProtocol is Script {
    struct PointerInfo {
        uint256 codeIndex;
        uint256 end;
        uint256 start;
    }

    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14: sepolia
        address WETH9 = vm.envAddress("WETH9");

        // 0x0227628f3f023bb0b980b67d528571c95c6dac1c: sepolia
        IUniswapV3Factory uniFactory = IUniswapV3Factory(vm.envAddress("UNIV3_FACTORY"));

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        string memory metadata = vm.readFile("./metadata/out/MetadataPackage.json");

        bytes[] memory bytecodes = vm.parseJsonBytesArray(metadata, ".bytecodes");
        address[] memory pointerAddresses = new address[](bytecodes.length);

        for (uint256 i = 0; i < bytecodes.length; i++) {
            bytes memory code = bytecodes[i];
            address pointer;
            // deploy code and store pointer
            assembly {
                pointer := create(0, add(code, 0x20), mload(code))
                if iszero(extcodesize(pointer)) {
                    revert(0, 0)
                }
            }
            pointerAddresses[i] = pointer;
        }

        PointerInfo[][] memory pointerInfo = abi.decode(
            vm.parseJson(metadata, ".pointers"),
            (PointerInfo[][])
        );
        Pointer[][] memory pointers = new Pointer[][](pointerInfo.length);

        for (uint256 i = 0; i < pointerInfo.length; i++) {
            pointers[i] = new Pointer[](pointerInfo[i].length);
            for (uint256 j = 0; j < pointerInfo[i].length; j++) {
                pointers[i][j] = PointerLibrary.createPointer(
                    pointerAddresses[pointerInfo[i][j].codeIndex],
                    uint48(pointerInfo[i][j].start),
                    uint48(pointerInfo[i][j].end)
                );
            }
        }

        string[] memory propsStr = vm.parseJsonStringArray(metadata, ".properties");
        bytes32[] memory props = new bytes32[](propsStr.length);
        for (uint256 i = 0; i < propsStr.length; i++) {
            props[i] = bytes32(bytes(propsStr[i]));
        }

        string[][] memory indicesStr = abi.decode(vm.parseJson(metadata, ".indices"), (string[][]));
        uint256[][] memory indices = new uint256[][](indicesStr.length);
        for (uint256 i = 0; i < indicesStr.length; i++) {
            indices[i] = new uint256[](indicesStr[i].length);
            for (uint256 j = 0; j < indicesStr[i].length; j++) {
                indices[i][j] = vm.parseUint(indicesStr[i][j]);
            }
        }

        SemiFungiblePositionManager sfpm = new SemiFungiblePositionManager(uniFactory);
        new PanopticFactory(
            WETH9,
            sfpm,
            uniFactory,
            address(new PanopticPool(sfpm)),
            address(new CollateralTracker(10, 2_000, 1_000, -128, 5_000, 9_000, 20_000)),
            props,
            indices,
            pointers
        );

        new PanopticHelper(sfpm);

        // factory.tokenURI(0x00c34C41289e6c433723542BB1Eba79c6919504EDD);
        vm.stopBroadcast();
    }
}
