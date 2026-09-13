// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice DEX router abstraction. One function is enough: swap and deliver to `recipient`.
/// @dev On mainnet implement an adapter over the live DEX (Noxa / Uniswap router);
///      on testnet use `mocks/MockExchange.sol` which provides the same interface.
interface IExchangeRouter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);
}

/// @notice Price oracle abstraction: quote `amountIn` of `tokenIn` in `tokenOut` (18-dec scale).
/// @dev Implementations: `oracle/TwapOracle.sol` (Uniswap-V2 TWAP) and
///      `oracle/StaticOracle.sol` (admin-set prices, testnet / bootstrap).
interface IPriceOracle {
    function consult(address tokenIn, uint256 amountIn, address tokenOut)
        external
        view
        returns (uint256 amountOut);
}

/// @notice What FuguiBank needs from the BankNote (银票) NFT.
interface IBankNote {
    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
}
