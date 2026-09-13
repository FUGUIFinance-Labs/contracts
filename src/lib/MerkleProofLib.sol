// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MerkleProofLib
/// @notice Standard sorted-pair Merkle proof verification (OpenZeppelin-compatible proof format).
/// @dev Leaf convention: keccak256(bytes.concat(keccak256(abi.encode(PAYLOAD)))).
library MerkleProofLib {
    error InvalidProof();

    /// @notice Returns true if `leaf` can be proven to be a member of the tree rooted at `root`.
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    /// @notice Returns the rebuilt root obtained by traversing `proof`.
    function processProof(bytes32[] memory proof, bytes32 leaf) internal pure returns (bytes32 root) {
        root = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            root = _hashPair(root, proof[i]);
        }
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }
}
