// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "oz/utils/math/SafeCast.sol";

import {ud60x18} from "@prb/math/src/UD60x18.sol";
import {ud2x18} from "@prb/math/src/UD2x18.sol";
import {ISablierV2LockupLinear} from "@sablier/v2-core/src/interfaces/ISablierV2LockupLinear.sol";
import {ISablierV2LockupDynamic} from "@sablier/v2-core/src/interfaces/ISablierV2LockupDynamic.sol";
import {Broker, LockupLinear, LockupDynamic} from "@sablier/v2-core/src/types/DataTypes.sol";

abstract contract SablierStreamCreator {
    using SafeCast for uint256;
    //@note  maybe we need to move this to the exercise contract??
    ISablierV2LockupLinear public immutable LOCKUP_LINEAR; 
    //Mainnet Addr ISablierV2LockupLinear(0xAFb979d9afAd1aD27C5eFf4E27226E3AB9e5dCC9);

    ISablierV2LockupDynamic public immutable LOCKUP_DYNAMIC; 
    //Mainnet Addr ISablierV2LockupDynamic(0x7CC7e125d83A581ff438608490Cc0f7bDff79127);

    constructor(address lockupLinear_, address lockupDynamic_) {
        if(lockupLinear_ == address(0) || lockupDynamic_ == address(0)) {
            revert("SablierStreamCreator: cannot set zero address");
        }
        LOCKUP_LINEAR = ISablierV2LockupLinear(lockupLinear_);
        LOCKUP_DYNAMIC = ISablierV2LockupDynamic(lockupDynamic_);
    }

    /////////////////////////////////
    /// Stream Creation Functions ///
    /////////////////////////////////

    function createLinearStream(uint40 cliffDuration_, uint40 totalDuration_, uint256 amount_, address token_, address recipient_)
        internal
        virtual
        returns (uint256 streamId)
    {

        // Approve the Sablier contract to pull the tokens from this contract
        IERC20(token_).approve(address(LOCKUP_LINEAR), amount_);

        LockupLinear.CreateWithDurations memory params;
        // Declare the function parameters
        params.sender = address(this); // The sender will be able to cancel the stream
        params.recipient = recipient_; // The recipient of the streamed assets
        params.totalAmount = amount_.toUint128(); // Total amount is the amount inclusive of all fees
        params.asset = IERC20(token_); // The streaming asset
        params.cancelable = true; // Whether the stream will be cancelable or not
        params.transferable = true; // Whether the stream will be transferable or not @note do we want this?
        params.durations = LockupLinear.Durations({
            //@note just use this as a "locked" stream set the cliff duration to the time you wish to release the tokens and the totalDuration to clifftime + 1 seconds
            cliff: cliffDuration_, // Assets will be unlocked / begin streaming only after this time @note I think we want to keep this a constant
            total: totalDuration_ // Setting a total duration of the stream
        });
        params.broker = Broker(address(0), ud60x18(0)); // Optional parameter for charging a fee @note we take fees in other places so no need for this I believe

        // Create the LockupLinear stream using a function that sets the start time to `block.timestamp`
        streamId = LOCKUP_LINEAR.createWithDurations(params);

        IERC20(token_).approve(address(LOCKUP_LINEAR), 0);
    }

    function createStreamWithCustomSegments(uint256 amount_, address token_, address recipient_, LockupDynamic.Segment[] memory segments_) internal returns (uint256 streamId) {
       
        // Approve the Sablier contract to spend DAI
        IERC20(token_).approve(address(LOCKUP_DYNAMIC), amount_);

        // Declare the params struct
        LockupDynamic.CreateWithMilestones memory params;

        // Declare the function parameters
        params.sender = address(this); // The sender will be able to cancel the stream
        params.recipient = recipient_; // The recipient of the streamed assets
        params.totalAmount = amount_.toUint128(); // Total amount is the amount inclusive of all fees
        params.asset = IERC20(token_); // The streaming asset
        params.cancelable = true; // Whether the stream will be cancelable or not
        params.transferable = true; // Whether the stream will be transferable or not
        params.broker = Broker(address(0), ud60x18(0)); // Optional parameter left undefined
        params.segments = segments_;

        // Create the LockupDynamic stream
        streamId = LOCKUP_DYNAMIC.createWithMilestones(params);

        IERC20(token_).approve(address(LOCKUP_LINEAR), 0);
    }

    //@note can't pass an array of udx218 types @adam - I'm thinking this is the function exercise contract can implement to build their custom shapes
    ///@param amounts_ The amount of assets to be streamed in this segment, denoted in units of the asset's decimals.
    ///@param exponents_ The exponent of this segment, denoted as a fixed-point number. ex. ud2x18(6e18)
    ///@param milestones_ The Unix timestamp indicating this segment's end.
    function setSegments(uint128[] calldata amounts_, uint64[] calldata exponents_, uint40[] calldata milestones_) public virtual returns (LockupDynamic.Segment[] memory){}
   


    // Use this as an example for how to create a exponential stream - with custom segments we can create any type or stream we want.

    // function createExponentialStream(uint256 amount_, address token_, address recipient_) internal returns (uint256 streamId) {
       
    //     // Approve the Sablier contract to spend DAI
    //     IERC20(token_).approve(address(LOCKUP_DYNAMIC), amount_);

    //     // Declare the params struct
    //     LockupDynamic.CreateWithDeltas memory params;

    //     // Declare the function parameters
    //     params.sender = address(this); // The sender will be able to cancel the stream
    //     params.recipient = recipient_; // The recipient of the streamed assets
    //     params.totalAmount = amount_.toUint128(); // Total amount is the amount inclusive of all fees
    //     params.asset = IERC20(token_); // The streaming asset
    //     params.cancelable = true; // Whether the stream will be cancelable or not
    //     params.transferable = true; // Whether the stream will be transferable or not
    //     params.broker = Broker(address(0), ud60x18(0)); // Optional parameter left undefined

    //     // Declare a single-size segment to match the curve shape
    //     params.segments = new LockupDynamic.SegmentWithDelta[](1);
    //     params.segments[0] =
    //         LockupDynamic.SegmentWithDelta({ amount: amount_.toUint128(), delta: 100 days, exponent: ud2x18(6e18) });

    //     // Create the LockupDynamic stream
    //     streamId = LOCKUP_DYNAMIC.createWithDeltas(params);
    // }


}
