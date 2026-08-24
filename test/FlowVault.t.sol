// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FlowVault} from "../src/FlowVault.sol";

contract FlowVaultTest is Test {
    FlowVault internal vault;
    MockERC20 internal token;
    Currency internal cur;

    address internal hook = makeAddr("hook");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    uint32 internal constant COOLDOWN = 30;

    function setUp() public {
        vault = new FlowVault(COOLDOWN);
        vault.setHook(hook);

        token = new MockERC20("Bond", "BOND", 18);
        cur = Currency.wrap(address(token));

        token.mint(alice, 1e21);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);

        // Past the cooldown from block 0 so an untouched payer can withdraw.
        vm.roll(COOLDOWN + 1);
    }

    function test_depositAndWithdraw() public {
        vm.prank(alice);
        vault.deposit(cur, 1e18);
        assertEq(vault.balanceOf(alice, cur), 1e18);
        assertEq(vault.freeBalanceOf(alice, cur), 1e18);

        vm.prank(alice);
        vault.withdraw(cur, 4e17, alice);
        assertEq(vault.balanceOf(alice, cur), 6e17);
        assertEq(token.balanceOf(alice), 1e21 - 6e17);
    }

    function test_hookOnlySurface() public {
        vm.expectRevert(FlowVault.NotHook.selector);
        vault.lock(alice, cur, 1);
        vm.expectRevert(FlowVault.NotHook.selector);
        vault.debit(alice, cur, 1, keeper);
        vm.expectRevert(FlowVault.NotHook.selector);
        vault.debitOut(alice, cur, 1, keeper);
        vm.expectRevert(FlowVault.NotHook.selector);
        vault.credit(alice, cur, 1);
    }

    function test_hookIsSetOnce() public {
        vm.expectRevert(FlowVault.HookAlreadySet.selector);
        vault.setHook(address(0xdead));
    }

    /// A short bond fails the lock rather than reverting, so beforeSwap can fall back cleanly.
    function test_lockReturnsFalseWhenShort() public {
        vm.prank(alice);
        vault.deposit(cur, 100);

        vm.prank(hook);
        assertFalse(vault.lock(alice, cur, 101), "lock should have failed");
        vm.prank(hook);
        assertTrue(vault.lock(alice, cur, 100), "lock should have succeeded");
        assertEq(vault.freeBalanceOf(alice, cur), 0);
    }

    /// Locked bond cannot be withdrawn: this is what keeps a payer on the hook for settlement.
    function test_cannotWithdrawLockedBond() public {
        vm.prank(alice);
        vault.deposit(cur, 1e18);
        vm.prank(hook);
        vault.lock(alice, cur, 1e17);

        vm.prank(alice);
        vm.expectRevert(FlowVault.BondStillLocked.selector);
        vault.withdraw(cur, 1e17, alice);
    }

    /// Even with nothing locked, a payer must wait out the settlement window after a swap.
    function test_withdrawCooldown() public {
        vm.prank(alice);
        vault.deposit(cur, 1e18);

        vm.prank(hook);
        vault.lock(alice, cur, 1e17);
        vm.prank(hook);
        vault.unlock(alice, cur, 1e17);

        vm.prank(alice);
        vm.expectRevert(FlowVault.CooldownActive.selector);
        vault.withdraw(cur, 1e18, alice);

        vm.roll(block.number + COOLDOWN);
        vm.prank(alice);
        vault.withdraw(cur, 1e18, alice);
        assertEq(vault.balanceOf(alice, cur), 0);
    }

    /// Debit can only ever reach locked bond, never a payer's free balance.
    function test_debitIsCappedAtLockedAmount() public {
        vm.prank(alice);
        vault.deposit(cur, 1e18);
        vm.prank(hook);
        vault.lock(alice, cur, 1e16);

        vm.prank(hook);
        uint256 taken = vault.debit(alice, cur, 1e18, keeper);

        assertEq(taken, 1e16, "debit exceeded the lock");
        assertEq(vault.balanceOf(keeper, cur), 1e16);
        assertEq(vault.balanceOf(alice, cur), 1e18 - 1e16);
        assertEq(vault.lockedOf(alice, cur), 0);
    }

    function test_debitOutSendsTokens() public {
        vm.prank(alice);
        vault.deposit(cur, 1e18);
        vm.prank(hook);
        vault.lock(alice, cur, 1e16);

        vm.prank(hook);
        vault.debitOut(alice, cur, 1e16, keeper);
        assertEq(token.balanceOf(keeper), 1e16);
    }

    /// Rebates come out of the hook's own vault account and can never overdraw it.
    function test_creditIsCappedAtRebatePool() public {
        vm.prank(alice);
        vault.depositFor(hook, cur, 1e15);

        vm.prank(hook);
        vault.credit(alice, cur, 1e18);

        assertEq(vault.balanceOf(alice, cur), 1e15, "credit exceeded the pool");
        assertEq(vault.balanceOf(hook, cur), 0);
    }

    function test_nativeBondsRejected() public {
        vm.prank(alice);
        vm.expectRevert(FlowVault.NativeNotSupported.selector);
        vault.deposit(Currency.wrap(address(0)), 1);
    }
}
