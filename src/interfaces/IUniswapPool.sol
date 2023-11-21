pragma solidity ^0.8.0;

import {IUniswapV3PoolDerivedState} from "v3-core/interfaces/pool/IUniswapV3PoolDerivedState.sol";
import {IUniswapV3PoolImmutables} from "v3-core/interfaces/pool/IUniswapV3PoolImmutables.sol";

/**
 * @dev Interface for querying historical data from a UniswapV3 Pool that can be used as a Price Oracle.
 * @notice From v3-core/interfaces
 */
interface IUniswapPool is IUniswapV3PoolDerivedState, IUniswapV3PoolImmutables {}
