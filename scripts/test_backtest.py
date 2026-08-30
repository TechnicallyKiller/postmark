"""
Unit tests for the backtest simulation math.

Deliberately does NOT write any chart. The charts must only ever come from real mainnet flow;
a synthetic chart that leaked into the deck would be worse than no chart at all.

    python3 scripts/test_backtest.py
"""

import sys

import numpy as np
import pandas as pd

sys.path.insert(0, "scripts")
from backtest import (  # noqa: E402
    ALPHA_BPS, BASELINE_FEE_BPS, BONDED_ENTRY_TIER, DEFAULT_TIER, LP_SHARE,
    MAX_CHARGE_BPS, MIN_HISTORY, TIER_FEE_BPS, W, simulate, tier_of,
)

failures = []


def check(name, cond, detail=""):
    if cond:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        failures.append(name)


def test_tier_rules():
    print("\ntier_of mirrors ScoreRegistry")
    check("unbonded is always the baseline", tier_of(0.0, 100, bonded=False) == DEFAULT_TIER)
    check("no history enters at the bonded entry tier", tier_of(0.0, 0) == BONDED_ENTRY_TIER)
    check("history + clean score reaches tier 0", tier_of(0.0, MIN_HISTORY) == 0)
    check("mildly toxic lands in tier 1", tier_of(3.0, MIN_HISTORY) == 1)
    check("toxic lands in the entry tier", tier_of(15.0, MIN_HISTORY) == BONDED_ENTRY_TIER)
    check("very toxic falls to the baseline", tier_of(50.0, MIN_HISTORY) == DEFAULT_TIER)


def _frame(prices, zero_for_one, notional=1_000_000.0, first_block=100):
    """One swap per block at the given prices."""
    return pd.DataFrame({
        "blockNumber": np.arange(first_block, first_block + len(prices)),
        "logIndex": np.zeros(len(prices), dtype=int),
        "sender": ["0xpayer"] * len(prices),
        "price": np.array(prices, dtype=float),
        "zeroForOne": [zero_for_one] * len(prices),
        "notional": [notional] * len(prices),
    })


def test_markout_sign():
    print("\nmarkout signs match the contract")
    # oneForZero buying token0, price then rises -> the payer profited at the LPs' expense.
    df = _frame([1.0] + [1.02] * (W + 2), zero_for_one=False)
    out = simulate(df, 100, int(df["blockNumber"].max()))
    check("adverse oneForZero is positive markout", out["markout"].iloc[0] > 0,
          f"got {out['markout'].iloc[0]:.4f}")

    # Same move, but the payer was selling token0 - they sold too cheap, so benign.
    # Under extremum billing a seller is priced against the window's LOW. Here the low IS their own
    # execution price (the market only went up), so the billing markout is exactly zero rather than
    # negative. Not charged, which is the property that matters.
    df = _frame([1.0] + [1.02] * (W + 2), zero_for_one=True)
    out = simulate(df, 100, int(df["blockNumber"].max()))
    check("same move for a seller is not charged", out["markout"].iloc[0] <= 0,
          f"got {out['markout'].iloc[0]:.4f}")
    check("  and the accounting markout is genuinely negative", out["true_markout"].iloc[0] < 0,
          f"got {out['true_markout'].iloc[0]:.4f}")


def test_charge_is_alpha_and_capped():
    print("\ncharge = alpha x markout, capped")
    notional = 1_000_000.0
    # A 0.5% adverse move: markout 50 bps, alpha 0.6 -> 30 bps, under the 100 bps cap.
    df = _frame([1.0] + [1.005] * (W + 2), zero_for_one=False, notional=notional)
    out = simulate(df, 100, int(df["blockNumber"].max()))
    row = out.iloc[0]
    expected = row["markout"] * ALPHA_BPS / 10_000
    check("charge is alpha x markout below the cap", abs(row["pm_charge"] - expected) < 1e-6,
          f"{row['pm_charge']:.4f} vs {expected:.4f}")
    check("charge is strictly less than the markout", row["pm_charge"] < row["markout"])

    # A 10% move would be 600 bps of charge before the cap.
    df = _frame([1.0] + [1.10] * (W + 2), zero_for_one=False, notional=notional)
    out = simulate(df, 100, int(df["blockNumber"].max()))
    cap = notional * MAX_CHARGE_BPS / 10_000
    check("cap binds on an extreme move", abs(out["pm_charge"].iloc[0] - cap) < 1e-6,
          f"{out['pm_charge'].iloc[0]:.2f} vs cap {cap:.2f}")


def test_benign_flow_is_never_charged():
    print("\nbenign flow")
    df = _frame([1.0] + [0.98] * (W + 2), zero_for_one=False)
    out = simulate(df, 100, int(df["blockNumber"].max()))
    check("a benign trade incurs no ex-post charge", out["pm_charge"].iloc[0] == 0.0)
    check("but still pays the fee quoted up front",
          out["pm_effective_fee_bps"].iloc[0] == TIER_FEE_BPS[BONDED_ENTRY_TIER],
          f"got {out['pm_effective_fee_bps'].iloc[0]}")


def test_effective_fee_includes_upfront():
    print("\neffective fee is all-in")
    df = _frame([1.0] + [1.005] * (W + 2), zero_for_one=False)
    out = simulate(df, 100, int(df["blockNumber"].max()))
    row = out.iloc[0]
    both = (row["upfront_fee"] + row["pm_charge"]) / row["notional"] * 10_000
    check("effective fee = upfront + ex-post", abs(row["pm_effective_fee_bps"] - both) < 1e-9)
    check("effective fee exceeds the upfront leg alone",
          row["pm_effective_fee_bps"] > row["upfront_fee_bps"])
    # The bug this guards: an effective fee built from the charge alone would show benign flow at
    # 0 bps rather than the 2 bps floor the mechanism actually quotes.
    check("benign flow floors at the tier fee, not zero",
          out["pm_effective_fee_bps"].min() >= min(TIER_FEE_BPS))


def test_reputation_declines_for_benign_flow():
    print("\nreputation")
    # A long run of benign swaps must walk the payer down the tiers.
    prices = [1.0, 0.999] * 20
    df = _frame(prices, zero_for_one=False)
    out = simulate(df, 100, int(df["blockNumber"].max()))
    check("tier improves over a benign run", out["tier"].iloc[-1] < out["tier"].iloc[0],
          f"{out['tier'].iloc[0]} -> {out['tier'].iloc[-1]}")
    check("first swap enters at the entry tier", out["tier"].iloc[0] == BONDED_ENTRY_TIER)


def test_lp_pnl_accounting():
    print("\nLP PnL accounting")
    df = _frame([1.0] + [1.005] * (W + 2), zero_for_one=False)
    out = simulate(df, 100, int(df["blockNumber"].max()))
    row = out.iloc[0]
    # PnL is booked against true_markout - the adverse selection that actually happened - not
    # against the extremum used for billing. Booking the extremum as the LP's loss would overstate
    # the damage in both pools.
    expected = row["upfront_fee"] + LP_SHARE * row["pm_charge"] - row["true_markout"]
    check("LP keeps the upfront fee plus its share of the charge",
          abs(row["pm_pnl"] - expected) < 1e-9)
    check("LP share nets out keeper and rebate", abs(LP_SHARE - 0.80) < 1e-12)
    check("vanilla PnL is the flat fee minus the true markout",
          abs(row["vanilla_pnl"] - (row["notional"] * BASELINE_FEE_BPS / 10_000 - row["true_markout"])) < 1e-9)
    check("billing markout is at least the accounting markout",
          row["markout"] >= row["true_markout"] - 1e-9,
          "the extremum must never be less adverse than the mean")


if __name__ == "__main__":
    test_tier_rules()
    test_markout_sign()
    test_charge_is_alpha_and_capped()
    test_benign_flow_is_never_charged()
    test_effective_fee_includes_upfront()
    test_reputation_declines_for_benign_flow()
    test_lp_pnl_accounting()

    print()
    if failures:
        print(f"{len(failures)} FAILED: {', '.join(failures)}")
        sys.exit(1)
    print("all backtest math checks passed")
