import os
import sys
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
from web3 import Web3
from tqdm import tqdm
import time
import warnings
import requests
from hexbytes import HexBytes

# Suppress pandas deprecation warnings
warnings.filterwarnings('ignore')

# --- Constants & Configuration ---
RPC_URL = os.getenv('ETH_RPC_URL', 'https://eth.llamarpc.com')
POOL_ADDRESS = '0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8'  # Mainnet USDC/WETH 0.3%
W = 12
ALPHA = 0.6
BASELINE_FEE_BPS = 30.0
BATCH_SIZE = 500  # Safe batch size for Alchemy free tier

# Uniswap V3 Pool Swap Event ABI
SWAP_ABI = [{
    "anonymous": False,
    "inputs": [
        {"indexed": True, "internalType": "address", "name": "sender", "type": "address"},
        {"indexed": True, "internalType": "address", "name": "recipient", "type": "address"},
        {"indexed": False, "internalType": "int256", "name": "amount0", "type": "int256"},
        {"indexed": False, "internalType": "int256", "name": "amount1", "type": "int256"},
        {"indexed": False, "internalType": "uint160", "name": "sqrtPriceX96", "type": "uint160"},
        {"indexed": False, "internalType": "uint128", "name": "liquidity", "type": "uint128"},
        {"indexed": False, "internalType": "int24", "name": "tick", "type": "int24"}
    ],
    "name": "Swap",
    "type": "event"
}]

def fetch_events(w3, contract, start_block, end_block, chunk_size=BATCH_SIZE):
    events = []
    # Uniswap V3 Swap event signature
    swap_topic = "0x"+ w3.keccak(text="Swap(address,address,int256,int256,uint160,uint128,int24)").hex()
    
    print(f"Fetching Swap events from block {start_block} to {end_block} (batch size {chunk_size})...")
    
    for chunk_start in tqdm(range(start_block, end_block + 1, chunk_size)):
        chunk_end = min(chunk_start + chunk_size - 1, end_block)
        retries = 3
        
        while retries > 0:
            try:
                # Raw RPC Call: Bypasses web3.py HTTPProvider exceptions and formatting bugs
                payload = {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "eth_getLogs",
                    "params": [{
                        "address": contract.address,
                        "fromBlock": hex(chunk_start),
                        "toBlock": hex(chunk_end),
                        "topics": [swap_topic]
                    }]
                }
                
                resp = requests.post(RPC_URL.strip(), json=payload, headers={"Content-Type": "application/json"})
                
                # If Alchemy throws a 400, this lets us actually read their error message!
                if resp.status_code != 200:
                    raise Exception(f"HTTP {resp.status_code} - {resp.text}")
                    
                data = resp.json()
                if "error" in data:
                    raise Exception(f"RPC Error - {data['error']}")
                
                raw_logs = data.get("result", [])
                
                for log in raw_logs:
                    # Reconstruct the log dict so web3.py can parse the ABI correctly
                    formatted_log = {
                        'address': log['address'],
                        'blockHash': HexBytes(log['blockHash']),
                        'blockNumber': int(log['blockNumber'], 16),
                        'data': log['data'],
                        'logIndex': int(log['logIndex'], 16),
                        'topics': [HexBytes(t) for t in log['topics']],
                        'transactionHash': HexBytes(log['transactionHash']),
                        'transactionIndex': int(log['transactionIndex'], 16),
                    }
                    parsed = contract.events.Swap().process_log(formatted_log)
                    events.append(parsed)
                    
                break
                
            except Exception as e:
                retries -= 1
                if retries == 0:
                    print(f"\nFailed chunk {chunk_start}-{chunk_end}: {e}")
                else:
                    time.sleep(1.5)
                    
    return events

def main():
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        print(f"CRITICAL: Failed to connect to RPC: {RPC_URL}")
        print("Please ensure ETH_RPC_URL is set correctly in your environment.")
        sys.exit(1)
        
    print(f"Connected to RPC. Current head block: {w3.eth.block_number}")
    contract = w3.eth.contract(address=w3.to_checksum_address(POOL_ADDRESS), abi=SWAP_ABI)
    
    end_block = w3.eth.block_number
    start_block = end_block - 10000
    
    raw_events = fetch_events(w3, contract, start_block, end_block)
    if not raw_events:
        print("No events fetched. Check block range or network connection.")
        return
        
    print(f"\nFetched {len(raw_events)} live swaps.")
    
    # --- Parse Events into DataFrame ---
    print("Parsing swap data...")
    data = []
    for ev in raw_events:
        args = ev['args']
        data.append({
            'blockNumber': ev['blockNumber'],
            'transactionHash': ev['transactionHash'].hex(),
            'logIndex': ev['logIndex'],
            'amount0': args['amount0'],
            'amount1': args['amount1'],
            'sqrtPriceX96': args['sqrtPriceX96'],
            'tick': args['tick']
        })
        
    df = pd.DataFrame(data)
    df.sort_values(['blockNumber', 'logIndex'], inplace=True)
    df.reset_index(drop=True, inplace=True)
    
    # Price = (sqrtPriceX96 / 2^96)^2
    df['price'] = (df['sqrtPriceX96'].astype(float) / (2**96)) ** 2
    df['P_exec'] = df['price']
    
    # Trade Direction: zeroForOne (USDC -> WETH) if amount0 > 0
    df['zeroForOne'] = df['amount0'] > 0
    df['notional'] = df['amount0'].abs() / 1e6  # Normalize USDC decimals (6)
    
    # Drop zero-notional dust transactions
    df = df[df['notional'] > 0.1].copy()
    
    # --- Build Block-by-Block Price History ---
    print("Constructing W-block TWAP history...")
    all_blocks = pd.DataFrame({'blockNumber': np.arange(start_block, end_block + 1)})
    price_hist = df.drop_duplicates('blockNumber', keep='last')[['blockNumber', 'price']]
    price_hist = pd.merge(all_blocks, price_hist, on='blockNumber', how='left')
    price_hist['price'] = price_hist['price'].ffill().bfill()
    price_hist.set_index('blockNumber', inplace=True)
    
    # --- Simulate Postmark Settlement Math ---
    print("Simulating Postmark Settlement LVR Recapture...")
    markouts = []
    charges = []
    
    for _, row in df.iterrows():
        b = row['blockNumber']
        p_exec = row['P_exec']
        zfo = row['zeroForOne']
        
        # P_ref: TWAP over [B, B+W]
        window_end = min(b + W, end_block)
        if b > end_block - W:
            window_end = end_block
            
        twap_price = price_hist.loc[b:window_end, 'price'].mean()
        p_ref = twap_price
        
        # Markout = Notional * (P_ref - P_exec) / P_exec
        ratio = p_ref / p_exec
        diff = (1 - ratio) if zfo else (ratio - 1)
            
        m = diff * row['notional']
        markouts.append(m)
        
        # LVR Recapture Charge
        charge = m * ALPHA if m > 0 else 0
        
        # Cap: 5000 bps (50%) of notional
        if charge > 0.5 * row['notional']:
            charge = 0.5 * row['notional']
            
        charges.append(charge)
        
    df['markout'] = markouts
    df['vanilla_fee'] = (BASELINE_FEE_BPS / 10000) * df['notional']
    df['pm_charge'] = charges
    
    # Effective Fee in BPS
    df['pm_effective_fee_bps'] = (df['pm_charge'] / df['notional']) * 10000
    df['markout_bps'] = (df['markout'] / df['notional']) * 10000
    
    # --- Chart 1: Effective Fee by Flow Decile ---
    print("Generating Chart 1: Effective Fee by Flow Decile...")
    df['decile'] = pd.qcut(df['markout_bps'], 10, labels=False, duplicates='drop')
    decile_summary = df.groupby('decile')['pm_effective_fee_bps'].mean()
    
    plt.figure(figsize=(10, 6))
    sns.set_style("whitegrid")
    
    x = np.arange(len(decile_summary))
    plt.bar(x, decile_summary.values, color='#8b5cf6', alpha=0.9, label='Postmark Ex-Post Fee')
    plt.axhline(BASELINE_FEE_BPS, color='#ef4444', linestyle='--', linewidth=2.5, label='Vanilla Pool (30 bps)')
    
    plt.title('Effective Fee by Flow Toxicity Decile (Live Mainnet Data)', fontsize=14, pad=15)
    plt.xlabel('Flow Toxicity Decile (0 = Most Benign, 9 = Most Toxic)', fontsize=12)
    plt.ylabel('Effective Fee (bps)', fontsize=12)
    plt.xticks(x, [f"D{i+1}" for i in x])
    plt.legend(loc='upper left', fontsize=11)
    plt.tight_layout()
    plt.savefig('chart_effective_fee.png', dpi=300, bbox_inches='tight')
    print("  -> Saved 'chart_effective_fee.png'")
    
    # --- Chart 2: LP PnL vs Rebalancing Benchmark (Bootstrap) ---
    print("Generating Chart 2: LP PnL (Bootstrap Resampling)...")
    df['vanilla_pnl'] = df['vanilla_fee'] - df['markout']
    df['pm_pnl'] = (df['pm_charge'] * 0.8) - df['markout']
    
    N_BOOTSTRAP = 1000
    n_swaps = len(df)
    
    vanilla_paths = np.zeros((N_BOOTSTRAP, n_swaps))
    pm_paths = np.zeros((N_BOOTSTRAP, n_swaps))
    
    for i in tqdm(range(N_BOOTSTRAP), desc="Bootstrapping PnL Paths"):
        sample_idx = np.random.choice(df.index, size=n_swaps, replace=True)
        v_pnl = df.loc[sample_idx, 'vanilla_pnl'].values
        p_pnl = df.loc[sample_idx, 'pm_pnl'].values
        
        vanilla_paths[i] = np.cumsum(v_pnl)
        pm_paths[i] = np.cumsum(p_pnl)
        
    v_mean = np.mean(vanilla_paths, axis=0)
    v_lb = np.percentile(vanilla_paths, 2.5, axis=0)
    v_ub = np.percentile(vanilla_paths, 97.5, axis=0)
    
    p_mean = np.mean(pm_paths, axis=0)
    p_lb = np.percentile(pm_paths, 2.5, axis=0)
    p_ub = np.percentile(pm_paths, 97.5, axis=0)
    
    plt.figure(figsize=(10, 6))
    x_axis = np.arange(n_swaps)
    plt.plot(x_axis, p_mean, color='#10b981', label='Postmark LP (Mean)', linewidth=2.5)
    plt.fill_between(x_axis, p_lb, p_ub, color='#10b981', alpha=0.2, label='Postmark 95% CI')
    
    plt.plot(x_axis, v_mean, color='#ef4444', label='Vanilla 30 bps LP (Mean)', linewidth=2.5)
    plt.fill_between(x_axis, v_lb, v_ub, color='#ef4444', alpha=0.2, label='Vanilla 95% CI')
    
    plt.title('Cumulative LP PnL: Postmark vs Vanilla (1,000x Bootstrap)', fontsize=14, pad=15)
    plt.xlabel('Swap Sequence', fontsize=12)
    plt.ylabel('Cumulative LP PnL (USDC Normalized)', fontsize=12)
    plt.legend(loc='upper left', fontsize=11)
    plt.tight_layout()
    plt.savefig('chart_lp_pnl.png', dpi=300, bbox_inches='tight')
    print("  -> Saved 'chart_lp_pnl.png'")
    
    print("\nBacktest Harness Execution Complete.")

if __name__ == "__main__":
    main()