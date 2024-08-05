// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "oz/utils/math/SafeCast.sol";

import {ud60x18} from "@prb/math/src/UD60x18.sol";
import {ud2x18} from "@prb/math/src/UD2x18.sol";
import {ISablierV2LockupLinear} from "@sablier/v2-core/src/interfaces/ISablierV2LockupLinear.sol";
import {ISablierV2LockupDynamic} from "@sablier/v2-core/src/interfaces/ISablierV2LockupDynamic.sol";
import {Broker, LockupLinear, LockupDynamic} from "@sablier/v2-core/src/types/DataTypes.sol";

struct ConstructorAddresses {
    address sender;
    address lockupLinear;
    address lockupDynamic;
}

abstract contract SablierStreamCreator {
    using SafeCast for uint256;

    error SablierStreamCreator__SegmentsNotSet();
    error SablierStreamCreator__RecipientCannotBeAContract();

    address public immutable SENDER;
    ISablierV2LockupLinear public immutable LOCKUP_LINEAR;
    ISablierV2LockupDynamic public immutable LOCKUP_DYNAMIC;

    uint64[] public segmentExponents;
    uint40[] public segmentDurations;

    constructor(ConstructorAddresses constructorAddresses) {
        if (
            constructorAddresses.lockupLinear_ == address(0) || constructorAddresses.lockupDynamic_ == address(0)
                || constructorAddresses.sender_ == address(0)
        ) {
            revert("SablierStreamCreator: cannot set zero address");
        }
        SENDER = constructorAddresses.sender_;
        LOCKUP_LINEAR = ISablierV2LockupLinear(constructorAddresses.lockupLinear_);
        LOCKUP_DYNAMIC = ISablierV2LockupDynamic(constructorAddresses.lockupDynamic_);
    }

    /////////////////////////////////
    /// Stream Creation Functions ///
    /////////////////////////////////

    function createLinearStream(uint40 cliffDuration_, uint40 totalDuration_, uint256 amount_, address token_, address recipient_)
        internal
        virtual
        returns (uint256 streamId)
    {
        // revert if the recipient is a contract
        if (recipient_.code.length > 0) {
            revert SablierStreamCreator__RecipientCannotBeAContract();
        }

        // Approve the Sablier contract to pull the tokens from this contract
        IERC20(token_).approve(address(LOCKUP_LINEAR), amount_);

        LockupLinear.CreateWithDurations memory params;
        // Declare the function parameters
        params.sender = SENDER; // The sender will be able to cancel the stream
        params.recipient = recipient_; // The recipient of the streamed assets
        params.totalAmount = amount_.toUint128(); // Total amount is the amount inclusive of all fees
        params.asset = IERC20(token_); // The streaming asset
        params.cancelable = true; // Whether the stream will be cancelable or not
        params.transferable = true; // Whether the stream will be transferable or not
        params.durations = LockupLinear.Durations({
            cliff: cliffDuration_, // Assets will be unlocked / begin streaming only after this time
            total: totalDuration_ // Setting a total duration of the stream
        });
        params.broker = Broker(address(0), ud60x18(0)); // Optional parameter for charging a fee

        // Create the LockupLinear stream using a function that sets the start time to `block.timestamp`
        streamId = LOCKUP_LINEAR.createWithDurations(params);

        IERC20(token_).approve(address(LOCKUP_LINEAR), 0);
    }

    function createStreamWithCustomSegments(uint256 amount_, address token_, address recipient_) internal returns (uint256 streamId) {
        // Approve the Sablier contract to spend DAI
        IERC20(token_).approve(address(LOCKUP_DYNAMIC), amount_);

        // Declare the params struct
        LockupDynamic.CreateWithDurations memory params;

        // Declare the function parameters
        params.sender = SENDER; // The sender will be able to cancel the stream
        params.recipient = recipient_; // The recipient of the streamed assets
        params.totalAmount = amount_.toUint128(); // Total amount is the amount inclusive of all fees
        params.asset = IERC20(token_); // The streaming asset
        params.cancelable = true; // Whether the stream will be cancelable or not
        params.transferable = true; // Whether the stream will be transferable or not
        params.broker = Broker(address(0), ud60x18(0)); // Optional parameter left undefined
        params.segments = _constructSegmentWithDuration(amount_);

        // Create the LockupDynamic stream
        streamId = LOCKUP_DYNAMIC.createWithDurations(params);

        IERC20(token_).approve(address(LOCKUP_LINEAR), 0);
    }

    ///@notice Set the segments aka define the shape of streams
    ///@notice The amount for the stream will be divided up equally into each section based on the number of segments
    ///@param exponents_ The exponent of this segment, denoted as a fixed-point number. ex. ud2x18(6e18)
    ///@param deltas_ The time in seconds of when each segment ends
    function setSegments(uint64[] calldata exponents_, uint40[] calldata deltas_) external virtual {}

    ///@notice Construct the segments for the stream creation
    ///@param amount_ The amount of the stream
    ///@dev Sablier checks that the total deposited amount is equal to the sum of the segment amounts otherwise stream creation will revert. To handle truncation and make sure we stream the full amount to the recipient we take the remainder from the division of amount and segments length and add it to the amoun stream in the last segment.
    function _constructSegmentWithDuration(uint256 amount_) internal view returns (LockupDynamic.SegmentWithDuration[] memory) {
        if (segmentExponents.length == 0 || segmentDurations.length == 0) {
            revert SablierStreamCreator__SegmentsNotSet();
        }
        uint256 amountPerSegment = amount_ / segmentExponents.length;
        uint256 remainder = amount_ % segmentExponents.length;

        LockupDynamic.SegmentWithDuration[] memory segments = new LockupDynamic.SegmentWithDuration[](segmentExponents.length);
        for (uint256 i = 0; i < segmentExponents.length; i++) {
            uint128 segmentAmount = amountPerSegment.toUint128();
            // Add the remainder to the last segment
            if (i == segmentExponents.length - 1) {
                segmentAmount += remainder.toUint128();
            }

            segments[i] =
                LockupDynamic.SegmentWithDuration({amount: segmentAmount, exponent: ud2x18(segmentExponents[i]), duration: segmentDurations[i]});
        }
        return segments;
    }
}
