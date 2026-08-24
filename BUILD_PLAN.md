# Policy Router for Uniswap v4 — Technical Build Plan

**Status:** pre-Phase-0. **Date:** 2026-08-23.
**Repositioning:** not "a compliance hook." A **fail-contained policy router** that composes hooks —
including Uniswap's own Permissioned Pools hook — behind one address.

---

## 0. Strategic frame (read before writing code)

### What changed
Uniswap Labs shipped **Permissioned Pools** (2026-07-23): first-party open-source hook standard,
issuer allowlists on swap + LP mint, ERC-3643, virtual accounting, partners Superstate/Securitize/Dowgo.
KYC-gating an RWA pool is now a solved, free, first-party problem.

### The surviving wedge
Every issuer gets **one monolithic hook**. Adding a second behavior = fork + re-audit + redeploy the pool.
v4 allows exactly one hook per pool and its callback set is immutable. Therefore:

> **Thesis:** the scarce good is not compliance logic. It is *safe composition* of independently-audited
> policy contracts behind a single hook address, with deterministic ordering and provable failure isolation.

### The objection you must answer on slide 1
Uniswap prototyped hook middleware (`BaseMiddleware`, `MiddlewareProtect`, `MiddlewareRemove`) in
v4-periphery and it is **not in mainline today**. Why does yours ship?
Answer to develop and defend: their middleware wrapped *one* hook for safety; it did not solve
N-module ordering, return-value arbitration, or gas-bounded quarantine. Those are the three hard parts
and they are the entire scope of this repo.

### Non-goals (say these out loud; scope discipline is a grading criterion)
- Not building a better KYC oracle. Adapt existing ones.
- Not competing with Permissioned Pools. **Wrap it as a module.**
- Not a general "hook app store." One vertical, three modules, one killer demo.

---

## Phase 0 — Requirements gate & environment

### 0.1 Go/no-go checks (do these BEFORE any Solidity — a "no" here kills weeks of work)

| # | Check | How | Kill condition |
|---|---|---|---|
| R1 | Permissioned Pools hook is `call`-composable as a sub-module | Read its source; confirm it does not require being `msg.sender` to PoolManager beyond hook callbacks, and that its allowlist check is a pure view or self-contained state write | If it *must* be the pool's hook address itself and cannot be delegated to, the adapter story dies — pivot to "router that reimplements ERC-3643 gating natively" |
| R2 | Nobody shipped this in the last 6 months | Search Atrium UHI demo days, `awesome-uniswap-hooks`, v4 hook explorers, Ethereum Magicians, OZ uniswap-hooks issues | If an audited router exists, contribute to it instead |
| R3 | Gas overhead is survivable | Prototype spike (0.4 below) | If a 3-module chain costs >80k gas over a monolith, institutional pools still take it but retail never will — narrow the pitch to RWA only, permanently |
| R4 | UHI cohort timing | atrium.academy/uniswap — verify current cohort dates and whether apps are open | If closed, retarget: Uniswap Foundation grants, or ship independently and apply next cycle |
| R5 | A real design partner exists | 3 outreach convos: an RWA issuer, a compliance-oracle vendor, a v4 hook team | Zero interest after 3 → the composition pain is theoretical; rethink |

**Exit criterion:** R1, R3, R4 answered in writing in `docs/00-feasibility.md`. R5 in progress.

### 0.2 Toolchain
```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge init --no-git .            # repo is not a git repo yet — `git init` first
forge install uniswap/v4-core uniswap/v4-periphery OpenZeppelin/openzeppelin-contracts OpenZeppelin/uniswap-hooks
```
`foundry.toml`: `solc = "0.8.26"` (needs EIP-1153 transient storage), `evm_version = "cancun"`,
`optimizer_runs = 800`, `via_ir = true`, `ffi = true` (salt mining), `gas_reports = ["*"]`.

Pin every dependency to a **commit hash**, not a branch. v4-periphery moves and will break you.

### 0.3 Conceptual baseline — verify by writing tests, not by reading
Prove to yourself in a Foundry test that you understand each of:
1. Singleton PoolManager + `unlock`/`settle`/`take` flash accounting.
2. Hook flags = low 14 bits of address, `ALL_HOOK_MASK = (1<<14)-1`, checked at `initialize`, **immutable**.
3. `Hooks.callHook` uses `call(gas(), ...)` and **bubbles reverts** — default behavior is fail-closed on everything.
4. `beforeSwap` returns `(bytes4, BeforeSwapDelta, uint24 lpFeeOverride)`; fee override honored **only** if `key.fee.isDynamicFee()` (`0x800000`).
5. `BEFORE_SWAP_RETURNS_DELTA_FLAG` requires `BEFORE_SWAP_FLAG` (`isValidHookAddress`).
6. `noSelfCall` — hook is skipped when it is itself the caller.

### 0.4 Spike (2 days, throwaway, delete after)
Hardcode a hook that calls 3 dummy `view` contracts in `beforeSwap`, and measure gas vs a hook with the
same logic inlined. **This number decides the project.** Record in `docs/00-feasibility.md`.

### 0.5 Networks
Base Sepolia primary (v4 deployed, cheap, where RWA issuers actually are). Unichain Sepolia secondary.
Drop Monad unless a judge asks — it splits your testing time for no narrative gain.

---

## Phase 1 — The Router ("baseplate")

Goal: a hook that does nothing except route, safely.

### 1.1 The flag-immutability problem — solve it first
Because callbacks are fixed at the address, define **flag profiles** and mine one manager per profile:

```
PROFILE_SWAP_GUARD  = BEFORE_SWAP | AFTER_SWAP | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY
PROFILE_FULL_FEE    = PROFILE_SWAP_GUARD | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA
PROFILE_MAX         = ALL_HOOK_MASK
```
`PolicyRouterFactory.deploy(profile, salt)` — CREATE2 with `HookMiner`-mined salt (v4-periphery utils).
Registration **must revert** if a module declares a callback the router's address does not enable.
Document the tradeoff honestly: `PROFILE_MAX` pays a router call on every callback forever.
Recommend `PROFILE_SWAP_GUARD` as the institutional default.

### 1.2 `IPolicyModule`
Modules are **advisory pure/effectful checkers that return intents**. They never touch PoolManager.

```solidity
enum Tier { CRITICAL, ADVISORY }   // CRITICAL: revert propagates. ADVISORY: caught + quarantined.

struct PolicyResult {
    bool allow;              // false => router reverts (CRITICAL) or logs+skips (ADVISORY)
    int128 deltaSpecified;   // only honored if module is the pool's delta authority
    int128 deltaUnspecified;
    uint24 feeOverride;      // only honored if module is the pool's fee authority; 0 = abstain
    bytes context;           // passed to the next module in the chain
}

interface IPolicyModule {
    function moduleId() external view returns (bytes32);
    function supportedCallbacks() external view returns (uint160 flagMask);
    function tier() external view returns (Tier);
    function onBeforeSwap(address sender, PoolKey calldata key, SwapParams calldata p,
                          bytes calldata moduleData, bytes calldata context)
        external returns (PolicyResult memory);
    // ...one entrypoint per supported callback
}
```

### 1.3 Router responsibilities
- **Ordering:** `bytes32[] chain` per (poolId, callback). Explicit array, not a priority queue — deterministic,
  cheap to read, and *auditable by a human looking at one storage slot*. CRITICAL modules are forced to
  sort before ADVISORY ones at registration time.
- **Arbitration:** at registration, at most **one** `feeAuthority` and **one** `deltaAuthority` per
  (poolId, callback). Any other module returning nonzero for those fields is ignored and an event is emitted.
  (Alternative you must evaluate and document: sum deltas / take max fee. Single-authority is safer for v1.)
- **hookData routing:** define the encoding now. `abi.decode(hookData, (bytes32[] ids, bytes[] payloads))`,
  router dispatches payload `i` to module `ids[i]`, empty bytes to the rest. Align with the Uniswap Foundation
  hook-data-standards post so integrators can reuse routers.
- **Context chain:** each module's `context` return feeds the next module's `context` param. Cap its length
  (e.g. 1KB) to bound gas.
- **Transient storage:** per-swap accumulators (volume, cumulative delta) in `tstore`/`tload`, flushed to
  storage once in `afterSwap` if at all. This is where you win the gas argument.

### 1.4 Security invariants — write these as a checklist file and test every one
1. Router **never** `delegatecall`s a module. Enforce by grepping CI.
2. Modules cannot call `PoolManager.unlock` during a callback — router sets a transient reentrancy flag;
   router rejects any re-entry into itself.
3. Module code is pinned: `extcodehash` recorded at registration, verified before each call.
   Any change (proxy upgrade, metamorphic redeploy) auto-quarantines the module.
4. Registration/deregistration is **timelocked** (48h default, per-pool configurable). An admin key that can
   swap the KYC module inside one block makes the whole thing uninvestable. Emergency *removal* of an
   ADVISORY module may be instant; CRITICAL modules never are.
5. Router holds no funds, ever. Assert `balance == 0` invariant in fuzz tests.
6. Only the PoolManager may call hook entrypoints (`onlyPoolManager`).

**Exit criterion:** router + 2 no-op modules pass integration tests on a forked Base Sepolia pool;
gas report committed.

---

## Phase 2 — Fail containment (this is the product — do it before the policy modules)

Default v4 behavior is: any module reverts → swap reverts. Containment must be built.

### 2.1 Bounded-gas dispatch
```solidity
uint256 stipend = moduleGasLimit[id];               // per-module, set at registration
try IPolicyModule(m).onBeforeSwap{gas: stipend}(...) returns (PolicyResult memory r) { ... }
catch { _recordFailure(id); if (tier == CRITICAL) revert; }
```
**The 63/64 trap:** a malicious module can burn the entire stipend and, if you sized it wrong, leave
too little gas for the rest of the swap. After every `try`, assert `gasleft() > MIN_TAIL_GAS` and revert
otherwise. Fuzz this with a module that runs an unbounded loop.

### 2.2 Circuit breaker
Per-module failure counter. After `N` failures in a window → auto-quarantine (skipped, event emitted,
governance must explicitly re-enable). CRITICAL modules are **never** quarantined — they fail closed,
the pool halts, and that is the correct behavior for a compliance gate.

### 2.3 The tier decision table (put this in the pitch deck)

| Module | Tier | On failure |
|---|---|---|
| KYC / allowlist | CRITICAL | swap reverts — fail closed |
| RWA settlement | CRITICAL | swap reverts |
| Volume cap | CRITICAL | swap reverts |
| Tiered fee | ADVISORY | fall back to pool static fee |
| MEV / analytics / experimental | ADVISORY | skipped + quarantined |

**Exit criterion:** a test named `test_MaliciousModuleCannotHaltCompliantPool` that injects an
infinite-loop module, a reverting module, and a returns-garbage module, and proves in all three cases:
KYC still enforced, funds intact, pool still swappable after quarantine.

---

## Phase 3 — Policy modules

Build **three**, not a library. Each independently unit-testable with no router present.

1. **`PermissionedPoolsAdapter`** — wraps Uniswap's official Permissioned Pools hook as an `IPolicyModule`.
   *Build this first.* "We compose the standard, we don't compete with it" is your entire credibility story,
   and it deletes the "you rebuilt KYC worse" objection. Falls back to a native ERC-3643 / attestation
   reader if R1 in Phase 0 came back negative.
2. **`RiskControlModule`** — per-address rolling daily volume caps + tiered fee by institutional profile.
   Uses transient storage for the intra-tx accumulator, one `sstore` per address per day.
   This is your `feeAuthority`; the pool must be initialized with the dynamic-fee flag.
3. **`SettlementModule`** — T+0 escrow attestation for RWA legs. Scope tightly: emit a settlement receipt
   event with a custodian-verifiable payload and enforce a settlement-window check. Do **not** build a
   custody system.

---

## Phase 4 — Governance & registry

- `AccessControl` roles: `POOL_ADMIN` (chain edits, timelocked), `GUARDIAN` (emergency ADVISORY removal only),
  `CURATOR` (signs attestations, no power).
- **Hot-swap** = propose → 48h timelock → execute, with the *pending* chain publicly readable so LPs can exit
  before a rule change lands. Emphasize this: institutional capital cares more about *predictability of rule
  changes* than about the rules.
- **Curator metadata:** EIP-712 signed attestations `(moduleAddress, codehash, vertical, auditURI, expiry)`,
  stored as an IPFS CID on-chain. A curator vouching for a codehash that later changes = attestation
  auto-invalid (ties into invariant 1.4.3).

---

## Phase 5 — Testing

- **Unit:** each module in isolation, no router.
- **Integration:** router + full chain on a forked pool.
- **Invariant/fuzz (Foundry `invariant_`):** router balance always 0; CRITICAL chain always executes or
  tx reverts; quarantine is monotonic until governance acts; ordering is stable under reentrancy attempts.
- **Adversarial module suite** (`test/malicious/`): gas bomb, reverter, garbage returndata, reentrant module,
  module that lies about `supportedCallbacks`, module that self-destructs/redeploys at same address.
- **Gas regression CI:** `forge snapshot --check`. Fail the build on regression. Publish the table.
- **Differential test:** router+3 modules vs a hand-written monolith with identical logic — assert identical
  swap outcomes, report the gas delta. This single table is the most persuasive artifact you will produce.

---

## Phase 6 — Deploy, demo, pitch

- Deploy factory + router + 3 modules to Base Sepolia; init a dynamic-fee pool; seed liquidity.
- **Frontend: one screen, not a dashboard.** Live swap panel + the module chain rendered as boxes lighting
  up green/red as the tx executes. One big red button: **"Break the fee module."** Click it → fee module
  goes red and quarantines → swap still succeeds at the static fee → KYC box still green.
  That 20-second loop *is* the pitch. Frameworks demo badly; a live controlled failure demos unforgettably.
- **Deck order:** (1) issuers now have one monolithic hook and forking it costs an audit — (2) here's why
  Uniswap's own middleware attempt didn't solve it — (3) router + tier table — (4) live break-a-module demo
  — (5) gas table — (6) design partner quote.

---

## Timeline (solo, focused)

| Week | Deliverable |
|---|---|
| 1 | Phase 0 complete incl. gas spike + feasibility doc. **Go/no-go.** |
| 2–3 | Phase 1 router + factory + salt mining + no-op modules |
| 4 | Phase 2 containment + adversarial suite |
| 5–6 | Phase 3 three modules |
| 7 | Phase 4 governance + timelock |
| 8 | Phase 5 invariants, gas CI, differential test |
| 9 | Phase 6 deploy + demo UI |
| 10 | Deck, docs, architecture diagrams, submission |

## Biggest risks, ranked
1. **Gas overhead kills retail applicability** → mitigate by owning the RWA/institutional niche explicitly.
2. **Uniswap ships official composition** → mitigate by being the adapter layer, not the rival.
3. **Scope creep into building compliance oracles** → the non-goals list is load-bearing.
4. **"Why didn't Uniswap's middleware work?"** unanswered → answer it in Phase 0, in writing.
