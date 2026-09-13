// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwapOracle} from "../src/oracle/TwapOracle.sol";
import {FullMath} from "../src/lib/FullMath.sol";

/// @notice Minimal V2-style pair with controllable price for TWAP simulation.
contract MockV2Pair {
    address public immutable token0;
    address public immutable token1;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;

    uint256 private _p0; // UQ112x112: token1 per token0
    uint256 private _p1; // UQ112x112: token0 per token1

    constructor(address t0, address t1, uint112 r0, uint112 r1) {
        token0 = t0;
        token1 = t1;
        blockTimestampLast = uint32(block.timestamp);
        _set(r0, r1);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function setReserves(uint112 r0, uint112 r1) external {
        _set(r0, r1);
    }

    function sync() external {
        uint32 t = uint32(block.timestamp);
        uint32 dt = t - blockTimestampLast;
        price0CumulativeLast += _p0 * dt;
        price1CumulativeLast += _p1 * dt;
        blockTimestampLast = t;
    }

    function _set(uint112 r0, uint112 r1) internal {
        reserve0 = r0;
        reserve1 = r1;
        _p0 = FullMath.mulDiv(r1, 2 ** 112, r0);
        _p1 = FullMath.mulDiv(r0, 2 ** 112, r1);
    }
}

/// @title TwapOracleTest
contract TwapOracleTest is Test {
    address t0 = makeAddr("token0");
    address t1 = makeAddr("token1");
    MockV2Pair pair;
    TwapOracle oracle;

    function setUp() public {
        // 1 t0 = 2 t1
        pair = new MockV2Pair(t0, t1, 1e24, 2e24);
        oracle = new TwapOracle();
        oracle.registerPair(address(pair));
    }

    function _advance() internal {
        vm.warp(block.timestamp + oracle.period());
        pair.sync();
        assertTrue(oracle.update(address(pair)));
    }

    function test_TwapTracksPrice() public {
        _advance();
        assertApproxEqRel(oracle.consult(t0, 1e18, t1), 2e18, 1e15); // 0.1%
        assertApproxEqRel(oracle.consult(t1, 1e18, t0), 0.5e18, 1e15);
    }

    function test_TwapFollowsPriceChange() public {
        _advance();
        pair.setReserves(1e24, 4e24); // now 1 t0 = 4 t1
        _advance();
        assertApproxEqRel(oracle.consult(t0, 1e18, t1), 4e18, 1e15);
    }

    function test_UpdateWithinPeriodReturnsFalse() public {
        _advance();
        vm.warp(block.timestamp + 100);
        pair.sync();
        assertFalse(oracle.update(address(pair)));
    }

    function test_ConsultUnregisteredPairReverts() public {
        address fakeT = makeAddr("fake");
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.PairNotInitialized.selector, fakeT, t0));
        oracle.consult(fakeT, 1e18, t0);
    }

    function test_SetPeriod_OnlyAdmin() public {
        vm.prank(address(1));
        vm.expectRevert();
        oracle.setPeriod(600);
    }
}
