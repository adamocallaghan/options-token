// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeCast} from "oz/utils/math/SafeCast.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";

import {BaseExercise} from "../exercise/BaseExercise.sol";
import {OptionsToken} from "../OptionsToken.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {IPairFactory} from "../interfaces/IPairFactory.sol";
import {IPair} from "../interfaces/IPair.sol";

import {SablierStreamCreator} from "./Sablier/SablierStreamCreator.sol";

struct LockedExerciseParams {
    uint256 maxPaymentAmount;
    uint256 deadline;
    uint256 multiplier;
}

/// @title Options Token Locked LP Price Exercise Contract
/// @author @adamo
/// @notice Contract that allows the holder of options tokens to exercise them,
/// in this case, by purchasing the underlying token at a discount to the market
/// price. Those underlying token are paired 50:50 with additional payment tokens
/// to create an LP which is timelocked for release to the user
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract LockedExercise is BaseExercise, SablierStreamCreator {
    /// Library usage
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// Errors
    error Exercise__SlippageTooHigh();
    error Exercise__PastDeadline();
    error Exercise__InvalidMultiplier();
    error Exercise__InvalidOracle();

    /// Events
    event SetOracle(IOracle indexed newOracle);
    event SetRouter(address indexed newRouter);
    event SetPair(IERC20 indexed paymentToken, IERC20 indexed underlyingToken, address indexed pair);
    event ExerciseLp(
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint256 paymentAmount,
        uint256 lpTokenAmount,
        uint256 lockDuration,
        uint256 streamId
    );

    /// Constants

    /// @notice The denominator for converting the multiplier into a decimal number.
    /// i.e. multiplier uses 4 decimals.
    uint256 internal constant MULTIPLIER_DENOM = 10000;

    /// Immutable parameters

    /// @notice The token paid by the options token holder during redemption
    IERC20 public immutable paymentToken;

    /// @notice The underlying token purchased during redemption
    IERC20 public immutable underlyingToken;

    /// Storage variables

    /// @notice The router for adding liquidity
    address public router;

    /// @notice The pair for transferring LP tokens to Sablier
    address public pair;

    /// @notice the factory for getting the pair address
    address public factory;

    /// @notice The oracle contract that provides the current price to purchase
    /// the underlying token while exercising options (the strike price)
    IOracle public oracle;

    /// @notice the discount given during exercising with locking to the LP
    uint256 public maxMultiplier = 3000; // 70% discount
    uint256 public minMultiplier = 8000; // 20% discount

    uint256 public minLpLockDuration = 7 * 86400; // one week
    uint256 public maxLpLockDuration = 52 * 7 * 86400; // one year

    constructor(
        OptionsToken oToken_,
        address owner_,
        IERC20 paymentToken_,
        IERC20 underlyingToken_,
        IOracle oracle_,
        address router_,
        address factory_,
        address[] memory feeRecipients_,
        uint256[] memory feeBPS_
    ) BaseExercise(oToken_, feeRecipients_, feeBPS_) Owned(owner_) {
        paymentToken = paymentToken_;
        underlyingToken = underlyingToken_;
        factory = factory_;

        _setOracle(oracle_);
        _setRouter(router_);
        _setPair(paymentToken_, underlyingToken_);
    }

    // /// External functions
    function exercise(address from, uint256 amount, address recipient, bytes memory params)
        external
        override
        onlyOToken
        returns (uint256 paymentAmount, address lpTokenAddress, uint256 lockDuration, uint256 streamId)
    {
        return _exercise(from, amount, recipient, params);
    }

    /// Internal functions

    function _exercise(address from, uint256 amount, address recipient, bytes memory params)
        internal
        returns (uint256 paymentAmount, address lpTokenAddress, uint256 lockDuration, uint256 streamId)
    {
        // ===============
        //  === CHECKS ===
        // ===============

        // decode params
        LockedExerciseParams memory _params = abi.decode(params, (LockedExerciseParams));

        if (block.timestamp > _params.deadline) revert Exercise__PastDeadline();

        // multiplier validity
        if (_params.multiplier > minMultiplier || _params.multiplier < maxMultiplier) {
            revert Exercise__InvalidMultiplier();
        }

        // =========================
        //  === PRICE & DISCOUNT ===
        // =========================

        // apply multiplier to price
        uint256 price = oracle.getPrice().mulDivUp(_params.multiplier, MULTIPLIER_DENOM);

        // get payment amount
        paymentAmount = amount.mulWadUp(price);
        if (paymentAmount > _params.maxPaymentAmount) revert Exercise__SlippageTooHigh();

        // ======================
        //  === PROTOCOL FEES ===
        // ======================

        distributeFeesFrom(paymentAmount, paymentToken, from); // transfer payment tokens from user to the set receivers

        // ==================
        //  === CREATE LP ===
        // ==================

        // calculate second side (payment token) amount of the LP that user needs to supply
        (uint256 underlyingReserve, uint256 paymentReserve) = IRouter(router).getReserves(address(underlyingToken), address(paymentToken), false);
        uint256 paymentAmountToAddLiquidity = (amount * paymentReserve) / underlyingReserve;

        // get payment token from user to pair with underlying token in lp
        paymentToken.safeTransferFrom(from, address(this), paymentAmountToAddLiquidity);

        // Create LP
        (,, uint256 lpTokenAmount) = IRouter(router).addLiquidity(
            address(underlyingToken), address(paymentToken), false, amount, paymentAmountToAddLiquidity, 1, 1, address(this), block.timestamp
        );

        // ================
        //  === LOCK LP ===
        // ================

        // get the lock duration using the chosen multiplier
        lockDuration = getLockDurationForLpDiscount(_params.multiplier);

        // get lp token address
        lpTokenAddress = IPairFactory(factory).getPair(address(underlyingToken), address(paymentToken), false);

        // Create Sablier timelock (the lock is really a '1 second' cliff)
        streamId = createLinearStream(uint40(lockDuration), uint40(lockDuration + 100), lpTokenAmount, address(lpTokenAddress), recipient);
        // uint256 streamId = 123; // @note dummy streamId until the rest of the contract flow is working correctly

        emit ExerciseLp(msg.sender, recipient, amount, paymentAmount, lpTokenAmount, lockDuration, streamId);
    }

    /// Owner functions

    /// @notice Sets the oracle contract. Only callable by the owner.
    /// @param oracle_ The new oracle contract
    function setOracle(IOracle oracle_) external onlyOwner {
        _setOracle(oracle_);
    }

    function _setOracle(IOracle oracle_) internal {
        (address paymentToken_, address underlyingToken_) = oracle_.getTokens();
        if (paymentToken_ != address(paymentToken) || underlyingToken_ != address(underlyingToken)) {
            revert Exercise__InvalidOracle();
        }
        oracle = oracle_;
        emit SetOracle(oracle_);
    }

    /// @notice Sets the router contract. Only callable by the owner.
    /// @param router_ The new router contract
    function setRouter(address router_) external onlyOwner {
        _setRouter(router_);
    }

    function _setRouter(address router_) internal {
        // *** need to check router validity here ***
        router = router_;
        emit SetRouter(router_);
    }

    /// @notice Retrieves the pair contract address by calling getPair, and sets the pair on this contract
    function _setPair(IERC20 paymentToken_, IERC20 underlyingToken_) internal {
        pair = IPairFactory(factory).getPair(address(paymentToken_), address(underlyingToken_), false); // get & set pair address
        emit SetPair(paymentToken_, underlyingToken_, pair);
    }

    /// View functions

    function getLockDurationForLpDiscount(uint256 _discount) public view returns (uint256 duration) {
        (int256 slope, int256 intercept) = getSlopeInterceptForLpDiscount();
        duration = SignedMath.abs(slope * int256(_discount) + intercept);
        // lockDuration = 1 weeks;
    }

    function getSlopeInterceptForLpDiscount() public view returns (int256 slope, int256 intercept) {
        slope = int256(maxLpLockDuration - minLpLockDuration) / (int256(maxMultiplier) - int256(minMultiplier));
        intercept = int256(minLpLockDuration) - (slope * int256(minMultiplier));
    }
}
