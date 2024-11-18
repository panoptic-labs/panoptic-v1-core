import subprocess
import json
import os
import eth_abi

print("\033[95mCompiling metadata...")

subprocess.run(["bun", "run", "./metadata/compiler.js"], check=True)

with open("metadata/out/MetadataPackage.json", "r") as file:
    metadata = json.load(file)

print("\033[92mOK")

print("\033[95mBuilding and verifying contracts...")

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

    print(f"\033[96m{contract_name}:", "\033[33mCompiling...")
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)

    command = [
        "forge",
        "verify-contract",
        options["deployment"]["address"],
        contract_name,
        "--optimizer-runs",
        str(options["optimizeRuns"]),
        "--chain",
        os.environ["CHAIN_NAME"],
        "--watch",
    ]

    if "constructorArgs" in options:
        for i, arg in enumerate(options["constructorArgs"][0]):
            if type(arg) is str:
                if arg[0] == "@":
                    options["constructorArgs"][0][i] = config["logicContracts"][
                        arg[1:]
                    ]["deployment"]["address"]
                elif arg[0] == "$":
                    options["constructorArgs"][0][i] = config["env"][arg[1:]]
        command.append("--constructor-args")
        command.append(
            eth_abi.encode(
                options["constructorArgs"][1], options["constructorArgs"][0]
            ).hex()
        )

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

    print(f"\033[96m{contract_name}:", "\033[33mVerifying...")
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)

    print(f"\033[96m{contract_name}:", "\033[92mOK")
