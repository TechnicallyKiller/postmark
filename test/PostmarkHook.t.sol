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

contract PostmarkHookTest is PostmarkTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        setUpPostmark();
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
}

interface PostmarkHookErrors {
    error NotPoolManager();
}
