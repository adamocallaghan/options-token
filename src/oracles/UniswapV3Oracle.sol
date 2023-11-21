// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import "forge-std/console.sol";

import {IUniswapPool} from "../interfaces/IUniswapPool.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";

/// @title Oracle using Uniswap TWAP oracle as data source
/// @author zefram.eth & lookeey
/// @notice The oracle contract that provides the current price to purchase
/// the underlying token while exercising options. Uses UniswapV3 TWAP oracle
/// as data source, and then applies a multiplier & lower bound.
/// @dev IMPORTANT: This oracle assumes both tokens have 18 decimals, and
/// returns the price with 18 decimals.
contract UniswapV3Oracle is IOracle, Owned {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using FixedPointMathLib for uint256;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error UniswapOracle__TWAPOracleNotReady();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event SetParams(uint16 multiplier, uint56 secs, uint56 ago, uint128 minPrice);

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @notice The denominator for converting the multiplier into a decimal number.
    /// i.e. multiplier uses 4 decimals.
    uint256 internal constant MULTIPLIER_DENOM = 10000;

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The UniswapV3 Pool contract (provides the oracle)
    IUniswapPool public immutable uniswapPool;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice The multiplier applied to the TWAP value. Encodes the discount of
    /// the options token. Uses 4 decimals.
    uint16 public multiplier;

    /// @notice The size of the window to take the TWAP value over in seconds.
    uint32 public secs;

    /// @notice The number of seconds in the past to take the TWAP from. The window
    /// would be (block.timestamp - secs - ago, block.timestamp - ago].
    uint32 public ago;

    /// @notice The minimum value returned by getPrice(). Maintains a floor for the
    /// price to mitigate potential attacks on the TWAP oracle.
    uint128 public minPrice;

    /// @notice Whether the price should be returned in terms of token0.
    /// If false, the price is returned in terms of token1.
    bool public isToken0;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(
        IUniswapPool uniswapPool_,
        address token,
        address owner_,
        uint16 multiplier_,
        uint32 secs_,
        uint32 ago_,
        uint128 minPrice_
    ) Owned(owner_) {
        uniswapPool = uniswapPool_;
        isToken0 = token == uniswapPool_.token0();
        multiplier = multiplier_;
        secs = secs_;
        ago = ago_;
        minPrice = minPrice_;

        emit SetParams(multiplier_, secs_, ago_, minPrice_);
    }

    /// -----------------------------------------------------------------------
    /// IOracle
    /// -----------------------------------------------------------------------

    /// @inheritdoc IOracle
    function getPrice() external view override returns (uint256 price) {
        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint256 multiplier_ = multiplier;
        uint32 secs_ = secs;
        uint32 ago_ = ago;
        uint256 minPrice_ = minPrice;

        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        // The UniswapV3 pool reverts on invalid TWAP queries, so we don't need to

        /// -----------------------------------------------------------------------
        /// Computation
        /// -----------------------------------------------------------------------

        // query Uniswap oracle to get TWAP tick
        {
            uint32 _twapDuration = secs_;
            uint32 _twapAgo = ago_;
            uint32[] memory secondsAgo = new uint32[](2);
            secondsAgo[0] = _twapDuration + _twapAgo;
            secondsAgo[1] = _twapAgo;

            (int56[] memory tickCumulatives,) = uniswapPool.observe(secondsAgo);
            int24 tick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(_twapDuration)));

            // token decimals is 18
            uint256 decimals = 1e18;

            // from https://optimistic.etherscan.io/address/0xB210CE856631EeEB767eFa666EC7C1C57738d438#code#F5#L49
            uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

            // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
            if (sqrtRatioX96 <= type(uint128).max) {
                uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
                price = isToken0
                    ? FullMath.mulDiv(ratioX192, decimals, 1 << 192)
                    : FullMath.mulDiv(1 << 192, decimals, ratioX192);
            } else {
                uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
                price = isToken0
                    ? FullMath.mulDiv(ratioX128, decimals, 1 << 128)
                    : FullMath.mulDiv(1 << 128, decimals, ratioX128);
            }
        }

        // apply multiplier to price
        price = price.mulDivUp(multiplier_, MULTIPLIER_DENOM);

        // bound price above minPrice
        price = price < minPrice_ ? minPrice_ : price;
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @notice Updates the oracle parameters. Only callable by the owner.
    /// @param multiplier_ The multiplier applied to the TWAP value. Encodes the discount of
    /// the options token. Uses 4 decimals.
    /// @param secs_ The size of the window to take the TWAP value over in seconds.
    /// @param ago_ The number of seconds in the past to take the TWAP from. The window
    /// would be (block.timestamp - secs - ago, block.timestamp - ago].
    /// @param minPrice_ The minimum value returned by getPrice(). Maintains a floor for the
    /// price to mitigate potential attacks on the TWAP oracle.
    /// @param isToken0_ Whether the price should be returned in terms of token0.
    function setParams(uint16 multiplier_, uint32 secs_, uint32 ago_, uint128 minPrice_, bool isToken0_)
        external
        onlyOwner
    {
        multiplier = multiplier_;
        secs = secs_;
        ago = ago_;
        minPrice = minPrice_;
        isToken0 = isToken0_;
        emit SetParams(multiplier_, secs_, ago_, minPrice_);
    }
}
