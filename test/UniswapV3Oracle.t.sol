// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {UniswapV3Oracle} from "../src/oracles/UniswapV3Oracle.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IUniswapPool} from "../src/interfaces/IUniswapPool.sol";
import {MockUniswapPool} from "./mocks/MockUniswapPool.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

struct Params {
    IUniswapPool pool;
    address token;
    address owner;
    uint16 multiplier;
    uint32 secs;
    uint32 ago;
    uint128 minPrice;
}

contract UniswapOracleTest is Test {
    using stdStorage for StdStorage;

    // mock config
    Params _mock;
    MockUniswapPool mockV3Pool;
    // observation on 2023-09-20 11:26 UTC-3, UNIWETH Ethereum Pool
    int56[2] sampleCumulatives = [int56(-4072715107990), int56(-4072608557758)];
    // expected price in terms of token0
    uint256 expectedPriceToken0 = 372078200928347021722;

    string OPTIMISM_RPC_URL = vm.envString("OPTIMISM_RPC_URL");
    uint32 FORK_BLOCK = 112198905;
    
    address SWAP_ROUTER_ADDRESS = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address WETH_OP_POOL_ADDRESS = 0x68F5C0A2DE713a54991E01858Fd27a3832401849;
    address OP_ADDRESS = 0x4200000000000000000000000000000000000042;
    address WETH_ADDRESS = 0x4200000000000000000000000000000000000006;
    uint24 POOL_FEE = 3000;

    uint256 opFork;

    ISwapRouter swapRouter;
    Params _default;

    function setUp() public {
        mockV3Pool = new MockUniswapPool();
        mockV3Pool.setCumulatives(sampleCumulatives);
        mockV3Pool.setToken0(OP_ADDRESS);

        _default = Params(IUniswapPool(WETH_OP_POOL_ADDRESS), OP_ADDRESS, address(this), 10000, 30 minutes, 0, 1000);
        swapRouter = ISwapRouter(SWAP_ROUTER_ADDRESS);
    }

    /// ----------------------------------------------------------------------
    /// Mock tests
    /// ----------------------------------------------------------------------

    function test_PriceToken0() public {
        UniswapV3Oracle oracle = new UniswapV3Oracle(
            mockV3Pool,
            OP_ADDRESS,
            _default.owner,
            _default.multiplier,
            _default.secs,
            _default.ago,
            _default.minPrice
        );

        uint256 price = oracle.getPrice();
        assertEq(price, expectedPriceToken0);
    }

    function test_PriceToken1() public {
        UniswapV3Oracle oracle = new UniswapV3Oracle(
            mockV3Pool,
            address(0),
            _default.owner,
            _default.multiplier,
            _default.secs,
            _default.ago,
            _default.minPrice
        );

        uint256 price = oracle.getPrice();
        uint256 expectedPriceToken1 = price = FixedPointMathLib.divWadUp(1e18, price);
        assertEq(price, expectedPriceToken1);
    }

    function test_PriceToken0Multiplier() public {
        uint16 multiplier = 5000;
        UniswapV3Oracle oracle = new UniswapV3Oracle(
            mockV3Pool,
            _default.token,
            _default.owner,
            multiplier,
            _default.secs,
            _default.ago,
            _default.minPrice
        );

        uint256 price = oracle.getPrice();
        uint256 expectedPriceWithMultiplier = FixedPointMathLib.mulDivUp(expectedPriceToken0, multiplier, 10000);
        assertEq(price, expectedPriceWithMultiplier);
    }

    /// ----------------------------------------------------------------------
    /// Fork tests
    /// ----------------------------------------------------------------------

    function test_priceWithinAcceptableRange() public {
        opFork = vm.createSelectFork(OPTIMISM_RPC_URL, FORK_BLOCK);

        UniswapV3Oracle oracle = new UniswapV3Oracle(
            _default.pool,
            _default.token,
            _default.owner,
            _default.multiplier,
            _default.secs,
            _default.ago,
            _default.minPrice
        );

        uint oraclePrice = oracle.getPrice();

        (uint160 sqrtRatioX96,,,,,,) = IUniswapV3Pool(WETH_OP_POOL_ADDRESS).slot0();
        uint256 spotPrice = computePriceFromX96(sqrtRatioX96);
        assertApproxEqRel(oraclePrice, spotPrice, 0.01 ether, "Price delta too big"); // 1%
    }

    function test_priceManipulation() public {
        opFork = vm.createSelectFork(OPTIMISM_RPC_URL, FORK_BLOCK);

        UniswapV3Oracle oracle = new UniswapV3Oracle(
            _default.pool,
            _default.token,
            _default.owner,
            _default.multiplier,
            _default.secs,
            _default.ago,
            _default.minPrice
        );

        address manipulator1 = makeAddr("manipulator");
        deal(OP_ADDRESS, manipulator1, 1000000 ether);

        // register initial oracle price
        uint256 price_1 = oracle.getPrice();

        // perform a large swap
        vm.startPrank(manipulator1);
        ISwapRouter.ExactInputSingleParams memory paramsIn =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: OP_ADDRESS,
                tokenOut: WETH_ADDRESS,
                fee: POOL_FEE,
                recipient: manipulator1,
                deadline: block.timestamp,
                amountIn: 1000000 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
        IERC20(OP_ADDRESS).approve(address(swapRouter), 1000000 ether);
        uint amountOut = swapRouter.exactInputSingle(paramsIn);
        vm.stopPrank();

        // wait 60 seconds
        skip(1 minutes);
        
        // perform additional, smaller swap
        address manipulator2 = makeAddr("manipulator");
        deal(OP_ADDRESS, manipulator2, amountOut);
        vm.startPrank(manipulator2);
        ISwapRouter.ExactInputSingleParams memory paramsOut =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: OP_ADDRESS,
                tokenOut: WETH_ADDRESS,
                fee: POOL_FEE,
                recipient: manipulator1,
                deadline: block.timestamp,
                amountIn: amountOut / 100, // perform small swap
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
        IERC20(OP_ADDRESS).approve(address(swapRouter), amountOut / 100);
        swapRouter.exactInputSingle(paramsOut);
        
        assertApproxEqRel(price_1, oracle.getPrice(), 0.01 ether, "price variance too large");
    }

    function computePriceFromX96(uint160 sqrtRatioX96) internal view returns (uint256 price) {
        bool isToken0 = OP_ADDRESS == IUniswapV3Pool(WETH_OP_POOL_ADDRESS).token0();
        uint decimals = 1e18;

        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            price = isToken0
                ? FullMath.mulDiv(ratioX192, decimals, 1 << 192)
                : FullMath.mulDiv(1 << 192, decimals, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            price = isToken0
                ? FullMath.mulDiv(ratioX128, decimals, 1 << 128)
                : FullMath.mulDiv(1 << 128, decimals, ratioX128);
        }
    }

}
