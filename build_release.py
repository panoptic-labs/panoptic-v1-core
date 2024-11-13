import subprocess
import json
import os
import eth_abi

print("\033[95mCompiling metadata...")

subprocess.run(["bun", "run", "./metadata/compiler.js"], check=True)

with open("metadata/out/MetadataPackage.json", "r") as file:
    metadata = json.load(file)

print("\033[92mOK")

print("\033[95mBuilding contracts...")

with open("build-config.json", "r") as file:
    config = json.load(file)

# propagate metadata to environment
config["env"]["MD_PROPERTIES"] = list(
    map(lambda prop: str.encode(prop), metadata["properties"])
)
config["env"]["MD_INDICES"] = list(
    map(
        lambda propIndices: list(map(lambda index: int(index), propIndices)),
        metadata["indices"],
    )
)
config["env"]["MD_POINTERS"] = list(
    map(
        lambda propPointers: list(
            map(
                lambda pointer: (pointer["size"] << 208)
                + (pointer["start"] << 160)
                + int(config["dataContracts"][pointer["codeIndex"]]["address"], 16),
                propPointers,
            )
        ),
        metadata["pointers"],
    )
)

deploymentInfo = {"dataContracts": [], "logicContracts": []}
for deployment, code in zip(config["dataContracts"], metadata["bytecodes"]):
    deploymentInfo["dataContracts"].append(
        {
            "address": deployment["address"],
            "salt": deployment["salt"],
            "nonce": deployment["nonce"],
            "initcode": "0x" + code,
        }
    )

for contract_name, options in config["logicContracts"].items():
    subprocess.run(["forge", "clean"], check=True)

    command = [
        "forge",
        "build",
        options["path"],
        "--deny-warnings",
        "--use",
        "0.8.28",
        "--evm-version",
        "cancun",
        "--optimize",
        "true",
        "--optimizer-runs",
        str(options["optimizeRuns"]),
    ]

    if "links" in options:
        for lib in options["links"]:
            command.append("--libraries")
            command.append(
                config["logicContracts"][lib]["path"]
                + ":"
                + lib
                + ":"
                + config["logicContracts"][lib]["deployment"]["address"]
            )

    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)

    with open(
        os.path.join("out", os.path.basename(options["path"]), f"{contract_name}.json"),
        "r",
    ) as output_json_file:
        deploymentInfo["logicContracts"].append(
            {
                "address": options["deployment"]["address"],
                "contractName": contract_name,
                "initcode": json.load(output_json_file)["bytecode"]["object"],
                "nonce": options["deployment"]["nonce"],
                "salt": options["deployment"]["salt"],
            }
        )

    if "constructorArgs" in options:
        for i, arg in enumerate(options["constructorArgs"][0]):
            if type(arg) is str:
                if arg[0] == "@":
                    options["constructorArgs"][0][i] = config["logicContracts"][
                        arg[1:]
                    ]["deployment"]["address"]
                elif arg[0] == "$":
                    options["constructorArgs"][0][i] = config["env"][arg[1:]]
        deploymentInfo["logicContracts"][len(deploymentInfo["logicContracts"]) - 1]["initcode"] += eth_abi.encode(
            options["constructorArgs"][1], options["constructorArgs"][0]
        ).hex()

    print(f"\033[96m{contract_name}:", "\033[92mOK")

with open("deployment-info.json", "w+") as output_file:
    json.dump(deploymentInfo, output_file)
    print("\033[95minitcodes written to deployment-info.json")
