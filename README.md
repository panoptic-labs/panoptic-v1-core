<p align="center">
  <img src="assets/Smart Contracts_1.png" width="1000" title="Panoptic Banner"></img>
</p>

[![Lint](https://github.com/panoptic-labs/panoptic-v1-core/actions/workflows/lint.yml/badge.svg)](https://github.com/panoptic-labs/panoptic-v1-core/actions/workflows/lint.yml)
[![Tests & Coverage](https://github.com/panoptic-labs/panoptic-v1-core/actions/workflows/main.yml/badge.svg)](https://github.com/panoptic-labs/panoptic-v1-core/actions/workflows/main.yml)

[![Twitter](https://img.shields.io/twitter/url/https/twitter.com/cloudposse.svg?style=social&label=Follow%20%40Panoptic_xyz)](https://twitter.com/panoptic_xyz)

Panoptic is a permissionless options trading protocol. It enables the trading of perpetual options on top of any [Uniswap V3](https://uniswap.org/) pool

The Panoptic protocol is noncustodial, has no counterparty risk, offers instantaneous settlement, and is designed to remain fully collateralized at all times.

- [Panoptic's Website](https://www.panoptic.xyz)
- [Whitepaper](https://paper.panoptic.xyz/)
- [Litepaper](https://intro.panoptic.xyz)
- [Documentation](https://docs.panoptic.xyz/)
- [Twitter](https://twitter.com/Panoptic_xyz)
- [Discord](https://discord.gg/7fE8SN9pRT)
- [Blog](https://www.panoptic.xyz/blog)
- [YouTube](https://www.youtube.com/@Panopticxyz)

## Further Reading

Panoptic has been presented at conferences and was conceived with the first Panoptic's Genesis blog post in mid-summer 2021:

- [Panoptic @ EthCC 2023](https://www.youtube.com/watch?v=9ubpnQRvxY8)
- [Panoptic @ ETH Denver 2023](https://www.youtube.com/watch?v=Dt5AdCNavjs)
- [Panoptic @ ETH Denver 2022](https://www.youtube.com/watch?v=mtd4JphPcuA)
- [Panoptic @ DeFi Guild](https://www.youtube.com/watch?v=vlPIFYfG0FU)
- [Panoptic's Genesis: Blog Series](https://lambert-guillaume.medium.com/)

## Codebase Walkthrough

TBA

## Core Contracts

### SemiFungiblePositionManager

A gas-efficient alternative to Uniswap’s NonFungiblePositionManager that manages complex, multi-leg Uniswap positions encoded in ERC1155 tokenIds, performs swaps allowing users to mint positions with only one type of token, and, most crucially, supports the minting of both typical LP positions where liquidity is added to Uniswap and “long” positions where Uniswap liquidity is burnt. While the SFPM is enshrined as a core component of the protocol and we consider it to be the “engine” of Panoptic, it is also a public good that we hope savvy Uniswap V3 LPs will grow to find an essential tool and upgrade for managing their liquidity.

### CollateralTracker

An ERC4626 vault where token liquidity from passive Panoptic Liquidity Providers (PLPs) and collateral for option positions are deposited. CollateralTrackers are also responsible for paying out commission fees and options premia, handling payments of intrinsic value for options and distributing P&L, calculating liquidation bonuses, and determining costs for forcefully exercising another user’s options. However, by far the most important functionality of the CollateralTracker is to calculate the collateral requirement for every account and position. Each time positions are minted or burned in Panoptic, the CollateralTracker updates the collateral balances and provides information on the collateral requirement, ensuring that the protocol remains solvent and we retain the ability to liquidate distressed positions when needed.

### PanopticPool

The Panoptic Pool exposes the core functionality of the protocol. If the SFPM is the “engine” of Panoptic, the Panoptic Pool is the “conductor”. All interactions with the protocol, be it minting or burning positions, liquidating or force exercising distressed accounts, or just checking position balances and accumulating premiums, originate in this contract. It is responsible for orchestrating the required calls to the SFPM to actually create option positions in Uniswap, tracking user balances of and accumulating the premia on those positions, and calling the CollateralTracker with the data it needs to settle position changes.

## Architecture & Actors

Each instance of the Panoptic protocol on a Uniswap pool contains:

- One PanopticPool that orchestrates all interactions in the protocol
- Two CollateralTrackers, one for each constituent token0/token1 in the Uniswap pool
- A canonical SFPM - the SFPM manages liquidity across every Panoptic Pool

There are five primary roles assumed by actors in this Panoptic Ecosystem:

### Panoptic Liquidity Providers (PLPs)

Users who deposit tokens into one or both CollateralTracker vaults. The liquidity deposited by these users is borrowed by option sellers to create their positions - their liquidity is what enables undercollateralized positions. In return, they receive commission fees on both the notional and intrinsic values of option positions when they are minted. Note that options buyers and sellers are PLPs too - they must deposit collateral to open their positions. We consider users who deposit collateral but do not _trade_ on Panoptic to be “passive” PLPs

### Option Sellers

These users deposit liquidity into the Uniswap pool through Panoptic, making it available for options buyers to remove. This role is similar to providing liquidity directly to Uniswap V3, but offers numerous benefits including advanced tools to manage risky, complex positions and a multiplier on the fees/premia generated by their liquidity when it is removed by option buyers. Sold option positions on Panoptic have similar payoffs to traditional options.

### Option Buyers

These users remove liquidity added by option sellers from the Uniswap Pool and move the tokens back into Panoptic. The premia they pay to sellers for the privilege is equivalent to the fees that would have been generated by the removed liquidity, plus a spread multiplier based on the portion of available liquidity in their Uniswap liquidity chunk that has been removed or utilized.

### Liquidators

These users are responsible for liquidating distressed accounts that no longer meet the collateral requirements needed to maintain their positions. They provide the tokens necessary to close all positions in the distressed account and receive a bonus from the remaining collateral. Sometimes, they may also need to buy or sell options to allow lower liquidity positions to be exercised

### Force Exercisors

These are usually options sellers. They provide the required tokens and forcefully exercise long positions (from option buyers) in out-of-range strikes that are no longer generating premia, so the liquidity from those positions is added back to Uniswap and the sellers can exercise their positions (which involves burning that liquidity). They pay a fee to the exercised user for the inconvenience.

## Flow

All protocol users first onboard by depositing tokens into one or both CollateralTracker vaults and being issued shares (becoming PLPs in the process). Panoptic’s CollateralTracker supports the full ERC4626 interface, making deposits and withdrawals a simple and standardized process. Passive PLPs stop here.

Once they have deposited, there are many options for the other actors in the protocol. Buyers and sellers can call :

- `mintOptions` - create an option position with up to four distinct legs with a specially encoded - positionID/tokenID, each of which is its own short (sold/added) or long (bought/removed) liquidity chunk
- `burnOptions` - burn or exercise a position created through `mintOptions`

Meanwhile, force exercisers and liquidators can perform their respective roles with the `forceExercise` and `liquidateAccount` functions.

## Repository Structure

```ml
contracts/
├── CollateralTracker - "ERC4626 vault where token liquidity from Panoptic Liquidity Providers (PLPs) and collateral for option positions are deposited and collateral requirements are computed"
├── PanopticFactory - "Handles deployment of new Panoptic instances on top of Uniswap pools, initial liquidity deployments, and NFT rewards for deployers"
├── PanopticPool - "Coordinates all options trading activity - minting, burning, force exercises, liquidations"
├── SemiFungiblePositionManager - "The 'engine' of Panoptic - manages all Uniswap V3 positions in the protocol as well as being a more advanced, gas-efficient alternative to NFPM for Uniswap LPs"
├── base
│   ├── FactoryNFT - "Constructs dynamic SVG art and metadata for Panoptic Factory NFTs from a set of building blocks"
│   ├── MetadataStore - "Base contract that can store two-deep objects with large value sizes at deployment time"
│   └── Multicall - "Adds a function to inheriting contracts that allows for multiple calls to be executed in a single transaction"
├── tokens
│   ├── ERC1155Minimal - "A minimalist implementation of the ERC1155 token standard without metadata"
│   ├── ERC20Minimal - "A minimalist implementation of the ERC20 token standard without metadata"
│   └── interfaces
│       └── IERC20Partial - "An incomplete ERC20 interface containing functions used in Panoptic with some return values omitted to support noncompliant tokens such as USDT"
├── types
│   ├── LeftRight - "Implementation for a set of custom data types that can hold two 128-bit numbers"
│   ├── LiquidityChunk - "Implementation for a custom data type that can represent a liquidity chunk of a given size in Uniswap - containing a tickLower, tickUpper, and liquidity"
│   ├── Pointer - "Implementation for a custom data type that represents a pointer to a slice of contract code at an address"
│   ├── PositionBalance - "Implementation for a custom data type that holds a position size, the pool utilizations at mint, and the current/fastOracle/slowOracle/latestObserved ticks at mint"
│   └── TokenId - "Implementation for the custom data type used in the SFPM and Panoptic to encode position data in 256-bit ERC1155 tokenIds - holds a pool identifier and up to four full position legs"
└── libraries
    ├── CallbackLib - "Library for verifying and decoding Uniswap callbacks"
    ├── Constants - "Library of Constants used in Panoptic"
    ├── Errors - "Contains all custom errors used in Panoptic's core contracts"
    ├── FeesCalc - "Utility to calculate up-to-date swap fees for liquidity chunks"
    ├── InteractionHelper - "Helpers to perform bytecode-size-heavy interactions with external contracts like batch approvals and metadata queries"
    ├── Math - "Library of generic math functions like abs(), mulDiv, etc"
    ├── PanopticMath - "Library containing advanced Panoptic/Uniswap-specific functionality such as our TWAP, price conversions, and position sizing math"
    └── SafeTransferLib - "Safe ERC20 transfer library that gracefully handles missing return values"
```

## Installation

Panoptic uses the Foundry framework for testing and deployment, and Prettier for linting.

To get started, clone the repo, install the pre-commit hooks, and compile the metadata with [bun](https://bun.sh):

```bash
git clone https://github.com/panoptic-labs/panoptic-v1-core.git --recurse-submodules
npm i
bun run ./metadata/compiler.js
```

## Testing

Run the Foundry test suite:

```bash
forge test
```

Get a coverage report (requires `genhtml` to be installed):

```bash
forge coverage --report lcov && genhtml lcov.info --branch-coverage --output-dir coverage
```

## Deployment (Release)

Panoptic can also be deployed at a preconfigured set of addresses on mainnet. The canonical initcodes are saved in `deployment-info.json` and can be updated by running the following commands:

```bash
curl -fsSL https://bun.sh/install | bash
pip install eth_abi
python3 build_release.py
```

The configuration file `build-config.json` can be modified with the desired set of addresses and constructor arguments for each contract. The `env`
section contains deployment variables expected to change, such as the `UNIV3_FACTORY` address.

Each `address` and `salt` pair specified by `build-config.json` can be deployed through the `CREATE3` factory at `0x000000000000b361194cfe6312EE3210d53C15AA`. All salts in the current configuration are owned by `vault.panoptic.eth`.

The following command can be run to generate the Safe transaction batches required to deploy Panoptic with the code in `deployment-info.json` from a Safe multisig that owns salts:

```bash
python3 gen_safetx.py
```

The generated batches for each contract will be saved in individual JSON files in the `safe-txns` directory. These can be uploaded to a Gnosis Safe for execution via the "Transaction Builder" app. To ensure an accurate deployment process, each transaction batch should be queued in alphabetical order and checked against `deployment-info.json` for correctness prior to execution.

## Deployment (Legacy)

Panoptic can be deployed on any chain with a Uniswap V3 instance. To go through with the deployment, several environment variables need to be set:

- `DEPLOYER_PRIVATE_KEY` The private key of the EOA deploying the contracts
- `UNISWAP_V3_FACTORY` The address of the Uniswap V3 Factory Panoptic is being deployed on
- `WETH9` The canonical Wrapped Ether deployment on the chain

To deploy Panoptic for testing purposes, run:

```bash
forge script script/DeployProtocol.s.sol:DeployProtocol --rpc-url sepolia -vvvv --broadcast
```

Include the `--verify` flag, after exporting your ETHERSCAN_API_KEY into the environment, to ensure deployed contracts are verified on Etherscan.

The preconfigured RPC URL aliases are: `sepolia`. To deploy on another chain a custom RPC URL can be passed.

## License

The primary license for Panoptic V1 is the Business Source License 1.1 (`BUSL-1.1`), see [LICENSE](https://github.com/panoptic-labs/panoptic-v1-core/blob/main/LICENSE). Minus the following exceptions:

- [Interfaces](./contracts/interfaces), [tokens](./contracts/tokens), and [Multicall.sol](./contracts/multicall/Multicall.sol) have a General Public License
- Some [libraries](./contracts/libraries) and [types](./contracts/types/) have a General Public License
- [Tests](./test/) and some [scripts](./scripts) are unlicensed

Each of these files states their license type.
