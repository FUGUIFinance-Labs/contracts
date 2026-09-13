// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {IExchangeRouter} from "../interfaces/IBank.sol";
import {Roles} from "../lib/Roles.sol";
import {FullMath} from "../lib/FullMath.sol";

/// @title MockExchange
/// @notice Constant-product simulator used on the testnet (and in tests) wherever a
///         real DEX router sits on mainnet. Implements `IExchangeRouter` exactly.
/// @dev Admin helpers `setReserves` / `setPrice` let a keeper bot simulate market
///      moves (keeping the invariant k = rIn × rOut constant for setPrice).
contract MockExchange is IExchangeRouter, Roles {
    uint256 public constant BPS = 10_000;
    uint32 public feeBps = 30; // 0.3%

    /// @dev reserveOf[tokenA][tokenB] = reserve of tokenA on the A/B pair (mirrored).
    mapping(address => mapping(address => uint256)) public reserveOf;

    event LiquidityAdded(address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB);
    event ReservesSet(address indexed tokenA, address indexed tokenB, uint256 reserveA, uint256 reserveB);
    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    error InsufficientLiquidity(address tokenIn, address tokenOut);
    error InsufficientOutput(uint256 minOut, uint256 amountOut);
    error ZeroAmount();

    function setFeeBps(uint32 newFeeBps) external onlyAdmin {
        feeBps = newFeeBps;
    }

    function addLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB) external {
        if (amountA == 0 || amountB == 0) revert ZeroAmount();
        if (!IERC20(tokenA).transferFrom(msg.sender, address(this), amountA)) _revertTransfer();
        if (!IERC20(tokenB).transferFrom(msg.sender, address(this), amountB)) _revertTransfer();
        reserveOf[tokenA][tokenB] += amountA;
        reserveOf[tokenB][tokenA] += amountB;
        emit LiquidityAdded(tokenA, tokenB, amountA, amountB);
    }

    /// @notice Testnet-only: force reserves (e.g. to simulate depth changes).
    function setReserves(address tokenA, address tokenB, uint256 rA, uint256 rB) external onlyAdmin {
        reserveOf[tokenA][tokenB] = rA;
        reserveOf[tokenB][tokenA] = rB;
        emit ReservesSet(tokenA, tokenB, rA, rB);
    }

    /// @notice Testnet-only: move the market price of A/B while keeping k constant.
    /// @param priceAB Units of B (1e18 scale) per 1e18 of A.
    function setPrice(address tokenA, address tokenB, uint256 priceAB) external onlyAdmin {
        uint256 rA = reserveOf[tokenA][tokenB];
        uint256 rB = reserveOf[tokenB][tokenA];
        uint256 k = rA * rB;
        uint256 newRA = _sqrt(FullMath.mulDiv(k, 1e18, priceAB));
        uint256 newRB = _sqrt(FullMath.mulDiv(k, priceAB, 1e18));
        reserveOf[tokenA][tokenB] = newRA;
        reserveOf[tokenB][tokenA] = newRB;
        emit ReservesSet(tokenA, tokenB, newRA, newRB);
    }

    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        returns (uint256 amountOut)
    {
        uint256 rIn = reserveOf[tokenIn][tokenOut];
        uint256 rOut = reserveOf[tokenOut][tokenIn];
        if (rIn == 0 || rOut == 0) revert InsufficientLiquidity(tokenIn, tokenOut);
        uint256 effIn = FullMath.mulDiv(amountIn, BPS - feeBps, BPS);
        amountOut = FullMath.mulDiv(effIn, rOut, rIn + effIn);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external override returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        amountOut = getAmountOut(tokenIn, tokenOut, amountIn);
        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);

        if (!IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn)) _revertTransfer();
        reserveOf[tokenIn][tokenOut] += amountIn;
        reserveOf[tokenOut][tokenIn] -= amountOut;
        if (!IERC20(tokenOut).transfer(recipient, amountOut)) _revertTransfer();

        emit Swapped(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _revertTransfer() private pure {
        revert("MockExchange: TRANSFER_FAILED");
    }
}
