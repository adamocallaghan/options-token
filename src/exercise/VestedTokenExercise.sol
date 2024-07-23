// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.19;

import {Owned} from "solmate/auth/Owned.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";


import {BaseExercise} from "../exercise/BaseExercise.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {OptionsToken} from "../OptionsToken.sol";
import {SablierStreamCreator} from "src/sablier/SablierStreamCreator.sol";

struct VestedExerciseParams {
    uint256 maxPaymentAmount;
    uint256 deadline;
    uint256 multiplier;
}

/// @title Options Token Vested Exercise Contract
/// @author @funkornaut, @adamo
/// @notice Contract that allows the holder of options tokens to exercise them,
/// in this case, by purchasing the underlying token at a discount to the market price
/// and vested/released linearly over a set period of time per account.
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract VestedTokenExercise is BaseExercise, SablierStreamCreator {
    /// Library usage ///
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// Errors ///
    error Exercise__InvalidOracle();
    error Exercise__VestHasNotBeenSet(address);
    error Exercise__InvalidCliffDuration(uint40);
    error Exercise__ContractOutOfTokens();
    error Exercise__SlippageTooHigh();
    error Exercise__PastDeadline();
    error Exercise__InvalidMultiplier();

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

    /// @notice the discount given during exercising with locking to the LP
    uint256 public maxMultiplier = 3000; // 70% discount
    uint256 public minMultiplier = 8000; // 20% discount

    uint256 public minVestDuration = 7 * 86400; // one week
    uint256 public maxVestDuration = 52 * 7 * 86400; // one year

    /// @notice The length of time tokens will be vested before they are begin to release to the user - this is the cliff
    uint40 public cliffDuration;

    constructor(
        OptionsToken oToken_,
        address owner_,
        address sender_,
        address lockUpLinear_,
        address lockUpDynamic_,
        IERC20 paymentToken_,
        IERC20 underlyingToken_,
        IOracle oracle_,
        uint40 cliffDuration_,
        address[] memory feeRecipients_,
        uint256[] memory feeBPS_
    ) BaseExercise(oToken_, feeRecipients_, feeBPS_) SablierStreamCreator(sender_, lockUpLinear_, lockUpDynamic_) Owned(owner_) {
        paymentToken = paymentToken_;
        underlyingToken = underlyingToken_;

        _setCliffDuration(cliffDuration_);
        _setOracle(oracle_);

        emit SetOracle(oracle_);
    }

    /////////////////
    /// Modifiers ///
    /////////////////
    modifier contractHasTokens(uint256 amount) {
        if (IERC20(underlyingToken).balanceOf(address(this)) < amount) {
            revert Exercise__ContractOutOfTokens();
        }
        _;
    }

    //////////////////////////
    /// External functions ///
    //////////////////////////

    /// @notice Exercises options tokens to purchase the underlying tokens. This will start the vesting period of the underlying tokens
    /// @dev The oracle may revert if it cannot give a secure result.
    /// @param from The user that is exercising their options tokens
    /// @param amount The amount of options tokens to exercise
    /// @param recipient The recipient of the purchased underlying tokens
    function exercise(address from, uint256 amount, address recipient, bytes memory params)
        external
        override
        onlyOToken
        returns (uint256 paymentAmount, address, uint256 streamId, uint256)
    {
        return _exercise(from, amount, recipient, params);
    }

    ///////////////////////
    /// Owner functions ///
    ///////////////////////

    /// @notice Sets the oracle contract. Only callable by the owner.
    /// @param oracle_ The new oracle contract
    //@audit - should these be addresses not IOracle?
    function setOracle(IOracle oracle_) external onlyOwner {
        _setOracle(oracle_);
    }

    function setCliffDuration(uint40 cliffDuration_) external onlyOwner {
        _setCliffDuration(cliffDuration_);
    }

    //////////////////////////
    /// Internal functions ///
    //////////////////////////

    function _exercise(address from, uint256 amount, address recipient, bytes memory params)
        internal
        contractHasTokens(amount)
        returns (uint256 paymentAmount, address, uint256 vestDuration, uint256 streamId)
    {
        // ===============
        //  === CHECKS ===
        // ===============

        // decode params
        VestedExerciseParams memory _params = abi.decode(params, (VestedExerciseParams));

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
        distributeFeesFrom(paymentAmount, paymentToken, from);

        // ======================
        //  === Create Stream ===
        // ======================

        // get the lock duration using the chosen multiplier
        vestDuration = getLockDurationFromDiscount(_params.multiplier);

        // create the token stream
        (streamId) = createLinearStream(cliffDuration, uint40(vestDuration), amount, address(underlyingToken), recipient);

        emit Exercised(from, recipient, amount, paymentAmount);
    }

    function _setCliffDuration(uint40 cliffDuration_) internal {
        if (cliffDuration_ > minVestDuration) revert Exercise__InvalidCliffDuration(cliffDuration_);
        cliffDuration = cliffDuration_;
    }

    function _setOracle(IOracle oracle_) internal {
        (address paymentToken_, address underlyingToken_) = oracle_.getTokens();
        if (paymentToken_ != address(paymentToken) || underlyingToken_ != address(underlyingToken)) {
            revert Exercise__InvalidOracle();
        }
        oracle = oracle_;
        emit SetOracle(oracle_);
    }

    ////////////////////////
    /// Helper Functions ///
    ////////////////////////

    // /// @notice Returns the amount of payment tokens required to exercise the given amount of options tokens.
    // /// @param amount The amount of options tokens to exercise
    // function getPaymentAmount(uint256 amount) internal view returns (uint256 paymentAmount) {
    //     paymentAmount = amount.mulWadUp(oracle.getPrice().mulDivUp(multiplier, MULTIPLIER_DENOM));
    // }

    function getLockDurationFromDiscount(uint256 _discount) public view returns (uint256 duration) {
        (int256 slope, int256 intercept) = getSlopeInterceptForLpDiscount();
        duration = SignedMath.abs(slope * int256(_discount) + intercept);
        // lockDuration = 1 weeks;
    }

    function getSlopeInterceptForLpDiscount() public view returns (int256 slope, int256 intercept) {
        slope = int256(maxVestDuration - minVestDuration) / (int256(maxMultiplier) - int256(minMultiplier));
        intercept = int256(minVestDuration) - (slope * int256(minMultiplier));
    }

}
