// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title PriceAccumulator
/// @notice Cumulative tick observations per pool, used to compute the settlement TWAP.
///
/// @dev Accumulation follows Uniswap's oracle convention: when a new observation is written, the
/// interval that just elapsed is credited with the tick that *prevailed during it* — the previous
/// observation's tick — not the new post-swap tick.
///
/// This direction matters for the TWAP-manipulation defence. Crediting the new tick backwards over
/// the elapsed interval would retroactively apply a manipulator's final price to the window they
/// were trying to distort, which is precisely the direction the defence has to resist.
library PriceAccumulator {
    struct Observation {
        uint40 blockNumber; //  40 bits ┐
        int24 tick; //  24 bits │ slot 0, 256 bits exactly
        int192 cumulativeTick; // 192 bits ┘
    }

    /// @notice Fixed-size ring. Observations are the swap hot path, so slots are reused: writing a
    /// slot that already holds a value costs ~5k, while a fresh slot costs 22.1k. `CARDINALITY`
    /// only has to cover the settlement window, which is a handful of blocks.
    uint256 internal constant CARDINALITY = 128;

    struct ObservationHistory {
        uint128 count; // total pushes ever; index is count % CARDINALITY
        mapping(uint256 => Observation) observations;
    }

    error NoObservations();
    error InvalidWindow();

    /// @notice Record the pool's tick at the current block.
    /// @dev At most one observation per block; a second call in the same block is a no-op, so the
    /// first price seen in a block is the one that anchors the next interval.
    function push(mapping(PoolId => ObservationHistory) storage histories, PoolId poolId, int24 tick) internal {
        ObservationHistory storage history = histories[poolId];
        uint256 total = history.count;

        if (total == 0) {
            history.observations[0] =
                Observation({blockNumber: uint40(block.number), tick: tick, cumulativeTick: 0});
            history.count = 1;
            return;
        }

        Observation memory prev = history.observations[(total - 1) % CARDINALITY];
        if (prev.blockNumber == uint40(block.number)) return;

        // An observation at the same tick carries no information: `_cumulativeAt` extrapolates
        // forward from the newest observation at its own tick, so the unchanged stretch is credited
        // correctly whenever the next real move is written. Skipping saves a full cold SSTORE
        // (~22.1k) on every swap that does not move the tick.
        if (prev.tick == tick) return;

        // The elapsed interval was spent at `prev.tick`, not at the tick we are now recording.
        int256 elapsed = int256(uint256(uint40(block.number) - prev.blockNumber));
        int192 cumulative = prev.cumulativeTick + int192(int256(prev.tick) * elapsed);

        history.observations[total % CARDINALITY] =
            Observation({blockNumber: uint40(block.number), tick: tick, cumulativeTick: cumulative});
        history.count = uint128(total + 1);
    }

    /// @notice The most adverse-to-the-payer tick printed in [startBlock, endBlock].
    ///
    /// @dev This, not the mean, is what settlement prices against. A mean can be un-done: a payer
    /// who traded ahead of a move can trade back inside their own window, pull the average toward
    /// their execution price, and settle for nothing — and because trading back is the
    /// economically natural move for them anyway, it costs them nothing to do it. Measured on a
    /// three-world test, that dodged 100% of the charge at zero cost.
    ///
    /// An extremum cannot be un-done. Once the price has printed a low, no later trade removes it.
    /// That is the property the whole design rests on: you cannot un-happen a price.
    ///
    /// @param wantMin true for a zeroForOne receipt (the payer sold token0, so a LOW reference
    /// price is the adverse one), false for oneForZero.
    function extremeTickOver(
        mapping(PoolId => ObservationHistory) storage histories,
        PoolId poolId,
        uint40 startBlock,
        uint40 endBlock,
        bool wantMin
    ) internal view returns (int24) {
        ObservationHistory storage history = histories[poolId];
        if (history.count == 0) revert NoObservations();
        if (endBlock <= startBlock) revert InvalidWindow();

        uint256 total = history.count;
        uint256 live = total < CARDINALITY ? total : CARDINALITY;
        uint256 oldestPos = total - live;

        // Start from the tick that was already in effect when the window opened.
        uint256 pos = _positionAt(history, startBlock);
        int24 best = history.observations[(oldestPos + pos) % CARDINALITY].tick;

        // Then walk forward over every price that printed inside the window.
        for (uint256 i = pos + 1; i < live; ++i) {
            Observation memory o = history.observations[(oldestPos + i) % CARDINALITY];
            if (o.blockNumber > endBlock) break;
            if (wantMin ? o.tick < best : o.tick > best) best = o.tick;
        }
        return best;
    }

    /// @notice Time-weighted average tick over [startBlock, endBlock].
    /// @dev Retained for comparison and analysis. Settlement uses `extremeTickOver` — see the note
    /// there for why a mean is not safe to bill against.
    function twapOver(
        mapping(PoolId => ObservationHistory) storage histories,
        PoolId poolId,
        uint40 startBlock,
        uint40 endBlock
    ) internal view returns (int24) {
        ObservationHistory storage history = histories[poolId];
        if (history.count == 0) revert NoObservations();
        if (endBlock <= startBlock) revert InvalidWindow();

        int192 cumStart = _cumulativeAt(history, startBlock);
        int192 cumEnd = _cumulativeAt(history, endBlock);

        int256 span = int256(uint256(endBlock - startBlock));
        return int24((int256(cumEnd) - int256(cumStart)) / span);
    }

    /// @dev Cumulative tick at an arbitrary block, interpolating from the observation in effect.
    /// @dev Logical index of the newest observation at or before `targetBlock`, clamped to the
    /// oldest surviving one. Searches over logical positions [0, live) and maps each to its ring
    /// slot, so the search still sees ascending block order after the ring has wrapped.
    function _positionAt(ObservationHistory storage history, uint40 targetBlock)
        private
        view
        returns (uint256)
    {
        uint256 total = history.count;
        uint256 live = total < CARDINALITY ? total : CARDINALITY;
        uint256 oldestPos = total - live;
        uint256 high = live - 1;

        if (history.observations[(oldestPos + high) % CARDINALITY].blockNumber <= targetBlock) return high;
        if (history.observations[oldestPos % CARDINALITY].blockNumber >= targetBlock) return 0;

        uint256 low = 0;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (history.observations[(oldestPos + mid) % CARDINALITY].blockNumber <= targetBlock) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return low;
    }

    function _cumulativeAt(ObservationHistory storage history, uint40 targetBlock)
        private
        view
        returns (int192)
    {
        uint256 total = history.count;
        uint256 live = total < CARDINALITY ? total : CARDINALITY;
        uint256 oldestPos = total - live;
        uint256 high = live - 1;

        // After the newest observation: extrapolate forward at the tick still in effect.
        Observation memory newest = history.observations[(oldestPos + high) % CARDINALITY];
        if (newest.blockNumber <= targetBlock) {
            int256 elapsed = int256(uint256(targetBlock - newest.blockNumber));
            return newest.cumulativeTick + int192(int256(newest.tick) * elapsed);
        }

        // Before the oldest surviving observation there is no price history to speak for. An earlier
        // implementation extrapolated backwards, inventing a price the chain never witnessed.
        Observation memory oldest = history.observations[oldestPos % CARDINALITY];
        if (oldest.blockNumber >= targetBlock) return oldest.cumulativeTick;

        uint256 pos = _positionAt(history, targetBlock);
        Observation memory obs = history.observations[(oldestPos + pos) % CARDINALITY];
        int256 delta = int256(uint256(targetBlock - obs.blockNumber));
        return obs.cumulativeTick + int192(int256(obs.tick) * delta);
    }
}
