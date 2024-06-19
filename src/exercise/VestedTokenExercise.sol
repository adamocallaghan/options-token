// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.19;

import {Owned} from "solmate/auth/Owned.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
//import {SafeCast} from "oz/utils/math/SafeCast.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ISablierV2LockupLinear} from "@sablier/v2-core/src/interfaces/ISablierV2LockupLinear.sol";
import {ISablierV2LockupDynamic} from "@sablier/v2-core/src/interfaces/ISablierV2LockupDynamic.sol";

import {BaseExercise} from "../exercise/BaseExercise.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {OptionsToken} from "../OptionsToken.sol";
import {SablierStreamCreator} from "src/exercise/Sablier/SablierStreamCreator.sol";


/// @title Options Token Vested Exercise Contract
/// @author @funkornaut
/// @notice Contract that allows the holder of options tokens to exercise them,
/// in this case, by purchasing the underlying token at a discount to the market price 
/// and vested/released linearly over a set period of time per account.
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract VestedTokenExercise is BaseExercise, SablierStreamCreator {
    /// Library usage
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;
    //using SafeCast for uint256;

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

    /// @notice The length of time tokens will be vested before they are begin to release to the user - this is the cliff
    uint40 public cliffDuration;

    /// @notice The length of time it takes for the vested tokens to be fully released - this is the totalDuration
    uint40 public totalDuration;

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
        uint40 cliffDuration_,
        uint40 totalDuration_,
        address[] memory feeRecipients_,
        uint256[] memory feeBPS_
    ) BaseExercise(oToken_, feeRecipients_, feeBPS_) SablierStreamCreator(lockUpLinear_, lockUpDynamic_) Owned(owner_) {
        paymentToken = paymentToken_;
        underlyingToken = underlyingToken_;
        cliffDuration = cliffDuration_;
        totalDuration = totalDuration_;

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
        returns (uint256 paymentAmount, address, uint256 tokenId, uint256)
    {
        return _exercise(from, amount, recipient, params);
    }

    //@todo do we want to keep this in here and credit users if there is not enough tokens in the contract to create the whole stream?
    //@note the would need to create a stream if we keep the credit system in
    function claim(address to) external {
        uint256 amount = credit[msg.sender];
        if (amount == 0) return;
        credit[msg.sender] = 0;
        underlyingToken.safeTransfer(to, amount);
    }

    /// @notice allows the owener of the stream or an approved address to withdraw from the stream. The stream sender can call this function only if the to address is the recipient of the stream.
    function withdrawFromLinearStream(uint256 streamId, address to, uint128 amount) external {
        withdrawLinerStream(streamId, to, amount);
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

    /// @notice Allows the owner/sender of the stream to cancel the stream
    function cancelLinerStream(uint256 streamId) external onlyOwner {
        cancelLinearStream(streamId);
    }


    //////////////////////////
    /// Internal functions ///
    //////////////////////////

    function _exercise(address from, uint256 amount, address recipient, bytes memory params)
        internal
        returns (uint256 paymentAmount, address, uint256 tokenId, uint256)
    {

        // apply multiplier to price
        uint256 price = oracle.getPrice().mulDivUp(multiplier, MULTIPLIER_DENOM);

        paymentAmount = amount.mulWadUp(price);
        // @todo figure out max payment amount - do we need this?
        // if (paymentAmount > _params.totalAmount) revert Exercise__RequestedAmountTooHigh();

        // transfer payment tokens from user to the set receivers - these are the tokens the user needs to pay to get the underlying tokens at the discounted price
        distributeFeesFrom(paymentAmount, paymentToken, from);
        
        // create the token stream
        // @note needs to take a uint128 amount 
        ( , tokenId) = _createLinearStream(recipient, amount);

        emit Exercised(from, recipient, amount, paymentAmount);
    }

    function _createLinearStream(address to, uint256 amount) internal returns (uint256 remainingAmount, uint256 tokenId) { 
        uint256 balance = underlyingToken.balanceOf(address(this));
        if (amount > balance) {
            tokenId = createLinearStream(cliffDuration, totalDuration, balance, address(underlyingToken), to);
            remainingAmount = amount - balance;
        } else {
            tokenId = createLinearStream(cliffDuration, totalDuration, amount, address(underlyingToken), to);
        }
        credit[to] += remainingAmount;
    }

    ////////////////////////
    /// Helper Functions ///
    ////////////////////////

    /// @notice Returns the amount of payment tokens required to exercise the given amount of options tokens.
    /// @param amount The amount of options tokens to exercise
    function getPaymentAmount(uint256 amount) external view returns (uint256 paymentAmount) {
        paymentAmount = amount.mulWadUp(oracle.getPrice().mulDivUp(multiplier, MULTIPLIER_DENOM));
    }

    //@note probaly want this function - Sablier shoudl have a function that achieves this.
    /// @notice Calculates the amount of tokens released for the given account.
    /// @param account_ The account to calculate the tokens released for
    // function calculateTokensReleased(address account_) public view returns (uint256) {
    //     VestedReleaseParams memory params = userVests[account_];
    //     if (block.timestamp < params.startTime) return 0;
    //     if (block.timestamp >= params.endTime) return params.totalAmount;
    //     uint256 timePassed = block.timestamp - params.startTime;
    //     uint256 totalTime = params.endTime - params.startTime;
    //     return params.totalAmount.mulDiv(timePassed, totalTime);
    // }

}
