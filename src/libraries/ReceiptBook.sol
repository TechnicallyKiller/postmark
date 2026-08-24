// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title ReceiptBook
/// @notice Stores packed receipts of swaps above the dust threshold for post-swap settlement.
/// Designed explicitly to fit into exactly 2 storage slots to keep afterSwap overhead < 40k gas.
library ReceiptBook {
    struct Receipt {
        address payer;         // 160 bits
        uint32 blockNumber;    // 32 bits
        int24 tickAfter;       // 24 bits
        uint32 notionalScaled; // 32 bits (notional / DUST_THRESHOLD)
        uint8 flags;           // 8 bits (bit 0: zeroForOne, bit 1-2: tier)
    } // Exactly 256 bits (1 storage slot)

    struct RingBuffer {
        uint128 head;
        uint128 tail;
        mapping(uint256 => Receipt) receipts;
    }

    function write(
        mapping(PoolId => RingBuffer) storage buffers,
        PoolId poolId,
        address payer,
        bool zeroForOne,
        uint8 tier,
        uint32 notionalScaled,
        int24 tickAfter
    ) internal {
        RingBuffer storage buffer = buffers[poolId];
        uint256 id = buffer.tail++;
        buffer.receipts[id] = Receipt({
            payer: payer,
            blockNumber: uint32(block.number),
            tickAfter: tickAfter,
            notionalScaled: notionalScaled,
            flags: (tier << 1) | (zeroForOne ? 1 : 0)
        });
    }

    function length(mapping(PoolId => RingBuffer) storage buffers, PoolId poolId) internal view returns (uint256) {
        RingBuffer storage buffer = buffers[poolId];
        return buffer.tail - buffer.head;
    }
}
