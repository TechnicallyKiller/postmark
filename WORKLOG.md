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
