# Mocks for Testing

This folder `contracts/test` contain contracts that are used as part of testing our codebase.
They are NOT deployed to production but purely used for development and testing.

We have both mock contracts to mimic behavior of other contracts and also test contracts (prepended with "Test").

The tests have two components to them:

- 1.  all passing tests are written within the test contract itself via `require` statements - called via `runAll()`
- 2.  all failing tests are written in the javascript test file under `test/Libraries/LibraryTest.js` as expected reverts

Separate Foundry tests (also written in Solidity) are under `test/Foundry/*.t.sol`.

# Appendix

## Does this affect Slither?

Note that, when running the Slither Github action, there is a step before calling Slither which removes
this folder (because we don't want to run Slither on these files).
