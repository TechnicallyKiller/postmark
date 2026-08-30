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

contract AdversarialTest is PostmarkTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        setUpPostmark();
    }

    /// @notice A1: TWAP manipulation. The attacker executes an adverse swap, then pushes the price
    /// back before settlement so the receipt reads benign.
    ///
    /// @dev The defence is NOT "manipulation always gets charged" — pushing the price back really
    /// does flip the markout sign. The defence is that doing so costs more than it saves, because
    /// alpha < 1 and the attacker pays fees and price impact on the manipulating leg. So this is an
    /// EV test across two worlds, not an assertion about the charge.
    function test_A1_TWAPManipulation_NegativeEV() public {
        uint256 notional = 1e15;
        address attacker = address(0xbad);
        fundTrader(attacker, 100 ether);
        bond(attacker, hook.requiredBond(notional) * 10);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        uint256 snap = vm.snapshotState();

        // World A: settle honestly, eat whatever charge the markout implies.
        vm.startPrank(attacker);
        swap(key, true, -int256(notional), abi.encode(attacker));
        vm.stopPrank();
        vm.roll(block.number + hook.W() + 1);
        hook.settle(key, ids);
        uint256 honestValue = _attackerValue(attacker);

        vm.revertToState(snap);

        // World B: manipulate the price back inside the window, then settle.
        vm.startPrank(attacker);
        swap(key, true, -int256(notional), abi.encode(attacker));
        vm.roll(block.number + hook.W() - 1);
        swap(key, false, -int256(notional / 2), abi.encode(attacker));
        vm.stopPrank();
        vm.roll(block.number + 2);
        hook.settle(key, ids);
        uint256 manipulatedValue = _attackerValue(attacker);

        console.log("attacker value, settled honestly  :", honestValue);
        console.log("attacker value, after manipulating:", manipulatedValue);

        assertLt(manipulatedValue, honestValue, "TWAP manipulation was profitable");
    }

    /// @dev Attacker's total holdings: both tokens plus anything still in the vault. The pool sits
    /// at ~1:1 so summing the legs is a fair proxy for value at these sizes.
    function _attackerValue(address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(currency0)).balanceOf(who)
            + MockERC20(Currency.unwrap(currency1)).balanceOf(who) + vault.balanceOf(who, bondCurrency);
    }

    /// @notice A2: Sybil Attack - Rotating fresh addresses defaults to top tier.
    function test_A2_SybilAttack_DefaultsToMaxTier() public {
        address sybil1 = address(0x111);
        address sybil2 = address(0x222);
        
        assertEq(hook.registry().tierOf(sybil1, false), 3); // DEFAULT_TIER
        assertEq(hook.registry().tierOf(sybil2, false), 3); // DEFAULT_TIER
        
        assertEq(hook.tierFee(hook.registry().tierOf(sybil1, false)), 3000); // 30 bps
    }

    /// @notice A3: Wash Trading Rebates - Wash trading for zero-markout rebates is net negative.
    function test_A3_WashTradingRebates_NegativeEV() public {
        uint256 notional = 1e15;
        address attacker = address(0xbad);
        fundTrader(attacker, 100 ether);
        bond(attacker, hook.requiredBond(notional) * 10);
        
        vm.startPrank(attacker);
        
        uint256 bal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 bal1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);
        
        // Swap A -> B
        swap(key, true, -int256(notional), abi.encode(attacker));
        // Swap B -> A
        swap(key, false, -int256(notional), abi.encode(attacker));
        
        vm.roll(block.number + hook.W());
        
        // Settle both
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        hook.settle(key, ids);
        
        uint256 bal0After = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 bal1After = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);
        // In wash trading, they will have slightly more of one token and significantly less of the other.
        // We assert the sum of their balances is less than the starting sum, as fees drain the total system value.
        assertTrue(bal0After + bal1After < bal0Before + bal1Before, "Wash trading should be negative EV");
        vm.stopPrank();
    }

    /// @notice A4: Receipt Spam - Micro-swaps below dustThreshold are ignored.
    function test_A4_ReceiptSpam_DustThresholdIgnored() public {
        uint256 notional = hook.DUST_THRESHOLD() - 1; // Below dust
        address attacker = address(0xbad);
        fundTrader(attacker, 100 ether);
        bond(attacker, hook.requiredBond(notional) * 10);
        
        vm.startPrank(attacker);
        swap(key, true, -int256(notional), abi.encode(attacker));
        vm.stopPrank();
        
        vm.roll(block.number + hook.W());
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.expectRevert(); // Receipt empty or settled
        hook.settle(key, ids);
    }

    /// @notice A5: LP Withdrawal - Standard LP operations are not blocked.
    function test_A5_LPWithdrawal_NotBlockedDuringActiveBonds() public {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
    }

    /// @notice Security: Premature settlement reverts
    function test_Security_PrematureSettlementReverts() public {
        uint256 notional = 1e15;
        address swapper = address(0xbad);
        fundTrader(swapper, 100 ether);
        bond(swapper, hook.requiredBond(notional) * 10);
        
        vm.prank(swapper);
        swap(key, true, -int256(notional), abi.encode(swapper));
        
        vm.roll(block.number + hook.W() - 1); // 1 block early
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        
        vm.expectRevert("TWAP window pending");
        hook.settle(key, ids);
    }

    /// @notice Security: Unauthorized bond withdrawal
    function test_Security_UnauthorizedBondWithdrawal() public {
        uint256 notional = 1e15;
        address swapper = address(0xbad);
        fundTrader(swapper, 100 ether);
        uint256 bondAmount = hook.requiredBond(notional) * 10;
        bond(swapper, bondAmount);
        
        // Start cooldown timer by moving blocks
        vm.startPrank(swapper);
        swap(key, true, -int256(notional), abi.encode(swapper));
        
        // Try to withdraw ALL bonded collateral. Since 10% is locked by the active receipt, this must fail.
        vm.expectRevert(); 
        vault.withdraw(bondCurrency, bondAmount, swapper);
        
        // Also try withdrawing during cooldown
        vm.expectRevert(); 
        vault.withdraw(bondCurrency, bondAmount / 10, swapper);
        vm.stopPrank();
    }

    /// @notice Security: Permissionless settler bounty
    function test_Security_PermissionlessSettlerBounty() public {
        uint256 notional = 1e15;
        address swapper = address(0xbad);
        fundTrader(swapper, 100 ether);
        bond(swapper, hook.requiredBond(notional) * 10);
        
        vm.prank(swapper);
        swap(key, true, -int256(notional), abi.encode(swapper));
        
        // Move price to create adverse selection
        vm.roll(block.number + 1);
        swap(key, true, -int256(notional), ZERO_BYTES);
        
        vm.roll(block.number + hook.W());
        
        address keeper = address(0x42);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        
        uint256 keeperBalBefore = hook.vault().balanceOf(keeper, bondCurrency);
        vm.prank(keeper);
        hook.settle(key, ids);
        uint256 keeperBalAfter = hook.vault().balanceOf(keeper, bondCurrency);
        
        assertGt(keeperBalAfter, keeperBalBefore, "Keeper should receive a bounty");
    }
}
