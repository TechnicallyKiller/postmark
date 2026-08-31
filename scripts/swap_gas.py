"""
Report Postmark's on-chain gas overhead from a SetupPool run.

    RPC=https://sepolia.unichain.org python3 scripts/swap_gas.py

Numbers come from GasProbe's SwapGas events, which are measured inside the transaction that
performs the swap. Forge's broadcast log is not used: its `transactions` and `receipts` arrays are
not aligned and a transaction's `function` label does not correspond to its `hash`, so gas read out
of it is misattributed.

Only the LAST round is a fair comparison. The first swap into a fresh pool pays for cold token
balances and cold pool state, which is warm-up, not hook cost.
"""
import json
import os
import sys
import urllib.request

rpc = os.getenv("RPC") or os.getenv("UNICHAIN_SEPOLIA_RPC") or "https://sepolia.unichain.org"
from_block = os.getenv("FROM_BLOCK", "earliest")

# keccak256("SwapGas(bytes32,uint256,bool,uint256)")
TOPIC = "0x" + "".rjust(0, "0")


def rpc_call(method, params):
    req = urllib.request.Request(
        rpc,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=45) as r:
        body = json.load(r)
    if "error" in body:
        raise RuntimeError(body["error"])
    return body["result"]


def keccak_topic():
    # Computed with the same tooling the contract was compiled by, to avoid a hand-copied constant.
    import subprocess
    out = subprocess.run(
        ["cast", "sig-event", "SwapGas(bytes32,uint256,bool,bool,uint256)"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit("Could not compute the event topic; is `cast` on PATH?")
    return out.stdout.strip()


topic = keccak_topic()
logs = rpc_call("eth_getLogs", [{"fromBlock": from_block, "toBlock": "latest", "topics": [topic]}])
if not logs:
    sys.exit("No SwapGas events found. Run SetupPool against this chain first.")

rows = []
for l in logs:
    data = l["data"][2:]
    words = [data[i:i + 64] for i in range(0, len(data), 64)]
    rows.append({
        "gas": int(words[0], 16),
        "hooked": int(words[1], 16) == 1,
        "bonded": int(words[2], 16) == 1,
        "round": int(words[3], 16),
        "block": int(l["blockNumber"], 16),
    })

rounds = sorted({r["round"] for r in rows})
print(f"{len(rows)} SwapGas events from {rpc}\n")
print(f"{'round':>6} {'vanilla':>10} {'quote only':>12} {'+receipt':>10} {'quote ovh':>10} {'full ovh':>10}")
last = None
for rd in rounds:
    v = next((r["gas"] for r in rows if r["round"] == rd and not r["hooked"]), None)
    q = next((r["gas"] for r in rows if r["round"] == rd and r["hooked"] and not r["bonded"]), None)
    b = next((r["gas"] for r in rows if r["round"] == rd and r["hooked"] and r["bonded"]), None)
    qo = f"{q-v:,}" if (v and q) else "-"
    fo = f"{b-v:,}" if (v and b) else "-"
    print(f"{rd:>6} {(f'{v:,}' if v else '-'):>10} {(f'{q:,}' if q else '-'):>12} "
          f"{(f'{b:,}' if b else '-'):>10} {qo:>10} {fo:>10}")
    if v and q and b:
        last = (v, q, b)

if last is None:
    sys.exit("Did not find a complete round.")

last_v, last_q, last_p = last
print(f"\nsteady state (last round)")
print(f"  vanilla swap                 : {last_v:,}")
print(f"  postmark, quote only         : {last_q:,}   (+{last_q-last_v:,})")
print(f"  postmark, receipt + bond lock: {last_p:,}   (+{last_p-last_v:,})")
print(f"\nON-CHAIN HOOK OVERHEAD: {last_p - last_v:,} gas (full path)")

gwei = float(os.getenv("GAS_PRICE_GWEI", "0.0005"))
eth = float(os.getenv("ETH_PRICE", "3000"))
cost = (last_p - last_v) * gwei * 1e-9 * eth
print(f"at {gwei} gwei and ${eth:,.0f}/ETH that overhead costs ${cost:.6f} per swap")
