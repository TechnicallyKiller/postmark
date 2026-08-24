# Postmark

**A Uniswap v4 hook that charges 2 bps up front and sends the rest of the bill afterwards, to whoever actually caused the loss.**

UHI10 Hookathon. Theme track: Sustainable Liquidity and MEV Protection.
Build window: August 24 to September 3, 2026. Demo Day: September 11, 2026.

---

## 1. The pitch, in one paragraph

Every MEV hook shipped so far protects LPs by charging everyone more when the weather looks bad. Volatility fees (Aegis, Arrakis), priority fee taxes (Angstrom L2), reserve surcharges (EvenFlow). None of them can tell the arbitrageur from the retail swapper at trade time, so they overcharge retail to underprice arbitrage, and volatile pairs stay unviable at low fees. Postmark inverts the sequence. It quotes a near zero fee up front, records a receipt, and settles the adverse selection afterwards, billing the specific counterparty who caused it, from a bond they posted, with the loss measured from the pool's own realized price path. No signed oracle. No offchain sequencer. No priority ordering assumption.

**The trust line, borrowed from what won UHI9:** an offchain oracle has to sign its data and anything signable can be bribed. Postmark's markout is computed from what the chain has already witnessed. You cannot un happen a price.

---

## 2. Why this is defensible

| Existing approach | What it prices on | Why it fails |
|---|---|---|
| Aegis DFM, Arrakis Pro, Detoxer, AdaptiveSwap | Realized volatility, per block price movement | Volatility is a proxy for the *probability* of toxic flow, not the identity of it. Charges retail for the arbitrageur's crime. |
| Angstrom L2 | Priority fee attached to the tx | Only works where the sequencer orders by tip. Blind on L1, blind on FCFS chains, blind to out of band builder payments. |
| Angstrom L1 | Batch auction, uniform clearing price | Requires an entire offchain consensus network. Not a hook, a protocol. |
| EvenFlow (UHI9) | Pool wide surcharge during adverse periods | Surcharges the flow, not the counterparty. No attribution, no enforcement, no rebate for proven benign flow. |
| Brevis volume discount | Cumulative trade volume | Rewards the *largest* traders, who are disproportionately the informed ones. Subsidises adverse selection. Wrong sign. |
| **Postmark** | **Realized markout, per payer, settled ex post** | — |

Nearest neighbour is EvenFlow, seen by these same judges two months ago. The one line differentiation to say on stage: **EvenFlow taxes the weather. Postmark bills the driver.**

---

## 3. Mechanism

### 3.1 Contracts

```
PostmarkHook.sol      v4 hook. beforeSwap, afterSwap, afterInitialize.
FlowVault.sol         Bond escrow. deposit, withdraw, lock, debit.
ReceiptBook.sol       Packed open receipts per pool, ring buffer.
ScoreRegistry.sol     Per payer EWMA toxicity score. Shared across all Postmark pools.
PriceAccumulator.sol  Cumulative tick observations for the settlement TWAP.
```

Hook permissions: `AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP`. Pool must be created with `LPFeeLibrary.DYNAMIC_FEE_FLAG`. Mine the hook address with `HookMiner`.

### 3.2 Lifecycle

**Bonding (opt in, permissionless).**
A payer calls `FlowVault.deposit(token1, amount)`. Anyone can still swap without bonding; they simply land in the top fee tier. Bonding only ever lowers your cost. This is the sybil answer, and it is structural rather than defensive.

**beforeSwap.**
1. Resolve `payer`. v1 uses `sender` (the router or contract calling `poolManager.swap`). Optional `hookData` field lets a router attest to an end user address, which is the v2 path to per user rather than per router scoring.
2. `tier = ScoreRegistry.tierOf(payer)`.
3. `fee = tierFee[tier]`.
4. Check bond covers `requiredBond(notional, tier)`. If it does not, silently fall back to the top tier rather than reverting. **Never revert on a swap.** Reverts destroy router integration and disqualify you from the routing allowlist.
5. `poolManager.updateDynamicLPFee(key, fee)`.

**afterSwap.**
1. If notional is above `dustThreshold`, write a packed receipt: `{payer, poolId, zeroForOne, notional, sqrtPriceAfter, blockNumber}`. Two storage slots. Measure this gas and put the number in the README.
2. Lock `requiredBond` in the vault against that receipt.
3. Push a tick observation into `PriceAccumulator`.

**settle(poolId, receiptIds[]), callable by anyone after W blocks.**
1. `P_ref = twapOver(receipt.blockNumber, receipt.blockNumber + W)`. TWAP, never spot.
2. `markout = notional * (P_ref - P_exec) / P_exec`, signed by trade direction. Positive markout means the payer got a better price than where the market settled, which means the LPs were adversely selected.
3. `charge = min(alpha * max(0, markout), maxChargeBps * notional)`.
4. Debit `charge` from the bond. Route `keeperBps` to `msg.sender`, `rebateShare` to the rebate pool, remainder to LPs.
5. If `markout <= 0`, credit the payer a rebate from the rebate pool, capped at `rebateCapRatio * feesPaid`.
6. `ScoreRegistry.update(payer, normalizedMarkout)` with EWMA factor lambda.
7. Release the bond lock.

**Who calls settle.** The elegant part: **a payer's bond stays locked until their receipts settle.** Benign payers settle to unlock capital and claim rebates, so they self serve. Toxic payers would rather not settle, which is what `keeperBps` is for. Both sides covered without assuming an altruistic keeper.

**withdraw.** Requires zero open receipts plus a cooldown of W blocks past the last swap.

### 3.3 Default parameters

| Parameter | Default | Note |
|---|---|---|
| `tierFee[0]` | 2 bps | proven benign |
| `tierFee[1]` | 8 bps | |
| `tierFee[2]` | 15 bps | |
| `tierFee[3]` | 30 bps | unbonded or unknown, matches the vanilla baseline |
| `W` | ~60 seconds of wall clock in blocks | configurable per pool |
| `alpha` | 0.6 | LVR recapture rate, must stay below 1 |
| `maxChargeBps` | 100 bps of notional | |
| `keeperBps` | 5% of charge | |
| `bondRatio` | 2% of notional per open receipt | plus a floor |
| `lambda` | 0.9 | EWMA |
| `rebateCapRatio` | 0.5 | rebate can never exceed half of fees paid |

---

## 4. The attack slide (this is the presentation)

Most hookathon pitches present a mechanism. Almost none attack their own and show the bound that survives. Present these five as passing Foundry tests, one sentence each.

**A1. TWAP manipulation.** The payer pushes the price back before settlement to fake a benign markout.
Defence: the reference is a TWAP across W blocks, not a spot read. Holding a manipulated TWAP costs roughly the arbitrage others take from you every block of the window. Since `alpha < 1`, the recoverable saving is strictly less than the manipulation cost. Derive the numeric bound at your chosen W and alpha and put it on the slide. Secondary defence: require K distinct payers in the window, otherwise extend it.

**A2. Sybil.** A new address per swap.
Defence: reputation only lowers cost. Fresh addresses start at the top tier. There is no blacklist to escape. Postmark is a prove you are benign system, not a catch the bad guy system. State the honest consequence out loud: a determined arbitrageur just always pays 30 bps, which is exactly what they should pay. The mechanism does not need to catch them. It needs to stop overcharging everyone else.

**A3. Wash trading for rebates.** Trade back and forth to farm zero markout.
Defence: `rebateCapRatio < 1`, so round tripping is strictly negative expected value. Show the arithmetic.

**A4. Receipt spam.** Dust swaps to bloat state.
Defence: `dustThreshold`, and the spammer pays the storage gas themselves.

**A5. Hook rug risk.** Immutable parameters after deploy or timelocked. A `withdrawOnly` emergency mode that pauses swaps while never blocking LP withdrawals. Copy the Angstrom guardrail pattern and cite it.

**Stated limitation, do not hide it.** `donate()` distributes to whoever is in range at settlement time, not necessarily the LPs who were harmed at swap time. v1 accepts this approximation. Put the per tick snapshot accumulator design in the README as v2. Judges reward a clearly stated limitation far more than they punish it, and hiding it is how you lose to the one hostile question.

---

## 5. The two charts that win Impact

Nearly every submission shows a passing test suite. Almost none shows a counterfactual on real data. This is where your empirical background is an unfair advantage.

**Chart 1: effective fee by flow decile.** Pull real ETH/USDC swap history from Unichain or mainnet. Sort every swap by its realized markout, bucket into deciles, plot the effective fee Postmark charged each decile against the flat 30 bps line. If the mechanism works, this chart is a rising staircase crossing the flat line. It is the single most persuasive artifact you can produce, because it proves the claim rather than asserting it.

**Chart 2: LP PnL versus the rebalancing benchmark**, Postmark pool against vanilla 30 bps pool, replayed over the same real flow, with 95 percent confidence intervals from bootstrap resampling over days. Error bars, not a point estimate.

**Stretch, only if days 1 to 8 are green:** port the tier logic as a fee strategy to Paradigm's Optimization Arena Simple AMM challenge, submit it, and put the leaderboard rank on a slide. Third party validation nobody else in the cohort will have.

---

## 6. Day by day

Hard gates. If a gate is red at end of day, you cut scope, not sleep.

**Day 1, Mon Aug 24. Scaffold.**
v4 template, forge install v4 core and periphery. `PostmarkHook` skeleton with correct flags, `HookMiner` address mining, pool init with the dynamic fee flag.
*Gate: a swap executes through the hook on a local fork.*

**Day 2, Tue Aug 25. Bonds and tiers.**
`FlowVault` deposit, withdraw, lock, debit. Static tier table. `beforeSwap` reads tier, sets fee, falls back for unbonded.
*Gate: two addresses, one bonded one not, pay measurably different fees in a test.*

**Day 3, Wed Aug 26. Receipts and price accumulator.**
Packed receipt struct, ring buffer, dust threshold, cumulative tick observations.
*Gate: gas overhead per swap measured and written down. Target under 40k. If it is over 80k, simplify the struct today, not later.*

**Day 4, Thu Aug 27. Settlement math. The hardest day.**
`twapOver()`, markout with correct direction signs, alpha, caps, bond debit, donate, keeper cut.
*Gate: a unit test where a synthetic arbitrage trade is charged approximately its known realized LVR. This is the correctness gate for the entire project. Do not move past it.*

**Day 5, Fri Aug 28. Rebates, EWMA, crosspool registry.**
Rebate pool funded from a slice of charges. `ScoreRegistry` shared across every pool using the hook.
*Gate: a benign payer's effective fee visibly declines across 20 swaps in a test.*

**Day 6, Sat Aug 29. DECISION GATE, bond invariant, then pull Day 7 forward.**

*Morning, 30 minutes, mechanical.* Run the gate as a checklist, not a discussion. Day 4 red: cut everything, spend today finishing Day 4, ship charge only. Day 5 red: cut the crosspool registry, keep rebates single pool. Both green: proceed full. Decide by 10am and do not revisit.

*Midday.* Prove the bond invariant. For all notionals and tiers, `minBond(notional) > maxCharge(notional)`. At the default parameters that is 2% locked against a 1% cap. This makes forfeiture irrational, which makes settlement self enforcing for every payer, which means **Postmark has no settlement liveness problem.** The keeper cut becomes belt and braces rather than load bearing, and the failure mode if nobody ever settles is a locked bond, which fails closed rather than open. Write it as a Foundry property test.

*No Reactive Network on the critical path.* It would solve a problem the bond design already removed, and if it becomes load bearing it costs the strongest slide in the deck: no offchain oracle, no external network, only ledger memory. Parked as optional, see Section 7. Sponsor rule for anything else: integrate only if it hardens the core mechanism. Chainlink as a second reference price feeding a `min()` into the markout computation qualifies, because it strengthens the A1 defence. Anything that adds a parallel feature does not.

*Afternoon.* Start A1, the TWAP manipulation test. It is the hardest of the five and the most valuable, and Days 7 and 8 are both heavier than one day each.

*Gate: bond invariant test green, A1 scaffolded.*

**Day 7, Sun Aug 30. Adversarial suite.**
Write A1 through A5 as tests where the attacker loses money. Plus access control, reentrancy, unauthorized settle, settle before window.
*Gate: every attack fails, suite green, and you can narrate each in one sentence without notes.*

**Day 8, Mon Aug 31. Backtest harness.**
Real swap data in, both pools replayed, Chart 1 and Chart 2 out.
*Gate: Chart 1 exists and shows the staircase.*

**Day 9, Tue Sep 1. Deploy and frontend.**
Unichain Sepolia deploy. Minimal scoreboard: address, tier, cumulative markout, fees paid, rebates earned, live. Deployed addresses into the README.
*Gate: a judge could open the URL and swap.*

**Day 10, Wed Sep 2. Freeze.**
No new features. README: mechanism, parameters, attack analysis, gas table, both charts, deployed addresses, stated limitations, run instructions.

**Thu Sep 3. Submit** via the Tally form. GitHub repo, demo video link, and both tests and frontend rather than either or. Buffer day for whatever breaks.

**Sep 4 to 10. Pitch.**
3 minute demo video. 5 minute deck:
1. 30s, the problem framed as a price discrimination failure, not an MEV failure.
2. 45s, why every existing fix fails. One slide, name Angstrom, Aegis, EvenFlow.
3. 60s, the mechanism in one diagram.
4. 60s, the attack slide with the numeric bound.
5. 60s, the two charts.
6. 30s, what is live, what is not, what is next.

---

## 7. Scope discipline

**Cut list if you fall behind, in this order:** Paradigm leaderboard, then crosspool registry, then rebates, then the frontend (keep the tests instead). Never cut the adversarial suite or Chart 1. Those two are the submission.

**Optional, only once the submission is already safe.** Do not start any of these until the adversarial suite is green and Chart 1 exists. Realistic slots are the Day 9 evening, an early Day 10 freeze, or the Sept 3 buffer.

*Reactive Network settler.* A reactive contract that watches for receipts past their window and fires `settle` without waiting for anyone. Two extra contracts, one on Reactive and one on the destination chain. Worth it because the track is a separate prize pool and the judges verify a callback actually fired onchain, which only six UHI9 teams cleared.

The framing is what protects the pitch. Present it as **a convenience settler, not a dependency**. The exact line: settle is permissionless, the bond invariant already makes settlement self enforcing, and the reactive contract is one possible caller among many. Said that way it costs nothing and adds a track. Said as "our settlement runs on Reactive" it invites the question that undercuts the trust slide. If you cannot fit that clarification into the deck, leave the integration in the repo and out of the pitch.

*Paradigm Optimization Arena rank.* See Section 5.

**Do not build:** crosschain hedging (lambda and CrossHedge both did it at UHI9), tranching (Unistrata and TrancheShield), Harberger managed pools (Maestro), any LLM or offchain model in the fee path, any AVS you cannot demo live.

**Naming:** Postmark. Backup if it collides: Tab, as in put it on my tab.
