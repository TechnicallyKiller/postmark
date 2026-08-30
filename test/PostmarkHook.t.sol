// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PostmarkTestBase} from "./utils/PostmarkTestBase.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ReceiptBook} from "../src/libraries/ReceiptBook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract PostmarkHookTest is PostmarkTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        setUpPostmark();
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    }

    /// Day 1 gate: a swap executes through the hook.
    function test_swapExecutesThroughHook() public {
        assertTrue(_registered(poolId), "pool not registered by afterInitialize");

        uint256 balBefore = currency1.balanceOfSelf();
        BalanceDelta delta = swap(key, true, -1e15, ZERO_BYTES);
        uint256 balAfter = currency1.balanceOfSelf();

        assertGt(balAfter, balBefore, "no output received");
        assertLt(delta.amount0(), 0, "token0 not spent");
        assertGt(delta.amount1(), 0, "token1 not received");
    }

    /// The pool is dynamic-fee and seeded at the unbonded baseline.
    function test_poolSeededAtBaselineFee() public view {
        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, hook.tierFee(hook.DEFAULT_TIER()), "pool not seeded at baseline");
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "pool is not dynamic-fee");
    }

    /// An unknown payer pays the top tier: 30 bps, the vanilla baseline.
    function test_unknownPayerPaysBaseline() public {
        uint256 out = _swapAndMeasureOutput(1e15);
        // 30 bps of 1e15 in, priced at ~1:1 with shallow depth. Assert the fee is in the ballpark
        // rather than exact: the pool also moves price.
        uint256 grossOut = 1e15;
        uint256 impliedFeeBps = ((grossOut - out) * 10_000) / grossOut;
        assertGe(impliedFeeBps, 30, "fee below the 30 bps baseline");
        assertLe(impliedFeeBps, 40, "fee far above baseline, price impact too large for this assert");
    }

    /// The hook must refuse a static-fee pool: it cannot quote per-swap without dynamic fees.
    function test_revertsOnStaticFeePool() public {
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }

    /// Hook callbacks are only reachable from the PoolManager.
    function test_callbacksGatedToPoolManager() public {
        vm.expectRevert(PostmarkHookErrors.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function _registered(PoolId id) internal view returns (bool r) {
        (r,) = hook.poolConfig(id);
    }

    function _swapAndMeasureOutput(uint256 amountIn) internal returns (uint256) {
        uint256 before = currency1.balanceOfSelf();
        swap(key, true, -int256(amountIn), ZERO_BYTES);
        return currency1.balanceOfSelf() - before;
    }

    /// Day 4 gate: Settlement Math Correctness
    function test_arbitrageLVR_settlement_Correctness() public {
        uint256 notional = 1e15; // move price without hitting limit
        
        // Setup bond
        uint256 required = hook.requiredBond(notional);
        address currency1Addr = Currency.unwrap(currency1);
        deal(currency1Addr, address(this), required);
        (bool success, ) = currency1Addr.call(
            abi.encodeWithSignature("approve(address,uint256)", address(hook.vault()), required)
        );
        assertTrue(success, "approve failed");
        hook.vault().deposit(currency1, required);

        // Block 100: Payer swaps (zeroForOne = true)
        vm.roll(100);
        swap(key, true, -int256(notional), abi.encode(address(this)));
        
        // Block 101: Price moves further in the same direction, pushing TWAP down!
        vm.roll(101);
        swap(key, true, -int256(notional), abi.encode(address(this)));
        
        // Settle once the window has elapsed. Derived from W, not hardcoded, so the test follows
        // the parameter instead of silently breaking when it changes.
        vm.roll(100 + hook.W() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0; // The first receipt is at index 0
        
        uint256 balBefore = hook.vault().balanceOf(address(this), currency1);
        hook.settle(key, ids);
        uint256 balAfter = hook.vault().balanceOf(address(this), currency1);
        
        uint256 charge = balBefore - balAfter;
        assertGt(charge, 0, "Payer was not charged for LVR");
        console.log("LVR Charge paid by swapper:", charge);
    }

    /// Day 5 gate: EWMA improves tier for a benign swapper
    function test_day5_BenignSwapper_TierImprovement() public {
        uint256 notional = 1e15; 
        uint256 required = hook.requiredBond(notional) * 20; // Enough bond for 20 swaps
        
        address payer = address(this);
        address currency1Addr = Currency.unwrap(currency1);
        deal(currency1Addr, payer, required);
        (bool success, ) = currency1Addr.call(
            abi.encodeWithSignature("approve(address,uint256)", address(hook.vault()), required)
        );
        assertTrue(success, "approve failed");
        hook.vault().deposit(currency1, required);

        // Deal currency0 for the alternating swaps
        address currency0Addr = Currency.unwrap(currency0);
        deal(currency0Addr, payer, 100 ether);
        deal(currency1Addr, payer, 100 ether + required);

        uint8 initialTier = hook.registry().tierOf(payer, true);
        assertEq(initialTier, 2, "Initial bonded tier should be BONDED_ENTRY_TIER (2)");

        for (uint256 i = 0; i < 20; i++) {
            // Swap (alternate direction to avoid hitting price limit)
            vm.roll(block.number + 10);
            swap(key, i % 2 == 0, -int256(notional), abi.encode(payer));

            // Move forward W blocks to settle without moving price further
            // Because price didn't move after swap, TWAP == P_exec, Markout == 0
            vm.roll(block.number + hook.W());
            uint256[] memory ids = new uint256[](1);
            ids[0] = i; // Settle the current receipt
            
            hook.settle(key, ids);
        }

        uint8 finalTier = hook.registry().tierOf(payer, true);
        assertLt(finalTier, initialTier, "Tier did not improve after 20 benign swaps");
        
        int256 score = hook.registry().scoreOf(payer);
        assertLe(score, 0, "Score should be benign (<= 0)");
        console.log("Final Tier:", finalTier);
        console.logInt(score);
    }

    /// Day 6 gate: the bond invariant, as a property.
    /// @dev `requiredBond(n) > maxCharge(n)` alone is just 2% > 1% on two constants and cannot
    /// fail. The invariant that carries weight is that the bond LOCKED at swap time covers the
    /// charge that settlement can actually debit — which is only true while both are derived from
    /// the same recorded notional. That is exactly what the uint32 truncation broke.
    function test_day6_fuzz_BondInvariant(uint256 notional) public view {
        notional = bound(notional, hook.DUST_THRESHOLD() + 1, ReceiptBook.MAX_NOTIONAL);

        // What afterSwap locks, keyed on the notional the receipt records.
        uint96 recorded = uint96(notional);
        assertEq(uint256(recorded), notional, "notional does not survive the receipt encoding");

        uint256 locked = hook.requiredBond(notional);
        uint256 releasable = hook.requiredBond(uint256(recorded));
        assertEq(locked, releasable, "bond released at settlement differs from bond locked at swap");

        assertGt(locked, hook.maxCharge(uint256(recorded)), "max charge exceeds the locked bond");
    }
}

interface PostmarkHookErrors {
    error NotPoolManager();
}
