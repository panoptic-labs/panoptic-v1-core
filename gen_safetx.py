import json 
import os

with open("deployment-info.json", "r") as file:
    deploymentInfo = json.load(file)

os.makedirs('./safe-txns', exist_ok=True)

for idx, contract in enumerate(deploymentInfo["dataContracts"]):
    safeTx = {
        "chainId": "1",
        "meta": {
            "name": f"Deploy data contract {idx} at {contract["address"]}",
        },
        "transactions": [
            {
                "to": "0x000000000000b361194cfe6312EE3210d53C15AA",
                "value": "0",
                "data": None,
                "contractMethod": {
                    "inputs": [
                        {
                            "internalType": "address",
                            "name": "to",
                            "type": "address"
                        },
                        {
                            "internalType": "uint256",
                            "name": "id",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint8",
                            "name": "nonce",
                            "type": "uint8"
                        }
                    ],
                    "name": "mint",
                    "payable": False
                },
                "contractInputsValues": {
                    "to": "0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1",
                    "id": str(int(contract["salt"], 16)),
                    "nonce": str(contract["nonce"])
                }
            },
            {
                "to": "0x000000000000b361194cfe6312EE3210d53C15AA",
                "value": "0",
                "data": None,
                "contractMethod": {
                    "inputs": [
                        {
                            "internalType": "uint256",
                            "name": "id",
                            "type": "uint256"
                        },
                        {
                            "internalType": "bytes",
                            "name": "initcode",
                            "type": "bytes"
                        }
                    ],
                    "name": "deploy",
                    "payable": True
                },
                "contractInputsValues": {
                    "to": "0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1",
                    "id": str(int(contract["salt"], 16)),
                    "initcode": contract["initcode"]
                }
            }
        ]
    }

    with open(f"./safe-txns/dataDeploy_{idx}.json", "w") as output_file:
        json.dump(safeTx, output_file)

for idx, contract in enumerate(deploymentInfo["logicContracts"]):
    safeTx = {
        "chainId": "1",
        "meta": {
            "name": f"Deploy contract {contract["contractName"]} at {contract["address"]}",
        },
        "transactions": [
            {
                "to": "0x000000000000b361194cfe6312EE3210d53C15AA",
                "value": "0",
                "data": None,
                "contractMethod": {
                    "inputs": [
                        {
                            "internalType": "address",
                            "name": "to",
                            "type": "address"
                        },
                        {
                            "internalType": "uint256",
                            "name": "id",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint8",
                            "name": "nonce",
                            "type": "uint8"
                        }
                    ],
                    "name": "mint",
                    "payable": False
                },
                "contractInputsValues": {
                    "to": "0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1",
                    "id": str(int(contract["salt"], 16)),
                    "nonce": str(contract["nonce"])
                }
            },
            {
                "to": "0x000000000000b361194cfe6312EE3210d53C15AA",
                "value": "0",
                "data": None,
                "contractMethod": {
                    "inputs": [
                        {
                            "internalType": "uint256",
                            "name": "id",
                            "type": "uint256"
                        },
                        {
                            "internalType": "bytes",
                            "name": "initcode",
                            "type": "bytes"
                        }
                    ],
                    "name": "deploy",
                    "payable": True
                },
                "contractInputsValues": {
                    "to": "0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1",
                    "id": str(int(contract["salt"], 16)),
                    "initcode": contract["initcode"]
                }
            }
        ]
    }

    with open(f"./safe-txns/deploy_{idx}_{contract["contractName"]}.json", "w") as output_file:
        json.dump(safeTx, output_file)
