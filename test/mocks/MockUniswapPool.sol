// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.11;

import {IUniswapPool} from "../../src/interfaces/IUniswapPool.sol";

contract MockUniswapPool is IUniswapPool {
    int56[2] cumulatives;
    address public token0;

    function setCumulatives(int56[2] memory value) external {
        cumulatives = value;
    }

    function setToken0(address value) external {
        token0 = value;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        secondsAgos;
        secondsPerLiquidityCumulativeX128s;

        tickCumulatives = new int56[](2);
        tickCumulatives[0] = cumulatives[0];
        tickCumulatives[1] = cumulatives[1];
    }

    // mandatory overrides

    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        override
        returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside)
    {}

    function factory() external view override returns (address) {}

    function token1() external view override returns (address) {}

    function fee() external view override returns (uint24) {}

    function tickSpacing() external view override returns (int24) {}

    function maxLiquidityPerTick() external view override returns (uint128) {}
}
