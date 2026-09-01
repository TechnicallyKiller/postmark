'use client'

import { motion, AnimatePresence } from 'framer-motion'
import { useEffect, useMemo, useState } from 'react'
import {
  ADDRESSES, EXPLORER, POOL_ID, TIER_COLOR, TIER_NAME,
  amount, bps, readAddress, readPoolState, short,
  type Address, type Payer, type PoolState, type Receipt,
} from '@/lib/postmark'

const connectionPaths = [
  'M 8 74 C 28 52, 38 48, 54 34 S 78 18, 96 22',
  'M 18 88 C 42 72, 54 70, 69 53 S 88 36, 100 40',
  'M 3 38 C 24 42, 31 30, 48 28 S 73 50, 98 62',
]

const tabVariants = {
  initial: { opacity: 0, y: 10 },
  animate: { opacity: 1, y: 0 },
  exit: { opacity: 0, y: -10, transition: { duration: 0.2 } },
}

const tabs = ['Ledger', 'Receipts', 'Pool'] as const
type Tab = (typeof tabs)[number]

export default function HookInterface() {
  const [activeTab, setActiveTab] = useState<Tab>('Ledger')
  const [state, setState] = useState<PoolState | null>(null)
  const [error, setError] = useState<string>('')
  const [selected, setSelected] = useState<number | null>(null)

  useEffect(() => {
    let live = true
    const load = () =>
      readPoolState()
        .then((s) => { if (live) { setState(s); setError('') } })
        .catch((e: unknown) => { if (live) setError(e instanceof Error ? e.message : String(e)) })
    load()
    const t = setInterval(load, 20_000)
    return () => { live = false; clearInterval(t) }
  }, [])

  const open = useMemo(() => state?.receipts.filter((r) => !r.settled) ?? [], [state])

  return (
    <main className="min-h-screen flex flex-col bg-neutral-950 text-white overflow-hidden">
      <nav className="relative z-10 border-b border-neutral-800 px-4 py-4 md:px-6 md:py-5 lg:px-10">
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-4">
          <a href="#top" className="flex items-center gap-3" aria-label="Postmark home">
            <span className="grid size-10 place-items-center border border-neutral-700 bg-neutral-900 text-lg font-bold text-[#CCFF00]">PM</span>
            <span className="hidden sm:block">
              <strong className="block text-sm tracking-[0.18em]">POSTMARK</strong>
              <small className="block text-[9px] tracking-[0.16em] text-neutral-500">EX-POST FEE SETTLEMENT</small>
            </span>
          </a>
          <div className="flex space-x-2 md:space-x-8">
            {tabs.map((tab) => (
              <button
                key={tab}
                onClick={() => setActiveTab(tab)}
                className={`relative px-2 py-2 text-[11px] md:text-sm font-bold tracking-widest transition-colors ${activeTab === tab ? 'text-white' : 'text-neutral-500 hover:text-neutral-300'}`}
              >
                {tab.toUpperCase()}
                {activeTab === tab && <motion.div layoutId="activeTabIndicator" className="absolute bottom-0 left-0 right-0 h-0.5 bg-[#CCFF00]" />}
              </button>
            ))}
          </div>
          <LiveBadge state={state} error={error} />
        </div>
      </nav>

      <div id="top" className="relative isolate flex-1 mx-auto w-full max-w-7xl px-4 py-8 md:px-6 md:py-14 lg:px-10 lg:py-20">
        <svg className="hidden md:block pointer-events-none absolute inset-0 -z-10 h-full w-full opacity-25" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
          {connectionPaths.map((path, i) => (
            <motion.path key={path} d={path} fill="none" stroke={i % 2 ? '#B026FF' : '#CCFF00'} strokeWidth="0.12" strokeDasharray="1 1.6"
              initial={{ pathLength: 0, opacity: 0 }} animate={{ pathLength: 1, opacity: 0.35 }} transition={{ duration: 1.5, delay: i * 0.25 }} />
          ))}
        </svg>

        {error && (
          <div className="relative mb-8 border border-[#FF4D4D] bg-[#FF4D4D]/10 p-4 text-xs text-[#FF4D4D]">
            Could not reach Unichain Sepolia: {error}. Retrying every 20 seconds.
          </div>
        )}

        <AnimatePresence mode="wait">
          {activeTab === 'Ledger' && (
            <motion.div key="Ledger" variants={tabVariants} initial="initial" animate="animate" exit="exit"
              className="relative z-0 grid items-start gap-12 grid-cols-1 lg:grid-cols-[1fr_420px] lg:gap-16">
              <section className="max-w-2xl">
                <p className="mb-4 lg:mb-7 inline-flex border border-[#B026FF] bg-[#B026FF]/10 px-3 py-1 text-[10px] font-bold tracking-[0.18em] text-[#CCFF00]">
                  LIVE · UNICHAIN SEPOLIA · {short(ADDRESSES.hook, 8)}
                </p>
                <h1 className="font-mono text-4xl md:text-5xl font-bold leading-[0.98] tracking-[-0.06em] lg:text-6xl">
                  Bills the driver, <span className="text-[#CCFF00]">not the weather.</span>
                </h1>
                <p className="mt-6 md:mt-8 max-w-xl text-sm md:text-base leading-7 text-neutral-400">
                  Every swap leaves a receipt. {state ? state.windowBlocks : 100} blocks later the adverse selection is
                  measured against the pool&apos;s own price path and billed to whoever caused it — from a bond they
                  posted, with no oracle anywhere in the loop.
                </p>

                <div className="mt-10 grid max-w-xl grid-cols-3 border border-neutral-800 bg-neutral-900">
                  <Stat label="RECEIPTS WRITTEN" value={state ? String(state.receiptCount) : '—'} tone="#CCFF00" />
                  <Stat label="SETTLEMENT WINDOW" value={state ? `${state.windowBlocks}` : '—'} sub="blocks" border />
                  <Stat label="BOND / CAP" value={state ? `${state.bondRatioBps / 100}% / ${state.maxChargeBps / 100}%` : '—'} tone="#B026FF" />
                </div>

                <h2 className="mt-12 mb-4 text-[10px] tracking-[0.2em] text-neutral-500">PAYERS WITH OPEN RECEIPTS</h2>
                <PayerTable payers={state?.payers ?? []} loading={!state && !error} />
              </section>

              <LookupPanel bondCurrency={state?.bondCurrency} tierFees={state?.tierFees} />
            </motion.div>
          )}

          {activeTab === 'Receipts' && (
            <motion.div key="Receipts" variants={tabVariants} initial="initial" animate="animate" exit="exit" className="relative z-0 grid grid-cols-1 lg:grid-cols-[380px_1fr] gap-8 lg:gap-12">
              <div>
                <h2 className="font-mono text-3xl font-bold lg:text-4xl">Open receipts</h2>
                <p className="mt-3 text-xs md:text-sm text-neutral-400">
                  Read straight from <code className="text-[#CCFF00]">getReceipt</code> on the live hook. A settled
                  receipt is deleted in place, so it disappears from this list.
                </p>
                <div className="mt-6 grid gap-2">
                  {open.length === 0 && <Empty loading={!state && !error} what="receipts" />}
                  {open.map((r) => (
                    <button key={r.id} onClick={() => setSelected(r.id)}
                      className={`border p-4 text-left transition-colors ${selected === r.id ? 'border-[#CCFF00] bg-neutral-900' : 'border-neutral-800 bg-neutral-900 hover:border-neutral-600'}`}>
                      <div className="flex items-center justify-between">
                        <span className="font-mono text-xs text-neutral-500">#{r.id}</span>
                        <span className="text-[10px] font-bold" style={{ color: TIER_COLOR[r.tier] }}>T{r.tier}</span>
                      </div>
                      <div className="mt-2 font-mono text-sm">{short(r.payer, 10)}</div>
                      <div className="mt-1 font-mono text-[10px] text-neutral-500">
                        {amount(r.notional)} · block {r.blockNumber.toLocaleString()} · tick {r.tickAfter}
                      </div>
                    </button>
                  ))}
                </div>
              </div>
              <ReceiptDetail receipt={open.find((r) => r.id === selected) ?? open[0]} state={state} />
            </motion.div>
          )}

          {activeTab === 'Pool' && (
            <motion.div key="Pool" variants={tabVariants} initial="initial" animate="animate" exit="exit" className="relative z-0 flex flex-col gap-8 lg:gap-12">
              <div>
                <h2 className="font-mono text-3xl font-bold lg:text-5xl">The schedule</h2>
                <p className="mt-3 max-w-2xl text-xs md:text-sm text-neutral-400">
                  Bonding never raises your cost — an unbonded address still trades, it just pays the baseline. Only
                  settled, benign flow moves a payer down the schedule, and the discount it earns is collateralised the
                  whole way. Fees below are read live from the hook.
                </p>
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 md:gap-4">
                {(state?.tierFees ?? [200, 800, 1500, 3000]).map((fee, t) => (
                  <div key={t} className="border border-neutral-800 bg-neutral-900 p-5" style={{ borderTopColor: TIER_COLOR[t], borderTopWidth: 3 }}>
                    <p className="font-mono text-[10px] tracking-[0.16em]" style={{ color: TIER_COLOR[t] }}>TIER {t}</p>
                    <p className="mt-2 font-mono text-3xl font-bold">{bps(fee)}<span className="text-base text-neutral-500"> bps</span></p>
                    <p className="mt-1 text-[10px] text-neutral-500">{TIER_NAME[t]}</p>
                    <div className="mt-4 border-t border-neutral-800 pt-3 grid gap-1.5 text-[10px]">
                      <Row k="realized markout" v={['0.98', '6.41', '14.90', '39.14'][t] + ' bps'} tone={TIER_COLOR[t]} />
                      <Row k="all-in paid" v={['2.59', '11.85', '23.94', '53.48'][t] + ' bps'} />
                      <Row k="share of volume" v={['0.15%', '1.31%', '27.75%', '70.79%'][t]} />
                    </div>
                  </div>
                ))}
              </div>
              <p className="-mt-4 text-[10px] text-neutral-600">
                Markout, all-in fee and volume share are measured over 3,465 real mainnet USDC/WETH swaps replayed
                through both pools — not from this testnet pool, which carries only demo flow.
              </p>

              <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 lg:gap-8">
                <div className="border border-neutral-700 bg-neutral-900 p-5 md:p-8">
                  <h3 className="text-[10px] tracking-[0.2em] text-neutral-500 mb-5 border-b border-neutral-800 pb-3">LIVE CONTRACTS</h3>
                  <div className="grid gap-3 font-mono text-[11px]">
                    {Object.entries(ADDRESSES).map(([name, addr]) => (
                      <a key={name} href={`${EXPLORER}/address/${addr}`} target="_blank" rel="noreferrer"
                        className="flex items-center justify-between gap-3 border border-neutral-800 bg-neutral-950 p-3 transition-colors hover:border-[#CCFF00]">
                        <span className="text-neutral-500">{name}</span>
                        <span>{short(addr, 10)}</span>
                      </a>
                    ))}
                    <div className="flex items-center justify-between gap-3 border border-neutral-800 bg-neutral-950 p-3">
                      <span className="text-neutral-500">pool</span>
                      <span>{short(POOL_ID, 10)}</span>
                    </div>
                  </div>
                  <div className="mt-5 grid gap-1.5 text-[10px]">
                    <Row k="settlement window" v={state ? `${state.windowBlocks} blocks` : '—'} />
                    <Row k="recapture α" v={state ? `${state.alphaBps / 10000}` : '—'} />
                    <Row k="withdraw cooldown" v={state ? `${state.cooldownBlocks} blocks` : '—'} />
                    <Row k="emergency brake" v={state ? (state.emergencyMode ? 'ENGAGED' : 'not engaged') : '—'}
                      tone={state?.emergencyMode ? '#FF4D4D' : '#CCFF00'} />
                  </div>
                </div>

                <div className="flex flex-col gap-6">
                  <div className="border border-neutral-700 bg-neutral-900 p-5 md:p-8">
                    <h3 className="text-[10px] tracking-[0.2em] text-neutral-500 mb-5 border-b border-neutral-800 pb-3">MEASURED ON REAL FLOW</h3>
                    <div className="flex items-baseline gap-4">
                      <span className="font-mono text-4xl font-bold text-[#CCFF00]">2.06×</span>
                      <span className="text-xs text-neutral-400">LP PnL against a flat 30 bps pool on identical flow</span>
                    </div>
                    <p className="mt-4 text-[11px] leading-5 text-neutral-500">
                      Averaged over all volume Postmark charges 30.60 bps against the flat pool&apos;s 30 — it is not a
                      discount scheme. What changes is who pays. Benign flow pays 2.59 where a flat pool charges it 30;
                      the toxic tail pays 53.48.
                    </p>
                  </div>
                  <div className="border border-neutral-700 bg-neutral-900 p-5 md:p-8">
                    <h3 className="text-[10px] tracking-[0.2em] text-neutral-500 mb-5 border-b border-neutral-800 pb-3">HOOK GAS, ON CHAIN</h3>
                    <div className="grid grid-cols-2 gap-4 font-mono">
                      <div><p className="text-2xl font-bold">+36,328</p><p className="mt-1 text-[10px] text-neutral-500">quote only</p></div>
                      <div><p className="text-2xl font-bold">+98,209</p><p className="mt-1 text-[10px] text-neutral-500">with a receipt</p></div>
                    </div>
                    <p className="mt-4 text-[11px] leading-5 text-neutral-500">
                      About $0.00015 a swap at Unichain gas. The same overhead on mainnet would be $6.48 — which is why
                      this is an L2 mechanism and says so.
                    </p>
                  </div>
                </div>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      <footer className="border-t border-neutral-800 px-6 py-6 text-center text-[10px] tracking-[0.16em] text-neutral-500">
        POSTMARK · READ LIVE FROM UNICHAIN SEPOLIA · READ-ONLY, NO WALLET REQUIRED
      </footer>
    </main>
  )
}

// ---------------------------------------------------------------------------

function LiveBadge({ state, error }: { state: PoolState | null; error: string }) {
  const tone = error ? '#FF4D4D' : state ? '#CCFF00' : '#666'
  const text = error ? 'offline' : state ? `block ${state.blockNumber.toLocaleString()}` : 'connecting…'
  return (
    <div className="hidden sm:flex items-center gap-2 border border-neutral-800 bg-neutral-900 px-3 py-2">
      <span className="size-2 rounded-full" style={{ background: tone }} />
      <span className="font-mono text-[10px] text-neutral-400">{text}</span>
    </div>
  )
}

function Stat({ label, value, sub, tone, border }: { label: string; value: string; sub?: string; tone?: string; border?: boolean }) {
  return (
    <div className={`p-4 md:p-5 ${border ? 'border-x border-neutral-800' : ''}`}>
      <p className="font-mono text-xl md:text-2xl font-bold" style={tone ? { color: tone } : undefined}>
        {value}{sub && <span className="text-xs text-neutral-500"> {sub}</span>}
      </p>
      <p className="mt-2 text-[9px] md:text-[10px] tracking-[0.14em] text-neutral-500">{label}</p>
    </div>
  )
}

function Row({ k, v, tone }: { k: string; v: string; tone?: string }) {
  return (
    <div className="flex justify-between gap-3">
      <span className="text-neutral-500">{k}</span>
      <span className="font-mono font-bold" style={tone ? { color: tone } : undefined}>{v}</span>
    </div>
  )
}

function Empty({ loading, what }: { loading: boolean; what: string }) {
  return (
    <div className="border border-dashed border-neutral-800 p-8 text-center text-xs text-neutral-500">
      {loading ? `Reading ${what} from the chain…` : `No open ${what}. Every receipt written so far has been settled.`}
    </div>
  )
}

function PayerTable({ payers, loading }: { payers: Payer[]; loading: boolean }) {
  if (!payers.length) return <Empty loading={loading} what="payers" />
  return (
    <div className="border border-neutral-800 bg-neutral-900">
      <div className="grid grid-cols-[1fr_60px_80px_90px_80px] gap-2 border-b border-neutral-800 px-4 py-3 text-[9px] tracking-[0.14em] text-neutral-500">
        <span>PAYER</span><span>TIER</span><span className="text-right">SCORE</span><span className="text-right">BOND</span><span className="text-right">LOCKED</span>
      </div>
      {payers.map((p) => (
        <div key={p.address} className="grid grid-cols-[1fr_60px_80px_90px_80px] items-center gap-2 border-b border-neutral-800/60 px-4 py-3 text-xs last:border-b-0">
          <a href={`${EXPLORER}/address/${p.address}`} target="_blank" rel="noreferrer" className="font-mono hover:text-[#CCFF00]">{short(p.address, 8)}</a>
          <span className="font-mono font-bold" style={{ color: TIER_COLOR[p.tier] }}>T{p.tier}</span>
          <span className="text-right font-mono" style={{ color: TIER_COLOR[p.tier] }}>{p.score.toFixed(2)}</span>
          <span className="text-right font-mono text-neutral-300">{amount(p.bond)}</span>
          <span className="text-right font-mono text-[#B026FF]">{amount(p.locked)}</span>
        </div>
      ))}
    </div>
  )
}

function ReceiptDetail({ receipt, state }: { receipt?: Receipt; state: PoolState | null }) {
  if (!receipt || !state) {
    return <div className="border border-dashed border-neutral-800 p-10 text-center text-xs text-neutral-500">Select a receipt.</div>
  }
  const settleAt = receipt.blockNumber + state.windowBlocks
  const ready = Number(state.blockNumber) >= settleAt
  const remaining = Math.max(0, settleAt - Number(state.blockNumber))
  const bond = (receipt.notional * BigInt(state.bondRatioBps)) / 10_000n
  const cap = (receipt.notional * BigInt(state.maxChargeBps)) / 10_000n

  return (
    <div className="flex flex-col gap-6">
      <div className="border border-neutral-700 bg-neutral-900 p-5 md:p-8">
        <div className="flex items-start justify-between border-b border-neutral-800 pb-4">
          <div>
            <p className="text-[10px] tracking-[0.2em] text-neutral-500">RECEIPT #{receipt.id}</p>
            <h3 className="mt-2 font-mono text-xl font-bold">{short(receipt.payer, 12)}</h3>
          </div>
          <span className="border px-3 py-1.5 text-[10px] font-bold" style={{ borderColor: TIER_COLOR[receipt.tier], color: TIER_COLOR[receipt.tier] }}>
            T{receipt.tier} · {bps(state.tierFees[receipt.tier])} bps
          </span>
        </div>
        <div className="mt-5 grid grid-cols-2 gap-5 md:grid-cols-4">
          <Field k="NOTIONAL" v={amount(receipt.notional)} />
          <Field k="EXECUTION TICK" v={String(receipt.tickAfter)} />
          <Field k="DIRECTION" v={receipt.zeroForOne ? 'zero → one' : 'one → zero'} />
          <Field k="WRITTEN AT" v={receipt.blockNumber.toLocaleString()} />
          <Field k="BOND LOCKED" v={amount(bond)} tone="#B026FF" />
          <Field k="MOST IT CAN COST" v={amount(cap)} tone="#FF4D4D" />
          <Field k="SETTLEABLE AT" v={settleAt.toLocaleString()} />
          <Field k="STATUS" v={ready ? 'ready to settle' : `${remaining} blocks to go`} tone={ready ? '#CCFF00' : undefined} />
        </div>
      </div>

      <div className="border border-neutral-700 bg-neutral-900 p-5 md:p-8">
        <h3 className="text-[10px] tracking-[0.2em] text-neutral-500 mb-5 border-b border-neutral-800 pb-3">HOW THIS WILL SETTLE</h3>
        <ol className="grid gap-4 text-xs">
          {[
            ['Reference price', `the most adverse tick that printed between block ${receipt.blockNumber.toLocaleString()} and ${settleAt.toLocaleString()} — not the average`],
            ['Realized markout', `notional × (reference ÷ execution − 1), signed by direction`],
            ['Charge', `α = ${state.alphaBps / 10000} of any positive markout, capped at ${state.maxChargeBps / 100}% of notional`],
            ['Split', '80% donated to LPs, 5% to whoever calls settle, 15% to the rebate pool'],
            ['Reputation', 'the normalised markout folds into the payer’s EWMA, which sets their next quote'],
          ].map(([label, detail], i) => (
            <li key={label} className="grid grid-cols-[28px_1fr] gap-3">
              <span className="font-mono text-[10px] text-neutral-600">0{i + 1}</span>
              <span><b className="text-white">{label}.</b> <span className="text-neutral-400">{detail}</span></span>
            </li>
          ))}
        </ol>
        <p className="mt-5 border-l-2 border-[#CCFF00] pl-4 text-[11px] leading-5 text-neutral-400">
          The reference is an extremum rather than a mean because a mean can be undone: a payer could trade back inside
          their own window and settle for nothing, at no cost to themselves. A price that has printed cannot be
          un-printed.
        </p>
      </div>
    </div>
  )
}

function Field({ k, v, tone }: { k: string; v: string; tone?: string }) {
  return (
    <div>
      <p className="font-mono text-[9px] tracking-[0.14em] text-neutral-500">{k}</p>
      <p className="mt-1.5 font-mono text-sm font-bold" style={tone ? { color: tone } : undefined}>{v}</p>
    </div>
  )
}

function LookupPanel({ bondCurrency, tierFees }: { bondCurrency?: Address; tierFees?: number[] }) {
  const [value, setValue] = useState('')
  const [result, setResult] = useState<Awaited<ReturnType<typeof readAddress>> | null>(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState('')

  const look = async () => {
    const a = value.trim()
    if (!/^0x[0-9a-fA-F]{40}$/.test(a)) { setMsg('That is not a 20-byte address.'); setResult(null); return }
    if (!bondCurrency) { setMsg('Still connecting to the chain.'); return }
    setBusy(true); setMsg('')
    try {
      setResult(await readAddress(a as Address, bondCurrency))
    } catch (e) {
      setMsg(e instanceof Error ? e.message : String(e)); setResult(null)
    } finally { setBusy(false) }
  }

  return (
    <div className="w-full border border-neutral-700 bg-neutral-900 p-5 md:p-6 shadow-[0_0_42px_rgba(204,255,0,0.06)] backdrop-blur-md lg:p-7">
      <div className="mb-5 border-b border-neutral-800 pb-4">
        <p className="text-[10px] tracking-[0.2em] text-neutral-500">SCORE REGISTRY</p>
        <h2 className="mt-2 font-mono text-xl md:text-2xl font-bold">What would you pay?</h2>
        <p className="mt-2 text-[11px] leading-5 text-neutral-500">
          Any address, read live. Reputation is shared across every Postmark pool, so a payer carries it with them.
        </p>
      </div>
      <div className="flex flex-col gap-3">
        <input value={value} onChange={(e) => setValue(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && look()}
          placeholder="0x…" spellCheck={false}
          className="border border-neutral-700 bg-neutral-950 p-4 font-mono text-sm outline-none focus:border-[#CCFF00]"
          aria-label="Address to look up" />
        <button type="button" onClick={look} disabled={busy}
          className="bg-[#CCFF00] px-6 py-4 text-xs font-bold tracking-[0.12em] text-neutral-950 transition-transform hover:scale-[1.02] disabled:cursor-wait disabled:opacity-60">
          {busy ? 'READING CHAIN…' : 'LOOK UP →'}
        </button>
        {msg && <p className="text-[11px] text-[#FF4D4D]" role="status">{msg}</p>}

        {result && (
          <div className="mt-2 grid gap-3 border border-neutral-800 bg-neutral-950 p-4">
            <div className="flex items-center justify-between">
              <span className="font-mono text-[11px] text-neutral-500">{short(result.address, 8)}</span>
              <span className="border px-3 py-1 text-[10px] font-bold" style={{ borderColor: TIER_COLOR[result.tier], color: TIER_COLOR[result.tier] }}>
                TIER {result.tier}
              </span>
            </div>
            <p className="font-mono text-3xl font-bold" style={{ color: TIER_COLOR[result.tier] }}>
              {tierFees ? bps(tierFees[result.tier]) : '—'}<span className="text-sm text-neutral-500"> bps</span>
            </p>
            <p className="-mt-2 text-[10px] text-neutral-500">{TIER_NAME[result.tier]}</p>
            <div className="mt-1 grid gap-1.5 border-t border-neutral-800 pt-3 text-[10px]">
              <Row k="EWMA score" v={`${result.score.toFixed(2)} bps`} />
              <Row k="receipts settled" v={String(result.settled)} />
              <Row k="bond posted" v={amount(result.bond)} />
              <Row k="bond locked" v={amount(result.locked)} />
            </div>
            {result.bond === 0n && (
              <p className="text-[10px] leading-4 text-neutral-500">
                No bond posted, so this address is quoted the baseline — exactly what a flat pool would charge it.
                Bonding is the only way down, and it can never push a fee up.
              </p>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
