// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FuguiToken} from "../src/tokens/FuguiToken.sol";
import {StockToken} from "../src/tokens/StockToken.sol";
import {StaticOracle} from "../src/oracle/StaticOracle.sol";
import {FuguiTreasury} from "../src/bank/FuguiTreasury.sol";

/// @title PeripheralTest
/// @notice FuguiToken / StockToken / StaticOracle / FuguiTreasury behaviour.
contract PeripheralTest is Test {
    FuguiToken fugui;
    StockToken nvda;
    StaticOracle oracle;
    FuguiTreasury treasury;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        fugui = new FuguiToken(1_000_000 ether);
        nvda = new StockToken("NVIDIA Stock Token", "tNVDA", "NVDA", "T");
        oracle = new StaticOracle();
        treasury = new FuguiTreasury();
    }

    // ------------------------------------------------------------- FuguiToken

    function test_FuguiToken_Basics() public {
        assertEq(fugui.name(), "Fugui");
        assertEq(fugui.symbol(), "FUGUI");
        assertEq(fugui.totalSupply(), 1_000_000 ether);
        assertEq(fugui.balanceOf(address(this)), 1_000_000 ether);

        fugui.transfer(alice, 100 ether);
        assertEq(fugui.balanceOf(alice), 100 ether);

        fugui.approve(alice, 10 ether);
        vm.prank(alice);
        fugui.transferFrom(address(this), bob, 10 ether);
        assertEq(fugui.balanceOf(bob), 10 ether);
        assertEq(fugui.allowance(address(this), alice), 0);

        vm.prank(alice);
        vm.expectRevert(FuguiToken.InsufficientAllowance.selector);
        fugui.transferFrom(address(this), bob, 1);

        uint256 supply = fugui.totalSupply();
        vm.prank(alice);
        fugui.burn(100 ether);
        assertEq(fugui.totalSupply(), supply - 100 ether);
    }

    function test_FuguiToken_InfiniteAllowance() public {
        fugui.approve(alice, type(uint256).max);
        vm.prank(alice);
        fugui.transferFrom(address(this), bob, 1 ether);
        assertEq(fugui.allowance(address(this), alice), type(uint256).max);
    }

    // ------------------------------------------------------------- StockToken

    function test_StockToken_MetaAndMint() public {
        (string memory ticker, string memory issuerName, bool locked) = nvda.meta();
        assertEq(ticker, "NVDA");
        assertEq(issuerName, "T");
        assertFalse(locked);

        nvda.mint(alice, 10 ether);
        assertEq(nvda.balanceOf(alice), 10 ether);

        vm.prank(alice);
        vm.expectRevert();
        nvda.mint(alice, 1 ether); // not ISSUER
    }

    function test_StockToken_TransferLock() public {
        nvda.mint(alice, 10 ether);
        nvda.setTransfersLocked(true);

        // owner can still move own funds
        vm.prank(alice);
        nvda.transfer(bob, 1 ether);

        // third parties (allowance spends) are blocked while locked
        vm.prank(alice);
        nvda.approve(address(this), 1 ether);
        vm.expectRevert(StockToken.TransfersLockedError.selector);
        nvda.transferFrom(alice, bob, 1 ether);

        nvda.setTransfersLocked(false);
        nvda.transferFrom(alice, bob, 1 ether);
        assertEq(nvda.balanceOf(bob), 2 ether);
    }

    // ------------------------------------------------------------ StaticOracle

    function test_StaticOracle_PriceAndInverse() public {
        oracle.grantRole(oracle.ROLE_SETTER(), address(this));
        oracle.setPrice(address(nvda), address(fugui), 1000 ether);

        assertEq(oracle.consult(address(nvda), 1 ether, address(fugui)), 1000 ether);
        assertApproxEqRel(oracle.consult(address(fugui), 1000 ether, address(nvda)), 1 ether, 1e15);
        assertEq(oracle.consult(address(nvda), 1 ether, address(nvda)), 1 ether); // same token
    }

    function test_StaticOracle_UnsetReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(StaticOracle.UnsetPrice.selector, address(1), address(2))
        );
        oracle.consult(address(1), 1 ether, address(2));
    }

    // ---------------------------------------------------------------- Treasury

    function test_Treasury_ERC20AndETH() public {
        nvda.mint(address(treasury), 50 ether);
        treasury.withdraw(address(nvda), alice, 50 ether);
        assertEq(nvda.balanceOf(alice), 50 ether);

        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 bobBalBefore = bob.balance;
        treasury.withdraw(address(0), bob, 1 ether);
        assertEq(bob.balance - bobBalBefore, 1 ether);
    }

    function test_Treasury_OnlyPayout() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.withdraw(address(0), alice, 1 ether);
    }
}
