# Setup Instructions

Throughout this engagement, it is pretty normal to find bugs in our tools (including Echidna, Medusa, and cloudexec) – so we will be keeping track of known workarounds and issues in this readme, and updating this content as releases are pushed.

## Cloudexec

cloudexec allows us to orchestrate jobs to the cloud, allowing fuzzing suites to run for extended periods of time, without needing our involvement. This allows us to deploy fuzzing jobs of various lengths.

1. Run `cloudexec configure` and make sure you replace your username\*
2. Set up the additional API codes as specified in the README

A bug exists in step (1) where cloudexec will try to pull your username containing your email, which contains invalid characters, and results in a malformed request.

## Echidna

Echidna is our primary smart contract fuzzer, which will be exploring state within the contracts, and the main tool used for invariant development. You can find Echidna on brew, if you are on Mac OS – otherwise, you can also find instructions to build from source or to [download binaries on our Echidna repository](https://github.com/crytic/echidna).

```bash
brew install echidna
```

We are currently also testing an in-progress [PR#1228](https://github.com/crytic/echidna/pull/1228), which provides bug fixes for a [bottleneck issues described here](https://github.com/crytic/echidna/issues/1207). More testing is required to switch to this branch first, however preliminary investigations show larger improvement.

## Medusa

Medusa is our beta smart contract fuzzer, built off of go-ethereum. Medusa's value generation, state exploration, and mainnet forking are limited, however it can be a fantastic asset for stateless fuzzing.

You can find [installation instructions for Medusa here.](https://github.com/crytic/medusa)

# Running the tests

To execute the test harness using the provided Makefile, run:

```bash
make echidna
```

Alternatively, you can invoke echidna directly from the command line, specifying the configuration file to be used and the contract to be fuzzed:

```bash
echidna . --contract ContractName --config path/to/config.yaml
```

This allows you to have different configuration files for different tests, for example, you could fuzz the whole FuzzDeployments contract:

```bash
echidna . --contract EchidnaWrapper --config contracts/fuzz/echidna.yaml
```
