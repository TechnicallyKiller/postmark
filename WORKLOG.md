# Postmark — Worklog

**Append an entry at the end of every working session. Newest at the top.**

This is the shared running log. [HANDOFF.md](HANDOFF.md) is the stable overview; this file is the
chronology — what actually happened, what broke, what got decided. If you spent an hour on
something, write the one sentence that saves the other person that hour.

### Entry template — copy this

```markdown
## Day N — <Weekday D Mon> — <your name>

**Gate:** <the gate for this day, verbatim from HANDOFF>
**Status:** GREEN / RED / PARTIAL

**Done**
-

**Decisions**
- <anything you chose that the plan didn't specify, and why>

**Broke / cost me time**
-

**Left for next session**
-

**Numbers** <!-- gas, fees, test counts — anything that goes on a slide later -->
-
```

Rules:
- **RED is a valid status.** Write it down. A red gate you logged is recoverable; a red gate you
  papered over kills the submission on Day 9.
- Record numbers as you measure them (gas overhead, effective fees, charge vs known LVR). Day 10
  needs them for the README and the deck, and re-deriving them under freeze is miserable.
- Log decisions even when they feel obvious at the time. They never look obvious a week later.

---

## Days 3-6 review + fixes — Sun 24 Aug — Claude (reviewing CodeWithSwapnil's commit 0fef929)

**Gate:** Day 3 gas overhead under 40k / Day 4 charge ~= known LVR
**Status:** RED on both. Blocking correctness bugs found and fixed; gas gate still open.

**What I found in 0fef929**
The commit compiled and 30/31 tests passed, but the core billing quantity was corrupt.

- **Receipt notional overflowed `uint32`.** `ReceiptBook` stored `uint32(notional / DUST_THRESHOLD)`
  with `DUST_THRESHOLD = 1e7`, so the largest representable notional was 4.295e16 — 0.043 tokens at
  18 decimals. A 1-token swap was recorded 82x too small. Notional drives the charge, the score and
  the bond release, so every one of them was wrong at realistic size.
- **Bond residue locked funds permanently.** `afterSwap` locked `requiredBond(trueNotional)`;
  settlement unlocked `requiredBond(truncatedNotional)`. `FlowVault.withdraw` requires
  `locked == 0`, so a single remainder bricked the payer's entire bond.
- **Wrap-to-zero bricked settlement.** When the wrap landed on zero, `markout * BPS / notional`
  divided by zero and the receipt could never be settled.
- **`PriceAccumulator` accumulated the wrong tick** — the new post-swap tick over the interval that
  had already elapsed, rather than the tick that prevailed during it. This retroactively applies a
  manipulator's final price to the window they are distorting, which is the wrong direction for A1.
- **`vault.lock()`'s return value was ignored**, so a failed lock still wrote a receipt.
- **The A1 test asserted `assertTrue(true)`.** The bond-invariant fuzz test asserted 2% > 1% on two
  constants and could not fail. The Day 4 test asserted only `charge > 0`, never comparing against a
  known LVR.

Worth noting: the commit's own changelog records "Debugged EvmError: Revert ... by standardizing
test notional sizes to 1e15." That revert *was* the overflow. Shrinking the test inputs below the
wrap point is why 30 tests passed on top of broken accounting.

**Fixed**
- `ReceiptBook` stores the notional **exactly** in `uint96` (7.9e28 ceiling). Receipt is 2 slots:
  `payer|notional` then `blockNumber|tick|flags`. Oversized notionals are skipped, never truncated.
- Lock now happens *before* the receipt write and its result is honoured, so an open receipt always
  has collateral behind it.
- Settlement reads `receipt.notional` as the single source of truth for both the charge and the
  bond release, so locked == released by construction.
- `PriceAccumulator` accumulates `prev.tick` over the elapsed interval, per Uniswap's convention.
  `Observation` repacked to one slot (`uint40|int24|int192`). Backwards extrapolation before the
  first observation removed — it invented prices the chain never witnessed.
- Added `getReceipt` / `receiptCount` views (the auto-getter can't reach a struct behind a mapping).
- Rewrote the three vacuous tests. A1 is now a two-world EV test: settle honestly vs manipulate and
  settle, asserting the attacker ends up poorer. The invariant fuzz now asserts what actually
  matters — that the notional survives the receipt encoding, so bond locked == bond released.

**Broke / cost me time**
- The shared fixture's pool is deliberately shallow (liquidity 1e18 across +/-120 ticks), so a 1e18
  swap only fills ~6e15 and never reaches the old wrap point. Notional regressions need
  `_deepenPool()` first or they test nothing.
- My first A1 assertion ("manipulation must still be charged") was wrong-headed and failed. Pushing
  the price back genuinely does flip the markout sign — the defence is that it costs more than it
  saves, not that it fails to work. The EV framing is the correct test.

**Left for next session**
- **Day 3 gate is red and structural.** See numbers below. Needs an architecture decision, not
  tuning.
- **Day 4 gate still untested.** `test_arbitrageLVR_settlement_Correctness` asserts `charge > 0`,
  not that the charge approximates a known LVR. This is the plan's stated correctness gate for the
  whole project.
- `DUST_THRESHOLD = 1e7` is ~1e-11 tokens at 18 decimals, so it is not currently a meaningful spam
  filter. Pick a real value per pool.
- `W = 5` blocks is ~60s on mainnet but ~5s on Unichain at 1s blocks, which is the deploy target.
  The A1 margin below is thin and W is why.
- Markout precision: `P_exec` is a tick (1 bp granularity) and `twapOver` truncates on int24
  division. At 2-30 bps fee levels the quantization is comparable to the signal.
- Receipts are append-only; `head` never advances. Fine, but the A4 slide should not say "ring
  buffer".

**Numbers**
- Hook overhead vs an identical vanilla pool: **191,395 gas**. Plan gate 40k, hard stop 80k.
  Breakdown: ~75k paid by *every* swap (fee quote reads + price observation), ~62k more when a
  receipt is written (2 cold SSTOREs for the receipt, 2 for the bond lock). A cold SSTORE is 22.1k,
  so 40k allows about one new storage slot per swap in total. Options: pack FlowVault
  balance/locked/lastActivity into one slot (~22-44k), pack the observation count into the
  observation slot (~22k), or emit receipts as events and store only a hash (~22k). Even all three
  land around 100k. Reaching 40k means not writing a receipt per swap at all.
- A1 EV margin, W=5, alpha=0.6: attacker ends **2.37e9 wei poorer** on a 1e15 notional by
  manipulating. Negative, but thin — this is the number the attack slide needs, and it wants a
  larger W behind it.
- Suite: 36 passing, 1 red (the Day 3 gate, deliberately).

---

## Day 2 — Sun 24 Aug — Claude (pairing with TechnicallyKiller)

<!-- Note: Days 1 and 2 were both completed on 24 Aug, so we are one day ahead of the plan's schedule. -->

**Gate:** two addresses, one bonded one not, pay measurably different fees in a test
**Status:** GREEN

**Done**
- `FlowVault.sol` — deposit / depositFor / withdraw / lock / unlock / debit / debitOut / credit.
  Withdraw is gated on both zero locked bond *and* a cooldown past the settlement window, so a
  payer can't swap and run.
- `ScoreRegistry.sol` — EWMA of realized markout (λ = 0.9), tier resolution, owner-managed hook
  allowlist. `update()` is written but has no caller until Day 4.
- `IFlowVault` / `IScoreRegistry` interfaces.
- `PostmarkMath.sol` — `amount0To1`, `amount1To0`, `bpsOf`, `abs`.
- `beforeSwap` now resolves the payer, checks bond coverage against the swap's notional, and quotes
  the tier fee. Short bond silently drops to the top tier instead of reverting.
- 14 new tests (10 vault, 4 fee-tier). Suite at 19 green.

**Decisions**
- **A fresh bond enters at tier 2 (15 bps), not tier 0.** The plan says fresh addresses start at
  the top tier, but then the Day 2 gate can't pass. Reconciled: unbonded is always 30 bps, bonding
  buys entry at 15 bps because the discount is collateralised and clawable, and only settled benign
  history (`MIN_HISTORY = 5`) reaches 8 and 2 bps. **This changes the A2 slide.**
- **Bonds are ERC20-only, in `currency1`** (quote asset by v4 ordering). Native reverts.
- **`FlowVault`'s hook address is set once, permanently** — the A5 guardrail where it matters.
  `ScoreRegistry` gets an owner allowlist instead, since it's shared and holds no funds.
- Bond ratio 200 bps against a 100 bps max charge, as constants on the hook. The Day 6 invariant
  test will pin this.

**Broke / cost me time**
- `vm.prank` gets consumed by the *next external call*, and a `balanceOf` read counts. Three tests
  measured the wrong address before I caught it. Capture balances before the prank.
- `sender` in `beforeSwap` is the router, not the trader — so bonding an EOA does nothing unless the
  router attests via `hookData`. Tests now pass `abi.encode(trader)`.

**Left for next session**
- `afterSwap` is still an empty stub. Day 3 fills it.
- Payer attribution is per-router. Decide whether per-user lands in v1 or stays the v2 story.

**Numbers**
- Bonded vs unbonded gap measured at ~15 bps of notional, as designed.
- Tier fees: 200 / 800 / 1500 / 3000 pips.

---

## Day 1 — Sun 24 Aug — Claude (pairing with TechnicallyKiller)

**Gate:** a swap executes through the hook
**Status:** GREEN

**Done**
- Foundry scaffold, `v4-periphery` (brings `v4-core` + `permit2`) as a submodule, remappings.
- `src/base/BaseHook.sol` — our own. The periphery version forge installs today no longer ships
  `BaseHook`; it was moved out to a separate hooks repo. Local copy is ~110 lines and means one
  fewer unreleased dependency.
- Vendored `HookMiner` from periphery's test dir into `src/libraries/` so deploy scripts can use it.
- `PostmarkHook.sol` with `AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP`, address mining, dynamic-fee
  pool init.
- 5 tests: swap through hook, baseline seeding, static-fee pool rejected, PoolManager-only callbacks.

**Decisions**
- **`beforeSwap` returns an override fee** rather than calling `updateDynamicLPFee`. Cheaper and
  genuinely per-swap. Pool still seeded at 30 bps at init, so a path that skips the override fails
  safe rather than free.
- Deleted the old `Counter` template files rather than adapting them.

**Broke / cost me time**
- Hunting for `BaseHook` in periphery before realising it had been moved to another repo entirely.
- `MockERC20` is at `solmate/src/test/utils/...`, not `solmate/test/utils/...`.

**Left for next session**
- Everything from Day 2.

**Numbers**
- 5 tests green. No gas measurements yet — that's the Day 3 gate.
