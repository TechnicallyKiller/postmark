// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title ReceiptBook
/// @notice Append-only log of open receipts per pool, written for swaps above the dust threshold.
///
/// @dev The notional is stored **exactly**, in `uint96`, not as a scaled multiple of the dust
/// threshold. An earlier version stored `uint32(notional / DUST_THRESHOLD)`, which silently wrapped
/// for any swap above ~0.043 tokens at 18 decimals and made every downstream number — the charge,
/// the score, and the bond released at settlement — wrong. Notional is the quantity the entire
/// mechanism bills on, so it does not get compressed.
///
/// `uint96` holds 7.9e28, or 79 billion tokens at 18 decimals. Anything larger is refused at the
/// call site rather than truncated.
library ReceiptBook {
    /// @notice Largest notional a receipt can represent.
    uint256 internal constant MAX_NOTIONAL = type(uint96).max;

    struct Receipt {
        address payer; // 160 bits ┐
        uint96 notional; //  96 bits ┘ slot 0, exactly full
        uint32 blockNumber; //  32 bits ┐
        int24 tickAfter; //  24 bits │ slot 1
        uint8 flags; //   8 bits ┘ bit 0: zeroForOne, bits 1-2: tier
    }

    /// @dev Append-only. Ids are never reused and `nextId` never wraps, so a settled receipt is
    /// deleted in place and its id stays retired. This is deliberately not a ring buffer: reusing
    /// ids would let a fresh swap land on the slot of a receipt that is still open.
    struct ReceiptLog {
        uint128 nextId;
        mapping(uint256 => Receipt) receipts;
    }

    function write(
        mapping(PoolId => ReceiptLog) storage logs,
        PoolId poolId,
        address payer,
        bool zeroForOne,
        uint8 tier,
        uint96 notional,
        int24 tickAfter
    ) internal returns (uint256 id) {
        ReceiptLog storage log = logs[poolId];
        id = log.nextId++;
        log.receipts[id] = Receipt({
            payer: payer,
            notional: notional,
            blockNumber: uint32(block.number),
            tickAfter: tickAfter,
            flags: (tier << 1) | (zeroForOne ? 1 : 0)
        });
    }

    /// @notice Total receipts ever written for a pool. Ids run [0, count).
    function count(mapping(PoolId => ReceiptLog) storage logs, PoolId poolId) internal view returns (uint256) {
        return logs[poolId].nextId;
    }
}
