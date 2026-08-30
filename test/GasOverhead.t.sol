// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PostmarkTestBase} from "./utils/PostmarkTestBase.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Measures the Day 3 gate properly: hook overhead = Postmark swap minus an identical
/// vanilla swap, not total swap gas.
contract GasOverheadTest is PostmarkTestBase {
    PoolKey internal vanillaKey;
    address internal trader = makeAddr("trader");

    function setUp() public {
        setUpPostmark();
        // Same tokens, same tick spacing, static 30 bps, no hook.
        (vanillaKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        fundTrader(trader, 1e24);
    }

    function test_measureHookOverhead() public {
        uint256 notional = 1e8; // same size the partner's test uses
        bond(trader, hook.requiredBond(notional) * 100);

        uint256 g0 = gasleft();
        vm.prank(trader);
        swap(vanillaKey, true, -int256(notional), ZERO_BYTES);
        uint256 vanillaGas = g0 - gasleft();

        uint256 g1 = gasleft();
        vm.prank(trader);
        swap(key, true, -int256(notional), abi.encode(trader));
        uint256 postmarkGas = g1 - gasleft();

        console.log("vanilla swap gas :", vanillaGas);
        console.log("postmark swap gas:", postmarkGas);
        console.log("HOOK OVERHEAD    :", postmarkGas - vanillaGas);
        console.log("plan gate is 40000, hard stop 80000");
    }

    /// @notice Day 3 gate. The plan's rule is: measure the overhead and write it down; if it is
    /// over 80k, simplify the struct that same day.
    ///
    /// @dev Steady state is the number a live pool pays: once the observation ring has wrapped,
    /// each observation rewrites an occupied slot (~5k) instead of claiming a fresh one (~22.1k),
    /// and the payer's vault account already exists. A brand-new pool's first swaps cost roughly
    /// twice this — see test_measureHookOverhead. The 40k target is NOT met; the 80k hard stop is.
    function test_DAY3_GATE_steadyStateOverheadUnderHardStop() public {
        uint256 notional = 1e8;
        bond(trader, hook.requiredBond(notional) * 5000);

        // Wrap the ring (CARDINALITY = 128) and warm the payer's vault account.
        for (uint256 i = 0; i < 135; i++) {
            vm.roll(block.number + 1);
            vm.prank(trader);
            swap(key, i % 2 == 0, -int256(notional), abi.encode(trader));
        }

        // Reset warm-storage state so both swaps pay real cold-access costs, the way a standalone
        // transaction does. Without this the loop above leaves every slot warm and the measurement
        // understates the on-chain number.
        vm.roll(block.number + 1);
        _coolAll();
        uint256 g0 = gasleft();
        vm.prank(trader);
        swap(vanillaKey, true, -int256(notional), ZERO_BYTES);
        uint256 vanillaGas = g0 - gasleft();

        vm.roll(block.number + 1);
        _coolAll();
        uint256 g1 = gasleft();
        vm.prank(trader);
        swap(key, true, -int256(notional), abi.encode(trader));
        uint256 postmarkGas = g1 - gasleft();

        console.log("steady-state vanilla :", vanillaGas);
        console.log("steady-state postmark:", postmarkGas);
        uint256 overhead = postmarkGas - vanillaGas;
        console.log("STEADY-STATE OVERHEAD:", overhead);
        assertLt(overhead, 80_000, "Day 3 hard stop: steady-state overhead above 80k");
    }

    /// @dev Cold every contract the swap path touches, so gas reflects a standalone transaction.
    function _coolAll() internal {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(vault));
        vm.cool(address(registry));
        vm.cool(Currency.unwrap(currency0));
        vm.cool(Currency.unwrap(currency1));
    }

    /// @notice Splits the overhead into the part paid by every swap (fee quoting + the price
    /// observation) and the part paid only when a receipt is written (receipt storage + bond lock).
    function test_overheadBreakdown() public {
        uint256 notional = 1e8;

        // Unbonded: beforeSwap still reads the vault and registry and afterSwap still pushes an
        // observation, but no receipt is written and no bond is locked.
        address poor = makeAddr("poor");
        fundTrader(poor, 1e24);

        uint256 g0 = gasleft();
        vm.prank(poor);
        swap(vanillaKey, true, -int256(notional), ZERO_BYTES);
        uint256 vanillaGas = g0 - gasleft();

        uint256 g1 = gasleft();
        vm.prank(poor);
        swap(key, true, -int256(notional), abi.encode(poor));
        uint256 quoteOnlyGas = g1 - gasleft();

        // Bonded: same path plus the receipt write and the bond lock.
        bond(trader, hook.requiredBond(notional) * 100);
        uint256 g2 = gasleft();
        vm.prank(trader);
        swap(key, true, -int256(notional), abi.encode(trader));
        uint256 fullGas = g2 - gasleft();

        console.log("vanilla                       :", vanillaGas);
        console.log("quote + observation only      :", quoteOnlyGas);
        console.log("  -> overhead, no receipt     :", quoteOnlyGas - vanillaGas);
        console.log("full (receipt + bond lock)    :", fullGas);
        console.log("  -> receipt + lock costs     :", fullGas - quoteOnlyGas);
    }
}
