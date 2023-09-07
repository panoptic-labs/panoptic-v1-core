/**
 * Test Libraries under `contracts/libraries`.
 *
 * @author Axicon Labs Limited
 * @year 2022
 */
const { deployments, ethers } = require("hardhat");
const { expect } = require("chai");
const { revertCustom } = require("../utils");

describe("Test TokenId Library", function () {
  const contractName = "TestTokenId"; // see contracts/test
  let testTokenId;

  before(async () => {
    await deployments.fixture([contractName]);
    const { address } = await deployments.get(contractName);

    testTokenId = await ethers.getContractAt(contractName, address);
  });

  it("should deploy the tokenId test", async function () {
    expect(testTokenId.address).to.be.not.undefined;
  });

  it("should pass all tests", async function () {
    await testTokenId.runAll();
  });

  it("should fail as expected", async () => {
    // handle the failing tests separately
    await expect(testTokenId.testFailExpectEqual()).to.be.reverted;
    await expect(testTokenId.testAsTicksMIN()).to.be.reverted;
    await expect(testTokenId.testAsTicksMAX()).to.be.reverted;
    await expect(testTokenId.testOptionRollFail()).to.be.revertedWith(
      revertCustom("NotAnOptionRoll()")
    );
    await expect(testTokenId.testValidateExercisedIdFail_part1()).to.be.reverted;
    await expect(testTokenId.testValidateExercisedIdFail_part2()).to.be.reverted;
    await expect(testTokenId.testValidateFail_part1()).to.be.revertedWith(
      revertCustom("InvalidTokenIdParameter(3)")
    );
    await expect(testTokenId.testValidateFail_part2()).to.be.revertedWith(
      revertCustom("InvalidTokenIdParameter(21)")
    );
    await expect(testTokenId.testValidateFail_part3()).to.be.revertedWith(
      revertCustom("InvalidTokenIdParameter(3)")
    );
    await expect(testTokenId.testValidateFail_part4()).to.be.revertedWith(
      revertCustom("InvalidTokenIdParameter(4)")
    );
  });
});

describe("Test LeftRight Library", function () {
  const contractName = "TestLeftRight"; // see contracts/test
  let testLeftRight;

  before(async () => {
    await deployments.fixture([contractName]);
    const { address } = await deployments.get(contractName);

    testLeftRight = await ethers.getContractAt(contractName, address);
  });

  it("should deploy the test", async function () {
    expect(testLeftRight.address).to.be.not.undefined;
  });

  it("should pass all tests", async function () {
    await expect(testLeftRight.runAll()).to.not.be.reverted;

    // reverting tests next
    await expect(testLeftRight.revertsWithNegativeValue()).to.be.reverted;
    await expect(testLeftRight.revertsOnOverflowLeft()).to.be.reverted;
    await expect(testLeftRight.revertsOnOverflowRight()).to.be.reverted;
    await expect(testLeftRight.revertsOnOverflowDowncast()).to.be.reverted;
    await expect(testLeftRight.revertsOnOverflowCast()).to.be.reverted;
    await expect(testLeftRight.toUint128Fail()).to.be.reverted;
    await expect(testLeftRight.toInt256Fail()).to.be.reverted;
    await expect(testLeftRight.addUint256FailX()).to.be.reverted;
    await expect(testLeftRight.addUint256FailY()).to.be.reverted;
    await expect(testLeftRight.subUint256Fail()).to.be.reverted;
    await expect(testLeftRight.mulUint256FailX()).to.be.reverted;
    await expect(testLeftRight.mulUint256FailY()).to.be.reverted;
    await expect(testLeftRight.mulUint256FailZeroX()).to.be.reverted;
    await expect(testLeftRight.mulUint256FailZeroY()).to.be.reverted;
    await expect(testLeftRight.divUint256Fail()).to.be.reverted;
    await expect(testLeftRight.addInt256FailX()).to.be.reverted;
    await expect(testLeftRight.addInt256FailY()).to.be.reverted;
    await expect(testLeftRight.addInt256FailNegX()).to.be.reverted;
    await expect(testLeftRight.addInt256FailNegY()).to.be.reverted;
    await expect(testLeftRight.subInt256Fail()).to.be.reverted;
    await expect(testLeftRight.subInt256FailNeg()).to.be.reverted;
    await expect(testLeftRight.mulInt256FailX()).to.be.reverted;
    await expect(testLeftRight.mulInt256FailY()).to.be.reverted;
    await expect(testLeftRight.mulInt256FailXNeg()).to.be.reverted;
    await expect(testLeftRight.mulInt256FailYNeg()).to.be.reverted;
    await expect(testLeftRight.divInt256Fail()).to.be.reverted;
    await expect(testLeftRight.divInt256Fail_part2()).to.be.reverted;
    await expect(testLeftRight.mulUint256FailRightSlot()).to.be.reverted;
    await expect(testLeftRight.addUint256Int256FailX()).to.be.revertedWith(
      revertCustom("UnderOverFlow()")
    );
    await expect(testLeftRight.addUint256Int256FailY()).to.be.revertedWith(
      revertCustom("UnderOverFlow()")
    );
    await expect(testLeftRight.addUint256Int256FailRight()).to.be.revertedWith(
      revertCustom("UnderOverFlow()")
    );
    await expect(testLeftRight.addUint256Int256FailLeft()).to.be.revertedWith(
      revertCustom("UnderOverFlow()")
    );
  });
});

describe("Test TickLimits", function () {
  const contractName = "TestTickLimits"; // see contracts/test
  let testTickLimits;

  before(async () => {
    await deployments.fixture([contractName]);
    const { address } = await deployments.get(contractName);

    testTickLimits = await ethers.getContractAt(contractName, address);
  });

  it("should deploy the test", async function () {
    expect(testTickLimits.address).to.be.not.undefined;
  });

  it("should pass all tests", async function () {
    await expect(testTickLimits.runAll()).to.not.be.reverted;
  });
});

describe("Test LiquidityChunk", function () {
  const contractName = "TestLiquidityChunk"; // see contracts/test
  let testLiquidityChunk;

  before(async () => {
    await deployments.fixture([contractName]);
    const { address } = await deployments.get(contractName);

    testLiquidityChunk = await ethers.getContractAt(contractName, address);
  });

  it("should deploy the test", async function () {
    expect(testLiquidityChunk.address).to.be.not.undefined;
  });

  it("should pass all tests", async function () {
    await expect(testLiquidityChunk.runAll()).to.not.be.reverted;
  });
});

describe("Test TickPriceFeeInfo", function () {
  const contractName = "TestTickPriceFeeInfo"; // see contracts/test
  let testTickPriceFeeInfo;

  before(async () => {
    await deployments.fixture([contractName]);
    const { address } = await deployments.get(contractName);

    testTickPriceFeeInfo = await ethers.getContractAt(contractName, address);
  });

  it("should deploy the test", async function () {
    expect(testTickPriceFeeInfo.address).to.be.not.undefined;
  });

  it("should pass all tests", async function () {
    await expect(testTickPriceFeeInfo.runAll()).to.not.be.reverted;
  });
});

describe("Test Math", function () {
  const contractName = "TestMath"; // see contracts/test
  let testMath;

  before(async () => {
    await deployments.fixture([contractName]);
    const { address } = await deployments.get(contractName);

    testMath = await ethers.getContractAt(contractName, address);
  });

  it("should deploy the test", async function () {
    expect(testMath.address).to.be.not.undefined;
  });

  it("should pass all tests", async function () {
    await expect(testMath.runAll()).to.not.be.reverted;
  });

  it("should fail as expected", async function () {
    await expect(testMath.testCastToUint128Fail()).to.be.reverted;
    await expect(testMath.testToInt128fail()).to.be.reverted;
    await expect(testMath.testAbsInt256Fail()).to.be.reverted;
  });
});

describe("Test PanopticMath", function () {
  const contractName = "TestPanopticMath"; // see contracts/test
  let testPanopticMath;

  before(async () => {
    await deployments.fixture([contractName]);
    const { address } = await deployments.get(contractName);

    testPanopticMath = await ethers.getContractAt(contractName, address);
  });

  it("should deploy the test", async function () {
    expect(testPanopticMath.address).to.be.not.undefined;
  });

  it("should pass all tests", async function () {
    await expect(testPanopticMath.runAll()).to.not.be.reverted;
  });

  it("should fail as expected", async function () {
    await expect(testPanopticMath.testFailConvertToTokenValue()).to.be.reverted;
  });
});
