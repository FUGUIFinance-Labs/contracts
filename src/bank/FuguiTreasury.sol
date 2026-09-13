// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {Roles} from "../lib/Roles.sol";

/// @title FuguiTreasury — 富贵金库
/// @notice Holds protocol fees and prize pools (Stock Tokens / $FUGUI / ETH).
///         Payouts are gated behind the PAYOUT role (multisig on mainnet).
contract FuguiTreasury is Roles {
    bytes32 public constant ROLE_PAYOUT = keccak256("PAYOUT");

    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();

    constructor() {
        _grantRole(ROLE_PAYOUT, msg.sender);
    }

    /// @notice Withdraw an ERC-20; `token == address(0)` withdraws ETH.
    function withdraw(address token, address to, uint256 amount) external onlyRole(ROLE_PAYOUT) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
        }
        emit Withdrawn(token, to, amount);
    }

    receive() external payable {}
}
