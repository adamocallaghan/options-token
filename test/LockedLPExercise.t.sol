// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";

import {OptionsToken} from "../src/OptionsToken.sol";
import {LockedExerciseParams, LockedExercise, BaseExercise} from "../src/exercise/LockedLPExercise.sol";

import {ThenaOracle} from "../src/oracles/ThenaOracle.sol";
import {IThenaPair} from "../src/interfaces/IThenaPair.sol";
import {IThenaRouter} from "./interfaces/IThenaRouter.sol";
import {IPair} from "../src/interfaces/IPair.sol"; // IPair has transferFrom for moving LP tokens to Sablier
import {IPairFactory} from "../src/interfaces/IPairFactory.sol";

struct Params {
    IThenaPair pair;
    address token;
    address owner;
    uint32 secs;
    uint128 minPrice;
}

contract LockedLPExerciseTest is Test {
    using FixedPointMathLib for uint256;

    uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
    uint256 constant ORACLE_INIT_TWAP_VALUE = 1e19;
    uint256 constant ORACLE_MIN_PRICE_DENOM = 10000;

    // fork vars
    uint256 bscFork;
    string BSC_RPC_URL = vm.envString("BSC_RPC_URL");
    uint32 FORK_BLOCK = 39748140; // free RPC won't cut it, need one with archive node to roll to specific block

    // thena addresses & token addresses
    address POOL_ADDRESS = 0x56EDFf25385B1DaE39d816d006d14CeCf96026aF; // the liquidity pool of our paired tokens
    address TOKEN_ADDRESS = 0x4d2d32d8652058Bf98c772953E1Df5c5c85D9F45; // the underlying token address - $DAO
    address PAYMENT_TOKEN_ADDRESS = 0x55d398326f99059fF775485246999027B3197955; // the payment token address - $BSC-USD
    address THENA_ROUTER = 0xd4ae6eCA985340Dd434D38F470aCCce4DC78D109; // the thena router for swapping
    address THENA_FACTORY = 0xAFD89d21BdB66d00817d4153E055830B1c2B3970; // the factory for getting our LP token pair address

    // EOA vars
    address owner;
    address tokenAdmin;

    // fee vars
    address[] feeRecipients_;
    uint256[] feeBPS_;

    // thena oralce params
    Params _default;

    // vars for contracts we will deploy
    OptionsToken optionsToken;
    LockedExercise exerciser;
    ThenaOracle oracle;

    // @note we are not deploying TestERC20s in these tests, we are using other deployed tokens on BSC mainnet
    // TOKEN_ADDRESS = $DAO, PAYMENT_TOKEN_ADDRESS = $BSC-USD (taken from ThenaOracle.t.sol)
    // This is because we need an existing liquidity pool to enter into for the locked LP exercise (on our fork)
    // So for these tests the oToken is treated as if it's an option token for the exisitng "TOKEN_ADDRESS" contract
    // we can look at creating a pool and adding liquidity for new tokens once the general flow of the exercise
    // is working correctly

    function setUp() public {
        // fork binance smart chain
        bscFork = vm.createFork(BSC_RPC_URL);
        // bscFork = vm.createSelectFork(BSC_RPC_URL, FORK_BLOCK);
        vm.selectFork(bscFork);

        // set up accounts
        owner = makeAddr("owner");
        tokenAdmin = makeAddr("tokenAdmin");

        feeRecipients_ = new address[](2);
        feeRecipients_[0] = makeAddr("feeRecipient");
        feeRecipients_[1] = makeAddr("feeRecipient2");

        feeBPS_ = new uint256[](2);
        feeBPS_[0] = 1000; // 10%
        feeBPS_[1] = 9000; // 90%

        address implementation = address(new OptionsToken());
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, "");
        optionsToken = OptionsToken(address(proxy));
        optionsToken.initialize("XYZ Call Option Token", "oXYZ", tokenAdmin);
        optionsToken.transferOwnership(owner);

        // address[] memory tokens = new address[](2);
        // tokens[0] = address(paymentToken);
        // tokens[1] = address(underlyingToken);

        // set up the thena oracle parameters
        _default = Params(IThenaPair(POOL_ADDRESS), TOKEN_ADDRESS, address(this), 30 minutes, 1000);
        // deploy oracle contract
        oracle = new ThenaOracle(_default.pair, _default.token, _default.owner, _default.secs, _default.minPrice);

        // deploy LockedExercise contract
        exerciser = new LockedExercise(
            optionsToken, owner, IERC20(PAYMENT_TOKEN_ADDRESS), IERC20(TOKEN_ADDRESS), oracle, THENA_ROUTER, THENA_FACTORY, feeRecipients_, feeBPS_
        );

        // add exerciser to the list of options
        vm.startPrank(owner);
        optionsToken.setExerciseContract(address(exerciser), true);
        vm.stopPrank();

        // deal(PAYMENT_TOKEN_ADDRESS, address(proxy), 1e6 * 1e18, true); // give the proxy payment tokens
        deal(TOKEN_ADDRESS, address(exerciser), 1e6 * 1e18, true); // fill the contract up with underlying tokens

        IERC20(PAYMENT_TOKEN_ADDRESS).approve(address(exerciser), type(uint256).max); // exerciser contract can spend max payment tokens

        vm.startPrank(address(exerciser));
        IERC20(PAYMENT_TOKEN_ADDRESS).approve(THENA_ROUTER, type(uint256).max);
        IERC20(TOKEN_ADDRESS).approve(THENA_ROUTER, type(uint256).max);
        vm.stopPrank();
    }

    function test_getPrice() public {
        uint256 oraclePrice = oracle.getPrice();

        uint256 spotPrice = getSpotPrice(_default.pair, _default.token);
        assertApproxEqRel(oraclePrice, spotPrice, 0.01 ether, "Price delta too large"); // 1%
    }

    function test_exerciseWithMultiplier() public {
        uint256 amount = 15000;
        address recipient = makeAddr("recipient");
        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        deal(PAYMENT_TOKEN_ADDRESS, address(this), 1e6 * 1e18, true);

        // exercise options tokens
        LockedExerciseParams memory params =
            LockedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max, multiplier: 5000});
        (uint256 paymentAmount,,,) = optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
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
}
