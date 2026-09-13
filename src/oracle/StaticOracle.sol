// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracle} from "../interfaces/IBank.sol";
import {Roles} from "../lib/Roles.sol";
import {FullMath} from "../lib/FullMath.sol";

/// @title StaticOracle
/// @notice Admin-set price oracle (18-dec mantissa) for bootstrapping and testnet demos.
/// @dev Real deployments should switch FuguiBank to `TwapOracle` once AMM pools are deep.
///      Setting a price automatically installs its multiplicative inverse.
contract StaticOracle is IPriceOracle, Roles {
    bytes32 public constant ROLE_SETTER = keccak256("SETTER");

    /// @dev priceOf[base][quote] = amount of quote (1e18 scale) per 1e18 of base.
    mapping(address => mapping(address => uint256)) public priceOf;

    event PriceSet(address indexed base, address indexed quote, uint256 price);

    error UnsetPrice(address base, address quote);
    error ZeroPrice();

    function setPrice(address base, address quote, uint256 price) external onlyRole(ROLE_SETTER) {
        if (price == 0) revert ZeroPrice();
        priceOf[base][quote] = price;
        priceOf[quote][base] = FullMath.mulDiv(1e36, 1, price);
        emit PriceSet(base, quote, price);
    }

    function consult(address tokenIn, uint256 amountIn, address tokenOut)
        external
        view
        override
        returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut) return amountIn;
        uint256 price = priceOf[tokenIn][tokenOut];
        if (price == 0) revert UnsetPrice(tokenIn, tokenOut);
        amountOut = FullMath.mulDiv(amountIn, price, 1e18);
    }
}
