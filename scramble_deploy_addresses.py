import json
import random
import string
from web3 import Web3

w3 = Web3(Web3.HTTPProvider("https://eth.public-rpc.com"))

CONTRACT_ADDRESS = Web3.to_checksum_address("0x000000000000b361194cfe6312ee3210d53c15aa")
CONTRACT_ABI = """
[
    {
        "constant": true,
        "inputs": [
            {"name": "salt", "type": "bytes32"},
            {"name": "nonce", "type": "uint8"}
        ],
        "name": "computeAddress",
        "outputs": [{"name": "vanity", "type": "address"}],
        "type": "function"
    }
]
"""
contract = w3.eth.contract(address=CONTRACT_ADDRESS, abi=CONTRACT_ABI)

def generate_salt():
    random_suffix = ''.join(random.choices(string.hexdigits.lower(), k=24))
    # replace these characters with the desired deployer address
    return f"0xbF24CBfE40482980AD88b11aDd53600EdcF0faEd{random_suffix}"

def compute_address(salt, nonce):
    return contract.functions.computeAddress(salt, nonce).call()

def update_json(json_data):
    for data_contract in json_data["dataContracts"]:
        salt = generate_salt()
        nonce = 0
        address = compute_address(salt, nonce)

        data_contract["salt"] = salt
        data_contract["nonce"] = nonce
        data_contract["address"] = address

    for key, logic_contract in json_data["logicContracts"].items():
        if "deployment" in logic_contract:
            salt = generate_salt()
            nonce = 0
            address = compute_address(salt, nonce)

            logic_contract["deployment"]["salt"] = salt
            logic_contract["deployment"]["nonce"] = nonce
            logic_contract["deployment"]["address"] = address

    return json_data

with open("build-config.json", "r") as file:
    json_data = json.load(file)

updated_json = update_json(json_data)

with open("build-config.json", "w") as file:
    json.dump(updated_json, file, indent=2)

print("JSON file updated and saved to build-config.json.")