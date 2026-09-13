// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {FuguiToken} from "../src/tokens/FuguiToken.sol";
import {StockToken} from "../src/tokens/StockToken.sol";
import {StaticOracle} from "../src/oracle/StaticOracle.sol";
import {FuguiBank} from "../src/bank/FuguiBank.sol";
import {BankNote} from "../src/bank/BankNote.sol";
import {FuguiTreasury} from "../src/bank/FuguiTreasury.sol";
import {MockExchange} from "../src/mocks/MockExchange.sol";
import {IFuguiBankView} from "../src/interfaces/IFuguiBankView.sol";
import {Roles} from "../src/lib/Roles.sol";

/// @title FuguiBankTest
/// @notice End-to-end behaviour of the 落袋金库: open / harvest / claim / close,
///         both modes, fees, keeper tips, pause, access control, rescue.
contract FuguiBankTest is Test {
    FuguiToken fugui;
    StockToken nvda;
    MockExchange exchange;
    StaticOracle oracle;
    FuguiTreasury treasury;
    BankNote note;
    FuguiBank bank;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint8 constant LUCKY = 0; // FuguiBank.MODE_LUCKY 落袋为安
    uint8 constant BOLD = 1; // FuguiBank.MODE_BOLD 富贵险中求
    uint256 constant PRICE0 = 1000 ether; // FUGUI per 1 tNVDA
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN");
    bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN");

    function setUp() public {
        fugui = new FuguiToken(1_000_000_000 ether);
        nvda = new StockToken("NVIDIA Stock Token", "tNVDA", "NVDA", "Test Issuer");
        exchange = new MockExchange();
        oracle = new StaticOracle();
        oracle.grantRole(oracle.ROLE_SETTER(), address(this));
        treasury = new FuguiTreasury();
        note = new BankNote();
        bank = new FuguiBank(address(oracle), address(exchange), address(note), address(treasury));

        note.setBank(address(bank));
        note.grantRole(note.ROLE_MINTER(), address(bank));
        bank.setTokenSupport(0, address(fugui), true);
        bank.setTokenSupport(1, address(nvda), true);

        // market bootstrap: 10M FUGUI / 10k tNVDA => 1000 FUGUI per tNVDA
        nvda.mint(address(this), 200_000 ether);
        fugui.approve(address(exchange), type(uint256).max);
        nvda.approve(address(exchange), type(uint256).max);
        exchange.addLiquidity(address(fugui), address(nvda), 10_000_000 ether, 10_000 ether);
        oracle.setPrice(address(nvda), address(fugui), PRICE0);

        // alice the degen
        fugui.transfer(alice, 1_000_000 ether);
        nvda.mint(alice, 1_000 ether);
        vm.startPrank(alice);
        fugui.approve(address(bank), type(uint256).max);
        nvda.approve(address(bank), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Move both the AMM pool and the oracle to `newPrice` (FUGUI per tNVDA).
    function _moveMarket(uint256 newPrice) internal {
        exchange.setPrice(address(nvda), address(fugui), newPrice);
        oracle.setPrice(address(nvda), address(fugui), newPrice);
    }

    function _openLucky() internal returns (uint256 id) {
        vm.prank(alice);
        id = bank.openPosition({
            mode: LUCKY,
            meme: address(fugui),
            stock: address(nvda),
            srcAmount: 100_000 ether,
            stepBps: 2_000, // +20%
            sellBps: 1_000 // sell 10% per trigger
        });
    }

    // ------------------------------------------------------------------- open

    function test_Open_MintsNoteAndRecordsPosition() public {
        uint256 id = _openLucky();
        IFuguiBankView.Position memory p = bank.getPosition(id);

        assertEq(p.owner, alice);
        assertEq(p.meme, address(fugui));
        assertEq(p.stock, address(nvda));
        assertEq(uint8(p.mode), LUCKY);
        assertEq(p.srcRemaining, 100_000 ether);
        assertEq(p.watermark, PRICE0);
        assertEq(p.stepBps, 2_000);
        assertEq(p.sellBps, 1_000);
        assertFalse(p.closed);

        assertEq(note.ownerOf(id), alice);
        assertEq(bank.positionsCount(), 1);
        assertEq(bank.positionsOf(alice).length, 1);
        assertEq(bank.openInterestCount(address(fugui)), 1);
        assertEq(bank.openInterestCount(address(nvda)), 1);
        assertEq(fugui.balanceOf(address(bank)), 100_000 ether);
    }

    function test_Open_RevertUnsupportedToken() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FuguiBank.TokenNotSupported.selector, address(123)));
        bank.openPosition(LUCKY, address(123), address(nvda), 1 ether, 2_000, 1_000);
    }

    function test_Open_RevertBadMode() public {
        vm.prank(alice);
        vm.expectRevert(FuguiBank.BadMode.selector);
        bank.openPosition(2, address(fugui), address(nvda), 1 ether, 2_000, 1_000);
    }

    function test_Open_RevertStepBounds() public {
        vm.prank(alice);
        vm.expectRevert(FuguiBank.StepOutOfBounds.selector);
        bank.openPosition(LUCKY, address(fugui), address(nvda), 1 ether, 50, 1_000);

        vm.prank(alice);
        vm.expectRevert(FuguiBank.SellOutOfBounds.selector);
        bank.openPosition(LUCKY, address(fugui), address(nvda), 1 ether, 2_000, 9_999);
    }

    // ---------------------------------------------------------------- harvest

    function test_Harvest_PumpSellsIntoStock_WithFeesAndKeeperTip() public {
        uint256 id = _openLucky();
        _moveMarket(1_500 ether); // meme +50% vs stock

        uint256 swapAmt = 100_000 ether * 1_000 / 10_000; // 10k FUGUI
        uint256 expectedOut = exchange.getAmountOut(address(fugui), address(nvda), swapAmt);

        vm.prank(keeper);
        bank.harvest(id);

        IFuguiBankView.Position memory p = bank.getPosition(id);
        assertEq(p.srcRemaining, 90_000 ether);
        assertEq(p.harvestCount, 1);
        assertEq(p.watermark, 1_500 ether);

        uint256 fee = expectedOut * 500 / 10_000;
        uint256 tip = expectedOut * 100 / 10_000;
        assertEq(p.dstAccrued, expectedOut - fee - tip);
        assertEq(p.harvestedOut, expectedOut);

        assertEq(nvda.balanceOf(address(bank)), expectedOut - tip); // tip paid out instantly
        assertEq(nvda.balanceOf(keeper), tip);
        assertEq(bank.pendingFees(address(nvda)), fee);
    }

    function test_Harvest_RevertWhenNoStepReached() public {
        uint256 id = _openLucky();
        _moveMarket(1_100 ether); // +10% < +20% step

        vm.expectRevert(FuguiBank.NoStepReached.selector);
        bank.harvest(id);
    }

    function test_Harvest_LadderMultipleSteps() public {
        uint256 id = _openLucky();

        _moveMarket(1_250 ether); // +25%: triggers at >= +20%
        vm.prank(keeper);
        bank.harvest(id);
        assertEq(bank.getPosition(id).watermark, 1_250 ether);
        uint256 srcAfter1 = bank.getPosition(id).srcRemaining; // 90k

        // next trigger needs >= 1250 * 1.2 = 1500
        _moveMarket(1_600 ether);
        vm.prank(keeper);
        bank.harvest(id);
        assertEq(bank.getPosition(id).watermark, 1_600 ether);
        assertEq(bank.getPosition(id).srcRemaining, srcAfter1 * 9_000 / 10_000);
        assertEq(bank.getPosition(id).harvestCount, 2);
    }

    function test_Harvest_BoldModeBuysMemeOnDip() public {
        vm.prank(alice);
        uint256 id = bank.openPosition({
            mode: BOLD,
            meme: address(fugui),
            stock: address(nvda),
            srcAmount: 100 ether, // tNVDA
            stepBps: 2_000,
            sellBps: 1_000
        });

        _moveMarket(700 ether); // FUGUI -30% vs stock => meme dip
        vm.prank(keeper);
        bank.harvest(id);

        IFuguiBankView.Position memory p = bank.getPosition(id);
        assertEq(p.srcRemaining, 90 ether);
        assertEq(p.watermark, 700 ether);
        assertGt(p.dstAccrued, 0); // bought FUGUI
        // ~10 tNVDA spent at ~700 FUGUI each (AMM impact + fee eat a few %)
        assertApproxEqRel(p.dstAccrued, 7_000 ether, 0.10e18);
    }

    function test_Harvest_BoldMode_RevertOnPump() public {
        vm.prank(alice);
        uint256 id =
            bank.openPosition(BOLD, address(fugui), address(nvda), 100 ether, 2_000, 1_000);

        _moveMarket(1_400 ether); // meme up, not a dip
        vm.expectRevert(FuguiBank.NoStepReached.selector);
        bank.harvest(id);
    }

    // -------------------------------------------------------------- claim/close

    function test_Claim_TransfersAccruedStock() public {
        uint256 id = _openLucky();
        _moveMarket(1_500 ether);
        vm.prank(keeper);
        bank.harvest(id);

        uint256 accrued = bank.getPosition(id).dstAccrued;
        uint256 before = nvda.balanceOf(alice);

        vm.prank(alice);
        bank.claim(id);
        assertEq(nvda.balanceOf(alice), before + accrued);
        assertEq(bank.getPosition(id).dstAccrued, 0);

        vm.prank(alice);
        vm.expectRevert(FuguiBank.NothingToClaim.selector);
        bank.claim(id);
    }

    function test_Claim_OnlyOwner() public {
        uint256 id = _openLucky();
        vm.prank(bob);
        vm.expectRevert(FuguiBank.NotPositionOwner.selector);
        bank.claim(id);
    }

    function test_Close_ReturnsFundsAndBurnsNote() public {
        uint256 id = _openLucky();
        _moveMarket(1_500 ether);
        vm.prank(keeper);
        bank.harvest(id);

        IFuguiBankView.Position memory p = bank.getPosition(id);
        uint256 aliceFugui = fugui.balanceOf(alice);
        uint256 aliceNvda = nvda.balanceOf(alice);

        vm.prank(alice);
        (uint256 src, uint256 dst) = bank.closePosition(id, false);
        assertEq(src, p.srcRemaining);
        assertEq(dst, p.dstAccrued);
        assertEq(fugui.balanceOf(alice), aliceFugui + src);
        assertEq(nvda.balanceOf(alice), aliceNvda + dst);

        assertTrue(bank.getPosition(id).closed);
        assertEq(bank.openInterestCount(address(fugui)), 0);
        assertEq(bank.openInterestCount(address(nvda)), 0);
        vm.expectRevert(abi.encodeWithSelector(BankNote.NonexistentToken.selector, id));
        note.ownerOf(id);

        vm.prank(alice);
        vm.expectRevert(FuguiBank.PositionAlreadyClosed.selector);
        bank.closePosition(id, false);
    }

    function test_Close_KeepNoteAsSouvenir() public {
        uint256 id = _openLucky();
        vm.prank(alice);
        bank.closePosition(id, true);
        assertEq(note.ownerOf(id), alice); // still alive
        string memory uri = note.tokenURI(id); // renders REDEEMED view
        assertGt(bytes(uri).length, 100);
    }

    // ------------------------------------------------------------------- admin

    function test_CollectFees_SendsToTreasury() public {
        uint256 id = _openLucky();
        _moveMarket(1_500 ether);
        vm.prank(keeper);
        bank.harvest(id);

        uint256 fee = bank.pendingFees(address(nvda));
        assertGt(fee, 0);
        bank.collectFees(address(nvda));
        assertEq(nvda.balanceOf(address(treasury)), fee);
        assertEq(bank.pendingFees(address(nvda)), 0);
    }

    function test_UpdateConfig() public {
        uint256 id = _openLucky();
        vm.prank(alice);
        bank.updateConfig(id, 3_000, 2_000);
        IFuguiBankView.Position memory p = bank.getPosition(id);
        assertEq(p.stepBps, 3_000);
        assertEq(p.sellBps, 2_000);

        vm.prank(alice);
        vm.expectRevert(FuguiBank.StepOutOfBounds.selector);
        bank.updateConfig(id, 99, 2_000);

        vm.prank(bob);
        vm.expectRevert(FuguiBank.NotPositionOwner.selector);
        bank.updateConfig(id, 1_000, 1_000);
    }

    function test_Pause_BlocksNewActions_NotWithdrawals() public {
        uint256 id = _openLucky();
        _moveMarket(1_500 ether);
        vm.prank(keeper);
        bank.harvest(id);

        bank.setPaused(true);

        vm.expectRevert(FuguiBank.PausedError.selector);
        bank.harvest(id);

        vm.prank(alice);
        vm.expectRevert(FuguiBank.PausedError.selector);
        bank.openPosition(LUCKY, address(fugui), address(nvda), 1 ether, 2_000, 1_000);

        // user funds remain accessible while paused
        vm.prank(alice);
        bank.claim(id);
        vm.prank(alice);
        bank.closePosition(id, false);
    }

    function test_Rescue_BlockedWhileOpenInterest() public {
        uint256 id = _openLucky();
        vm.expectRevert(abi.encodeWithSelector(FuguiBank.OpenInterestExists.selector, address(fugui)));
        bank.rescue(address(fugui));

        vm.prank(alice);
        bank.closePosition(id, false);
        bank.rescue(address(fugui)); // now fine
    }

    function test_AccessControl() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Roles.Unauthorized.selector, ADMIN_ROLE, bob));
        bank.setRouter(address(1));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Roles.Unauthorized.selector, GUARDIAN_ROLE, bob));
        bank.setPaused(true);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Roles.Unauthorized.selector, ADMIN_ROLE, bob));
        bank.setFeeConfig(100, 100, 300, address(treasury));
    }

    function test_SetFeeConfig_Bounds() public {
        vm.expectRevert(FuguiBank.FeesTooHigh.selector);
        bank.setFeeConfig(1_500, 1_000, 300, address(treasury)); // 25% total > 20% cap

        vm.expectRevert(FuguiBank.SlippageTooHigh.selector);
        bank.setFeeConfig(100, 100, 3_000, address(treasury));
    }

    // ------------------------------------------------------------------- views

    function test_StepStatusAndPreview() public {
        uint256 id = _openLucky();

        (bool reached, uint256 price, uint256 target) = bank.stepStatus(id);
        assertFalse(reached);
        assertEq(price, PRICE0);
        assertEq(target, 1_200 ether); // 1000 * 1.2

        _moveMarket(1_500 ether);
        (reached, price,) = bank.stepStatus(id);
        assertTrue(reached);
        assertEq(price, 1_500 ether);

        (bool triggered, uint256 srcSwap, uint256 minOut) = bank.previewHarvest(id);
        assertTrue(triggered);
        assertEq(srcSwap, 10_000 ether);
        assertGt(minOut, 0);
    }

    function test_BankNote_TransferAndUri() public {
        uint256 id = _openLucky();
        string memory uri = note.tokenURI(id);
        assertGt(bytes(uri).length, 500); // base64 json + svg payload

        vm.prank(alice);
        note.transferFrom(alice, bob, id);
        assertEq(note.ownerOf(id), bob);
        assertEq(note.balanceOf(alice), 0);
        assertEq(note.balanceOf(bob), 1);

        // bob no longer owns the position rights (on-chain owner still alice)
        vm.prank(bob);
        vm.expectRevert(FuguiBank.NotPositionOwner.selector);
        bank.closePosition(id, false);
    }
}

