// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LhbRewards} from "../src/lhb/LhbRewards.sol";
import {StockToken} from "../src/tokens/StockToken.sol";

/// @title LhbRewardsTest
/// @notice Merkle epoch rewards: set root, fund, claim, double-claim, bad proofs.
contract LhbRewardsTest is Test {
    LhbRewards rewards;
    StockToken nvda;

    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");
    address a3 = makeAddr("a3");
    address outsider = makeAddr("outsider");

    uint256 amt1 = 100 ether;
    uint256 amt2 = 50 ether;
    uint256 amt3 = 25 ether;

    bytes32 l1;
    bytes32 l2;
    bytes32 l3;
    bytes32 root;

    function setUp() public {
        rewards = new LhbRewards();
        nvda = new StockToken("NVIDIA Stock Token", "tNVDA", "NVDA", "T");
        nvda.mint(address(this), 1_000 ether);
        nvda.approve(address(rewards), type(uint256).max);

        rewards.grantRole(rewards.ROLE_RANKER(), address(this));
        rewards.grantRole(rewards.ROLE_FUNDER(), address(this));

        // 4-leaf tree: (l1,l2) -> n1, (l3,l4) -> n2, root = hp(n1,n2)
        l1 = _leaf(a1, amt1);
        l2 = _leaf(a2, amt2);
        l3 = _leaf(a3, amt3);
        bytes32 l4 = _leaf(outsider, 1 ether);
        root = _hp(_hp(l1, l2), _hp(l3, l4));

        rewards.setEpoch(1, root, address(nvda), uint64(block.timestamp), uint64(block.timestamp + 1 days));
        rewards.fund(1, 176 ether); // amt1+amt2+amt3+1
    }

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _hp(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    function test_Claim_ValidPayout() public {
        vm.prank(a1);
        rewards.claim(1, amt1, _proof1());
        assertEq(nvda.balanceOf(a1), amt1);

        vm.prank(a3);
        rewards.claim(1, amt3, _proof3());
        assertEq(nvda.balanceOf(a3), amt3);

        (,,, uint256 claimed,,, bool set) = rewards.epochInfo(1);
        assertTrue(set);
        assertEq(claimed, amt1 + amt3);
    }

    function _proof1() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = l2;
        p[1] = _hp(l3, _leaf(outsider, 1 ether));
    }

    function _proof3() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = _leaf(outsider, 1 ether);
        p[1] = _hp(l1, l2);
    }

    function test_Claim_DoubleClaimReverts() public {
        vm.startPrank(a1);
        rewards.claim(1, amt1, _proof1());
        vm.expectRevert(abi.encodeWithSelector(LhbRewards.AlreadyClaimed.selector, 1, a1));
        rewards.claim(1, amt1, _proof1());
        vm.stopPrank();
    }

    function test_Claim_WrongAmountFailsProof() public {
        vm.prank(a1);
        bytes32[] memory p = _proof1();
        vm.expectRevert(LhbRewards.InvalidProof.selector);
        rewards.claim(1, amt1 + 1, p);
    }

    function test_Claim_GarbageProof() public {
        bytes32[] memory p = new bytes32[](2);
        p[0] = bytes32(uint256(1));
        p[1] = bytes32(uint256(2));
        vm.prank(a1);
        vm.expectRevert(LhbRewards.InvalidProof.selector);
        rewards.claim(1, amt1, p);
    }

    function test_Claim_UnsetEpoch() public {
        vm.prank(a1);
        bytes32[] memory p = _proof1();
        vm.expectRevert(abi.encodeWithSelector(LhbRewards.EpochNotSet.selector, 9));
        rewards.claim(9, amt1, p);
    }

    function test_SetEpoch_OnlyRanker() public {
        vm.prank(outsider);
        vm.expectRevert();
        rewards.setEpoch(2, root, address(nvda), uint64(block.timestamp), uint64(block.timestamp + 1 days));
    }

    function test_Fund_OnlyFunder() public {
        vm.prank(outsider);
        vm.expectRevert();
        rewards.fund(1, 1 ether);
    }

    function test_BadEpochWindow() public {
        vm.expectRevert(LhbRewards.BadEpochWindow.selector);
        rewards.setEpoch(3, root, address(nvda), 100, 100);
    }
}
