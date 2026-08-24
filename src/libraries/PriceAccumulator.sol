// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title PriceAccumulator
/// @notice Tracks cumulative tick observations per pool to compute TWAP reference prices
/// for settlement. Simple append-only architecture for Day 3 scaffolding.
library PriceAccumulator {
    struct Observation {
        uint40 blockNumber;
        int216 cumulativeTick;
        int24 tick; // spot tick at this block
    }

    struct ObservationHistory {
        uint128 count;
        mapping(uint256 => Observation) observations;
    }

    /// @notice Pushes a tick observation to the pool's history.
    function push(
        mapping(PoolId => ObservationHistory) storage histories,
        PoolId poolId,
        int24 tick
    ) internal {
        ObservationHistory storage history = histories[poolId];
        uint256 id = history.count;
        if (id > 0) {
            Observation memory prev = history.observations[id - 1];
            if (prev.blockNumber == uint40(block.number)) return;
            
            int256 delta = int256(uint256(uint40(block.number) - prev.blockNumber));
            int216 newCumTick = prev.cumulativeTick + int216(int256(tick) * delta);
            history.observations[id] = Observation({
                blockNumber: uint40(block.number),
                cumulativeTick: newCumTick,
                tick: tick
            });
        } else {
            history.observations[id] = Observation({
                blockNumber: uint40(block.number),
                cumulativeTick: 0,
                tick: tick
            });
        }
        history.count = uint128(id + 1);
    }

    /// @notice Computes TWAP from startBlock to endBlock
    function twapOver(
        mapping(PoolId => ObservationHistory) storage histories,
        PoolId poolId,
        uint40 startBlock,
        uint40 endBlock
    ) internal view returns (int24) {
        ObservationHistory storage history = histories[poolId];
        require(history.count > 0, "No observations");
        require(endBlock > startBlock, "Invalid window");

        int216 cumStart = _getCumulativeTickAt(history, startBlock);
        int216 cumEnd = _getCumulativeTickAt(history, endBlock);

        int256 deltaBlocks = int256(uint256(endBlock - startBlock));
        return int24(int256(cumEnd - cumStart) / deltaBlocks);
    }

    function _getCumulativeTickAt(ObservationHistory storage history, uint40 targetBlock) private view returns (int216) {
        uint256 count = history.count;
        uint256 low = 0;
        uint256 high = count - 1;

        if (history.observations[high].blockNumber <= targetBlock) {
            Observation memory last = history.observations[high];
            int256 delta = int256(uint256(targetBlock - last.blockNumber));
            return last.cumulativeTick + int216(int256(last.tick) * delta);
        }
        if (history.observations[0].blockNumber >= targetBlock) {
            Observation memory first = history.observations[0];
            int256 delta = int256(uint256(first.blockNumber - targetBlock));
            return first.cumulativeTick - int216(int256(first.tick) * delta);
        }

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (history.observations[mid].blockNumber <= targetBlock) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        Observation memory obs = history.observations[low];
        int256 deltaMid = int256(uint256(targetBlock - obs.blockNumber));
        return obs.cumulativeTick + int216(int256(obs.tick) * deltaMid);
    }
}
