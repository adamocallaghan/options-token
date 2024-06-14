// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {BaseExercise} from "../exercise/BaseExercise.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {OptionsToken} from "../OptionsToken.sol";


/// @title Options Token Vested Exercise Contract
/// @author @funkornaut
/// @notice Contract that allows the holder of options tokens to exercise them,
/// in this case, by purchasing the underlying token at a discount to the market price 
/// and vested/released linearly over a set period of time per account.
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract VestedTokenRelease is BaseExercise {
    /// Library usage
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// Errors
    error Exercise__RequestedAmountTooHigh();
    error Exercise__VestHasNotStarted();
    error Exercise__MultiplierOutOfRange();
    error Exercise__InvalidOracle();
    error Exercise__VestHasNotBeenSet(address reciever);

    /// Events
    event Exercised(address indexed sender, address indexed recipient, uint256 amount, uint256 paymentAmount);
    event SetOracle(IOracle indexed newOracle);
    event SetTreasury(address indexed newTreasury);
    event SetMultiplier(uint256 indexed newMultiplier);

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

    /// @notice The oracle contract that provides the current price to purchase
    /// the underlying token while exercising options (the strike price)
    IOracle public oracle;

    /// @notice The multiplier applied to the TWAP value. Encodes the discount of
    /// the options token. Uses 4 decimals.
    uint256 public multiplier;

    /// @notice The length of time tokens will be vested before they are begin to release to the user
    uint256 public vestingTime;

    /// @notice The length of time it takes for the vested tokens to be fully released
    uint256 public releasePeriod;

    /// @notice The amount of payment tokens the user can claim
    /// Used when the contract does not have enough tokens to pay the user
    mapping (address => uint256) public credit;

    /// @notice Mapping of an address to their vested release parameters
    mapping(address => VestedReleaseParams[]) public userVests;

    //@question why is this "struct" type outside of the contract in the other exercise option? 
    struct VestedReleaseParams {
        address reciever;
        uint256 totalAmount;
        uint256 claimedAmount;
        uint40 startTime;
        uint40 endTime;
        uint40 releaseStartTime;

    }

    //@todo add checks for vesting times
    constructor(
        OptionsToken oToken_,
        address owner_,
        IERC20 paymentToken_,
        IERC20 underlyingToken_,
        IOracle oracle_,
        uint256 multiplier_,
        uint256 vestingTime_,
        uint256 releasePeriod_,
        address[] memory feeRecipients_,
        uint256[] memory feeBPS_
    ) BaseExercise(oToken_, feeRecipients_, feeBPS_) Owned(owner_) {
        paymentToken = paymentToken_;
        underlyingToken = underlyingToken_;
        vestingTime = vestingTime_;
        releasePeriod = releasePeriod_;

        _setOracle(oracle_);
        _setMultiplier(multiplier_);

        emit SetOracle(oracle_);
    }

    /// External functions

    /// @notice Exercises options tokens to purchase the underlying tokens. This will start the vesting period of the underlying tokens
    /// @dev The oracle may revert if it cannot give a secure result.
    /// @param from The user that is exercising their options tokens
    /// @param amount The amount of options tokens to exercise
    /// @param recipient The recipient of the purchased underlying tokens
    function exercise(address from, uint256 amount, address recipient, bytes memory params)
        external
        override
        onlyOToken
        returns (uint256 paymentAmount, address, uint256, uint256)
    {
        // @todo set the vesting params for the user 
        _setVestForUser(recipient, amount);
        return _exercise(from, amount, recipient, params);
    }

    ///@notice Allows the owner of the contract to set the vesting parameters for an account
    ///@param receiver_ The account to set the vesting parameters for
    ///@param totalAmount_ The total amount of tokens to be vested  
    ///@param startTime_ The time the vesting starts
    ///@param endTime_ The time the vesting ends
    function _setVestForUser(address receiver_, uint256 totalAmount_) internal {
         // Create a memory struct and add it to the user's array
        VestedReleaseParams memory newParams = VestedReleaseParams({
            receiver: receiver_,
            totalAmount: totalAmount_,
            claimedAmount: 0,
            startTime: uint40(block.timestamp),
            releaseStartTime: uint40(block.timestamp + vestingTime),
            endTime: uint40(block.timestamp + vestingTime + releasePeriod)
        });

        userVests[receiver_].push(newParams);
    }

    function claim(address to) external {
        uint256 amount = credit[msg.sender];
        if (amount == 0) return;
        credit[msg.sender] = 0;
        underlyingToken.safeTransfer(to, amount);
    }

    /// Owner functions

    /// @notice Sets the oracle contract. Only callable by the owner.
    /// @param oracle_ The new oracle contract
    function setOracle(IOracle oracle_) external onlyOwner {
        _setOracle(oracle_);
    }

    function _setOracle(IOracle oracle_) internal {
        (address paymentToken_, address underlyingToken_) = oracle_.getTokens();
        if (paymentToken_ != address(paymentToken) || underlyingToken_ != address(underlyingToken))
            revert Exercise__InvalidOracle();
        oracle = oracle_;
        emit SetOracle(oracle_);
    }

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



    /// Internal functions

    function _exercise(address from, uint256 amount, address recipient, bytes memory params)
        internal
        //override
        returns (uint256 paymentAmount, address, uint256, uint256)
    {
        // decode params
        VestedReleaseParams[] memory _params = userVests[from];

        if (block.timestamp < _params.startTime) revert Exercise__VestHasNotStarted();

        // apply multiplier to price
        uint256 price = oracle.getPrice().mulDivUp(multiplier, MULTIPLIER_DENOM);

        // get how many tokens have been released
        paymentAmount = calculateTokensReleased(from).mulWadUp(price);

        if (paymentAmount > _params.totalAmount) revert Exercise__RequestedAmountTooHigh();

        // transfer payment tokens from user to the set receivers
        distributeFeesFrom(paymentAmount, paymentToken, from);
        // transfer underlying tokens to recipient
        _pay(recipient, amount); // @todo set vest here and add withdraw func

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

    /// Helper Functions
    /// View functions

    /// @notice Returns the amount of payment tokens required to exercise the given amount of options tokens.
    /// @param amount The amount of options tokens to exercise
    function getPaymentAmount(uint256 amount) external view returns (uint256 paymentAmount) {
        paymentAmount = amount.mulWadUp(oracle.getPrice().mulDivUp(multiplier, MULTIPLIER_DENOM));
    }

    function getAccountVestedReleaseParams(address account) external view returns (VestedReleaseParams[] memory) {
        return userVests[account];
    }

    /// @notice Calculates the amount of tokens released for the given account.
    /// @param account_ The account to calculate the tokens released for
    function calculateTokensReleased(address account_) public view returns (uint256) {
        VestedReleaseParams memory params = userVests[account_];
        if (block.timestamp < params.startTime) return 0;
        if (block.timestamp >= params.endTime) return params.totalAmount;
        uint256 timePassed = block.timestamp - params.startTime;
        uint256 totalTime = params.endTime - params.startTime;
        return params.totalAmount.mulDiv(timePassed, totalTime);
    }
}
