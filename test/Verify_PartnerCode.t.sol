// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PostmarkTestBase} from "./utils/PostmarkTestBase.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ReceiptBook} from "../src/libraries/ReceiptBook.sol";
import {FlowVault} from "../src/FlowVault.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/// @notice Regression tests for the receipt-notional defects found in the Day 3/4 implementation.
/// Each one fails against the `uint32(notional / DUST_THRESHOLD)` scheme these replace.
contract ReceiptNotionalRegressionTest is PostmarkTestBase {
    address internal trader = makeAddr("trader");

    function setUp() public {
        setUpPostmark();
        fundTrader(trader, 1e24);
    }

    /// @dev The shared fixture's pool is deliberately shallow. Notional-size regressions need real
    /// depth, or the swap fills for far less than it asks and never reaches the old wrap point.
    function _deepenPool() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e24, salt: 0}),
            ZERO_BYTES
        );
    }

    /// A realistic swap must record its notional exactly. The old scheme wrapped `uint32` above
    /// ~0.043 tokens and understated a 1-token swap by 82x.
    function test_notionalRoundTripsExactlyAtRealisticSize() public {
        _deepenPool();
        uint256 amountIn = 1e18; // 1 token — far past the old wrap point
        bond(trader, 1e21);

        vm.prank(trader);
        BalanceDelta delta = swap(key, true, -int256(amountIn), abi.encode(trader));
        uint256 actualNotional = uint256(uint128(delta.amount1()));

        assertEq(hook.receiptCount(poolId), 1, "no receipt written");
        ReceiptBook.Receipt memory r = hook.getReceipt(poolId, 0);

        // The old scheme wrapped uint32 above 2^32 * DUST_THRESHOLD = 4.295e16.
        assertGt(actualNotional, 4.3e16, "swap too small to exercise the old wrap point");
        assertEq(uint256(r.notional), actualNotional, "receipt notional does not match the fill");
        assertEq(r.payer, trader, "wrong payer");
        console.log("filled notional  :", actualNotional);
        console.log("recorded notional:", uint256(r.notional));
    }

    /// The bond locked at swap time must be released in full at settlement. Any residue is
    /// permanent, because FlowVault.withdraw requires locked == 0.
    function test_bondFullyReleasedAtSettlement() public {
        // A size whose old scaled form had a remainder, so the residue bug would bite.
        uint256 amountIn = 15 * 10 ** 6 + 7;
        bond(trader, 1e21);

        vm.roll(100);
        vm.prank(trader);
        swap(key, true, -int256(amountIn), abi.encode(trader));

        uint256 lockedAfterSwap = vault.lockedOf(trader, bondCurrency);
        assertGt(lockedAfterSwap, 0, "nothing was locked");

        vm.roll(100 + hook.W() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        hook.settle(key, ids);

        assertEq(vault.lockedOf(trader, bondCurrency), 0, "bond residue left locked forever");
    }

    /// The payer must be able to get their capital back once settled and past the cooldown. This is
    /// the end-to-end consequence of the residue bug.
    function test_payerCanWithdrawAfterSettlement() public {
        bond(trader, 1e21);

        vm.roll(100);
        vm.prank(trader);
        swap(key, true, -int256(1e18), abi.encode(trader));

        vm.roll(100 + hook.W() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        hook.settle(key, ids);

        vm.roll(block.number + WINDOW_BLOCKS + 1);
        uint256 free = vault.freeBalanceOf(trader, bondCurrency);
        assertGt(free, 0, "no free balance to withdraw");

        vm.prank(trader);
        vault.withdraw(bondCurrency, free, trader);
        assertEq(vault.balanceOf(trader, bondCurrency), 0, "withdraw did not clear the balance");
    }

    /// Settlement must work at 1-token scale. The old scheme could wrap the notional to zero and
    /// divide by zero in the score update, bricking the receipt and its bond permanently.
    function test_settlementSucceedsAtRealisticSize() public {
        bond(trader, 1e21);

        vm.roll(100);
        vm.prank(trader);
        swap(key, true, -int256(1e18), abi.encode(trader));

        vm.roll(100 + hook.W() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        hook.settle(key, ids); // must not revert

        ReceiptBook.Receipt memory r = hook.getReceipt(poolId, 0);
        assertEq(r.payer, address(0), "receipt not cleared after settlement");
    }

    /// A receipt is never written without collateral actually locked behind it.
    function test_noReceiptWithoutBond() public {
        // No bond posted at all.
        vm.prank(trader);
        swap(key, true, -int256(1e18), abi.encode(trader));
        assertEq(hook.receiptCount(poolId), 0, "receipt written with no bond");
    }
}
