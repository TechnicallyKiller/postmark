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

    /// @notice Settlement TWAP window, in blocks.
    /// @dev Measured, not guessed. Replaying 627 real USDC/WETH swaps, a 5-block window saw only
    /// 3,823 USDC of the 17,947 USDC of adverse selection that actually materialised — 60 seconds
    /// is simply too soon for the price to have told you who was informed. At W = 5 the pool
    /// collected the equivalent of 14 bps against a 30 bps baseline, so LPs were strictly worse off
    /// than a flat pool. At W = 100 (~20 minutes on mainnet) it collects 31 bps equivalent while
    /// quoting benign flow ~4 bps, which is the whole point of the mechanism.
    ///
    /// The cost of a longer window is that a payer's bond stays locked for it, and
    /// FlowVault.withdrawCooldownBlocks must exceed it.
    uint40 public constant W = 100;

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
    mapping(PoolId => ReceiptBook.ReceiptLog) public receipts;
    mapping(PoolId => PriceAccumulator.ObservationHistory) public priceHistory;

    /// @notice Minimum notional required to write a receipt.
    /// @dev Prevents state bloat from receipt spam (A4 defence).
    uint256 public constant DUST_THRESHOLD = 10 * 10**6;

    /// @dev Transient slot carrying the payer, bonded flag, and tier resolved in beforeSwap into afterSwap.
    bytes32 private constant PAYER_SLOT = keccak256("postmark.transient.payer");

    /// @notice Address allowed to trip the emergency brake. Set once at deploy, never changeable.
    address public immutable guardian;

    /// @notice Once tripped, Postmark stops taking on new obligations: no new receipts, no new bond
    /// locks, everyone quoted the baseline fee. Settlement of existing receipts, bond withdrawals
    /// and every LP operation carry on untouched.
    ///
    /// @dev One-way by design (attack A5). A guardian who could switch it back off could use it to
    /// stall settlement while the price moved. The worst a compromised guardian can do here is turn
    /// Postmark into a plain 30 bps pool.
    bool public emergencyMode;

    error NotDynamicFee();
    error NotGuardian();

    event PoolRegistered(PoolId indexed poolId, Currency bondCurrency);
    event EmergencyModeEngaged();
    event FeeQuoted(PoolId indexed poolId, address indexed payer, uint8 tier, uint24 fee, bool bondCovered);

    constructor(IPoolManager _poolManager, IFlowVault _vault, IScoreRegistry _registry, address _guardian)
        BaseHook(_poolManager)
    {
        vault = _vault;
        registry = _registry;
        guardian = _guardian;
    }

    /// @notice Trip the emergency brake. Cannot be undone.
    function engageEmergencyMode() external {
        if (msg.sender != guardian) revert NotGuardian();
        emergencyMode = true;
        emit EmergencyModeEngaged();
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
        // In emergency mode nobody is treated as bonded, so nobody gets a discount and afterSwap
        // takes on no new obligation. The swap itself still goes through.
        bool bondCovered = !emergencyMode && vault.freeBalanceOf(payer, bondCurrency) >= requiredBond(notional);

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

        PoolId poolId = key.toId();
        uint256 notional = PostmarkMath.abs(int256(delta.amount1()));
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        // A receipt is only worth writing if it is above dust, backed by a bond, and small enough
        // to record exactly. Oversized notionals are skipped rather than truncated: a receipt that
        // misstates its own notional bills the wrong amount and releases the wrong bond.
        if (notional > DUST_THRESHOLD && bondCovered && notional <= ReceiptBook.MAX_NOTIONAL) {
            // Lock first. If the bond cannot actually be locked, no receipt is written, so there is
            // never an open receipt without collateral behind it.
            if (vault.lock(payer, poolConfig[poolId].bondCurrency, requiredBond(notional))) {
                ReceiptBook.write(receipts, poolId, payer, params.zeroForOne, tier, uint96(notional), tick);
            }
        }

        PriceAccumulator.push(priceHistory, poolId, tick);
    }

    /// @notice Read one receipt. The auto-generated getter cannot reach it because `ReceiptLog`
    /// holds a mapping, and the scoreboard needs it as much as the tests do.
    function getReceipt(PoolId poolId, uint256 id) external view returns (ReceiptBook.Receipt memory) {
        return receipts[poolId].receipts[id];
    }

    /// @notice Number of receipts ever written for a pool. Ids run [0, count).
    function receiptCount(PoolId poolId) external view returns (uint256) {
        return receipts[poolId].nextId;
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
        ReceiptBook.ReceiptLog storage buffer = receipts[poolId];
        ReceiptBook.Receipt memory receipt = buffer.receipts[id];
        require(receipt.payer != address(0), "Receipt empty or settled");
        require(block.number >= receipt.blockNumber + W, "TWAP window pending");

        // The bond released below must be derived from the same value that was locked at swap time,
        // or a residue stays locked forever and FlowVault.withdraw (which requires locked == 0)
        // strands the payer's entire balance.
        uint256 notional = receipt.notional;
        int256 markout;
        {
            bool zeroForOne_ = (receipt.flags & 1) == 1;

            // The reference price is the most adverse tick that PRINTED inside the window, not the
            // window's average. A mean can be un-done: a payer who traded ahead of a move can trade
            // back inside their own window, pull the average toward their execution price, and
            // settle for nothing. Because trading back is the move they wanted anyway, it costs them
            // nothing — measured on a three-world test, it dodged the entire charge for free.
            // An extremum cannot be un-done, which is the property this design claims.
            int24 tickRef = PriceAccumulator.extremeTickOver(
                priceHistory, poolId, receipt.blockNumber, receipt.blockNumber + W, zeroForOne_
            );

            uint160 sqrtPExec = TickMath.getSqrtPriceAtTick(receipt.tickAfter);
            uint160 sqrtPRef = TickMath.getSqrtPriceAtTick(tickRef);

            uint256 ratioX96;
            {
                uint256 R = FullMath.mulDiv(sqrtPRef, FixedPoint96.Q96, sqrtPExec);
                ratioX96 = FullMath.mulDiv(R, R, FixedPoint96.Q96);
            }

            int256 diffX96 = zeroForOne_
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

        vault.unlock(receipt.payer, poolConfig[poolId].bondCurrency, requiredBond(notional));
        delete buffer.receipts[id];
    }

    function _distributeCharge(PoolKey memory key, ReceiptBook.Receipt memory receipt, int256 markout, address keeper) private {
        PoolId poolId = key.toId();
        uint256 notional = receipt.notional;
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
