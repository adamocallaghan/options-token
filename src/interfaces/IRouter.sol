// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IRouter {
    struct route {
        address from;
        address to;
        bool stable;
    }

    function pairFor(address tokenA, address tokenB, bool stable) external view returns (address pair);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, route[] calldata routes, address to, uint256 deadline)
        external
        returns (uint256[] memory amounts);
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function isPair(address pair) external view returns (bool);
    function getReserves(address tokenA, address tokenB, bool stable) external view returns (uint256 reserveA, uint256 reserveB);
    function quoteRemoveLiquidity(address tokenA, address tokenB, bool stable, uint256 liquidity)
        external
        view
        returns (uint256 amountA, uint256 amountB);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountA, uint amountB)
}
