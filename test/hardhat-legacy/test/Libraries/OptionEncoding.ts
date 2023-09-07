/**
 * Helper function to encode Options Id.
 * @author Axicon Labs Limited
 * @year 2022
 */
type OptionConfig = {
  width: number;
  strike: number;
  riskPartner: number;
  ratio: number;
  asset: number;
  tokenType: number;
  long: boolean;
};
export const convertStrike = (n: number) => {
  if (n < 0) {
    // 3 bytes because strike is int24
    return 16777216 + n;
  } else {
    return n;
  }
};

export const encodeID = (poolId: bigint, data: OptionConfig[]) =>
  data.reduce((acc, { width, strike, riskPartner, tokenType, long, ratio, asset }, i) => {
    const _tmp = i * 48;
    return (
      acc +
      (BigInt(width) << BigInt(_tmp + 100)) +
      (BigInt(convertStrike(strike)) << BigInt(_tmp + 76)) +
      (BigInt(riskPartner) << BigInt(_tmp + 74)) +
      (BigInt(tokenType) << BigInt(_tmp + 73)) +
      (BigInt(long ? 1 : 0) << BigInt(_tmp + 72)) +
      (BigInt(ratio) << BigInt(_tmp + 65)) +
      (BigInt(asset) << BigInt(_tmp + 64))
    );
  }, poolId);
