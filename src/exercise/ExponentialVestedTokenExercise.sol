// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.19;

import {Owned} from "solmate/auth/Owned.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {BaseExercise} from "../exercise/BaseExercise.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {OptionsToken} from "../OptionsToken.sol";
import {SablierStreamCreator} from "src/sablier/SablierStreamCreator.sol";


/// @title Exponentially Vested Options Token Exercise Contract
/// @author @funkornaut
/// @notice Contract that allows the holder of options tokens to exercise them,
/// in this case, by purchasing the underlying token at a discount to the market price 
/// and vested/released exponentially over a set period of time per account.
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract ExponentialVestedTokenExercise is BaseExercise, SablierStreamCreator {
    /// Library usage ///
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// Errors /// 
    error Exercise__RequestedAmountTooHigh();
    error Exercise__VestHasNotStarted();
    error Exercise__MultiplierOutOfRange();
    error Exercise__InvalidOracle();
    error Exercise__VestHasNotBeenSet(address);
    error Exercise__InvalidTotalDuration(uint40);
    error Exercise__InvalidCliffDuration(uint40);
    error Exercise__NothingToClaim();

    /// Events ///
    event Exercised(address indexed sender, address indexed recipient, uint256 amount, uint256 paymentAmount);
    event SetOracle(IOracle indexed newOracle);
    event SetTreasury(address indexed newTreasury);
    event SetMultiplier(uint256 indexed newMultiplier);

    /////////////////
    /// Constants ///
    /////////////////

    /// @notice The denominator for converting the multiplier into a decimal number.
    /// i.e. multiplier uses 4 decimals.
    uint256 internal constant MULTIPLIER_DENOM = 10000;

    ////////////////////////////
    /// Immutable parameters ///
    ////////////////////////////

    /// @notice The token paid by the options token holder during redemption
    IERC20 public immutable paymentToken;

    /// @notice The underlying token purchased during redemption
    IERC20 public immutable underlyingToken;

    /////////////////////////
    /// Storage variables ///
    /////////////////////////

    /// @notice The oracle contract that provides the current price to purchase
    /// the underlying token while exercising options (the strike price)
    IOracle public oracle;

    /// @notice The multiplier applied to the TWAP value. Encodes the discount of
    /// the options token. Uses 4 decimals.
    uint256 public multiplier;

    /// @notice The amount of payment tokens the user can claim
    /// Used when the contract does not have enough tokens to pay the user
    mapping (address => uint256) public credit;

    //@todo add checks for vesting times
    constructor(
        OptionsToken oToken_,
        address owner_,
        address lockUpLinear_,
        address lockUpDynamic_,
        IERC20 paymentToken_,
        IERC20 underlyingToken_,
        IOracle oracle_,
        uint256 multiplier_,
        address[] memory feeRecipients_,
        uint256[] memory feeBPS_
    ) BaseExercise(oToken_, feeRecipients_, feeBPS_) SablierStreamCreator(lockUpLinear_, lockUpDynamic_) Owned(owner_) {
        paymentToken = paymentToken_;
        underlyingToken = underlyingToken_;

        _setOracle(oracle_);
        _setMultiplier(multiplier_);

        emit SetOracle(oracle_);
    }

    //////////////////////////
    /// External functions ///
    //////////////////////////

    /// @notice Exercises options tokens to purchase the underlying tokens. This will start the vesting period of the underlying tokens
    /// @dev The oracle may revert if it cannot give a secure result.
    /// @param from The user that is exercising their options tokens
    /// @param amount The amount of options tokens to exercise
    /// @param recipient The recipient of the purchased underlying tokens
    // @note don't need params - leave empty
    function exercise(address from, uint256 amount, address recipient, bytes memory params)
        external
        override
        onlyOToken 
        returns (uint256 paymentAmount, address, uint256 streamId, uint256)
    {
        return _exercise(from, amount, recipient, params);
    }

    /// @notice Claims the tokens for a user creating a new stream  
    function claim(address to) external returns (uint256 streamId) {
        uint256 amount = credit[msg.sender];
        if (amount == 0) revert Exercise__NothingToClaim();
        credit[msg.sender] = 0;
        (, streamId) = _createExponentialStream(to, amount);
    }


    ///////////////////////
    /// Owner functions ///
    ///////////////////////

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


    //////////////////////////
    /// Internal functions ///
    //////////////////////////

    function _exercise(address from, uint256 amount, address recipient, bytes memory params)
        internal
        returns (uint256 paymentAmount, address, uint256 streamId, uint256)
    {

        // apply multiplier to price
        paymentAmount = getPaymentAmount(amount);

        // @todo figure out max payment amount - do we need this?
        // if (paymentAmount > _params.totalAmount) revert Exercise__RequestedAmountTooHigh();

        // transfer payment tokens from user to the set receivers - these are the tokens the user needs to pay to get the underlying tokens at the discounted price
        distributeFeesFrom(paymentAmount, paymentToken, from);
        
        // create the token stream
        ( , streamId) = _createExponentialStream(recipient, amount);

        emit Exercised(from, recipient, amount, paymentAmount);
    }

    function _createExponentialStream(address to, uint256 amount) internal returns (uint256 remainingAmount, uint256 streamId) { 
        uint256 balance = underlyingToken.balanceOf(address(this));
        if (amount > balance) {
            streamId = createExponentialStream(balance, address(underlyingToken), to);
            remainingAmount = amount - balance;
        } else {
            streamId = createExponentialStream(amount, address(underlyingToken), to);
        }
        credit[to] += remainingAmount;
    }

    ////////////////////////
    /// Helper Functions ///
    ////////////////////////

    /// @notice Returns the amount of payment tokens required to exercise the given amount of options tokens.
    /// @param amount The amount of options tokens to exercise
    function getPaymentAmount(uint256 amount) internal view returns (uint256 paymentAmount) {
        paymentAmount = amount.mulWadUp(oracle.getPrice().mulDivUp(multiplier, MULTIPLIER_DENOM));
    }

}
