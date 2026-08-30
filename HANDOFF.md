# Postmark — Handoff

**Read this first, then [WORKLOG.md](WORKLOG.md) for the running log.**

Last updated: 2026-08-24. Days 1-9 are implemented; **46 Solidity tests and 22 backtest-math checks are green.** Day 4's correctness gate is closed with an exact match and the full A1-A5 suite passes. Two things are genuinely outstanding: **the charts need an archive RPC key**, and there is **no frontend**. See [WORKLOG.md](WORKLOG.md).
Repo: `TechnicallyKiller/postmark` (private) · Deadline: submit **Thu Sep 3**, demo day **Sep 11**.

---

## 1. Get running in five minutes

```bash
git clone --recurse-submodules https://github.com/TechnicallyKiller/postmark
cd postmark
forge build
forge test          # 19 tests, all green
```

If you already cloned without submodules: `git submodule update --init --recursive`.

Foundry, Solidity 0.8.26, EVM target `cancun`. No env vars needed yet.

**Before your first commit**, set your identity in this repo:

```bash
git config --local user.name "<your github name>"
git config --local user.email "<your github email>"
```

## 2. What Postmark is, in sixty seconds

Existing MEV hooks charge *everyone* more when volatility rises. They can't tell the arbitrageur from the retail swapper at trade time, so they overcharge retail to underprice arbitrage.

Postmark reverses the order. It quotes a low fee up front based on the payer's reputation, writes a receipt, and then **W blocks later** measures how the price actually moved and bills the adverse selection back to that specific payer, out of a bond they posted.

The three things that make it work:

1. **Bonding only ever lowers your cost.** Unbonded addresses still swap, they just pay the 30 bps baseline. That's the sybil answer — there's no blacklist to escape.
2. **`beforeSwap` never reverts.** A short bond silently loses the discount. Reverting would kill router integration.
3. **Bond (2% of notional) > max charge (1% of notional).** Forfeiting always costs more than paying, so settlement is self-enforcing. No liveness problem, and the failure mode is a locked bond — it fails closed.

Full pitch and parameter tables are in [README.md](README.md). Full ten-day plan in [docs/BUILD_PLAN.md](docs/BUILD_PLAN.md).

## 3. What's done

| | Milestone | Gate | Where |
|---|---|---|---|
| **Day 1** | Scaffold, hook flags, address mining, dynamic-fee pool | a swap executes through the hook | ✅ [test/PostmarkHook.t.sol](test/PostmarkHook.t.sol) |
| **Day 2** | Bonds and tiers | bonded vs unbonded pay measurably different fees | ✅ [test/FeeTiers.t.sol](test/FeeTiers.t.sol) |
| **Day 3** | Receipts, observation ring, price accumulator | overhead under 40k (hard stop 80k) | ⚠️ **77k steady state** — hard stop met, target missed |
| **Day 4** | Settlement math | charge ≈ known realized LVR | ✅ exact match, [test/SettlementMath.t.sol](test/SettlementMath.t.sol) |
| **Day 5** | Rebates, EWMA, cross-pool registry | benign payer's fee declines over 20 swaps | ✅ |
| **Day 6** | Bond invariant property test | locked bond ≥ chargeable amount | ✅ |
| **Day 7** | Adversarial suite | A1–A5 all lose money for the attacker | ✅ [test/Adversarial.t.sol](test/Adversarial.t.sol) |
| **Day 8** | Backtest harness | Chart 1 shows the staircase | ⚠️ harness + math tested, **charts need an archive RPC** |
| **Day 9** | Deploy + scoreboard | a judge could open the URL and swap | ⚠️ deploy verified locally, **no frontend** |

**46 Solidity tests + 22 backtest-math checks, none red.**

### The two things blocking submission

**Chart 1 needs an archive RPC key.** The plan says never cut it. The harness is rewritten to match
the contract and its math is unit tested; it just cannot fetch data from a public endpoint. Get a
free Alchemy or Infura key, `export ETH_RPC_URL=...`, run `python3 scripts/backtest.py`. Everything
else is in place. Note the charts previously in the repo were deleted — they came from a simulation
whose cap was 50x the contract's and which omitted the upfront fee, so they overstated the result.

**There is no frontend.** `getReceipt` and `receiptCount` are exposed on the hook for it.

### The gate still open

**Day 3 — the 40k target.** Steady-state overhead is 77,162, under the plan's 80k hard stop but
roughly double its 40k target. This is now an architecture question rather than tuning: ~55k is paid
by *every* swap (the fee-quote reads and the price observation) and ~22k more when a receipt is
written. The receipt is two slots and cannot shrink without dropping a field, and a cold SSTORE is
22,100 — so 40k allows about one new storage slot per swap in total. Reaching it means emitting
receipts as events and storing only a hash, or not keeping per-swap state at all. Worth deciding
before Day 9.

A new pool's first swaps cost roughly double the steady-state figure, because every slot is fresh
and the observation ring has not yet wrapped. Both numbers are in the tests.

### Contracts as they stand

| File | State |
|---|---|
| [src/PostmarkHook.sol](src/PostmarkHook.sol) | `afterInitialize` registers the pool and seeds the baseline fee. `beforeSwap` resolves the payer, checks bond coverage, quotes the tier fee via override. **`afterSwap` is an empty stub** — that's Day 3. |
| [src/FlowVault.sol](src/FlowVault.sol) | Complete for v1. deposit / withdraw / lock / unlock / debit / debitOut / credit. Hook address set once, never changeable. |
| [src/ScoreRegistry.sol](src/ScoreRegistry.sol) | Complete for v1. EWMA scoring, tier resolution, owner-managed hook allowlist. `update()` has no caller yet — Day 4 wires it. |
| [src/base/BaseHook.sol](src/base/BaseHook.sol) | Local copy. v4-periphery moved theirs to a separate repo, so we carry our own. |
| [src/libraries/PostmarkMath.sol](src/libraries/PostmarkMath.sol) | `amount0To1`, `amount1To0`, `bpsOf`, `abs`. |
| [src/libraries/HookMiner.sol](src/libraries/HookMiner.sol) | Vendored from periphery's test dir so scripts can use it. |
| `ReceiptBook.sol`, `PriceAccumulator.sol` | **Not written yet.** Day 3. |

## 4. What's left

Hard gates. **If a gate is red at end of day, cut scope, not sleep.**

| Day | Date | Milestone | Gate |
|---|---|---|---|
| **3** | Wed Aug 26 | `ReceiptBook` packed struct + ring buffer, dust threshold, `PriceAccumulator` cumulative tick observations, wire into `afterSwap` | **gas overhead per swap measured and written down. Target under 40k. If over 80k, simplify the struct that same day.** |
| **4** | Thu Aug 27 | Settlement math — `twapOver()`, markout with correct direction signs, alpha, caps, bond debit, donate, keeper cut. **The hardest day.** | a synthetic arbitrage trade is charged ≈ its known realized LVR. **This is the correctness gate for the whole project. Do not move past it.** |
| **5** | Fri Aug 28 | Rebate pool funded from a slice of charges, EWMA wired to settlement, cross-pool registry | a benign payer's effective fee visibly declines across 20 swaps |
| **6** | Sat Aug 29 | **Decision gate by 10am** (see below), then bond invariant property test, then start A1 | invariant test green, A1 scaffolded |
| **7** | Sun Aug 30 | Adversarial suite A1–A5, plus access control / reentrancy / unauthorized settle / settle-before-window | every attack loses money, and you can narrate each in one sentence without notes |
| **8** | Mon Aug 31 | Backtest harness — real swap data, both pools replayed, Chart 1 and Chart 2 | Chart 1 exists and shows the staircase |
| **9** | Tue Sep 1 | Unichain Sepolia deploy + minimal scoreboard frontend | a judge could open the URL and swap |
| **10** | Wed Sep 2 | Freeze. No new features. README complete. | — |
| — | Thu Sep 3 | **Submit** via Tally form | — |

### Day 6 decision gate — run it as a checklist, not a discussion. Decide by 10am, don't revisit.

- Day 4 red → cut everything, finish Day 4, ship charge-only.
- Day 5 red → cut the cross-pool registry, keep rebates single-pool.
- Both green → proceed full.

### Cut list, in this order

Paradigm leaderboard → cross-pool registry → rebates → frontend (keep the tests instead).

**Never cut the adversarial suite or Chart 1. Those two are the submission.**

### Do not build

Cross-chain hedging, tranching, Harberger pools, any LLM/offchain model in the fee path, any AVS you can't demo live. All of these were done at UHI9 and will read as derivative.

Reactive Network is explicitly **off the critical path** — the bond invariant already removes the problem it would solve. Optional extra only once the submission is safe, and if it ships it must be framed as "a convenience settler, not a dependency."

## 5. Decisions already made — argue with these before you build on them

These are mine, made while building Days 1–2. Four of them deviate from what's written in [docs/BUILD_PLAN.md](docs/BUILD_PLAN.md).

1. **A fresh bond enters at tier 2 (15 bps), not tier 0.** The plan's sybil defence says fresh addresses start at the top tier, but the Day 2 gate needs bonding alone to change the fee. Reconciled: unbonded is always 30 bps; bonding buys entry at 15 bps because the discount is *collateralised and clawable*; only settled benign history (`MIN_HISTORY = 5`) moves you to 8 and 2 bps. A sybil must post a fresh clawable bond per address and never reaches tier 0. **This changes the A2 slide** — worth a look.
2. **`beforeSwap` returns an override fee** (`fee | LPFeeLibrary.OVERRIDE_FEE_FLAG`) rather than calling `updateDynamicLPFee`. Cheaper and genuinely per-swap. The pool is still seeded at 30 bps at init so any path skipping the override fails safe.
3. **Bonds are ERC20-only, denominated in `currency1`** — the quote asset under v4 token ordering. Native bonds revert.
4. **`FlowVault`'s hook address is set once and can never change.** That's the A5 rug guardrail on the contract that holds money. `ScoreRegistry` keeps an owner-managed allowlist instead, because it's shared across pools — it holds no funds and can only lower a fee, so a bad entry costs a mispriced fee, never principal.

**Open question for you:** payer attribution is per-router in v1 (`sender` is whoever called `poolManager.swap`). The `hookData` attestation path works and is tested, but it's opt-in and self-reported. Do we push per-user attribution into v1, or keep it as the v2 story?

## 6. Gotchas that will cost you an hour each

- **`sender` in `beforeSwap` is the router, not the trader.** In tests, pass `abi.encode(trader)` as `hookData` to attest, and read balances on the *trader*, not the test contract.
- **`vm.prank` is consumed by the next external call** — including a `balanceOf` read. Capture balances *before* the prank, not between prank and swap. This silently broke three tests.
- **MockERC20 lives at `solmate/src/test/utils/mocks/MockERC20.sol`**, not `solmate/test/...`. The remapping points at solmate's repo root.
- **The hook address must be mined** so its low 14 bits match the declared permissions, and the constructor validates this. Change the constructor args and the salt changes — [test/utils/PostmarkTestBase.sol](test/utils/PostmarkTestBase.sol) re-mines every run.
- **Pools must be created with `LPFeeLibrary.DYNAMIC_FEE_FLAG`.** `afterInitialize` reverts otherwise, deliberately.
- **Transient storage carries the payer** from `beforeSwap` to `afterSwap`, so the EVM target must stay `cancun`.
- `lib/v4-periphery` is a **submodule**; `lib/forge-std` is committed as plain files. Inconsistent but working — don't "fix" it mid-sprint.

## 7. Conventions

- **Commits:** one per gate, message names the day and the gate. Keep gates and commits aligned so the history reads as the build log.
- **Tests:** `test_<behaviourInPlainEnglish>`. Every gate gets a test whose name *is* the gate.
- **Comments:** explain *why*, especially for anything adversarial. Every defence in the code should trace to an attack in the README table.
- **Never let `beforeSwap` or `afterSwap` revert** on a path a real swapper can hit. This is the single hardest rule in the codebase.
- **Update [WORKLOG.md](WORKLOG.md) at the end of every working session.** That's the file we both keep current.

## 8. Who does what

Fill this in:

| Area | Owner |
|---|---|
| Contracts (Days 3–7) | |
| Backtest + charts (Day 8) | |
| Deploy + frontend (Day 9) | |
| Deck + demo video (Sep 4–10) | |
