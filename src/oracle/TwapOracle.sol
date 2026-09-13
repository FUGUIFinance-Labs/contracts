// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracle} from "../interfaces/IBank.sol";
import {Roles} from "../lib/Roles.sol";
import {FullMath} from "../lib/FullMath.sol";

/// @title TwapOracle
/// @notice Time-weighted average price oracle over Uniswap-V2-style pairs
///         (price0CumulativeLast / price1CumulativeLast / getReserves interface).
/// @dev Follows the canonical "ExampleOracleSimple" pattern: `update(pair)` must be
///      called at least once per `period`; `consult` then reads the stored average.
contract TwapOracle is IPriceOracle, Roles {
    struct PairObs {
        address token0;
        address token1;
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
        uint32 blockTimestampLast;
        uint224 price0Average; // UQ112x112
        uint224 price1Average; // UQ112x112
        bool initialized;
    }

    uint32 public period = 30 minutes;

    mapping(address => PairObs) internal _pairs;
    /// @dev tokenA -> tokenB -> pair
    mapping(address => mapping(address => address)) public pairFor;

    event PairRegistered(address indexed pair, address indexed token0, address indexed token1);
    event PeriodUpdated(uint32 period);

    error PairNotRegistered(address pair);
    error EmptyReserves(address pair);
    error PairNotInitialized(address tokenIn, address tokenOut);

    function setPeriod(uint32 newPeriod) external onlyAdmin {
        period = newPeriod;
        emit PeriodUpdated(newPeriod);
    }

    /// @notice Register a V2-style pair for TWAP tracking.
    function registerPair(address pair) external onlyAdmin {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert EmptyReserves(pair);

        PairObs storage o = _pairs[pair];
        o.token0 = IUniswapV2Pair(pair).token0();
        o.token1 = IUniswapV2Pair(pair).token1();
        o.price0CumulativeLast = IUniswapV2Pair(pair).price0CumulativeLast();
        o.price1CumulativeLast = IUniswapV2Pair(pair).price1CumulativeLast();
        (,, o.blockTimestampLast) = IUniswapV2Pair(pair).getReserves();
        o.initialized = true;

        pairFor[o.token0][o.token1] = pair;
        pairFor[o.token1][o.token0] = pair;
        emit PairRegistered(pair, o.token0, o.token1);
    }

    /// @notice Roll the cumulative observations forward. Returns false when called
    ///         again within one period.
    function update(address pair) external returns (bool) {
        PairObs storage o = _pairs[pair];
        if (!o.initialized) revert PairNotRegistered(pair);

        (,, uint32 blockTimestamp) = IUniswapV2Pair(pair).getReserves();
        uint32 elapsed = blockTimestamp - o.blockTimestampLast;
        if (elapsed < period) return false;

        uint256 price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
        uint256 price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();

        o.price0Average = uint224(FullMath.mulDiv(price0Cumulative - o.price0CumulativeLast, 1, elapsed));
        o.price1Average = uint224(FullMath.mulDiv(price1Cumulative - o.price1CumulativeLast, 1, elapsed));
        o.price0CumulativeLast = price0Cumulative;
        o.price1CumulativeLast = price1Cumulative;
        o.blockTimestampLast = blockTimestamp;
        return true;
    }

    /// @notice Quote `amountIn` of `tokenIn` into `tokenOut` using the stored TWAP.
    function consult(address tokenIn, uint256 amountIn, address tokenOut)
        external
        view
        override
        returns (uint256 amountOut)
    {
        address pair = pairFor[tokenIn][tokenOut];
        PairObs storage o = _pairs[pair];
        if (!o.initialized) revert PairNotInitialized(tokenIn, tokenOut);

        uint224 average = tokenIn == o.token0 ? o.price0Average : o.price1Average;
        amountOut = FullMath.mulDiv(amountIn, average, 2 ** 112);
    }
}

/// @notice The slice of the Uniswap-V2 pair interface this oracle reads.
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
}
