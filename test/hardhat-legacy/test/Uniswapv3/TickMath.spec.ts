import { BigNumber } from "ethers";
import { ethers } from "hardhat";
import { TickMathTest } from "../../typechain/contracts/uniswapv3_core/contracts/test/TickMathTest";
import { expect } from "./shared/expect";
import snapshotGasCost from "./shared/snapshotGasCost";
import { encodePriceSqrt, MIN_SQRT_RATIO, MAX_SQRT_RATIO } from "./shared/utilities";
import Decimal from "decimal.js";

const MIN_TICK = -887272;
const MAX_TICK = 887272;

Decimal.config({ toExpNeg: -500, toExpPos: 500 });

describe("TickMath", () => {
  let tickMath: TickMathTest;

  before("deploy TickMathTest", async () => {
    const factory = await ethers.getContractFactory("TickMathTest");
    tickMath = (await factory.deploy()) as TickMathTest;
  });

  describe("#getSqrtRatioAtTick", () => {
    it("throws for too low", async () => {
      await expect(tickMath.getSqrtRatioAtTick(MIN_TICK - 1)).to.be.revertedWith("T");
    });

    it("throws for too low", async () => {
      await expect(tickMath.getSqrtRatioAtTick(MAX_TICK + 1)).to.be.revertedWith("T");
    });

    it("min tick", async () => {
      expect(await tickMath.getSqrtRatioAtTick(MIN_TICK)).to.eq("4295128739");
    });

    it("min tick +1", async () => {
      expect(await tickMath.getSqrtRatioAtTick(MIN_TICK + 1)).to.eq("4295343490");
    });

    it("max tick - 1", async () => {
      expect(await tickMath.getSqrtRatioAtTick(MAX_TICK - 1)).to.eq(
        "1461373636630004318706518188784493106690254656249"
      );
    });

    it("min tick ratio is less than js implementation", async () => {
      expect(await tickMath.getSqrtRatioAtTick(MIN_TICK)).to.be.lt(
        encodePriceSqrt(1, BigNumber.from(2).pow(127))
      );
    });

    it("max tick ratio is greater than js implementation", async () => {
      expect(await tickMath.getSqrtRatioAtTick(MAX_TICK)).to.be.gt(
        encodePriceSqrt(BigNumber.from(2).pow(127), 1)
      );
    });

    it("max tick", async () => {
      expect(await tickMath.getSqrtRatioAtTick(MAX_TICK)).to.eq(
        "1461446703485210103287273052203988822378723970342"
      );
    });

    for (const absTick of [
      50, 100, 250, 500, 1_000, 2_500, 3_000, 4_000, 5_000, 50_000, 150_000, 250_000, 500_000,
      738_203,
    ]) {
      for (const tick of [-absTick, absTick]) {
        describe(`tick ${tick}`, () => {
          it("is at most off by 1/100th of a bips", async () => {
            const jsResult = new Decimal(1.0001).pow(tick).sqrt().mul(new Decimal(2).pow(96));
            const result = await tickMath.getSqrtRatioAtTick(tick);
            const absDiff = new Decimal(result.toString()).sub(jsResult).abs();
            expect(absDiff.div(jsResult).toNumber()).to.be.lt(0.000001);
          });
          it("result", async () => {
            expect((await tickMath.getSqrtRatioAtTick(tick)).toString()).to.matchSnapshot();
          });
          it("gas", async () => {
            await snapshotGasCost(tickMath.getGasCostOfGetSqrtRatioAtTick(tick));
          });
        });
      }
    }
  });

  describe("#MIN_SQRT_RATIO", async () => {
    it("equals #getSqrtRatioAtTick(MIN_TICK)", async () => {
      const min = await tickMath.getSqrtRatioAtTick(MIN_TICK);
      expect(min).to.eq(await tickMath.MIN_SQRT_RATIO());
      expect(min).to.eq(MIN_SQRT_RATIO);
    });
  });

  describe("#MAX_SQRT_RATIO", async () => {
    it("equals #getSqrtRatioAtTick(MAX_TICK)", async () => {
      const max = await tickMath.getSqrtRatioAtTick(MAX_TICK);
      expect(max).to.eq(await tickMath.MAX_SQRT_RATIO());
      expect(max).to.eq(MAX_SQRT_RATIO);
    });
  });
});
