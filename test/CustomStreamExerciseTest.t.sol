// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.19;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CustomStreamExercise} from "../src/exercise/CustomStreamExercise.sol";
import {OptionsToken} from "../src/OptionsToken.sol";
import {BaseExercise} from "../src/exercise/BaseExercise.sol";
import {SablierStreamCreator} from "../src/sablier/SablierStreamCreator.sol";
import {ThenaOracle} from "../src/oracles/ThenaOracle.sol";
import {IThenaPair} from "../src/interfaces/IThenaPair.sol";

import {ISablierV2LockupLinear} from "@sablier/v2-core/src/interfaces/ISablierV2LockupLinear.sol";
import {ISablierV2LockupDynamic} from "@sablier/v2-core/src/interfaces/ISablierV2LockupDynamic.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";

struct Params {
    IThenaPair pair;
    address token;
    address owner;
    uint32 secs;
    uint128 minPrice;
}

contract CustomStreamExerciseTest is Test {
    using FixedPointMathLib for uint256;

    uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
    //uint56 constant ORACLE_SECS = 30 minutes;
    //uint56 constant ORACLE_AGO = 2 minutes;
    uint128 constant ORACLE_MIN_PRICE = 1e17;
    //uint56 constant ORACLE_LARGEST_SAFETY_WINDOW = 24 hours;
    uint256 constant ORACLE_INIT_TWAP_VALUE = 1e19;
    uint256 constant ORACLE_MIN_PRICE_DENOM = 10000;
    //uint256 constant MAX_SUPPLY = 1e27; // the max supply of the options token & the underlying token

    //SABLIER
    // Get the latest deployment address from the docs: https://docs.sablier.com/contracts/v2/deployments
    address public constant SABLIER_LINEAR_ADDRESS = address(0x88ad3B5c62A46Df953A5d428d33D70408F53C408); // v1.2 new - 0x88ad3B5c62A46Df953A5d428d33D70408F53C408 - old -> 0x14c35E126d75234a90c9fb185BF8ad3eDB6A90D2 
    address public constant SABLIER_DYNAMIC_ADDRESS = address(0xeB6d84c585bf8AEA34F05a096D6fAA3b8477D146); //  v1.2 - new -  old - 0xf900c5E3aA95B59Cc976e6bc9c0998618729a5fa

    // fork vars
    uint256 bscFork;
    string BSC_RPC_URL = vm.envString("BSC_RPC_URL");
    
    // thena addresses
    address POOL_ADDRESS = 0x56EDFf25385B1DaE39d816d006d14CeCf96026aF; // the liquidity pool of our paired tokens
    address UNDERLYING_TOKEN_ADDRESS = 0x4d2d32d8652058Bf98c772953E1Df5c5c85D9F45; // the underlying token address - DAO Maker token
    address PAYMENT_TOKEN_ADDRESS = 0x55d398326f99059fF775485246999027B3197955; // the payment token address - BSC pegged USD
    address THENA_ROUTER = 0xd4ae6eCA985340Dd434D38F470aCCce4DC78D109; // the thena router for swapping
    address THENA_FACTORY = 0xAFD89d21BdB66d00817d4153E055830B1c2B3970; // the factory for getting our LP token pair address

    // EOAs
    address owner;
    address tokenAdmin;
    address user;
    address sender;

    // Fee Vars
    address[] feeRecipients_;
    uint256[] feeBPS_;

    // thena oralce params
    Params _default;

    // vars for contracts we will deploy
    OptionsToken optionsToken;
    CustomStreamExercise exerciser;
    ISablierV2LockupLinear internal sablierLinear;
    ISablierV2LockupDynamic internal sablierDynamic;
    ThenaOracle oracle;
    IERC20 paymentToken;
    IERC20 underlyingToken;

    function setUp() public {
        // fork binance smart chain
        // 40184537
        vm.createSelectFork(BSC_RPC_URL);
        //assert(bscFork > 0); // Ensure the fork was created

        // set up accounts and fee recipients
        //@note not sure if deal's are necessary 
        owner = makeAddr("owner");
       // vm.deal(owner, 1 ether);
        tokenAdmin = makeAddr("tokenAdmin"); //oToken minter
       // vm.deal(tokenAdmin, 1 ether);
        sender = makeAddr("sender"); //sender of the token stream
       // vm.deal(sender, 1 ether);
        user = makeAddr("user");
       // vm.deal(user, 1 ether);

        feeRecipients_ = new address[](2);
        feeRecipients_[0] = makeAddr("feeRecipient");
        feeRecipients_[1] = makeAddr("feeRecipient2");

        feeBPS_ = new uint256[](2);
        feeBPS_[0] = 1000; // 10%
        feeBPS_[1] = 9000; // 90%

        // deploy contracts
        paymentToken = IERC20(PAYMENT_TOKEN_ADDRESS);
        underlyingToken = IERC20(UNDERLYING_TOKEN_ADDRESS);

        address implementation = address(new OptionsToken());
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, "");
        optionsToken = OptionsToken(address(proxy));
        optionsToken.initialize("XYZ Vested Option Token", "ovXYZ", tokenAdmin);
        optionsToken.transferOwnership(owner);

        // set up the thena oracle parameters
        _default = Params(IThenaPair(POOL_ADDRESS), UNDERLYING_TOKEN_ADDRESS, address(this), 30 minutes, 1000);
        // deploy oracle contract
        oracle = new ThenaOracle(_default.pair, _default.token, _default.owner, _default.secs, _default.minPrice);

        sablierLinear = ISablierV2LockupLinear(SABLIER_LINEAR_ADDRESS);
        sablierDynamic = ISablierV2LockupDynamic(SABLIER_DYNAMIC_ADDRESS);

        exerciser = new CustomStreamExercise(
            optionsToken,
            owner,
            sender,
            SABLIER_LINEAR_ADDRESS,
            SABLIER_DYNAMIC_ADDRESS,
            paymentToken,
            underlyingToken,
            oracle,
            PRICE_MULTIPLIER, // 50% discount
            feeRecipients_,
            feeBPS_
        );

        deal(UNDERLYING_TOKEN_ADDRESS, address(exerciser), type(uint128).max); // fill the vested exercise contract up with underlying tokens - tokens it will payout for oToken redemption
        assertEq(underlyingToken.balanceOf(address(exerciser)), type(uint128).max, "sender not funded");

        // add exerciser to the list of options
        vm.startPrank(owner);
        optionsToken.setExerciseContract(address(exerciser), true);
        vm.stopPrank();

        vm.startPrank(user);
        paymentToken.approve(address(exerciser), type(uint256).max); // exerciser contract can spend all payment tokens
        // IERC20(UNDERLYING_TOKEN_ADDRESS).approve(address(exerciser), type(uint256).max); // exerciser contract can spend all the monies
        vm.stopPrank();
    }

    function setSegments() public {
        uint64[] memory exponents = new uint64[](4);
        uint40[] memory durations = new uint40[](4);

        durations[0] = 1;
        durations[1] = 2;
        durations[2] = 3;
        durations[3] = 4;

        exponents[0] = 1;
        exponents[1] = 2;
        exponents[2] = 3;
        exponents[3] = 4;

        vm.prank(owner);
        exerciser.setSegments(exponents, durations);
    }

    function test_fuzzExerciseAndCreateSablierStreamExpo(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0));

        amount = bound(amount, 100, type(uint128).max);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(user, amount);

        // took this from the contract
        uint256 price = oracle.getPrice().mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM);
        console.log("price", price);
        uint256 expectedPaymentAmount = amount.mulWadUp(price);
        console.log("expectedPaymentAmount", expectedPaymentAmount); //@note there is a slight difference between the two values here

        // give payment tokens
        deal(PAYMENT_TOKEN_ADDRESS, user, expectedPaymentAmount);
        assertEq(IERC20(PAYMENT_TOKEN_ADDRESS).balanceOf(user), expectedPaymentAmount, "user not funded");

        // set stream segments
        setSegments();

        uint256 expectedStreamId = sablierDynamic.nextStreamId();

        vm.prank(user);
        (uint256 paymentAmount,, uint256 streamId,) = optionsToken.exercise(amount, recipient, address(exerciser), "");

        // verify options tokens were transferred
        assertEqDecimal(optionsToken.balanceOf(user), 0, 18, "user still has options tokens");
        assertEqDecimal(optionsToken.totalSupply(), 0, 18, "option tokens not burned");
        assertEq(streamId, expectedStreamId, "stream id not created");

        // verify payment tokens were transferred
        assertEqDecimal(IERC20(PAYMENT_TOKEN_ADDRESS).balanceOf(user), 0, 18, "user still has payment tokens");
        uint256 paymentFee1 = expectedPaymentAmount.mulDivDown(feeBPS_[0], 10000);
        uint256 paymentFee2 = expectedPaymentAmount - paymentFee1;
        assertEqDecimal(IERC20(PAYMENT_TOKEN_ADDRESS).balanceOf(feeRecipients_[0]), paymentFee1, 18, "fee recipient 1 didn't receive payment tokens");
        assertEqDecimal(IERC20(PAYMENT_TOKEN_ADDRESS).balanceOf(feeRecipients_[1]), paymentFee2, 18, "fee recipient 2 didn't receive payment tokens");
        assertEqDecimal(paymentAmount, expectedPaymentAmount, 18, "exercise returned wrong value");
        //@note assert balances of stream correct
    }

    function test_exerciseAndCreateSablierStreamExpo() public {
        //vm.assume(recipient != address(0));
        address recipient = makeAddr("recipient"); 

        uint256 amount = 40000000; //bound(amount, 100, type(uint128).max);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(user, amount);

        // took this from the contract
        uint256 price = oracle.getPrice().mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM);
        console.log("price", price);
        uint256 expectedPaymentAmount = amount.mulWadUp(price);
        console.log("expectedPaymentAmount", expectedPaymentAmount); //@note there is a slight difference between the two values here

        // give payment tokens
        deal(PAYMENT_TOKEN_ADDRESS, user, expectedPaymentAmount);
        assertEq(IERC20(PAYMENT_TOKEN_ADDRESS).balanceOf(user), expectedPaymentAmount, "user not funded");

        // set stream segments
        setSegments();

        uint256 expectedStreamId = sablierDynamic.nextStreamId();

        vm.prank(user);
        (uint256 paymentAmount,, uint256 streamId,) = optionsToken.exercise(amount, recipient, address(exerciser), "");

        // verify options tokens were transferred
        assertEqDecimal(optionsToken.balanceOf(user), 0, 18, "user still has options tokens");
        assertEqDecimal(optionsToken.totalSupply(), 0, 18, "option tokens not burned");
        assertEq(streamId, expectedStreamId, "stream id not created");

        // verify payment tokens were transferred
        assertEqDecimal(IERC20(PAYMENT_TOKEN_ADDRESS).balanceOf(user), 0, 18, "user still has payment tokens");
        uint256 paymentFee1 = expectedPaymentAmount.mulDivDown(feeBPS_[0], 10000);
        uint256 paymentFee2 = expectedPaymentAmount - paymentFee1;
        assertEqDecimal(IERC20(PAYMENT_TOKEN_ADDRESS).balanceOf(feeRecipients_[0]), paymentFee1, 18, "fee recipient 1 didn't receive payment tokens");
        assertEqDecimal(IERC20(PAYMENT_TOKEN_ADDRESS).balanceOf(feeRecipients_[1]), paymentFee2, 18, "fee recipient 2 didn't receive payment tokens");
        assertEqDecimal(paymentAmount, expectedPaymentAmount, 18, "exercise returned wrong value");
        //@note assert balances of stream correct
    }

    function test_onlyOwnerCanSetSegments() public {

        vm.startPrank(user);
        vm.expectRevert("UNAUTHORIZED");
        exerciser.setSegments(new uint64[](4), new uint40[](4));
        vm.stopPrank();

        uint64[] memory exponents = new uint64[](4);
        uint40[] memory durations = new uint40[](4);
        
        durations[0] = 1;
        durations[1] = 2;
        durations[2] = 3;
        durations[3] = 4;

        exponents[0] = 1;
        exponents[1] = 2;
        exponents[2] = 3;
        exponents[3] = 4;

        vm.prank(owner);
        exerciser.setSegments(exponents, durations);

        uint256 expo1 = exerciser.segmentExponents(0);
        uint256 expo2 = exerciser.segmentExponents(1);
        uint256 expo3 = exerciser.segmentExponents(2);
        uint256 expo4 = exerciser.segmentExponents(3);
        uint256 duration1 = exerciser.segmentDurations(0);
        uint256 duration2 = exerciser.segmentDurations(1);
        uint256 duration3 = exerciser.segmentDurations(2);
        uint256 duration4 = exerciser.segmentDurations(3);

        assertEq(expo1, 1);
        assertEq(expo2, 2);
        assertEq(expo3, 3);
        assertEq(expo4, 4);
        assertEq(duration1, 1);
        assertEq(duration2, 2);
        assertEq(duration3, 3);
        assertEq(duration4, 4);

    }
}
