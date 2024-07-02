// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";

import {OptionsToken} from "../src/OptionsToken.sol";
import {FixedExerciseParams, FixedExercise, BaseExercise} from "../src/exercise/FixedExercise.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract FixedOptionsTokenTest is Test {
    using FixedPointMathLib for uint256;

    uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
    uint56 constant SECS = 30 minutes;
    uint128 constant MIN_PRICE = 1e17;
    uint256 constant MIN_PRICE_DENOM = 10000;
    uint256 constant MAX_SUPPLY = 1e27; // the max supply of the options token & the underlying token

    address owner;
    address tokenAdmin;
    address[] feeRecipients_;
    uint256[] feeBPS_;

    OptionsToken optionsToken;
    FixedExercise exerciser;
    TestERC20 paymentToken;
    address underlyingToken;

    uint256 price;
    uint256 startTime;
    uint256 endTime;

    function setUp() public {
        // set up accounts
        owner = makeAddr("owner");
        tokenAdmin = makeAddr("tokenAdmin");

        feeRecipients_ = new address[](2);
        feeRecipients_[0] = makeAddr("feeRecipient");
        feeRecipients_[1] = makeAddr("feeRecipient2");

        feeBPS_ = new uint256[](2);
        feeBPS_[0] = 1000; // 10%
        feeBPS_[1] = 9000; // 90%

        // deploy contracts
        paymentToken = new TestERC20();
        underlyingToken = address(new TestERC20());

        address implementation = address(new OptionsToken());
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, "");
        optionsToken = OptionsToken(address(proxy));
        optionsToken.initialize("TIT Call Option Token", "oTIT", tokenAdmin);
        optionsToken.transferOwnership(owner);

        address[] memory tokens = new address[](2);
        tokens[0] = address(paymentToken);
        tokens[1] = underlyingToken;

        price = 1e22;
        startTime = block.timestamp + 1 hours;
        endTime = block.timestamp + 4 weeks;

        exerciser = new FixedExercise(
            optionsToken,
            owner,
            IERC20(address(paymentToken)),
            IERC20(underlyingToken),
            price,
            startTime,
            endTime,
            PRICE_MULTIPLIER,
            feeRecipients_,
            feeBPS_
        );

        TestERC20(underlyingToken).mint(address(exerciser), 1e20 ether);

        // add exerciser to the list of options
        vm.startPrank(owner);
        optionsToken.setExerciseContract(address(exerciser), true);
        vm.stopPrank();

        // set up contracts
        paymentToken.approve(address(exerciser), type(uint256).max);
    }

    function test_onlyTokenAdminCanMint(uint256 amount, address hacker) public {
        vm.assume(hacker != tokenAdmin);

        // try minting as non token admin
        vm.startPrank(hacker);
        vm.expectRevert(OptionsToken.OptionsToken__NotTokenAdmin.selector);
        optionsToken.mint(address(this), amount);
        vm.stopPrank();

        // mint as token admin
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // verify balance
        assertEqDecimal(optionsToken.balanceOf(address(this)), amount, 18);
    }

    function test_exerciseHappyPath(uint256 amount, address recipient) public {
        openExerciseWindow();

        amount = bound(amount, 100, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(price);
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        FixedExerciseParams memory params = FixedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        (uint256 paymentAmount,,,) = optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));

        // verify options tokens were transferred
        assertEqDecimal(optionsToken.balanceOf(address(this)), 0, 18, "user still has options tokens");
        assertEqDecimal(optionsToken.totalSupply(), 0, 18, "option tokens not burned");

        // verify payment tokens were transferred
        assertEqDecimal(paymentToken.balanceOf(address(this)), 0, 18, "user still has payment tokens");
        uint256 paymentFee1 = expectedPaymentAmount.mulDivDown(feeBPS_[0], 10000);
        uint256 paymentFee2 = expectedPaymentAmount - paymentFee1;
        assertEqDecimal(paymentToken.balanceOf(feeRecipients_[0]), paymentFee1, 18, "fee recipient 1 didn't receive payment tokens");
        assertEqDecimal(paymentToken.balanceOf(feeRecipients_[1]), paymentFee2, 18, "fee recipient 2 didn't receive payment tokens");
        assertEqDecimal(paymentAmount, expectedPaymentAmount, 18, "exercise returned wrong value");
    }

    // function test_exerciseMinPrice(uint256 amount, address recipient) public {
    //     amount = bound(amount, 1, MAX_SUPPLY);

    //     // mint options tokens
    //     vm.prank(tokenAdmin);
    //     optionsToken.mint(address(this), amount);

    //     // set TWAP value such that the strike price is below the oracle's minPrice value
    //     balancerTwapOracle.setTwapValue(MIN_PRICE - 1);

    //     // mint payment tokens
    //     uint256 expectedPaymentAmount = amount.mulWadUp(MIN_PRICE);
    //     paymentToken.mint(address(this), expectedPaymentAmount);

    //     // exercise options tokens
    //     FixedExerciseParams memory params = FixedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
    //     vm.expectRevert(bytes4(keccak256("BalancerOracle__BelowMinPrice()")));
    //     optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    // }

    function test_priceMultiplier(uint256 amount, uint256 multiplier) public {
        openExerciseWindow();

        amount = bound(amount, 1, MAX_SUPPLY / 2);

        address hacker = makeAddr("hacker");
        vm.prank(hacker);
        vm.expectRevert();
        exerciser.setMultiplier(10000);

        vm.prank(owner);
        exerciser.setMultiplier(10000); // full price

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount * 2);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(price);
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        FixedExerciseParams memory params = FixedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        (uint256 paidAmount,,,) = optionsToken.exercise(amount, address(this), address(exerciser), abi.encode(params));

        // add checks for exercise results

        // update multiplier
        multiplier = bound(multiplier, 1000, 20000);
        vm.prank(owner);
        exerciser.setMultiplier(multiplier);

        // exercise options tokens
        uint256 newPrice = price.mulDivUp(multiplier, 10000);
        uint256 newExpectedPaymentAmount = amount.mulWadUp(newPrice);
        params.maxPaymentAmount = newExpectedPaymentAmount;

        paymentToken.mint(address(this), newExpectedPaymentAmount);
        (uint256 newPaidAmount,,,) = optionsToken.exercise(amount, address(this), address(exerciser), abi.encode(params));
        // verify payment tokens were transferred
        assertEqDecimal(paymentToken.balanceOf(address(this)), 0, 18, "user still has payment tokens");
        assertEq(newPaidAmount, newPaidAmount.mulDivUp(multiplier, 10000), "incorrect discount");
    }

    function test_exerciseHighSlippage(uint256 amount, address recipient) public {
        openExerciseWindow();

        amount = bound(amount, 1, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(price.mulDivUp(PRICE_MULTIPLIER, MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens which should fail
        FixedExerciseParams memory params = FixedExerciseParams({maxPaymentAmount: expectedPaymentAmount - 1, deadline: type(uint256).max});
        vm.expectRevert(FixedExercise.Exercise__SlippageTooHigh.selector);
        optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    // function test_exerciseTwapOracleNotReady(uint256 amount, address recipient) public {
    //     amount = bound(amount, 1, MAX_SUPPLY);

    //     // mint options tokens
    //     vm.prank(tokenAdmin);
    //     optionsToken.mint(address(this), amount);

    //     // mint payment tokens
    //     uint256 expectedPaymentAmount = amount.mulWadUp(price.mulDivUp(PRICE_MULTIPLIER, MIN_PRICE_DENOM));
    //     paymentToken.mint(address(this), expectedPaymentAmount);

    //     // update oracle params
    //     // such that the TWAP window becomes (block.timestamp - ORACLE_LARGEST_SAFETY_WINDOW - SECS, block.timestamp - ORACLE_LARGEST_SAFETY_WINDOW]
    //     // which is outside of the largest safety window
    //     vm.prank(owner);
    //     oracle.setParams(SECS, ORACLE_LARGEST_SAFETY_WINDOW, MIN_PRICE);

    //     // exercise options tokens which should fail
    //     FixedExerciseParams memory params = FixedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
    //     vm.expectRevert(BalancerOracle.BalancerOracle__TWAPOracleNotReady.selector);
    //     optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    // }

    function test_exercisePastDeadline(uint256 amount, address recipient, uint256 deadline) public {
        openExerciseWindow();

        amount = bound(amount, 0, MAX_SUPPLY);
        deadline = bound(deadline, 0, block.timestamp - 1);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(price.mulDivUp(PRICE_MULTIPLIER, MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        FixedExerciseParams memory params = FixedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: deadline});
        if (amount != 0) {
            vm.expectRevert(FixedExercise.Exercise__PastDeadline.selector);
        }
        optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    function test_exerciseNotOToken(uint256 amount, address recipient) public {
        amount = bound(amount, 0, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        uint256 expectedPaymentAmount = amount.mulWadUp(price.mulDivUp(PRICE_MULTIPLIER, MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens which should fail
        FixedExerciseParams memory params = FixedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        vm.expectRevert(BaseExercise.Exercise__NotOToken.selector);
        exerciser.exercise(address(this), amount, recipient, abi.encode(params));
    }

    function test_exerciseNotExerciseContract(uint256 amount, address recipient) public {
        amount = bound(amount, 1, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // set option inactive
        vm.prank(owner);
        optionsToken.setExerciseContract(address(exerciser), false);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(price.mulDivUp(PRICE_MULTIPLIER, MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens which should fail
        FixedExerciseParams memory params = FixedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        vm.expectRevert(OptionsToken.OptionsToken__NotExerciseContract.selector);
        optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    function openExerciseWindow() public {
        vm.warp(block.timestamp + 2 hours);
    }
}
