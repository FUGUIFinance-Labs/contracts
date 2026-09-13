// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {Roles} from "../lib/Roles.sol";
import {MerkleProofLib} from "../lib/MerkleProofLib.sol";

/// @title LhbRewards — 龙虎榜激励
/// @notice Epoch-based Merkle rewards for the 富贵龙虎榜 terminal: the ranker
///         (indexer bot) publishes each epoch's leaderboard as a Merkle root;
///         winners claim payouts in Stock Tokens or $FUGUI.
/// @dev Leaf convention: keccak256(bytes.concat(keccak256(abi.encode(account, amount)))).
contract LhbRewards is Roles {
    bytes32 public constant ROLE_RANKER = keccak256("RANKER"); // publishes roots
    bytes32 public constant ROLE_FUNDER = keccak256("FUNDER"); // funds epochs

    struct Epoch {
        bytes32 root;
        address rewardToken;
        uint256 funded;
        uint256 claimed;
        uint64 startsAt;
        uint64 endsAt;
        bool set;
    }

    mapping(uint32 => Epoch) internal _epochs;
    /// @dev epochId => account => claimed
    mapping(uint32 => mapping(address => bool)) public hasClaimed;

    event EpochSet(uint32 indexed epochId, bytes32 root, address indexed rewardToken, uint64 startsAt, uint64 endsAt);
    event EpochFunded(uint32 indexed epochId, address indexed funder, uint256 amount);
    event Claimed(uint32 indexed epochId, address indexed account, uint256 amount);

    error EpochNotSet(uint32 epochId);
    error AlreadyClaimed(uint32 epochId, address account);
    error InvalidProof();
    error InsufficientFunding(uint256 requested, uint256 available);
    error ZeroAddress();
    error ZeroAmount();
    error BadEpochWindow();
    error RewardTokenMismatch();
    error TransferFailed();

    function setEpoch(
        uint32 epochId,
        bytes32 root,
        address rewardToken,
        uint64 startsAt,
        uint64 endsAt
    ) external onlyRole(ROLE_RANKER) {
        if (root == bytes32(0) || rewardToken == address(0)) revert ZeroAddress();
        if (endsAt <= startsAt) revert BadEpochWindow();
        _epochs[epochId] =
            Epoch({root: root, rewardToken: rewardToken, funded: 0, claimed: 0, startsAt: startsAt, endsAt: endsAt, set: true});
        emit EpochSet(epochId, root, rewardToken, startsAt, endsAt);
    }

    function fund(uint32 epochId, uint256 amount) external onlyRole(ROLE_FUNDER) {
        Epoch storage e = _epochs[epochId];
        if (!e.set) revert EpochNotSet(epochId);
        if (amount == 0) revert ZeroAmount();
        if (!IERC20(e.rewardToken).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        e.funded += amount;
        emit EpochFunded(epochId, msg.sender, amount);
    }

    function claim(uint32 epochId, uint256 amount, bytes32[] calldata proof) external {
        Epoch storage e = _epochs[epochId];
        if (!e.set) revert EpochNotSet(epochId);
        if (hasClaimed[epochId][msg.sender]) revert AlreadyClaimed(epochId, msg.sender);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        if (!MerkleProofLib.verify(proof, e.root, leaf)) revert InvalidProof();

        if (e.claimed + amount > e.funded) revert InsufficientFunding(amount, e.funded - e.claimed);

        hasClaimed[epochId][msg.sender] = true;
        e.claimed += amount;
        if (!IERC20(e.rewardToken).transfer(msg.sender, amount)) revert TransferFailed();
        emit Claimed(epochId, msg.sender, amount);
    }

    function epochInfo(uint32 epochId)
        external
        view
        returns (
            bytes32 root,
            address rewardToken,
            uint256 funded,
            uint256 claimed,
            uint64 startsAt,
            uint64 endsAt,
            bool set
        )
    {
        Epoch storage e = _epochs[epochId];
        return (e.root, e.rewardToken, e.funded, e.claimed, e.startsAt, e.endsAt, e.set);
    }
}
