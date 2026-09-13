// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {Roles} from "../lib/Roles.sol";

/// @title StockToken
/// @notice Tokenized US stock (ERC-20) stand-in for Robinhood Chain Stock Tokens
///         (tNVDA, tGME, ...) — 1 token : 1 share of economic exposure.
/// @dev On mainnet the protocol consumes Robinhood's official Stock Token addresses
///      through the same ERC-20 interface. This mock adds issuer metadata and an
///      emergency transfer lock for compliance simulations.
contract StockToken is Roles, IERC20 {
    string public name;
    string public symbol;
    string public underlyingTicker;
    string public issuer;

    uint8 public constant decimals = 18;
    uint256 public override totalSupply;
    bool public transfersLocked;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    bytes32 public constant ROLE_ISSUER = keccak256("ISSUER");

    event TransfersLocked(bool locked);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error TransfersLockedError();

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _underlyingTicker,
        string memory _issuer
    ) {
        name = _name;
        symbol = _symbol;
        underlyingTicker = _underlyingTicker;
        issuer = _issuer;
        _grantRole(ROLE_ISSUER, msg.sender);
    }

    /// @notice Rich meta for the LHB terminal.
    function meta()
        external
        view
        returns (string memory ticker, string memory issuerName, bool locked)
    {
        return (underlyingTicker, issuer, transfersLocked);
    }

    function mint(address to, uint256 amount) external onlyRole(ROLE_ISSUER) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) revert InsufficientBalance();
        balanceOf[msg.sender] = bal - amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function setTransfersLocked(bool locked) external onlyAdmin {
        transfersLocked = locked;
        emit TransfersLocked(locked);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (transfersLocked && msg.sender != from) revert TransfersLockedError();
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
