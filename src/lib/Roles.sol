// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Roles
/// @notice Minimal single-key-role access control (admin can grant/revoke every role).
abstract contract Roles {
    bytes32 public constant ROLE_ADMIN = keccak256("ADMIN");

    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    error Unauthorized(bytes32 role, address account);

    mapping(bytes32 => mapping(address => bool)) private _roles;

    modifier onlyRole(bytes32 role) {
        if (!_roles[role][msg.sender]) revert Unauthorized(role, msg.sender);
        _;
    }

    modifier onlyAdmin() {
        if (!_roles[ROLE_ADMIN][msg.sender]) revert Unauthorized(ROLE_ADMIN, msg.sender);
        _;
    }

    constructor() {
        _grantRole(ROLE_ADMIN, msg.sender);
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyAdmin {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyAdmin {
        _revokeRole(role, account);
    }

    function renounceRole(bytes32 role) external {
        _revokeRole(role, msg.sender);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account);
        }
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account);
        }
    }
}
