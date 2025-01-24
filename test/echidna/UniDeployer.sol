// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./fuzz-mocks/MockERC20.sol";
import {UniswapV3Pool} from "univ3-core/UniswapV3Pool.sol";
import {UniswapV3Factory} from "univ3-core/UniswapV3Factory.sol";

contract SetupToken {
    MockERC20 public token;

    constructor() {
        token = new MockERC20(type(uint248).max);
    }

    function mintTo(address _recipient, uint256 _amount) public {
        token.transfer(_recipient, _amount);
    }
}

contract SetupTokens {
    SetupToken tokenSetup0;
    SetupToken tokenSetup1;

    MockERC20 public token0;
    MockERC20 public token1;

    constructor() {
        // create the token wrappers
        tokenSetup0 = new SetupToken();
        tokenSetup1 = new SetupToken();

        // switch them around so that token0's address is lower than token1's
        // since this is what the uniswap factory will do when you create the pool
        if (address(tokenSetup0.token()) > address(tokenSetup1.token())) {
            (tokenSetup0, tokenSetup1) = (tokenSetup1, tokenSetup0);
        }

        // save the erc20 tokens
        token0 = tokenSetup0.token();
        token1 = tokenSetup1.token();
    }

    // mint either token0 or token1 to a chosen account
    function mintTo(uint256 _tokenIdx, address _recipient, uint256 _amount) public {
        require(_tokenIdx == 0 || _tokenIdx == 1, "invalid token idx");
        if (_tokenIdx == 0) tokenSetup0.mintTo(_recipient, _amount);
        if (_tokenIdx == 1) tokenSetup1.mintTo(_recipient, _amount);
    }
}

contract SetupUniswap {
    uint256 poolIndex;
    mapping(uint256 => UniswapV3Pool) public pools;

    MockERC20 token0;
    MockERC20 token1;

    UniswapV3Factory public factory;

    constructor(MockERC20 _token0, MockERC20 _token1) {
        factory = new UniswapV3Factory();
        token0 = _token0;
        token1 = _token1;
        factory.enableFeeAmount(100, 1);
    }

    function createPool(uint24 _fee, uint160 _startPrice) public returns (UniswapV3Pool pool) {
        pools[poolIndex] = UniswapV3Pool(
            factory.createPool(address(token0), address(token1), _fee)
        );
        pools[poolIndex].initialize(_startPrice);
        poolIndex++;

        return pools[poolIndex - 1];
    }
}

contract UniswapMinter {
    event LogStr(string);
    event LogUint(string, uint256);

    UniswapV3Pool pool;
    MockERC20 token0;
    MockERC20 token1;

    struct MinterStats {
        uint128 liq;
        uint128 tL_liqGross;
        int128 tL_liqNet;
        uint128 tU_liqGross;
        int128 tU_liqNet;
    }

    constructor(MockERC20 _token0, MockERC20 _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPool(UniswapV3Pool _pool) public {
        pool = _pool;
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata
    ) external {
        if (amount0Owed > 0) token0.transfer(address(pool), amount0Owed);
        if (amount1Owed > 0) token1.transfer(address(pool), amount1Owed);
    }

    function getTickLiquidityVars(
        int24 _tickLower,
        int24 _tickUpper
    ) internal view returns (uint128, int128, uint128, int128) {
        (uint128 tL_liqGross, int128 tL_liqNet, , , , , , ) = pool.ticks(_tickLower);
        (uint128 tU_liqGross, int128 tU_liqNet, , , , , , ) = pool.ticks(_tickUpper);
        return (tL_liqGross, tL_liqNet, tU_liqGross, tU_liqNet);
    }

    function getStats(
        int24 _tickLower,
        int24 _tickUpper
    ) internal view returns (MinterStats memory stats) {
        (uint128 tL_lg, int128 tL_ln, uint128 tU_lg, int128 tU_ln) = getTickLiquidityVars(
            _tickLower,
            _tickUpper
        );
        return MinterStats(pool.liquidity(), tL_lg, tL_ln, tU_lg, tU_ln);
    }

    function doMint(
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _amount
    ) public returns (MinterStats memory bfre, MinterStats memory aftr) {
        bfre = getStats(_tickLower, _tickUpper);
        pool.mint(address(this), _tickLower, _tickUpper, _amount, new bytes(0));
        aftr = getStats(_tickLower, _tickUpper);
    }

    function doBurn(
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _amount
    ) public returns (MinterStats memory bfre, MinterStats memory aftr) {
        bfre = getStats(_tickLower, _tickUpper);
        pool.burn(_tickLower, _tickUpper, _amount);
        aftr = getStats(_tickLower, _tickUpper);
    }
}

contract UniswapSwapper {
    UniswapV3Pool pool;
    MockERC20 token0;
    MockERC20 token1;

    struct SwapperStats {
        uint128 liq;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint256 bal0;
        uint256 bal1;
        int24 tick;
    }

    constructor(MockERC20 _token0, MockERC20 _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPool(UniswapV3Pool _pool) public {
        pool = _pool;
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata
    ) external {
        if (amount0Delta > 0) token0.transfer(address(pool), uint256(amount0Delta));
        if (amount1Delta > 0) token1.transfer(address(pool), uint256(amount1Delta));
    }

    function getStats() internal view returns (SwapperStats memory stats) {
        (, int24 currentTick, , , , , ) = pool.slot0();
        return
            SwapperStats(
                pool.liquidity(),
                pool.feeGrowthGlobal0X128(),
                pool.feeGrowthGlobal1X128(),
                token0.balanceOf(address(this)),
                token1.balanceOf(address(this)),
                currentTick
            );
    }

    function doSwap(
        bool _zeroForOne,
        int256 _amountSpecified,
        uint160 _sqrtPriceLimitX96
    ) public returns (SwapperStats memory bfre, SwapperStats memory aftr) {
        bfre = getStats();
        pool.swap(address(this), _zeroForOne, _amountSpecified, _sqrtPriceLimitX96, new bytes(0));
        aftr = getStats();
    }
}

contract UniDeployer {
    event LogStr(string);

    // 0.01%, 0.05%, 0.30%, and 1%
    // 1bps, 5bps, 30bps, 100bps
    UniswapV3Pool[4] public pools;

    // pools by fee tier
    UniswapV3Pool public pool1bps;
    UniswapV3Pool public pool5bps;
    UniswapV3Pool public pool30bps;
    UniswapV3Pool public pool100bps;

    // setup by fee tier
    SetupUniswap internal su;

    MockERC20 public token0;
    MockERC20 public token1;
    UniswapV3Factory public factory;

    SetupTokens internal st;
    UniswapMinter internal minter;

    constructor() {
        st = new SetupTokens();
        token0 = MockERC20(st.token0());
        token1 = MockERC20(st.token1());

        minter = new UniswapMinter(token0, token1);
        st.mintTo(0, address(minter), type(uint128).max);
        st.mintTo(1, address(minter), type(uint128).max);

        su = new SetupUniswap(token0, token1);

        factory = su.factory();

        /// 1bps
        pool1bps = su.createPool(100, 1446468563022924011445331901284352);
        minter.setPool(pool1bps);
        minter.doMint(-887272, 887272, 1e18);

        /// 5bps
        pool5bps = su.createPool(500, 1446468563022924011445331901284352);
        minter.setPool(pool5bps);
        minter.doMint(-887270, 887270, 1e18);

        /// 30bps
        pool30bps = su.createPool(3000, 1446468563022924011445331901284352);
        minter.setPool(pool30bps);
        minter.doMint(-887220, 887220, 1e18);

        /// 100bps
        pool100bps = su.createPool(10000, 1446468563022924011445331901284352);
        minter.setPool(pool100bps);
        minter.doMint(-887200, 887200, 1e18);

        pools = [pool1bps, pool5bps, pool30bps, pool100bps];
    }

    function mintToken(bool mintToken1, address recipient, uint256 amt) public {
        st.mintTo(mintToken1 ? 1 : 0, recipient, amt);
    }

    function getPools() public view returns (UniswapV3Pool[4] memory) {
        return pools;
    }
}
