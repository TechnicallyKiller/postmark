// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Per-payer realized-markout reputation, shared across every Postmark pool.
interface IScoreRegistry {
    event ScoreUpdated(address indexed payer, int256 score, uint32 settledCount);

    /// @notice Toxicity tier for a payer. 0 is the cheapest, TIER_COUNT-1 is the unknown default.
    /// @dev `bonded` is passed in by the hook because bonding is what makes a discount safe to give.
    function tierOf(address payer, bool bonded) external view returns (uint8);

    /// @notice EWMA of realized markout, in bps of notional. Positive means adversely selecting LPs.
    function scoreOf(address payer) external view returns (int256);

    function settledCountOf(address payer) external view returns (uint32);

    /// @dev Hook-only. Folds one settled receipt's normalized markout (bps) into the EWMA.
    function update(address payer, int256 markoutBps) external;
}
