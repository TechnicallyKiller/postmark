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
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFlowVault} from "./interfaces/IFlowVault.sol";
import {IScoreRegistry} from "./interfaces/IScoreRegistry.sol";
import {PostmarkMath} from "./libraries/PostmarkMath.sol";
import {ReceiptBook} from "./libraries/ReceiptBook.sol";
import {PriceAccumulator} from "./libraries/PriceAccumulator.sol";

/// @title PostmarkHook
/// @notice Quotes a low fee up front from the payer's realized-markout reputation, then bills the
/// adverse selection afterwards from a bond they posted. This file is the v4 surface; accounting
/// lives in FlowVault, ScoreRegistry, and (from Day 3) ReceiptBook and PriceAccumulator.
contract PostmarkHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

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

    /// @notice Settlement TWAP window in blocks
    uint40 public constant W = 5;

    /// @notice LVR recapture alpha (60% in bps)
    uint256 public constant ALPHA = 6000;

    /// @notice Keeper reward (5% of charge in bps)
    uint256 public constant KEEPER_BPS = 500;

    /// @notice Rebate pool share (15% of charge in bps)
    uint256 public constant REBATE_SHARE_BPS = 1500;

    /// @notice Cap for rebate as bps of fee paid (50%)
    uint256 public constant REBATE_CAP_RATIO = 5000;

    IFlowVault public immutable vault;
    IScoreRegistry public immutable registry;

    struct PoolConfig {
        bool registered;
        Currency bondCurrency;
    }

    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(PoolId => ReceiptBook.RingBuffer) public receipts;
    mapping(PoolId => PriceAccumulator.ObservationHistory) public priceHistory;

    /// @notice Minimum notional required to write a receipt.
    /// @dev Prevents state bloat from receipt spam (A4 defence).
    uint256 public constant DUST_THRESHOLD = 10 * 10**6;

    /// @dev Transient slot carrying the payer, bonded flag, and tier resolved in beforeSwap into afterSwap.
    bytes32 private constant PAYER_SLOT = keccak256("postmark.transient.payer");

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

        uint256 packed = uint256(uint160(payer)) | (bondCovered ? (1 << 160) : 0) | (uint256(tier) << 161);
        _tstore(PAYER_SLOT, packed);

        emit FeeQuoted(poolId, payer, tier, fee, bondCovered);

        // Never revert on a swap. Quote by overriding the LP fee for this swap only.
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        _handleAfterSwap(key, params, delta);
        return (BaseHook.afterSwap.selector, int128(0));
    }

    function _handleAfterSwap(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta) private {
        address payer;
        bool bondCovered;
        uint8 tier;
        {
            uint256 packed = _tload(PAYER_SLOT);
            _tstore(PAYER_SLOT, 0);

            payer = address(uint160(packed));
            bondCovered = ((packed >> 160) & 1) == 1;
            tier = uint8((packed >> 161) & 0xFF);
        }

        uint256 notional = PostmarkMath.abs(int256(delta.amount1()));
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());

        if (notional > DUST_THRESHOLD && bondCovered) {
            uint32 scaledNotional = uint32(notional / DUST_THRESHOLD);
            ReceiptBook.write(receipts, key.toId(), payer, params.zeroForOne, tier, scaledNotional, tick);
            vault.lock(payer, poolConfig[key.toId()].bondCurrency, requiredBond(notional));
        }

        PriceAccumulator.push(priceHistory, key.toId(), tick);
    }

    /// @notice Settle a batch of receipts. Calculates markout against TWAP and charges bond.
    function settle(PoolKey calldata key, uint256[] calldata receiptIds) external {
        poolManager.unlock(abi.encode(key, receiptIds, msg.sender));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Not PM");
        (PoolKey memory key, uint256[] memory receiptIds, address keeper) = abi.decode(data, (PoolKey, uint256[], address));
        
        for (uint256 i = 0; i < receiptIds.length; i++) {
            _settleReceipt(key, receiptIds[i], keeper);
        }
        return "";
    }

    function _settleReceipt(
        PoolKey memory key,
        uint256 id,
        address keeper
    ) private {
        PoolId poolId = key.toId();
        ReceiptBook.RingBuffer storage buffer = receipts[poolId];
        ReceiptBook.Receipt memory receipt = buffer.receipts[id];
        require(receipt.payer != address(0), "Receipt empty or settled");
        require(block.number >= receipt.blockNumber + W, "TWAP window pending");

        uint256 notional = uint256(receipt.notionalScaled) * DUST_THRESHOLD;
        int256 markout;
        {
            int24 tickRef = PriceAccumulator.twapOver(priceHistory, poolId, receipt.blockNumber, receipt.blockNumber + W);
            
            uint160 sqrtPExec = TickMath.getSqrtPriceAtTick(receipt.tickAfter);
            uint160 sqrtPRef = TickMath.getSqrtPriceAtTick(tickRef);

            uint256 ratioX96;
            {
                uint256 R = FullMath.mulDiv(sqrtPRef, FixedPoint96.Q96, sqrtPExec);
                ratioX96 = FullMath.mulDiv(R, R, FixedPoint96.Q96);
            }

            bool zeroForOne = (receipt.flags & 1) == 1;

            int256 diffX96 = zeroForOne
                ? int256(uint256(FixedPoint96.Q96)) - int256(ratioX96)
                : int256(ratioX96) - int256(uint256(FixedPoint96.Q96));

            markout = diffX96 >= 0
                ? int256(FullMath.mulDiv(notional, uint256(diffX96), FixedPoint96.Q96))
                : -int256(FullMath.mulDiv(notional, uint256(-diffX96), FixedPoint96.Q96));

            registry.update(receipt.payer, (markout * int256(PostmarkMath.BPS)) / int256(notional));
        }

        if (markout > 0) {
            _distributeCharge(key, receipt, markout, keeper);
        } else {
            // Negative markout (benign swap), credit rebate if any pool exists
            uint8 tier = receipt.flags >> 1;
            uint256 feePaid = (notional * uint256(tierFee(tier))) / PostmarkMath.BPS;
            uint256 rebateCap = PostmarkMath.bpsOf(feePaid, REBATE_CAP_RATIO);
            uint256 rebate = uint256(-markout);
            if (rebate > rebateCap) rebate = rebateCap;

            if (rebate > 0) {
                vault.credit(receipt.payer, poolConfig[poolId].bondCurrency, rebate);
            }
        }

        vault.unlock(receipt.payer, poolConfig[poolId].bondCurrency, requiredBond(uint256(receipt.notionalScaled) * DUST_THRESHOLD));
        delete buffer.receipts[id];
    }

    function _distributeCharge(PoolKey memory key, ReceiptBook.Receipt memory receipt, int256 markout, address keeper) private {
        PoolId poolId = key.toId();
        uint256 notional = uint256(receipt.notionalScaled) * DUST_THRESHOLD;
        uint256 rawCharge = PostmarkMath.bpsOf(uint256(markout), ALPHA);
        uint256 cap = maxCharge(notional);
        uint256 charge = rawCharge > cap ? cap : rawCharge;

        if (charge > 0) {
            Currency bondCurrency = poolConfig[poolId].bondCurrency;
            uint256 keeperFee = PostmarkMath.bpsOf(charge, KEEPER_BPS);
            if (keeperFee > 0) vault.debit(receipt.payer, bondCurrency, keeperFee, keeper);
            
            uint256 rebateShare = PostmarkMath.bpsOf(charge, REBATE_SHARE_BPS);
            if (rebateShare > 0) vault.debit(receipt.payer, bondCurrency, rebateShare, address(this));

            uint256 lpShare = charge - keeperFee - rebateShare;
            if (lpShare > 0) {
                vault.debitOut(receipt.payer, bondCurrency, lpShare, address(this));
                poolManager.donate(key, 0, lpShare, "");
                poolManager.sync(bondCurrency);
                IERC20(Currency.unwrap(bondCurrency)).safeTransfer(address(poolManager), lpShare);
                poolManager.settle();
            }
        }
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
