// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PostmarkTestBase} from "./utils/PostmarkTestBase.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {ReceiptBook} from "../src/libraries/ReceiptBook.sol";

/// @notice Day 4 gate: a synthetic arbitrage trade must be charged approximately its known
/// realized LVR.
///
/// @dev The scenario is built so the reference price is analytically determined rather than read
/// back out of the contract under test. The arbitrageur trades at block b, one other swap moves the
/// price at b+1, and nothing else touches the pool for the rest of the window — so the settlement
/// TWAP is exactly `(T1 + (W-1)*T2) / W` over the two observed ticks. Everything the settlement
/// path can get wrong (the sign, alpha, the cap, the notional) is pinned against that.
contract SettlementMathTest is PostmarkTestBase {
    using StateLibrary for IPoolManager;

    address internal arb = makeAddr("arbitrageur");
    address internal market = makeAddr("market");

    function setUp() public {
        setUpPostmark();
        fundTrader(arb, 1e24);
        fundTrader(market, 1e24);
        // Depth chosen so the swap sizes below move the tick by tens of ticks: deep enough not to
        // slam the price limit, shallow enough that the price actually moves.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e21, salt: 0}),
            ZERO_BYTES
        );
    }

    function test_DAY4_GATE_arbitrageChargedItsRealizedLVR() public {
        bond(arb, 1e22);

        // Block 100: the arbitrageur buys token0, expecting it to rise.
        vm.roll(100);
        vm.prank(arb);
        swap(key, false, -int256(1e18), abi.encode(arb));

        ReceiptBook.Receipt memory r = hook.getReceipt(poolId, 0);
        int24 t1 = r.tickAfter;
        uint256 notional = uint256(r.notional);

        // Block 101: the market confirms them — price keeps moving the same way.
        vm.roll(101);
        vm.prank(market);
        swap(key, false, -int256(4e18), ZERO_BYTES);
        (, int24 t2,,) = manager.getSlot0(poolId);

        // Nothing else touches the pool for the rest of the window.
        vm.roll(100 + hook.W());

        // --- independently derived expectation -------------------------------------------------
        // Settlement prices against the most adverse tick that PRINTED in the window, not its mean.
        // The payer bought token0, so the adverse direction is up, and the window's high is t2.
        int24 expectedTickRef = t2 > t1 ? t2 : t1;
        uint256 expectedCharge = _expectedCharge(notional, t1, expectedTickRef);

        // --- what the contract actually does ---------------------------------------------------
        vm.roll(block.number + 1);
        uint256 before = vault.balanceOf(arb, bondCurrency);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        hook.settle(key, ids);
        uint256 actualCharge = before - vault.balanceOf(arb, bondCurrency);

        console.log("tick at execution   :", int256(t1));
        console.log("tick after market   :", int256(t2));
        console.log("expected ref tick   :", int256(expectedTickRef));
        console.log("notional            :", notional);
        console.log("expected charge     :", expectedCharge);
        console.log("actual charge       :", actualCharge);
        console.log("charge, bps of notional:", (actualCharge * 10_000) / notional);

        assertGt(actualCharge, 0, "arbitrage went uncharged");
        assertApproxEqRel(actualCharge, expectedCharge, 0.01e18, "charge does not match the realized LVR");
    }

    /// The charge must be alpha of the LVR, not the whole of it. alpha < 1 is what keeps
    /// TWAP manipulation unprofitable, so it is worth pinning directly.
    function test_chargeIsAlphaOfMarkout() public {
        bond(arb, 1e22);

        vm.roll(100);
        vm.prank(arb);
        swap(key, false, -int256(1e18), abi.encode(arb));
        ReceiptBook.Receipt memory r = hook.getReceipt(poolId, 0);

        vm.roll(101);
        vm.prank(market);
        swap(key, false, -int256(4e18), ZERO_BYTES);
        (, int24 t2,,) = manager.getSlot0(poolId);

        vm.roll(100 + hook.W() + 1);
        int24 tickRef = t2 > r.tickAfter ? t2 : r.tickAfter; // window high, adverse for a buyer

        uint256 grossMarkout = _markout(uint256(r.notional), r.tickAfter, tickRef);
        uint256 before = vault.balanceOf(arb, bondCurrency);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        hook.settle(key, ids);
        uint256 charge = before - vault.balanceOf(arb, bondCurrency);

        uint256 cap = hook.maxCharge(uint256(r.notional));
        uint256 expected = (grossMarkout * hook.ALPHA()) / 10_000;
        if (expected > cap) expected = cap;

        console.log("gross markout:", grossMarkout);
        console.log("charge       :", charge);
        assertApproxEqRel(charge, expected, 0.01e18, "charge is not alpha x markout");
        assertLt(charge, grossMarkout, "charge must recapture less than the full LVR");
    }

    /// A trade the market moves *against* is benign and must never be charged.
    function test_benignTradeIsNotCharged() public {
        bond(arb, 1e22);

        vm.roll(100);
        vm.prank(arb);
        swap(key, false, -int256(1e18), abi.encode(arb)); // buys token0

        vm.roll(101);
        vm.prank(market);
        swap(key, true, -int256(4e18), ZERO_BYTES); // price goes the other way

        vm.roll(100 + hook.W() + 1);
        uint256 before = vault.balanceOf(arb, bondCurrency);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        hook.settle(key, ids);

        assertGe(vault.balanceOf(arb, bondCurrency), before, "a benign trade was charged");
    }

    /// The per-receipt cap must bind on an extreme move.
    function test_chargeIsCappedAtMaxChargeBps() public {
        bond(arb, 1e22);

        vm.roll(100);
        vm.prank(arb);
        swap(key, false, -int256(1e18), abi.encode(arb));
        ReceiptBook.Receipt memory r = hook.getReceipt(poolId, 0);

        // A violent move, far past anything alpha x markout would stay under the cap for.
        vm.roll(101);
        vm.prank(market);
        swap(key, false, -int256(60e18), ZERO_BYTES);

        vm.roll(100 + hook.W() + 1);
        uint256 before = vault.balanceOf(arb, bondCurrency);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        hook.settle(key, ids);
        uint256 charge = before - vault.balanceOf(arb, bondCurrency);

        assertEq(charge, hook.maxCharge(uint256(r.notional)), "cap did not bind");
        // And the cap must stay under the bond, or forfeiting would be rational.
        assertLt(charge, hook.requiredBond(uint256(r.notional)), "charge exceeded the bond");
    }

    // -------------------------------------------------------------------------

    function _markout(uint256 notional, int24 tickExec, int24 tickRef) internal pure returns (uint256) {
        uint160 sqrtExec = TickMath.getSqrtPriceAtTick(tickExec);
        uint160 sqrtRef = TickMath.getSqrtPriceAtTick(tickRef);
        uint256 rr = FullMath.mulDiv(sqrtRef, FixedPoint96.Q96, sqrtExec);
        uint256 ratioX96 = FullMath.mulDiv(rr, rr, FixedPoint96.Q96);
        // oneForZero: the payer bought token0, so a higher reference price means they profited at
        // the LPs' expense.
        require(ratioX96 >= FixedPoint96.Q96, "expected an adverse move");
        return FullMath.mulDiv(notional, ratioX96 - FixedPoint96.Q96, FixedPoint96.Q96);
    }

    function _expectedCharge(uint256 notional, int24 tickExec, int24 tickRef) internal view returns (uint256) {
        uint256 charge = (_markout(notional, tickExec, tickRef) * hook.ALPHA()) / 10_000;
        uint256 cap = hook.maxCharge(notional);
        return charge > cap ? cap : charge;
    }
}
