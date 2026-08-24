// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IFlowVault} from "./interfaces/IFlowVault.sol";
import {IScoreRegistry} from "./interfaces/IScoreRegistry.sol";
import {PostmarkMath} from "./libraries/PostmarkMath.sol";

/// @title PostmarkHook
/// @notice Quotes a low fee up front from the payer's realized-markout reputation, then bills the
/// adverse selection afterwards from a bond they posted. This file is the v4 surface; accounting
/// lives in FlowVault, ScoreRegistry, and (from Day 3) ReceiptBook and PriceAccumulator.
contract PostmarkHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    uint256 public constant TIER_COUNT = 4;
    uint8 public constant DEFAULT_TIER = 3;

    /// @notice Fee per tier, in pips (hundredths of a bip). 3000 pips == 30 bps.
    uint24[TIER_COUNT] internal _tierFee = [uint24(200), 800, 1500, 3000];

    /// @notice Bond required per open receipt, as bps of notional. 200 bps == 2%.
    /// @dev Must stay strictly above MAX_CHARGE_BPS: a payer who forfeits their bond must lose more
    /// than the charge they were dodging. That is what makes settlement self-enforcing.
    uint256 public constant BOND_RATIO_BPS = 200;

    /// @notice Hard cap on what one receipt can be charged, as bps of notional.
    uint256 public constant MAX_CHARGE_BPS = 100;

    IFlowVault public immutable vault;
    IScoreRegistry public immutable registry;

    struct PoolConfig {
        bool registered;
        Currency bondCurrency;
    }

    mapping(PoolId => PoolConfig) public poolConfig;

    /// @dev Transient slot carrying the payer resolved in beforeSwap into afterSwap.
    bytes32 private constant PAYER_SLOT = keccak256("postmark.transient.payer");
    /// @dev Transient slot carrying whether the payer's bond covered the swap.
    bytes32 private constant BONDED_SLOT = keccak256("postmark.transient.bonded");

    error NotDynamicFee();

    event PoolRegistered(PoolId indexed poolId, Currency bondCurrency);
    event FeeQuoted(PoolId indexed poolId, address indexed payer, uint8 tier, uint24 fee, bool bondCovered);

    constructor(IPoolManager _poolManager, IFlowVault _vault, IScoreRegistry _registry) BaseHook(_poolManager) {
        vault = _vault;
        registry = _registry;
    }

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

    function tierFee(uint8 tier) public view returns (uint24) {
        return _tierFee[tier >= TIER_COUNT ? TIER_COUNT - 1 : tier];
    }

    /// @notice Bond a payer must have free to keep their tier on a swap of this notional.
    function requiredBond(uint256 notional) public pure returns (uint256) {
        return PostmarkMath.bpsOf(notional, BOND_RATIO_BPS);
    }

    /// @notice Largest charge one receipt of this notional can ever incur.
    function maxCharge(uint256 notional) public pure returns (uint256) {
        return PostmarkMath.bpsOf(notional, MAX_CHARGE_BPS);
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
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        PoolId poolId = key.toId();
        // Bonds are posted in the quote asset, which is currency1 by v4's token ordering.
        poolConfig[poolId] = PoolConfig({registered: true, bondCurrency: key.currency1});

        // Seed at the unbonded baseline so a swap that somehow skips the override still pays the
        // top tier rather than nothing.
        poolManager.updateDynamicLPFee(key, _tierFee[DEFAULT_TIER]);

        emit PoolRegistered(poolId, key.currency1);
        return BaseHook.afterInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        address payer = _resolvePayer(sender, hookData);

        uint256 notional = _estimateNotional(poolId, params);
        Currency bondCurrency = poolConfig[poolId].bondCurrency;

        // Bonded means: enough free bond right now to cover this swap's requirement. A payer whose
        // bond is short is not rejected, they simply lose the discount for this swap.
        bool bondCovered = vault.freeBalanceOf(payer, bondCurrency) >= requiredBond(notional);

        uint8 tier = registry.tierOf(payer, bondCovered);
        uint24 fee = tierFee(tier);

        _tstore(PAYER_SLOT, uint256(uint160(payer)));
        _tstore(BONDED_SLOT, bondCovered ? 1 : 0);

        emit FeeQuoted(poolId, payer, tier, fee, bondCovered);

        // Never revert on a swap. Quote by overriding the LP fee for this swap only.
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        // Receipt write, bond lock and price observation land here on Day 3.
        return (BaseHook.afterSwap.selector, int128(0));
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev v1 attributes flow to the address that called `poolManager.swap`, normally a router.
    /// A router may attest to its end user with a 32-byte address in `hookData`. Attestation can
    /// only ever move cost onto the named address, never off the router, because a named address
    /// with no bond lands in the top tier.
    function _resolvePayer(address sender, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length == 32) {
            address attested = abi.decode(hookData, (address));
            if (attested != address(0)) return attested;
        }
        return sender;
    }

    /// @dev Notional of the pending swap in currency1 terms, from the pre-swap price. This is only
    /// used for the bond sufficiency check; the receipt written in afterSwap uses the exact filled
    /// amounts instead.
    function _estimateNotional(PoolId poolId, SwapParams calldata params) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 specified = PostmarkMath.abs(params.amountSpecified);
        bool exactInput = params.amountSpecified < 0;

        // The specified currency is the input on exact-input and the output on exact-output.
        bool specifiedIsCurrency0 = exactInput == params.zeroForOne;
        return specifiedIsCurrency0 ? PostmarkMath.amount0To1(specified, sqrtPriceX96) : specified;
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
