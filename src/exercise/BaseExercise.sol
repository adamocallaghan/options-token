// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {IExercise} from "../interfaces/IExercise.sol";
import {OptionsToken} from "../OptionsToken.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

abstract contract BaseExercise is IExercise, Owned {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    error Exercise__NotOToken();
    error Exercise__feeArrayLengthMismatch();

    event SetFees(address[] feeRecipients, uint256[] feeBPS);
    event DistributeFees(address[] feeRecipients, uint256[] feeBPS, uint256 totalAmount);

    uint256 public constant FEE_DENOMINATOR = 10_000;

    OptionsToken public immutable oToken;

    /// @notice The fee addresses which receive any tokens paid during redemption
    address[] public feeRecipients;

    /// @notice The fee percentage in basis points, feeRecipients[n] receives
    /// feeBPS[n] * fee / 10_000 in fees
    uint256[] public feeBPS;

    constructor (OptionsToken _oToken, address[] memory _feeRecipients, uint256[] memory _feeBPS) {
        oToken = _oToken;
        if (_feeRecipients.length != _feeBPS.length) revert Exercise__feeArrayLengthMismatch();
        feeRecipients = _feeRecipients;
        feeBPS = _feeBPS;
    }

    modifier onlyOToken() {
        if (msg.sender != address(oToken)) revert Exercise__NotOToken();
        _;
    }

    /// @notice Called by the oToken and handles rewarding logic for the user.
    /// @dev *Must* have onlyOToken modifier.
    /// @param from Wallet that is exercising tokens
    /// @param amount Amount of tokens being exercised
    /// @param recipient Wallet that will receive the rewards for exercising the oTokens
    /// @param params Extraneous parameters that the function may use - abi.encoded struct
    function exercise(address from, uint256 amount, address recipient, bytes memory params)
        external
        virtual
        returns (bytes memory data);
    
    function setFees(address[] memory _feeRecipients, uint256[] memory _feeBPS) external onlyOwner {
        if (_feeRecipients.length != _feeBPS.length) revert Exercise__feeArrayLengthMismatch();
        feeRecipients = _feeRecipients;
        feeBPS = _feeBPS;
        emit SetFees(_feeRecipients, _feeBPS);
    }

    /// @notice Distributes fees to the fee recipients from a token holder who has approved
    function distributeFeesFrom(uint256 totalAmount, ERC20 token, address from) internal virtual{
        for (uint256 i = 0; i < feeRecipients.length; i++) {
            uint256 feeAmount = totalAmount * feeBPS[i] / FEE_DENOMINATOR;
            token.safeTransferFrom(from, feeRecipients[i], feeAmount);
        }
        emit DistributeFees(feeRecipients, feeBPS, totalAmount);
    }

    /// @notice Distributes fees to the fee recipients from token balance of exercise contract
    function distributeFees(uint256 totalAmount, ERC20 token, address from) internal virtual{
        for (uint256 i = 0; i < feeRecipients.length; i++) {
            uint256 feeAmount = totalAmount * feeBPS[i] / FEE_DENOMINATOR;
            token.safeTransfer(feeRecipients[i], feeAmount);
        }
        emit DistributeFees(feeRecipients, feeBPS, totalAmount);
    }
}
