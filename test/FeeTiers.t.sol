// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PostmarkTestBase} from "./utils/PostmarkTestBase.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PostmarkHook} from "../src/PostmarkHook.sol";
import {ScoreRegistry} from "../src/ScoreRegistry.sol";
import {FlowVault} from "../src/FlowVault.sol";

contract FeeTiersTest is PostmarkTestBase {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant SWAP_IN = 1e15;
    /// 2% of a ~1e15 notional, with room to spare.
    uint256 internal constant BOND = 1e14;

    function setUp() public {
        setUpPostmark();
        fundTrader(alice, 1e21);
        fundTrader(bob, 1e21);
    }

    /// Day 2 gate: a bonded payer and an unbonded payer pay measurably different fees on the same
    /// swap against the same pool state.
    function test_bondedPayerPaysLessThanUnbonded() public {
        bond(alice, BOND);

        uint256 snap = vm.snapshotState();
        uint256 aliceOut = _swapAs(alice, SWAP_IN);
        vm.revertToState(snap);
        uint256 bobOut = _swapAs(bob, SWAP_IN);

        assertGt(aliceOut, bobOut, "bonded payer did not receive more output");

        // Alice enters at the bonded entry tier (15 bps), Bob is unknown (30 bps). The gap on the
        // input notional is 15 bps, which the output must reflect.
        uint256 gap = aliceOut - bobOut;
        uint256 expectedGap = (SWAP_IN * 15) / 10_000;
        assertApproxEqRel(gap, expectedGap, 0.02e18, "fee gap is not ~15 bps");
    }

    /// Tiers resolve as designed: unbonded is always the baseline, bonded-but-green enters mid.
    function test_tierResolution() public {
        assertEq(registry.tierOf(alice, false), hook.DEFAULT_TIER(), "unbonded not at baseline");
        assertEq(registry.tierOf(alice, true), registry.BONDED_ENTRY_TIER(), "fresh bond not at entry tier");
        assertEq(hook.tierFee(0), 200);
        assertEq(hook.tierFee(1), 800);
        assertEq(hook.tierFee(2), 1500);
        assertEq(hook.tierFee(3), 3000);
    }

    /// A bond too small for the swap's notional loses the discount, but never blocks the swap.
    function test_underBondedFallsBackWithoutReverting() public {
        // 2% of 1e15 is 2e13. Post half of that.
        bond(alice, 1e13);

        uint256 snap = vm.snapshotState();
        uint256 aliceOut = _swapAs(alice, SWAP_IN);
        vm.revertToState(snap);
        uint256 bobOut = _swapAs(bob, SWAP_IN);

        assertEq(aliceOut, bobOut, "under-bonded payer got a discount");
        assertGt(aliceOut, 0, "swap did not execute");
    }

    /// A payer attested by the router is the one whose bond is read, not the router.
    function test_routerAttestationMovesTheDiscount() public {
        bond(alice, BOND);

        uint256 snap = vm.snapshotState();
        uint256 attested = _swapAs(alice, SWAP_IN);
        vm.revertToState(snap);
        // Same caller, no attestation: the payer resolves to the router, which posted no bond.
        uint256 before = currency1.balanceOf(alice);
        vm.prank(alice);
        swap(key, true, -int256(SWAP_IN), ZERO_BYTES);
        uint256 unattested = currency1.balanceOf(alice) - before;

        assertGt(attested, unattested, "attestation did not apply alice's bond");
    }

    // -------------------------------------------------------------------------

    /// @dev Swap through the router with `who` attested as the payer in hookData, and return the
    /// token1 output they receive.
    function _swapAs(address who, uint256 amountIn) internal returns (uint256) {
        uint256 before = currency1.balanceOf(who);
        vm.prank(who);
        swap(key, true, -int256(amountIn), abi.encode(who));
        return currency1.balanceOf(who) - before;
    }
}
