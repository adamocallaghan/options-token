// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {ThenaOracle} from "../src/oracles/ThenaOracle.sol";
import {IThenaPair} from "../src/interfaces/IThenaPair.sol";
import {IThenaRouter} from "./interfaces/IThenaRouter.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

struct Params {
    IThenaPair pair;
    address token;
    address owner;
    uint16 multiplier;
    uint32 secs;
    uint128 minPrice;
}

contract ThenaOracleTest is Test {
    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;

    string BSC_RPC_URL = vm.envString("BSC_RPC_URL");
    uint32 FORK_BLOCK = 33672842;
    
    address POOL_ADDRESS = 0x63Db6ba9E512186C2FAaDaCEF342FB4A40dc577c;
    address TOKEN_ADDRESS = 0x4d2d32d8652058Bf98c772953E1Df5c5c85D9F45;
    address PAYMENT_TOKEN_ADDRESS = 0x55d398326f99059fF775485246999027B3197955;
    address THENA_ROUTER = 0xd4ae6eCA985340Dd434D38F470aCCce4DC78D109;

    uint MULTIPLIER_DENOM = 10000;

    uint256 bscFork;

    Params _default;

    function setUp() public {
        _default = Params(IThenaPair(POOL_ADDRESS), TOKEN_ADDRESS, address(this), 10000, 30 minutes, 1000);
        bscFork = vm.createSelectFork(BSC_RPC_URL, FORK_BLOCK);
    }

    function test_priceWithinAcceptableRange() public {

        ThenaOracle oracle = new ThenaOracle(
            _default.pair,
            _default.token,
            _default.owner,
            _default.multiplier,
            _default.secs,
            _default.minPrice
        );

        uint oraclePrice = oracle.getPrice();

        uint256 spotPrice = getSpotPrice(_default.pair, _default.token);
        assertApproxEqRel(oraclePrice, spotPrice, 0.01 ether, "Price delta too big"); // 1%
    }

    function test_priceToken1() public {

        ThenaOracle oracleToken0 = new ThenaOracle(
            _default.pair,
            IThenaPair(_default.pair).token0(),
            _default.owner,
            _default.multiplier,
            _default.secs,
            _default.minPrice
        );
        
        ThenaOracle oracleToken1 = new ThenaOracle(
            _default.pair,
            IThenaPair(_default.pair).token1(),
            _default.owner,
            _default.multiplier,
            _default.secs,
            _default.minPrice
        );

        uint priceToken0 = oracleToken0.getPrice();
        uint priceToken1 = oracleToken1.getPrice();

        assertEq(priceToken1, uint256(1e18).divWadDown(priceToken0), "incorrect price"); // 1%
    }

    function test_priceMultiplier(uint multiplier) public {
        multiplier = bound(multiplier, 0, 10000);

        ThenaOracle oracle0 = new ThenaOracle(
            _default.pair,
            _default.token,
            _default.owner,
            _default.multiplier,
            _default.secs,
            _default.minPrice
        );
        
        ThenaOracle oracle1 = new ThenaOracle(
            _default.pair,
            _default.token,
            _default.owner,
            uint16(multiplier),
            _default.secs,
            _default.minPrice
        );

        uint price0 = oracle0.getPrice();
        uint price1 = oracle1.getPrice();

        uint expectedPrice = max(
            price0.mulDivUp(multiplier, MULTIPLIER_DENOM),
            _default.minPrice
        );

        assertEq(price1, expectedPrice, "incorrect price multiplier"); // 1%
    }

    function test_priceManipulation() public {
        ThenaOracle oracle = new ThenaOracle(
            _default.pair,
            _default.token,
            _default.owner,
            _default.multiplier,
            _default.secs,
            _default.minPrice
        );

        address manipulator1 = makeAddr("manipulator");
        deal(TOKEN_ADDRESS, manipulator1, 1000000 ether);

        // register initial oracle price
        uint256 price_1 = oracle.getPrice();

        // perform a large swap
        vm.startPrank(manipulator1);
        IERC20(TOKEN_ADDRESS).approve(THENA_ROUTER, 1000000 ether);

        (uint256 reserve0, uint256 reserve1,) = _default.pair.getReserves();
        (uint256[] memory amountOut) = IThenaRouter(THENA_ROUTER).swapExactTokensForTokensSimple(
            (TOKEN_ADDRESS == _default.pair.token0() ? reserve0 : reserve1) / 10,
            0,
            TOKEN_ADDRESS,
            PAYMENT_TOKEN_ADDRESS,
            false,
            manipulator1,
            type(uint32).max
        );
        vm.stopPrank();

        // price should not have changed
        assertEq(oracle.getPrice(), price_1);

        // wait 60 seconds
        skip(1 minutes);
        
        // perform additional, smaller swap
        address manipulator2 = makeAddr("manipulator2");
        deal(PAYMENT_TOKEN_ADDRESS, manipulator2, amountOut[0] / 1000);
        vm.startPrank(manipulator2);
        IERC20(PAYMENT_TOKEN_ADDRESS).approve(THENA_ROUTER, 1000000 ether);

        IThenaRouter(THENA_ROUTER).swapExactTokensForTokensSimple(
            amountOut[0] / 1000,
            0,
            PAYMENT_TOKEN_ADDRESS,
            TOKEN_ADDRESS,
            false,
            manipulator2,
            type(uint32).max
        );
        vm.stopPrank();
        
        assertApproxEqRel(price_1, oracle.getPrice(), 0.01 ether, "price variance too large");
    }

    function getSpotPrice(IThenaPair pair, address token) internal view returns (uint256 price) {
        bool isToken0 = token == pair.token0();
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (isToken0) {
            price = uint256(reserve1).divWadDown(reserve0); 
        } else {
            price = uint256(reserve0).divWadDown(reserve1); 
        }
    }

    function max(uint x, uint y) internal pure returns (uint z) {
        z = x > y ? x : y;
    }

}
