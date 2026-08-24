// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IScoreRegistry} from "./interfaces/IScoreRegistry.sol";

/// @title ScoreRegistry
/// @notice Per-payer realized-markout reputation, shared across every pool that uses Postmark.
///
/// @dev The whole table only ever *lowers* a payer's fee. A fresh address starts unknown and pays
/// the top tier, which is the vanilla baseline, so there is nothing to gain by rotating addresses
/// and no blacklist to escape (attack A2). Reputation is earned by settling receipts that turn out
/// benign, not asserted.
contract ScoreRegistry is IScoreRegistry {
    /// @notice Tiers, cheapest first. Tier 3 is unknown/unbonded.
    uint8 public constant TIER_COUNT = 4;
    uint8 public constant DEFAULT_TIER = 3;

    /// @notice A bonded payer with no settled history enters here rather than at the cheapest tier.
    /// The discount is collateralised: whatever markout they turn out to cause is billed back from
    /// the bond. Only settled benign flow moves them below this.
    uint8 public constant BONDED_ENTRY_TIER = 2;

    /// @notice Settled receipts required before a payer can be promoted past the entry tier.
    uint32 public constant MIN_HISTORY = 5;

    /// @notice EWMA retention, in bps. 9000 == lambda 0.9.
    uint256 public constant LAMBDA_BPS = 9000;
    uint256 private constant BPS = 10_000;

    /// @dev Score is an EWMA of realized markout expressed in bps of notional, scaled by 1e18.
    /// Positive means the payer has been adversely selecting LPs.
    int256 private constant WAD = 1e18;

    /// @notice Upper score bound for each tier, in WAD-scaled bps. A payer sits in the first tier
    /// whose bound their score does not exceed.
    int256 public constant TIER0_MAX = 1 * WAD; // <= 1 bps of realized markout
    int256 public constant TIER1_MAX = 5 * WAD;
    int256 public constant TIER2_MAX = 20 * WAD;

    address public immutable owner;

    mapping(address => bool) public isAuthorizedHook;
    mapping(address payer => int256) private _score;
    mapping(address payer => uint32) private _settledCount;

    error NotOwner();
    error NotAuthorized();

    event HookAuthorized(address indexed hook, bool authorized);

    constructor() {
        owner = msg.sender;
    }

    /// @dev The registry is shared, so it needs an add/remove list rather than a single immutable
    /// hook. It holds no funds and can only lower fees, so the blast radius of a bad entry is a
    /// mispriced fee on that hook's own pools, never a loss of principal.
    function setAuthorizedHook(address hook, bool authorized) external {
        if (msg.sender != owner) revert NotOwner();
        isAuthorizedHook[hook] = authorized;
        emit HookAuthorized(hook, authorized);
    }

    function scoreOf(address payer) external view returns (int256) {
        return _score[payer];
    }

    function settledCountOf(address payer) external view returns (uint32) {
        return _settledCount[payer];
    }

    function tierOf(address payer, bool bonded) external view returns (uint8) {
        if (!bonded) return DEFAULT_TIER;
        if (_settledCount[payer] < MIN_HISTORY) return BONDED_ENTRY_TIER;

        int256 s = _score[payer];
        if (s <= TIER0_MAX) return 0;
        if (s <= TIER1_MAX) return 1;
        if (s <= TIER2_MAX) return BONDED_ENTRY_TIER;
        return DEFAULT_TIER;
    }

    /// @notice Fold one settled receipt's normalized markout into the payer's EWMA.
    /// @param markoutBps Realized markout as bps of notional, signed. Positive is toxic.
    function update(address payer, int256 markoutBps) external {
        if (!isAuthorizedHook[msg.sender]) revert NotAuthorized();

        int256 sample = markoutBps * WAD;
        int256 prior = _score[payer];
        // score = lambda * prior + (1 - lambda) * sample
        int256 next =
            (prior * int256(LAMBDA_BPS) + sample * int256(BPS - LAMBDA_BPS)) / int256(BPS);

        _score[payer] = next;
        uint32 count = _settledCount[payer] + 1;
        _settledCount[payer] = count;

        emit ScoreUpdated(payer, next, count);
    }
}
