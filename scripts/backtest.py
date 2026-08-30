"""
Postmark backtest harness.

Replays real Uniswap v3 USDC/WETH mainnet flow through both a vanilla 30 bps pool and a simulated
Postmark pool, and produces the two charts:

  Chart 1  effective fee by flow-toxicity decile, against the flat 30 bps line
  Chart 2  cumulative LP PnL, Postmark vs vanilla, with bootstrap confidence bands over days

The simulation mirrors the contract's constants and reputation rules exactly (see the CONTRACT
PARAMETERS block). Every swap's payer is the `sender` on the Swap event, which is the same
attribution the hook uses in v1 - the router, not the end user - so the tiers here evolve the way
they would on chain rather than under an idealised per-trader assumption.

Requires an ARCHIVE RPC. Public endpoints serve only head-adjacent blocks and will fail.
    export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<key>"
    python3 scripts/backtest.py

Fetched events are cached to swaps_cache.csv, so re-runs and chart tweaks cost no RPC calls.
    python3 scripts/backtest.py --cached
"""

import os
import re
import sys
import time
import warnings

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import requests
from tqdm import tqdm

warnings.filterwarnings("ignore")

# --- CONTRACT PARAMETERS -- these must track src/PostmarkHook.sol ------------------------------
W = 100                     # settlement window, blocks (~20 min on mainnet)
ALPHA_BPS = 6000            # LVR recapture rate, 0.6
MAX_CHARGE_BPS = 100        # hard cap per receipt, 1% of notional
TIER_FEE_BPS = [2, 8, 15, 30]   # pips/100: 200, 800, 1500, 3000 pips
BONDED_ENTRY_TIER = 2
DEFAULT_TIER = 3
MIN_HISTORY = 5
LAMBDA_BPS = 9000           # EWMA retention, 0.9
TIER0_MAX, TIER1_MAX, TIER2_MAX = 1.0, 5.0, 20.0   # score bounds, bps of markout
KEEPER_BPS = 500
REBATE_SHARE_BPS = 1500
LP_SHARE = 1 - (KEEPER_BPS + REBATE_SHARE_BPS) / 10_000   # 0.80

BASELINE_FEE_BPS = 30.0

# --- CONFIG -------------------------------------------------------------------------------------
RPC_URL = os.getenv("ETH_RPC_URL", "")
POOL_ADDRESS = "0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8"  # mainnet USDC/WETH 0.3%
LOOKBACK_BLOCKS = int(os.getenv("LOOKBACK_BLOCKS", "10000"))
# Providers cap the eth_getLogs block range and the caps differ wildly by plan - Alchemy's free
# tier allows 10 blocks, paid tiers allow thousands. Start optimistic and shrink on refusal.
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "500"))
CACHE_FILE = "swaps_cache.csv"
BLOCKS_PER_DAY = 7200

SWAP_TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"


def rpc(method, params):
    resp = requests.post(
        RPC_URL.strip(),
        json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
        headers={"Content-Type": "application/json"},
        timeout=30,
    )
    body = resp.json()
    if "error" in body:
        raise RuntimeError(f"{resp.status_code} {body['error']}")
    return body["result"]


def _twos(hexword):
    """32-byte hex word -> signed int."""
    v = int(hexword, 16)
    return v - (1 << 256) if v >= (1 << 255) else v


def parse_log(log):
    data = log["data"][2:]
    words = [data[i:i + 64] for i in range(0, len(data), 64)]
    return {
        "blockNumber": int(log["blockNumber"], 16),
        "logIndex": int(log["logIndex"], 16),
        # topics[1] is the sender - the router or contract that called swap. This is exactly what
        # PostmarkHook resolves as the payer when no hookData attestation is supplied.
        "sender": "0x" + log["topics"][1][-40:],
        "amount0": _twos(words[0]),
        "amount1": _twos(words[1]),
        "sqrtPriceX96": int(words[2], 16),
        "tick": _twos(words[4]) if len(words) > 4 else 0,
    }


RANGE_HINT = re.compile(r"up to a (\d+) block range")


def _range_limit_from(err):
    """Providers refuse oversized eth_getLogs ranges with wildly different wording. Pull the
    allowed range out of the message when they state it, otherwise just signal 'too big'."""
    text = str(err).lower()
    if "block range" not in text and "range is too large" not in text and "query returned more than" not in text:
        return None
    m = RANGE_HINT.search(text)
    return int(m.group(1)) if m else 0


def fetch_events(start_block, end_block):
    """Fetch Swap logs, adapting the batch size down to whatever the provider actually allows."""
    batch = BATCH_SIZE
    rows, failures = [], 0
    lo = start_block
    total = end_block - start_block + 1

    bar = tqdm(total=total, unit="blk", desc="Fetching swaps")
    while lo <= end_block:
        hi = min(lo + batch - 1, end_block)
        try:
            logs = rpc("eth_getLogs", [{
                "address": POOL_ADDRESS,
                "fromBlock": hex(lo),
                "toBlock": hex(hi),
                "topics": [SWAP_TOPIC],
            }])
        except Exception as exc:
            limit = _range_limit_from(exc)
            if limit is not None and batch > 1:
                # Shrink and retry the SAME range - do not advance, or we would silently skip blocks.
                new_batch = max(1, limit if limit else batch // 4)
                if new_batch < batch:
                    tqdm.write(f"  provider caps the range at {new_batch} blocks; adjusting batch {batch} -> {new_batch}")
                    batch = new_batch
                    continue
            if "429" in str(exc) or "rate" in str(exc).lower():
                time.sleep(2.0)
                continue
            failures += 1
            if failures <= 3:
                tqdm.write(f"  chunk {lo}-{hi} failed: {exc}")
            elif failures == 4:
                tqdm.write("  (further chunk failures suppressed)")
            bar.update(hi - lo + 1)
            lo = hi + 1
            continue

        rows.extend(parse_log(l) for l in logs)
        bar.update(hi - lo + 1)
        bar.set_postfix(swaps=len(rows), batch=batch)
        lo = hi + 1
    bar.close()

    if failures:
        print(f"{failures} chunk(s) failed and were skipped.")
    return rows, failures


def tier_of(score, settled, bonded=True):
    """Mirrors ScoreRegistry.tierOf."""
    if not bonded:
        return DEFAULT_TIER
    if settled < MIN_HISTORY:
        return BONDED_ENTRY_TIER
    if score <= TIER0_MAX:
        return 0
    if score <= TIER1_MAX:
        return 1
    if score <= TIER2_MAX:
        return BONDED_ENTRY_TIER
    return DEFAULT_TIER


def simulate(df, start_block, end_block):
    """Replay the flow through Postmark's fee quoting, settlement and reputation update."""
    # Per-block price series, forward filled across blocks with no swaps.
    blocks = pd.DataFrame({"blockNumber": np.arange(start_block, end_block + 1)})
    last_price = df.drop_duplicates("blockNumber", keep="last")[["blockNumber", "price"]]
    series = pd.merge(blocks, last_price, on="blockNumber", how="left")
    series["price"] = series["price"].ffill().bfill()
    series.set_index("blockNumber", inplace=True)

    lam = LAMBDA_BPS / 10_000
    scores, settled = {}, {}
    upfront_bps, charges, markouts, tiers = [], [], [], []

    for _, row in tqdm(df.iterrows(), total=len(df), desc="Replaying swaps"):
        payer = row["sender"]
        score = scores.get(payer, 0.0)
        count = settled.get(payer, 0)

        # 1. beforeSwap: quote from the payer's reputation as it stands right now.
        tier = tier_of(score, count)
        fee_bps = TIER_FEE_BPS[tier]

        # 2. settle: markout against the W-block TWAP of the pool's own price path.
        b = int(row["blockNumber"])
        window_end = min(b + W, end_block)
        p_ref = series.loc[b:window_end, "price"].mean()
        ratio = p_ref / row["price"]
        # zeroForOne sells token0: a higher reference price means they sold too cheap, so benign.
        diff = (1 - ratio) if row["zeroForOne"] else (ratio - 1)
        markout = diff * row["notional"]

        charge = max(0.0, markout) * (ALPHA_BPS / 10_000)
        charge = min(charge, row["notional"] * MAX_CHARGE_BPS / 10_000)

        # 3. ScoreRegistry.update with the normalised markout, in bps of notional.
        sample_bps = (markout / row["notional"]) * 10_000
        scores[payer] = lam * score + (1 - lam) * sample_bps
        settled[payer] = count + 1

        upfront_bps.append(fee_bps)
        charges.append(charge)
        markouts.append(markout)
        tiers.append(tier)

    df = df.copy()
    df["tier"] = tiers
    df["upfront_fee_bps"] = upfront_bps
    df["upfront_fee"] = df["notional"] * df["upfront_fee_bps"] / 10_000
    df["markout"] = markouts
    df["markout_bps"] = (df["markout"] / df["notional"]) * 10_000
    df["pm_charge"] = charges

    # What the payer actually paid, all in: the fee quoted up front plus the ex-post charge. The
    # upfront leg is not optional - leaving it out would show benign flow paying 0 bps instead of 2.
    df["pm_effective_fee_bps"] = ((df["upfront_fee"] + df["pm_charge"]) / df["notional"]) * 10_000
    df["vanilla_fee"] = (BASELINE_FEE_BPS / 10_000) * df["notional"]

    # LPs keep the whole upfront fee plus their share of the charge, and eat the markout either way.
    df["pm_pnl"] = df["upfront_fee"] + LP_SHARE * df["pm_charge"] - df["markout"]
    df["vanilla_pnl"] = df["vanilla_fee"] - df["markout"]
    return df


def chart_effective_fee(df):
    df["decile"] = pd.qcut(df["markout_bps"], 10, labels=False, duplicates="drop")
    summary = df.groupby("decile")["pm_effective_fee_bps"].mean()

    fig, ax = plt.subplots(figsize=(10, 6))
    x = np.arange(len(summary))
    ax.bar(x, summary.values, color="#8b5cf6", alpha=0.9, label="Postmark, all-in effective fee")
    ax.axhline(BASELINE_FEE_BPS, color="#ef4444", linestyle="--", linewidth=2.5,
               label=f"Vanilla pool ({BASELINE_FEE_BPS:.0f} bps)")
    ax.set_title("Effective fee by flow toxicity decile (live mainnet USDC/WETH)", fontsize=14, pad=15)
    ax.set_xlabel("Flow toxicity decile (0 = most benign, 9 = most toxic)", fontsize=12)
    ax.set_ylabel("Effective fee (bps)", fontsize=12)
    ax.set_xticks(x, [f"D{i + 1}" for i in x])
    ax.legend(loc="upper left", fontsize=11)
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig("chart_effective_fee.png", dpi=200, bbox_inches="tight")
    print("  -> chart_effective_fee.png")
    return summary


def chart_lp_pnl(df, n_boot=1000):
    # Bootstrap over DAYS, not over individual swaps: swaps within a day are not independent, and
    # resampling them individually would understate the true confidence interval.
    df = df.copy()
    df["day"] = (df["blockNumber"] - df["blockNumber"].min()) // BLOCKS_PER_DAY
    days = df["day"].unique()

    if len(days) < 2:
        print("  ! only one day of data; confidence bands would be meaningless. Skipping Chart 2.")
        print("    Increase LOOKBACK_BLOCKS (7200 blocks ~ 1 day) for a real interval.")
        return None

    by_day = {d: g for d, g in df.groupby("day")}
    n_days = len(days)
    v_totals, p_totals = [], []
    for _ in tqdm(range(n_boot), desc="Bootstrapping over days"):
        picked = np.random.choice(days, size=n_days, replace=True)
        v_totals.append(np.concatenate([by_day[d]["vanilla_pnl"].values for d in picked]).cumsum())
        p_totals.append(np.concatenate([by_day[d]["pm_pnl"].values for d in picked]).cumsum())

    n = min(min(len(p) for p in v_totals), min(len(p) for p in p_totals))
    v = np.array([p[:n] for p in v_totals])
    p = np.array([q[:n] for q in p_totals])

    fig, ax = plt.subplots(figsize=(10, 6))
    x = np.arange(n)
    ax.plot(x, p.mean(0), color="#10b981", linewidth=2.5, label="Postmark LP (mean)")
    ax.fill_between(x, np.percentile(p, 2.5, axis=0), np.percentile(p, 97.5, axis=0),
                    color="#10b981", alpha=0.2, label="Postmark 95% CI")
    ax.plot(x, v.mean(0), color="#ef4444", linewidth=2.5, label="Vanilla 30 bps LP (mean)")
    ax.fill_between(x, np.percentile(v, 2.5, axis=0), np.percentile(v, 97.5, axis=0),
                    color="#ef4444", alpha=0.2, label="Vanilla 95% CI")
    ax.set_title(f"Cumulative LP PnL, Postmark vs vanilla ({n_boot}x bootstrap over {n_days} days)",
                 fontsize=14, pad=15)
    ax.set_xlabel("Swap sequence", fontsize=12)
    ax.set_ylabel("Cumulative LP PnL (USDC)", fontsize=12)
    ax.legend(loc="upper left", fontsize=11)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig("chart_lp_pnl.png", dpi=200, bbox_inches="tight")
    print("  -> chart_lp_pnl.png")
    return p.mean(0)[-1], v.mean(0)[-1]


def main():
    use_cache = "--cached" in sys.argv

    if use_cache:
        if not os.path.exists(CACHE_FILE):
            sys.exit(f"No cache at {CACHE_FILE}. Run once without --cached first.")
        df = pd.read_csv(CACHE_FILE)
        start_block, end_block = int(df["blockNumber"].min()), int(df["blockNumber"].max())
        print(f"Loaded {len(df)} cached swaps, blocks {start_block}..{end_block}")
    else:
        if not RPC_URL:
            sys.exit(
                "ETH_RPC_URL is not set.\n\n"
                "This backtest needs an ARCHIVE node - it reads logs thousands of blocks back, and\n"
                "public endpoints serve only head-adjacent blocks. A free Alchemy or Infura key is\n"
                "enough:\n\n"
                '    export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<key>"\n'
            )
        head = int(rpc("eth_blockNumber", []), 16)
        end_block, start_block = head, head - LOOKBACK_BLOCKS
        print(f"Connected. Head block {head}.")

        rows, failures = fetch_events(start_block, end_block)
        if not rows:
            sys.exit(
                "\nNo events fetched.\n"
                "Every chunk failed. The usual cause is a non-archive endpoint: reading logs more\n"
                "than a few blocks back requires an archive RPC. Set ETH_RPC_URL to an Alchemy or\n"
                "Infura URL and retry."
            )
        df = pd.DataFrame(rows)
        df.to_csv(CACHE_FILE, index=False)
        print(f"\nFetched {len(df)} swaps -> cached to {CACHE_FILE}")

    df.sort_values(["blockNumber", "logIndex"], inplace=True)
    df.reset_index(drop=True, inplace=True)

    df["price"] = (df["sqrtPriceX96"].astype(float) / (2 ** 96)) ** 2
    df["zeroForOne"] = df["amount0"] > 0
    df["notional"] = df["amount0"].abs() / 1e6      # USDC, 6 decimals
    df = df[df["notional"] > 0.1].copy()
    if df.empty:
        sys.exit("Every swap was below the dust filter.")

    start_block, end_block = int(df["blockNumber"].min()), int(df["blockNumber"].max())
    df = simulate(df, start_block, end_block)

    print("\nChart 1: effective fee by flow decile")
    summary = chart_effective_fee(df)
    print("\nChart 2: LP PnL vs vanilla")
    pnl = chart_lp_pnl(df)

    print("\n--- Results " + "-" * 55)
    print(f"swaps replayed        : {len(df):,}")
    print(f"blocks                : {start_block}..{end_block} ({(end_block-start_block)/BLOCKS_PER_DAY:.1f} days)")
    print(f"distinct payers       : {df['sender'].nunique():,}")
    print(f"mean effective fee    : {df['pm_effective_fee_bps'].mean():.2f} bps (vanilla {BASELINE_FEE_BPS:.0f})")
    print(f"most benign decile    : {summary.iloc[0]:.2f} bps")
    print(f"most toxic decile     : {summary.iloc[-1]:.2f} bps")
    print(f"staircase is monotone : {bool((summary.diff().dropna() >= -1e-9).all())}")
    if pnl:
        print(f"final LP PnL, Postmark: {pnl[0]:,.2f} USDC")
        print(f"final LP PnL, vanilla : {pnl[1]:,.2f} USDC")
    print("-" * 67)


if __name__ == "__main__":
    main()
