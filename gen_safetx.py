import json 
import os

with open("deployment-info.json", "r") as file:
    deploymentInfo = json.load(file)

os.makedirs('./safe-txns', exist_ok=True)

deployBatches = []

deployBatches.append({
    "chainId": os.environ.get("CHAIN_ID") or "1",
    "meta": {
        "name": f"Deploy data contracts 0-3",
    },
    "transactions": []
})

deployBatches.append({
    "chainId": os.environ.get("CHAIN_ID") or "1",
    "meta": {
        "name": f"Deploy data contracts 4-6 and logic contracts 0-3",
    },
    "transactions": []
})

deployBatches.append({
    "chainId": os.environ.get("CHAIN_ID") or "1",
    "meta": {
        "name": f"Deploy logic contracts 4-5",
    },
    "transactions": []
})

deployBatches.append({
    "chainId": os.environ.get("CHAIN_ID") or "1",
    "meta": {
        "name": f"Deploy logic contracts 6-7",
    },
    "transactions": []
})

for idx, contract in enumerate(deploymentInfo["dataContracts"]):
    safeTx = {
        "chainId": os.environ.get("CHAIN_ID") or "1",
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
                    "to": contract["salt"][:42],
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
                    "id": str(int(contract["salt"], 16)),
                    "initcode": contract["initcode"]
                }
            }
        ]
    }

    if idx < 4: deployBatches[0]["transactions"] += safeTx["transactions"]
    else: deployBatches[1]["transactions"] += safeTx["transactions"]

    with open(f"./safe-txns/dataDeploy_{idx}.json", "w") as output_file:
        json.dump(safeTx, output_file)

libTxs = {
    "chainId": os.environ.get("CHAIN_ID") or "1",
    "meta": {
        "name": f"Deploy all libraries",
    },
    "transactions": []
}

coreTxs = {
    "chainId": os.environ.get("CHAIN_ID") or "1",
    "meta": {
        "name": f"Deploy all core contracts",
    },
    "transactions": []
}

for idx, contract in enumerate(deploymentInfo["logicContracts"]):
    safeTx = {
        "chainId": os.environ.get("CHAIN_ID") or "1",
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
                    "to": contract["salt"][:42],
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
                    "id": str(int(contract["salt"], 16)),
                    "initcode": contract["initcode"]
                }
            }
        ]
    }

    if idx < 4: deployBatches[1]["transactions"] += safeTx["transactions"]
    elif idx < 6: deployBatches[2]["transactions"] += safeTx["transactions"]
    else: deployBatches[3]["transactions"] += safeTx["transactions"]

    with open(f"./safe-txns/deploy_{idx}_{contract["contractName"]}.json", "w") as output_file:
        json.dump(safeTx, output_file)


for idx, batch in enumerate(deployBatches):
    with open(f"./safe-txns/batch_deploy_{idx}.json", "w") as output_file:
        json.dump(batch, output_file)

with open("./safe-txns/deploy_all_1_libraries.json", "w") as output_file:
    json.dump(libTxs, output_file)

with open("./safe-txns/deploy_all_2_core.json", "w") as output_file:
    json.dump(coreTxs, output_file)
