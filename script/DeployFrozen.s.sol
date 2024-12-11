// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry
import "forge-std/Script.sol";

interface IVanityMarket {
    function mint(address to, uint256 id, uint8 nonce) external;

    function deploy(
        uint256 id,
        bytes calldata initcode
    ) external payable returns (address deployed);

    function ownerOf(uint256 tokenId) external view returns (address owner);
}

contract DeployFrozen is Script {
    struct DeploymentEntry {
        address target;
        bytes initcode;
        uint8 nonce;
        bytes32 salt;
    }

    struct NamedDeploymentEntry {
        address target;
        string contractName;
        bytes initcode;
        uint8 nonce;
        bytes32 salt;
    }

    IVanityMarket c3 = IVanityMarket(0x000000000000b361194cfe6312EE3210d53C15AA);

    function run() public {
        vm.startBroadcast(0xbF24CBfE40482980AD88b11aDd53600EdcF0faEd);
        address deployer = 0xbF24CBfE40482980AD88b11aDd53600EdcF0faEd;

        string memory deploymentInfo = vm.readFile("./deployment-info.json");

        DeploymentEntry[] memory dataContracts = abi.decode(
            vm.parseJson(deploymentInfo, ".dataContracts"),
            (DeploymentEntry[])
        );

        for (uint256 i = 0; i < dataContracts.length; i++) {
            c3.mint(deployer, uint256(dataContracts[i].salt), dataContracts[i].nonce);
            c3.deploy(uint256(dataContracts[i].salt), dataContracts[i].initcode);
        }

        NamedDeploymentEntry[] memory logicContracts = abi.decode(
            vm.parseJson(deploymentInfo, ".logicContracts"),
            (NamedDeploymentEntry[])
        );

        address[] memory deployedContracts = new address[](logicContracts.length);
        for (uint256 i = 0; i < logicContracts.length; i++) {
            c3.mint(deployer, uint256(logicContracts[i].salt), logicContracts[i].nonce);
            c3.ownerOf(uint256(logicContracts[i].salt));
            deployedContracts[i] = c3.deploy(
                uint256(logicContracts[i].salt),
                logicContracts[i].initcode
            );
        }

        vm.writeFile(
            "panoptic-pool-code.txt",
            vm.toString(deployedContracts[deployedContracts.length - 2].code)
        );
        vm.writeFile(
            "sfpm-code.txt",
            vm.toString(deployedContracts[deployedContracts.length - 1].code)
        );

        vm.stopBroadcast();
    }
}
