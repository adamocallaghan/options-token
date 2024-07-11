// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";

import {OptionsToken} from "../src/OptionsToken.sol";
import {LockedExerciseParams, LockedExercise, BaseExercise} from "../src/exercise/LockedLPExercise.sol";

import {ThenaOracle} from "../src/oracles/ThenaOracle.sol";
import {IThenaPair} from "../src/interfaces/IThenaPair.sol";
import {IThenaRouter} from "./interfaces/IThenaRouter.sol";
import {IPair} from "../src/interfaces/IPair.sol";
import {IPairFactory} from "../src/interfaces/IPairFactory.sol";
import {ISablierV2LockupLinear} from "@sablier/v2-core/src/interfaces/ISablierV2LockupLinear.sol";
import {Lockup, LockupLinear} from "@sablier/v2-core/src/types/DataTypes.sol";

struct Params {
    IThenaPair pair;
    address token;
    address owner;
    uint32 secs;
    uint128 minPrice;
}

struct StreamDetails {
    address sender;
    address recipient;
    address tokenAddress;
    uint256 balance;
    uint256 startTime;
    uint256 stopTime;
    uint256 remainingBalance;
    uint256 ratePerSecond;
}

contract LockedLPExerciseTest is Test {
    using FixedPointMathLib for uint256;

    uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
    uint256 constant ORACLE_INIT_TWAP_VALUE = 1e19;
    uint256 constant ORACLE_MIN_PRICE_DENOM = 10000;
    uint256 constant MAX_SUPPLY = 1e27;

    // fork vars
    uint256 bscFork;
    string BSC_RPC_URL = vm.envString("BSC_RPC_URL");
    uint32 FORK_BLOCK = 39748140;

    // thena addresses & token addresses
    address POOL_ADDRESS = 0x56EDFf25385B1DaE39d816d006d14CeCf96026aF; // the liquidity pool of our paired tokens
    address TOKEN_ADDRESS = 0x4d2d32d8652058Bf98c772953E1Df5c5c85D9F45; // the underlying token address - $DAO
    address PAYMENT_TOKEN_ADDRESS = 0x55d398326f99059fF775485246999027B3197955; // the payment token address - $BSC-USD
    address THENA_ROUTER = 0xd4ae6eCA985340Dd434D38F470aCCce4DC78D109; // the thena router for swapping
    address THENA_FACTORY = 0xAFD89d21BdB66d00817d4153E055830B1c2B3970; // the factory for getting our LP token pair address

    // Sablier
    ISablierV2LockupLinear public immutable LOCKUP_LINEAR = ISablierV2LockupLinear(0x14c35E126d75234a90c9fb185BF8ad3eDB6A90D2); // Linear on BSC
    ISablierV2LockupLinear public constant SABLIER_DYNAMIC_ADDRESS = ISablierV2LockupLinear(0xF2f3feF2454DcA59ECA929D2D8cD2a8669Cc6214);

    // EOA vars
    address owner;
    address tokenAdmin;
    address sender;

    // fee vars
    address[] feeRecipients_;
    uint256[] feeBPS_;

    // thena oralce params
    Params _default;

    // vars for contracts we will deploy
    OptionsToken optionsToken;
    LockedExercise exerciser;
    ThenaOracle oracle;

    uint256 public maxMultiplier = 3000; // 70% discount
    uint256 public minMultiplier = 8000; // 20% discount

    uint256 public minLpLockDuration = 7 * 86400; // one week
    uint256 public maxLpLockDuration = 52 * 7 * 86400; // one year

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
        sender = makeAddr("sender");

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

        // set up the thena oracle parameters
        _default = Params(IThenaPair(POOL_ADDRESS), TOKEN_ADDRESS, address(this), 30 minutes, 1000);
        // deploy oracle contract
        oracle = new ThenaOracle(_default.pair, _default.token, _default.owner, _default.secs, _default.minPrice);

        // deploy LockedExercise contract
        exerciser = new LockedExercise(
            optionsToken,
            owner,
            sender,
            address(LOCKUP_LINEAR),
            address(SABLIER_DYNAMIC_ADDRESS),
            IERC20(PAYMENT_TOKEN_ADDRESS),
            IERC20(TOKEN_ADDRESS),
            oracle,
            THENA_ROUTER,
            THENA_FACTORY,
            feeRecipients_,
            feeBPS_
        );

        // add exerciser to the list of options
        vm.startPrank(owner);
        optionsToken.setExerciseContract(address(exerciser), true);
        vm.stopPrank();

        deal(TOKEN_ADDRESS, address(exerciser), 1e6 * 1e18, true); // fill the contract up with underlying tokens

        IERC20(PAYMENT_TOKEN_ADDRESS).approve(address(exerciser), type(uint256).max); // exerciser contract can spend max payment tokens

        // router approvals to transfer tokens for lp
        vm.startPrank(address(exerciser));
        IERC20(PAYMENT_TOKEN_ADDRESS).approve(THENA_ROUTER, type(uint256).max);
        IERC20(TOKEN_ADDRESS).approve(THENA_ROUTER, type(uint256).max);
        vm.stopPrank();
    }

    // ==============================
    // == EXERCISE WITH MULTIPLIER ==
    // ==============================

    function exerciseWithMultiplier(uint256 amount, uint256 multiplier)
        public
        returns (uint256 paymentAmount, address lpTokenAddress, uint256 lockDuration, uint256 streamId)
    {
        amount = bound(amount, 100, 1e18); // 1e18 works, but 1e27 doesn't - uint128 on sablier issue?
        multiplier = bound(multiplier, maxMultiplier, minMultiplier); // @note maxMult and minMult are reversed in bound here

        address recipient = makeAddr("recipient");

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        deal(PAYMENT_TOKEN_ADDRESS, address(this), 1e6 * 1e18, true);

        // exercise options tokens, create LP, and lock in Sablier
        LockedExerciseParams memory params =
            LockedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max, multiplier: multiplier});

        (paymentAmount, lpTokenAddress, lockDuration, streamId) = optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    // =================================
    // == Exercise Return Value tests ==
    // =================================

    function test_Exercise_ReturnedLpTokenAddressIsCorrect(uint256 amount, uint256 multiplier) public {
        // returned token address
        (, address lpTokenAddressReturned,,) = exerciseWithMultiplier(amount, multiplier);

        // get lp token address from token addresses
        address lpTokenAddressFromPair = IPairFactory(THENA_FACTORY).getPair(TOKEN_ADDRESS, PAYMENT_TOKEN_ADDRESS, false);

        assertEq(lpTokenAddressFromPair, lpTokenAddressReturned);
    }

    function test_Exercise_ReturnedLpLockDurationIsCorrect(uint256 amount, uint256 multiplier) public {
        multiplier = bound(multiplier, maxMultiplier, minMultiplier); // @note maxMult and minMult are reversed in bound here
        // returned token address
        (,, uint256 lockDurationReturned,) = exerciseWithMultiplier(amount, multiplier);

        // calculate lock duration @todo move to own function
        int256 slope = int256(maxLpLockDuration - minLpLockDuration) / (int256(maxMultiplier) - int256(minMultiplier));
        int256 intercept = int256(minLpLockDuration) - (slope * int256(minMultiplier));
        uint256 lockDurationCalculated = SignedMath.abs(slope * int256(multiplier) + intercept);

        assertEq(lockDurationCalculated, lockDurationReturned);
    }

    function test_Exercise_ReturnedStreamIdIsCorrect(uint256 amount, uint256 multiplier) public {
        // get the next streamId from Sablier
        uint256 nextStreamId = LOCKUP_LINEAR.nextStreamId();

        // returned token address
        (,,, uint256 streamIdReturned) = exerciseWithMultiplier(amount, multiplier);

        assertEq(nextStreamId, streamIdReturned);
    }

    // ===================
    // == Sablier tests ==
    // ===================

    function test_Sablier_CorrectSenderIsSetOnSablierStream(uint256 amount, uint256 multiplier) public {
        // exercise tokens with lock
        (,,, uint256 streamId) = exerciseWithMultiplier(amount, multiplier);

        // get stream information following lock
        LockupLinear.Stream memory streamDetails = LOCKUP_LINEAR.getStream(streamId);

        assertEq(address(sender), streamDetails.sender);
    }

    function test_Sablier_StreamStartAndEndTimesAreCorrect(uint256 amount, uint256 multiplier) public {
        // exercise tokens with lock
        (,, uint256 lockDuration, uint256 streamId) = exerciseWithMultiplier(amount, multiplier);

        // get stream information following lock
        LockupLinear.Stream memory streamDetails = LOCKUP_LINEAR.getStream(streamId);

        uint256 lockStartTime = block.timestamp + lockDuration;
        uint256 lockEndTime = lockStartTime + 100;

        assertEq(lockStartTime, streamDetails.cliffTime);
        assertEq(lockEndTime, streamDetails.endTime);
    }

    function test_Sablier_UserCanWithdrawMaxTokensAfterUnlockDate(uint256 amount, uint256 multiplier) public {
        address recipient = makeAddr("recipient");

        // exercise tokens with lock
        (, address lpTokenAddress, uint256 lockDuration, uint256 streamId) = exerciseWithMultiplier(amount, multiplier);

        // get stream information following lock
        uint128 streamBalance = LOCKUP_LINEAR.getDepositedAmount(streamId);

        // warp the block past the unlock date
        vm.warp(block.timestamp + lockDuration + 200 seconds);

        // withdraw tokens
        vm.prank(recipient);
        LOCKUP_LINEAR.withdrawMax({streamId: streamId, to: recipient});

        // user balance after withdrawal
        uint256 userBalanceAfterWithdrawal = IERC20(lpTokenAddress).balanceOf(recipient);

        assertEq(uint128(userBalanceAfterWithdrawal), streamBalance);
    }

    function test_Sablier_UserCannotWithdrawTokensBeforeUnlockDate(uint256 amount, uint256 multiplier) public {
        address recipient = makeAddr("recipient");

        // exercise tokens with lock
        (, address lpTokenAddress, uint256 lockDuration, uint256 streamId) = exerciseWithMultiplier(amount, multiplier);

        // withdraw tokens immediately, before unlock date
        vm.prank(recipient);
        vm.expectRevert();
        LOCKUP_LINEAR.withdrawMax({streamId: streamId, to: recipient});
    }

    function test_Sablier_StreamIsNotDepleted_BeforeBlockWarped(uint256 amount, uint256 multiplier) public {
        (,,, uint256 streamId) = exerciseWithMultiplier(amount, multiplier);
        bool streamDepletionStatus = LOCKUP_LINEAR.isDepleted(streamId);
        assertEq(streamDepletionStatus, false);
    }

    function test_Sablier_StreamIsNotDepleted_AfterBlockWarped(uint256 amount, uint256 multiplier) public {
        (,, uint256 lockDuration, uint256 streamId) = exerciseWithMultiplier(amount, multiplier);
        vm.warp(block.timestamp + lockDuration + 200 seconds);
        bool streamDepletionStatus = LOCKUP_LINEAR.isDepleted(streamId);
        assertEq(streamDepletionStatus, false);
    }

    // ===========================
    // == Exercise Revert tests ==
    // ===========================

    function test_Exercise_RevertsIfMultiplierTooLow(uint256 amount, uint256 multiplier) public {
        amount = bound(amount, 100, 1e18); // 1e18 works, but 1e27 doesn't - uint128 on sablier issue?
        multiplier = bound(multiplier, 0, maxMultiplier - 1);

        address recipient = makeAddr("recipient");

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        deal(PAYMENT_TOKEN_ADDRESS, address(this), 1e6 * 1e18, true);

        // exercise options tokens, create LP, and lock in Sablier
        LockedExerciseParams memory params =
            LockedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max, multiplier: multiplier});

        vm.expectRevert(LockedExercise.Exercise__InvalidMultiplier.selector);
        (uint256 paymentAmount, address lpTokenAddress, uint256 lockDuration, uint256 streamId) =
            optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    function test_Exercise_RevertsIfMultiplierTooHigh(uint256 amount, uint256 multiplier) public {
        amount = bound(amount, 100, 1e18); // 1e18 works, but 1e27 doesn't - uint128 on sablier issue?
        multiplier = bound(multiplier, minMultiplier + 1, type(uint256).max);

        address recipient = makeAddr("recipient");

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        deal(PAYMENT_TOKEN_ADDRESS, address(this), 1e6 * 1e18, true);

        // exercise options tokens, create LP, and lock in Sablier
        LockedExerciseParams memory params =
            LockedExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max, multiplier: multiplier});

        vm.expectRevert(LockedExercise.Exercise__InvalidMultiplier.selector);
        (uint256 paymentAmount, address lpTokenAddress, uint256 lockDuration, uint256 streamId) =
            optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    // ==========================
    // == Liquidity Pool tests ==
    // ==========================

    function test_LiquidityPool_UserCanBreakLpApartFollowingWithdrawalFromStream(uint256 amount, uint256 multiplier) public {
        // @todo create a function for the following as it's required for multiple tests
        // Exercise Tokens -> Lock LP -> Warp-Time-Past-Unlock -> Withdraw LP tokens
        address recipient = makeAddr("recipient");
        (, address lpTokenAddress, uint256 lockDuration, uint256 streamId) = exerciseWithMultiplier(amount, multiplier);
        uint128 streamBalance = LOCKUP_LINEAR.getDepositedAmount(streamId);
        vm.warp(block.timestamp + lockDuration + 200 seconds);
        vm.prank(recipient);
        LOCKUP_LINEAR.withdrawMax({streamId: streamId, to: recipient});
        uint256 userBalanceAfterWithdrawal = IERC20(lpTokenAddress).balanceOf(recipient);

        // check that user can withdraw underlying and payment tokens from LP using LP tokens

        // assert that the underlying tokens & payment tokens are correct and that amounts are correct
        // assertEq(uint128(userBalanceAfterWithdrawal), streamBalance);
    }

    // ==================
    // == ORACLE TESTS ==
    // ==================

    function test_getPrice() public {
        uint256 oraclePrice = oracle.getPrice();

        uint256 spotPrice = getSpotPrice(_default.pair, _default.token);
        assertApproxEqRel(oraclePrice, spotPrice, 0.01 ether, "Price delta too large"); // 1%
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
