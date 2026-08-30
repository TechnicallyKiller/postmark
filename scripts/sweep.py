"""
Parameter sweep over cached flow. Answers one question: at what settings, if any, do Postmark LPs
beat a flat-fee pool on the same flow?

Markout is a property of the flow, not the pool, so it is identical in every scenario. LP PnL
differences therefore reduce to revenue differences, which is what this compares.

    python3 scripts/sweep.py
"""
import sys
import numpy as np
import pandas as pd

sys.path.insert(0, "scripts")
import backtest as bt

df = pd.read_csv("swaps_cache.csv").sort_values(["blockNumber", "logIndex"]).reset_index(drop=True)
df["price"] = (df["sqrtPriceX96"].astype(float) / (2 ** 96)) ** 2
df["zeroForOne"] = df["amount0"] > 0
df["notional"] = df["amount0"].abs() / 1e6
df = df[df["notional"] > 0.1].copy()
b0, b1 = int(df.blockNumber.min()), int(df.blockNumber.max())
NOTIONAL = df.notional.sum()

print(f"{len(df)} swaps, {NOTIONAL:,.0f} USDC notional, blocks {b0}..{b1}\n")


def run(W, alpha_bps, tier_fees):
    bt.W, bt.ALPHA_BPS, bt.TIER_FEE_BPS = W, alpha_bps, tier_fees
    out = bt.simulate(df, b0, b1)
    revenue = out["upfront_fee"].sum() + bt.LP_SHARE * out["pm_charge"].sum()
    dec = out.groupby(pd.qcut(out["markout_bps"], 10, labels=False, duplicates="drop"))["pm_effective_fee_bps"].mean()
    return revenue, out, dec


def flat(bps):
    return NOTIONAL * bps / 10_000


print("A flat pool's LP fee revenue on this same flow:")
for f in (5, 10, 30):
    print(f"   {f:>2} bps -> {flat(f):>10,.0f} USDC")

print("\n--- Postmark revenue by settlement window and alpha (tier fees 2/8/15/30) ---")
print(f"{'W':>5} {'alpha':>7} {'revenue':>12} {'= flat bps':>11} {'vs 30bps':>10} {'vs 5bps':>9}")
base = [2, 8, 15, 30]
for W in (5, 12, 25, 50, 100, 300):
    for a in (6000, 9000):
        rev, _, _ = run(W, a, base)
        eq = rev / NOTIONAL * 10_000
        print(f"{W:>5} {a/10000:>7.1f} {rev:>12,.0f} {eq:>10.2f} "
              f"{rev/flat(30):>9.2f}x {rev/flat(5):>8.2f}x")

print("\n--- Raising the tier table, W=100, alpha=0.6 ---")
print(f"{'tiers (bps)':>20} {'revenue':>12} {'= flat bps':>11} {'vs 30bps':>10}")
for tiers in ([2, 8, 15, 30], [5, 12, 22, 40], [10, 20, 30, 50], [15, 25, 35, 60]):
    rev, _, _ = run(100, 6000, tiers)
    print(f"{str(tiers):>20} {rev:>12,.0f} {rev/NOTIONAL*1e4:>10.2f} {rev/flat(30):>9.2f}x")

print("\n--- Does the staircase hold? W=100, alpha=0.6, tiers 2/8/15/30 ---")
rev, out, dec = run(100, 6000, base)
for i, v in dec.items():
    print(f"   D{int(i)+1:>2}  {v:>7.2f} bps")
diffs = dec.diff().dropna()
print(f"   monotone: {bool((diffs >= -1e-9).all())}   "
      f"benign {dec.iloc[0]:.2f} -> toxic {dec.iloc[-1]:.2f} bps")
