// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PostmarkTestBase} from "./utils/PostmarkTestBase.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PostmarkHook} from "../src/PostmarkHook.sol";
import {FlowVault} from "../src/FlowVault.sol";

contract AdversarialTest is PostmarkTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        setUpPostmark();
    }

    /// @notice A1: TWAP manipulation. An informed trader whose call the market confirms pushes the
    /// price back inside the settlement window so the receipt reads benign.
    ///
    /// @dev The scenario has to make the attacker genuinely toxic first, or there is no charge to
    /// dodge and the test proves nothing. An earlier version of this test omitted the market leg:
    /// both worlds settled at zero and it "passed" purely because the manipulating swap cost a fee.
    ///
    /// So: the attacker sells, the market sells after them (confirming they were informed), and in
    /// world B they buy back immediately - early in the window, where a manipulated price carries
    /// almost the whole TWAP weight. That is the strongest form of the attack, not the weakest.
    ///
    /// The defence is not that manipulation fails. It is that it costs more than it saves, because
    /// alpha < 1 and the attacker pays fees and price impact on the manipulating leg.
    function test_A1_TWAPManipulation_NegativeEV() public {
        _deepenPool();

        uint256 notional = 1e18;
        address attacker = makeAddr("a1attacker");
        address market = makeAddr("a1market");
        fundTrader(attacker, 1e24);
        fundTrader(market, 1e24);
        bond(attacker, 1e22);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        uint256 snap = vm.snapshotState();

        // ---- World A: informed trade, settled honestly. ----
        vm.roll(100);
        vm.prank(attacker);
        swap(key, true, -int256(notional), abi.encode(attacker));
        vm.roll(101);
        vm.prank(market);
        swap(key, true, -int256(notional * 4), ZERO_BYTES); // market confirms: price falls further

        vm.roll(100 + hook.W() + 1);
        uint256 b = vault.balanceOf(attacker, bondCurrency);
        hook.settle(key, ids);
        uint256 honestCharge = b - vault.balanceOf(attacker, bondCurrency);
        uint256 honestValue = _attackerValue(attacker);

        vm.revertToState(snap);

        // ---- World B: same trade, same market move, buy back INSIDE the window. ----
        vm.roll(100);
        vm.prank(attacker);
        swap(key, true, -int256(notional), abi.encode(attacker));
        vm.roll(101);
        vm.prank(market);
        swap(key, true, -int256(notional * 4), ZERO_BYTES);

        // Buy back at the START of the window, so the manipulated price carries ~99/100 of the
        // TWAP weight. Manipulating at the end would be the weak version of this attack.
        vm.roll(102);
        vm.prank(attacker);
        swap(key, false, -int256(notional * 4), abi.encode(attacker));

        vm.roll(100 + hook.W() + 1);
        b = vault.balanceOf(attacker, bondCurrency);
        hook.settle(key, ids);
        uint256 manipulatedCharge = b - vault.balanceOf(attacker, bondCurrency);
        uint256 manipulatedValue = _attackerValue(attacker);

        vm.revertToState(snap);

        // ---- World C, the control: identical trades, buy-back moved AFTER the window closes. ----
        // The buy-back is a profitable trade in its own right - the market's 4x sell left a
        // dislocation. Comparing B against A would credit that trading profit to the manipulation.
        // C isolates the effect: same two trades, same P&L, only the timing differs, so any gap
        // between B and C is the manipulation and nothing else.
        vm.roll(100);
        vm.prank(attacker);
        swap(key, true, -int256(notional), abi.encode(attacker));
        vm.roll(101);
        vm.prank(market);
        swap(key, true, -int256(notional * 4), ZERO_BYTES);

        vm.roll(100 + hook.W() + 1);
        b = vault.balanceOf(attacker, bondCurrency);
        hook.settle(key, ids);
        uint256 controlCharge = b - vault.balanceOf(attacker, bondCurrency);

        vm.roll(100 + hook.W() + 2);
        vm.prank(attacker);
        swap(key, false, -int256(notional * 4), abi.encode(attacker));
        uint256 controlValue = _attackerValue(attacker);

        console.log("charge, settled honestly     :", honestCharge);
        console.log("charge, manipulated          :", manipulatedCharge);
        console.log("charge, control (late buyback):", controlCharge);
        console.log("value, manipulated           :", manipulatedValue);
        console.log("value, control               :", controlValue);
        honestValue;

        // The setup must actually bite, or the comparison below is vacuous.
        assertGt(honestCharge, 0, "scenario did not make the attacker toxic - test proves nothing");

        // The defence, stated precisely: moving the same trade inside the window must not pay.
        assertLe(
            manipulatedValue,
            controlValue,
            "TWAP manipulation is profitable: timing the same buy-back inside the window beats timing it after"
        );
    }

    /// @dev Attacker's total holdings: both tokens plus anything still in the vault. The pool sits
    /// near 1:1 so summing the legs is a fair proxy for value at these sizes.
    function _attackerValue(address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(currency0)).balanceOf(who)
            + MockERC20(Currency.unwrap(currency1)).balanceOf(who) + vault.balanceOf(who, bondCurrency);
    }

    /// @dev The shared fixture's pool is deliberately shallow, so a large swap fills for very little
    /// and the tick barely moves. Adversarial scenarios need the price to actually respond.
    function _deepenPool() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e21, salt: 0}),
            ZERO_BYTES
        );
    }

    // =========================================================================
    // A2: Sybil. Rotating fresh addresses cannot beat building a reputation.
    // =========================================================================

    /// @notice A fresh address can never buy its way below the entry tier, whatever it bonds.
    /// Reputation is earned by settling benign flow, not purchased.
    function test_A2_freshAddressCannotBuyALowerTier() public {
        address sybil = makeAddr("sybil");
        fundTrader(sybil, 1e24);

        assertEq(registry.tierOf(sybil, false), 3, "unbonded fresh address is not at the baseline");

        // Post an enormous bond. It changes nothing below the entry tier.
        bond(sybil, 1e22);
        assertEq(registry.tierOf(sybil, true), registry.BONDED_ENTRY_TIER(), "a large bond bought a discount");
        assertEq(registry.settledCountOf(sybil), 0, "fresh address has history");
    }

    /// @notice The economic claim: over the same flow, rotating addresses costs strictly more in
    /// fees than one address that settles its receipts and earns its way down the tiers.
    function test_A2_sybilPaysStrictlyMoreThanAReputation() public {
        uint256 notional = 1e15;
        uint256 swaps = 12;

        // Honest payer: one address, settling after every swap.
        address honest = makeAddr("honest");
        fundTrader(honest, 1e24);
        bond(honest, 1e22);

        uint256 honestFees;
        for (uint256 i = 0; i < swaps; i++) {
            honestFees += _feeFor(notional, registry.tierOf(honest, true));
            vm.roll(block.number + 10);
            vm.prank(honest);
            swap(key, i % 2 == 0, -int256(notional), abi.encode(honest));

            vm.roll(block.number + hook.W() + 1);
            uint256[] memory ids = new uint256[](1);
            ids[0] = i;
            hook.settle(key, ids);
        }

        // Sybil: a brand-new bonded address for every swap. Each starts with no history.
        uint256 sybilFees;
        for (uint256 i = 0; i < swaps; i++) {
            address sybil = makeAddr(string(abi.encodePacked("sybil", vm.toString(i))));
            fundTrader(sybil, 1e24);
            bond(sybil, 1e20);

            sybilFees += _feeFor(notional, registry.tierOf(sybil, true));
            vm.roll(block.number + 10);
            vm.prank(sybil);
            swap(key, i % 2 == 0, -int256(notional), abi.encode(sybil));
        }

        console.log("fees paid, one reputation :", honestFees);
        console.log("fees paid, rotating sybils:", sybilFees);
        assertLt(honestFees, sybilFees, "rotating addresses was not more expensive");
        assertLt(registry.tierOf(honest, true), registry.BONDED_ENTRY_TIER(), "honest payer never improved");
    }

    /// @notice An unbonded sybil - the cheapest rotation, no capital at risk - pays the full
    /// baseline on every swap. This is the honest consequence: Postmark does not catch them, it
    /// stops subsidising them.
    function test_A2_unbondedSybilAlwaysPaysBaseline() public {
        for (uint256 i = 0; i < 5; i++) {
            address sybil = makeAddr(string(abi.encodePacked("free", vm.toString(i))));
            assertEq(hook.tierFee(registry.tierOf(sybil, false)), 3000, "unbonded sybil got a discount");
        }
    }

    // =========================================================================
    // A3: Wash trading for rebates.
    // =========================================================================

    /// @notice Round-tripping is strictly negative EV. The attacker swaps token0 in, then puts the
    /// entire token1 proceeds straight back, so they end holding exactly the token1 they started
    /// with and strictly less token0. Same-token comparison on both legs - no cross-token summing.
    function test_A3_washTradingIsNegativeEV() public {
        address washer = makeAddr("washer");
        fundTrader(washer, 1e24);
        bond(washer, 1e22);

        uint256 t0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(washer);
        uint256 t1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(washer);
        uint256 vaultBefore = vault.balanceOf(washer, bondCurrency);

        vm.roll(100);
        vm.prank(washer);
        BalanceDelta outLeg = swap(key, true, -int256(1e15), abi.encode(washer));
        uint256 received = uint256(uint128(outLeg.amount1()));

        // Put every unit of the proceeds straight back.
        vm.prank(washer);
        swap(key, false, -int256(received), abi.encode(washer));

        vm.roll(100 + hook.W() + 1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        hook.settle(key, ids);

        uint256 t0After = MockERC20(Currency.unwrap(currency0)).balanceOf(washer);
        uint256 t1After = MockERC20(Currency.unwrap(currency1)).balanceOf(washer);
        uint256 rebates = vault.balanceOf(washer, bondCurrency) - vaultBefore;

        console.log("token0 lost to the round trip:", t0Before - t0After);
        console.log("token1 net change            :", t1After - t1Before);
        console.log("rebates credited             :", rebates);

        assertEq(t1After, t1Before, "token1 leg did not close out");
        assertLt(t0After, t0Before, "the round trip did not cost the washer anything");

        // The whole defence: rebates cannot cover what the round trip cost.
        uint256 feesPaid = _feeFor(1e15, 2) + _feeFor(received, 2);
        assertLt(rebates, feesPaid, "rebates exceeded fees paid - wash trading is profitable");
    }

    /// @notice The structural reason A3 holds: a rebate is capped at half the fee that generated it,
    /// so no sequence of trades can farm more back than it paid in.
    function test_A3_rebateCapIsBelowUnity() public view {
        assertLt(hook.REBATE_CAP_RATIO(), 10_000, "a rebate can reach or exceed the fee paid");
    }

    // =========================================================================
    // A4: Receipt spam.
    // =========================================================================

    /// @notice Dust swaps write no receipts at all, so the state they can bloat is zero - and the
    /// spammer still pays full gas for every one of them.
    function test_A4_dustSwapsWriteNoState() public {
        address spammer = makeAddr("spammer");
        fundTrader(spammer, 1e24);
        bond(spammer, 1e22);

        uint256 dust = hook.DUST_THRESHOLD() / 2;
        uint256 gasSpent;
        for (uint256 i = 0; i < 20; i++) {
            vm.roll(block.number + 1);
            uint256 g = gasleft();
            vm.prank(spammer);
            swap(key, i % 2 == 0, -int256(dust), abi.encode(spammer));
            gasSpent += g - gasleft();
        }

        assertEq(hook.receiptCount(poolId), 0, "dust swaps wrote receipts");
        assertEq(vault.lockedOf(spammer, bondCurrency), 0, "dust swaps locked bond");
        console.log("gas the spammer burned for zero receipts:", gasSpent);
        assertGt(gasSpent, 0, "spam was free");
    }

    /// @notice The threshold is a real boundary, not decoration: just above it a receipt appears.
    function test_A4_thresholdBoundaryIsLive() public {
        address trader = makeAddr("boundary");
        fundTrader(trader, 1e24);
        bond(trader, 1e22);

        // token1 output has to clear the threshold, so send well past it on the input side.
        vm.prank(trader);
        swap(key, true, -int256(hook.DUST_THRESHOLD() * 100), abi.encode(trader));
        assertEq(hook.receiptCount(poolId), 1, "a swap well above dust wrote no receipt");
    }

    // =========================================================================
    // A5: Hook rug risk.
    // =========================================================================

    /// @notice LPs can always withdraw, even with receipts open and bond locked. Postmark declares
    /// no liquidity callbacks at all, so it is not merely permitted - it is structurally incapable
    /// of blocking them.
    function test_A5_lpCanWithdrawWithReceiptsOpen() public {
        address trader = makeAddr("t");
        fundTrader(trader, 1e24);
        bond(trader, 1e22);

        vm.prank(trader);
        swap(key, true, -int256(1e15), abi.encode(trader));
        assertEq(hook.receiptCount(poolId), 1, "no open receipt to test against");
        assertGt(vault.lockedOf(trader, bondCurrency), 0, "no bond locked to test against");

        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertFalse(perms.beforeRemoveLiquidity, "hook can intercept LP removal");
        assertFalse(perms.afterRemoveLiquidity, "hook can intercept LP removal");

        // Actually remove it, with the receipt still open.
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    /// @notice The emergency brake stops Postmark taking on new obligations without ever blocking a
    /// swap, a settlement, an LP, or a bond withdrawal.
    function test_A5_emergencyModeStopsObligationsNotUsers() public {
        address trader = makeAddr("t2");
        fundTrader(trader, 1e24);
        bond(trader, 1e22);

        // An open receipt from before the brake is tripped.
        vm.roll(100);
        vm.prank(trader);
        swap(key, true, -int256(1e15), abi.encode(trader));
        assertEq(hook.receiptCount(poolId), 1);

        vm.prank(guardian);
        hook.engageEmergencyMode();
        assertTrue(hook.emergencyMode());

        // Swaps still work, and take on no new obligation.
        vm.roll(101);
        vm.prank(trader);
        swap(key, true, -int256(1e15), abi.encode(trader));
        assertEq(hook.receiptCount(poolId), 1, "emergency mode still wrote a receipt");

        // Everyone is quoted the baseline now, bond or no bond.
        assertEq(hook.tierFee(registry.tierOf(trader, false)), 3000);

        // The pre-existing receipt still settles.
        vm.roll(100 + hook.W() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        hook.settle(key, ids);
        assertEq(vault.lockedOf(trader, bondCurrency), 0, "settlement blocked in emergency mode");

        // LPs are untouched.
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        // And the payer gets their capital back.
        vm.roll(block.number + WINDOW_BLOCKS + 1);
        uint256 free = vault.freeBalanceOf(trader, bondCurrency);
        vm.prank(trader);
        vault.withdraw(bondCurrency, free, trader);
        assertEq(vault.balanceOf(trader, bondCurrency), 0, "bond withdrawal blocked in emergency mode");
    }

    /// @notice The brake is guardian-only and one-way. A guardian who could release it could stall
    /// settlement while the price moved.
    function test_A5_emergencyModeIsGuardianOnlyAndOneWay() public {
        vm.expectRevert(PostmarkHook.NotGuardian.selector);
        hook.engageEmergencyMode();

        vm.prank(guardian);
        hook.engageEmergencyMode();
        assertTrue(hook.emergencyMode());

        // There is no path back: no setter exists, so the only state transition is on.
        vm.prank(guardian);
        hook.engageEmergencyMode();
        assertTrue(hook.emergencyMode(), "emergency mode was releasable");
    }

    /// @notice The vault's hook is fixed at wiring time, so no owner can point the money at a new
    /// contract later.
    function test_A5_vaultHookIsImmutable() public {
        vm.expectRevert(FlowVault.HookAlreadySet.selector);
        vault.setHook(address(0xdead));
        assertEq(vault.hook(), address(hook));
    }

    // -------------------------------------------------------------------------

    /// @dev Fee in token terms for a notional at a given tier. tierFee is in pips (1e6 = 100%).
    function _feeFor(uint256 notional, uint8 tier) internal view returns (uint256) {
        return (notional * hook.tierFee(tier)) / 1_000_000;
    }
}
