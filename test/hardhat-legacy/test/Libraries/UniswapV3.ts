/**
 * Helper to interact with Uniswap V3.
 * @author Axicon Labs Limited
 * @year 2022
 */
import { BigNumber } from "ethers";
import { deployments, ethers } from "hardhat";

export const priceFromTick = (tick: number) => {
  return 1.0001 ** tick;
};

export const sqrtPriceFromTick = (tick: number) => {
  let price = Math.pow(1.0001, tick);
  return ethers.BigNumber.from(Math.floor(Math.sqrt(price)));
};

export const getAmount0ForLiquidity = (
  liquidity: BigNumber,
  paSqrt: BigNumber,
  pbSqrt: BigNumber
) => {
  return liquidity.mul(pbSqrt.sub(paSqrt)).div(paSqrt.mul(pbSqrt));
};

export const getAmount0ForPriceRange = (liquidity: BigNumber, tick: number, targetTick: number) => {
  const pa = priceFromTick(tick);
  const pb = priceFromTick(targetTick);
  const paSqrt = sqrtPriceFromTick(tick);
  const pbSqrt = sqrtPriceFromTick(targetTick);

  return getAmount0ForLiquidity(liquidity, paSqrt, pbSqrt);
};

export const getAmount1ForLiquidity = (
  liquidity: BigNumber,
  paSqrt: BigNumber,
  pbSqrt: BigNumber
) => {
  return liquidity.mul(pbSqrt.sub(paSqrt));
};

export const getAmount1ForPriceRange = (liquidity: BigNumber, tick: number, targetTick: number) => {
  const paSqrt = sqrtPriceFromTick(tick);
  const pbSqrt = sqrtPriceFromTick(targetTick);

  return getAmount1ForLiquidity(liquidity, paSqrt, pbSqrt);
};
