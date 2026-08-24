// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/// @title PostmarkHook
/// @notice Charges a low fee up front based on the payer's realized-markout reputation, then bills
/// the adverse selection afterwards from a bond. This file is the v4 surface; the accounting lives
/// in FlowVault, ReceiptBook, ScoreRegistry and PriceAccumulator.
contract PostmarkHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    /// @notice Number of reputation tiers. Tier 0 is proven benign, the last tier is the unknown /
    /// unbonded default and matches the vanilla baseline fee.
    uint256 public constant TIER_COUNT = 4;

    /// @notice Default tier for an address we know nothing about: the top (most expensive) tier.
    uint8 public constant DEFAULT_TIER = 3;

    /// @dev Fee charged per tier, in hundredths of a bip (pips). 3000 pips == 30 bps.
    uint24[TIER_COUNT] internal _tierFee = [uint24(200), 800, 1500, 3000];

    /// @notice Pools that were initialized through this hook.
    mapping(PoolId => bool) public registered;

    error NotDynamicFee();

    event PoolRegistered(PoolId indexed poolId);
    event FeeQuoted(PoolId indexed poolId, address indexed payer, uint8 tier, uint24 fee);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Fee for a tier, in pips.
    function tierFee(uint8 tier) public view returns (uint24) {
        return _tierFee[tier >= TIER_COUNT ? TIER_COUNT - 1 : tier];
    }

    // -------------------------------------------------------------------------
    // Hook callbacks
    // -------------------------------------------------------------------------

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        // Postmark can only quote per-swap fees on a dynamic-fee pool.
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        PoolId poolId = key.toId();
        registered[poolId] = true;

        // Seed the pool at the unbonded baseline so a swap that somehow bypasses the override
        // still pays the top tier rather than zero.
        poolManager.updateDynamicLPFee(key, _tierFee[DEFAULT_TIER]);

        emit PoolRegistered(poolId);
        return BaseHook.afterInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address payer = _resolvePayer(sender, hookData);
        uint8 tier = _tierOf(payer);
        uint24 fee = tierFee(tier);

        emit FeeQuoted(key.toId(), payer, tier, fee);

        // Never revert on a swap. Quote by overriding the LP fee for this swap only.
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        // Receipt write, bond lock and price observation land here on Day 3.
        sender;
        key;
        hookData;
        return (BaseHook.afterSwap.selector, int128(0));
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev v1 attributes flow to the address that called `poolManager.swap` (usually a router).
    /// A router may attest to its end user by passing a 32-byte address in `hookData`, which is the
    /// path to per-user rather than per-router scoring. Attestation is opt-in and self-reported:
    /// a router can only ever move cost onto an address it names, never off itself, because a
    /// named address that is unbonded lands in the top tier.
    function _resolvePayer(address sender, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length == 32) {
            address attested = abi.decode(hookData, (address));
            if (attested != address(0)) return attested;
        }
        return sender;
    }

    /// @dev Stubbed until the ScoreRegistry lands on Day 2. Everyone is unknown, so everyone pays
    /// the baseline.
    function _tierOf(address) internal view virtual returns (uint8) {
        return DEFAULT_TIER;
    }
}
