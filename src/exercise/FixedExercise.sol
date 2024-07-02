// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {BaseExercise} from "../exercise/BaseExercise.sol";
import {OptionsToken} from "../OptionsToken.sol";

struct FixedExerciseParams {
    uint256 maxPaymentAmount;
    uint256 deadline;
}

/// @title Options Token Fixed Price Exercise Contract
/// @author @adamo, @funkornaut
/// @notice Contract that allows the holder of options tokens to exercise them,
/// in this case, by purchasing the underlying token at a discount to a fixed
/// price set by owner.
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract FixedExercise is BaseExercise {
    /// Library usage
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// Errors
    error Exercise__SlippageTooHigh();
    error Exercise__PastDeadline();
    error Exercise__MultiplierOutOfRange();
    error Exercise__ExerciseWindowNotOpen();
    error Exercise__ExerciseWindowClosed();
    error Exercise__StartTimeIsInThePast();
    error Exercise__EndTimeIsBeforeStartTime();

    /// Events
    event Exercised(address indexed sender, address indexed recipient, uint256 amount, uint256 paymentAmount);
    event SetPriceAndTimeWindow(uint256 indexed price, uint256 indexed startTime, uint256 endTime);
    event SetTreasury(address indexed newTreasury);
    event SetMultiplier(uint256 indexed newMultiplier);
    event SetPrice(uint256 indexed price);

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

    /// @notice The multiplier applied to the price. Encodes the discount of
    /// the options token. Uses 4 decimals.
    uint256 public multiplier;

    /// @notice The time after which users can exercise their option tokens
    uint256 public startTime;

    /// @notice The time after which users can no longer exercise their option tokens
    uint256 public endTime;

    /// @notice The fixed token price, set by the owner
    uint256 public price;

    /// @notice The amount of payment tokens the user can claim
    /// Used when the contract does not have enough tokens to pay the user
    mapping(address => uint256) public credit;

    constructor(
        OptionsToken oToken_,
        address owner_,
        IERC20 paymentToken_,
        IERC20 underlyingToken_,
        uint256 price_,
        uint256 startTime_,
        uint256 endTime_,
        uint256 multiplier_,
        address[] memory feeRecipients_,
        uint256[] memory feeBPS_
    ) BaseExercise(oToken_, feeRecipients_, feeBPS_) Owned(owner_) {
        paymentToken = paymentToken_;
        underlyingToken = underlyingToken_;

        _setTimes(startTime_, endTime_);
        _setPrice(price_);
        _setMultiplier(multiplier_);
    }

    /// External functions

    /// @notice Exercises options tokens to purchase the underlying tokens.
    /// @param from The user that is exercising their options tokens
    /// @param amount The amount of options tokens to exercise
    /// @param recipient The recipient of the purchased underlying tokens
    /// @param params Extra parameters to be used by the exercise function
    function exercise(address from, uint256 amount, address recipient, bytes memory params)
        external
        virtual
        override
        onlyOToken
        returns (uint256 paymentAmount, address, uint256, uint256)
    {
        return _exercise(from, amount, recipient, params);
    }

    function claim(address to) external {
        uint256 amount = credit[msg.sender];
        if (amount == 0) return;
        credit[msg.sender] = 0;
        underlyingToken.safeTransfer(to, amount);
    }

    /// Owner functions

    /// @notice Sets the discount multiplier.
    /// @param multiplier_ The new multiplier
    function setMultiplier(uint256 multiplier_) external onlyOwner {
        _setMultiplier(multiplier_);
    }

    function _setMultiplier(uint256 multiplier_) internal {
        if (
            multiplier_ > MULTIPLIER_DENOM * 2 // over 200%
                || multiplier_ < MULTIPLIER_DENOM / 10 // under 10%
        ) revert Exercise__MultiplierOutOfRange();
        multiplier = multiplier_;
        emit SetMultiplier(multiplier_);
    }

    /// @notice Sets the fixed token price
    function setPrice(uint256 price_) external onlyOwner {
        _setPrice(price_);
    }

    function _setPrice(uint256 price_) internal {
        price = price_;
        emit SetPrice(price);
    }

    function setTimes(uint256 startTime_, uint256 endTime_) external onlyOwner {
        _setTimes(startTime_, endTime_);
    }

    function _setTimes(uint256 startTime_, uint256 endTime_) internal {
        // checks
        if (startTime_ < block.timestamp) {
            revert Exercise__StartTimeIsInThePast();
        }
        if (endTime_ <= startTime_) {
            revert Exercise__EndTimeIsBeforeStartTime();
        }
        startTime = startTime_;
        endTime = endTime_;
    }

    /// Internal functions

    function _exercise(address from, uint256 amount, address recipient, bytes memory params)
        internal
        virtual
        returns (uint256 paymentAmount, address, uint256, uint256)
    {
        // check if exercise window is open
        if (block.timestamp < startTime) revert Exercise__ExerciseWindowNotOpen();
        if (block.timestamp > endTime) revert Exercise__ExerciseWindowClosed();

        // decode params
        FixedExerciseParams memory _params = abi.decode(params, (FixedExerciseParams));

        if (block.timestamp > _params.deadline) revert Exercise__PastDeadline();

        paymentAmount = amount.mulWadUp(price);
        if (paymentAmount > _params.maxPaymentAmount) revert Exercise__SlippageTooHigh();

        // transfer payment tokens from user to the set receivers
        distributeFeesFrom(paymentAmount, paymentToken, from);
        // transfer underlying tokens to recipient
        _pay(recipient, amount);

        emit Exercised(from, recipient, amount, paymentAmount);
    }

    function _pay(address to, uint256 amount) internal returns (uint256 remainingAmount) {
        uint256 balance = underlyingToken.balanceOf(address(this));
        if (amount > balance) {
            underlyingToken.safeTransfer(to, balance);
            remainingAmount = amount - balance;
        } else {
            underlyingToken.safeTransfer(to, amount);
        }
        credit[to] += remainingAmount;
    }

    /// View functions

    /// @notice Returns the amount of payment tokens required to exercise the given amount of options tokens.
    /// @param amount The amount of options tokens to exercise
    function getPaymentAmount(uint256 amount) external view returns (uint256 paymentAmount) {
        paymentAmount = amount.mulWadUp(price.mulDivUp(multiplier, MULTIPLIER_DENOM));
    }
}
