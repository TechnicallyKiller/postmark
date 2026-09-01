'use client'

import { ADDRESSES, amount, bps, type PoolState, type Receipt } from '@/lib/postmark'

/**
 * Postmark Flow — a port of the `Postmark Flow.dc.html` design canvas.
 *
 * The layout is fixed at the design's 2000px canvas and scrolls horizontally rather than reflowing:
 * a five-node pipeline that wraps stops being a pipeline. Values the live chain can supply (tier
 * fees, the settlement window, the receipt, the head block) are read rather than hardcoded, so the
 * diagram and the Ledger tab can never disagree.
 */

const MONO = "var(--font-ibm-plex-mono), 'IBM Plex Mono', ui-monospace, monospace"
const SANS = "'Helvetica Neue', Helvetica, Arial, sans-serif"

const TIER_ROWS = [
  { t: 'T0', color: '#CCFF00', markout: '0.98 bps', paid: '2.59 bps', ratio: '2.6×' },
  { t: 'T1', color: '#9BE600', markout: '6.41 bps', paid: '11.85 bps', ratio: '1.8×' },
  { t: 'T2', color: '#FFA23A', markout: '14.90 bps', paid: '23.94 bps', ratio: '1.6×' },
  { t: 'T3', color: '#FF4D4D', markout: '39.14 bps', paid: '53.48 bps', ratio: '1.4×' },
]

const TIER_SWATCH = ['#CCFF00', '#9BE600', '#FFA23A', '#FF4D4D']

export default function FlowDiagram({ state }: { state: PoolState | null }) {
  const fees = state?.tierFees ?? [200, 800, 1500, 3000]
  const windowBlocks = state?.windowBlocks ?? 100
  const receipt: Receipt | undefined = state?.receipts.find((r) => !r.settled)

  return (
    <div className="overflow-x-auto">
      <div style={{ width: 2000, background: '#0a0a0a', color: '#e5e5e5', padding: '56px 64px 64px', fontFamily: SANS, boxSizing: 'border-box', textWrap: 'pretty' }}>

        {/* masthead */}
        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', borderBottom: '1px solid #262626', paddingBottom: 20, marginBottom: 44 }}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 22 }}>
            <div style={{ fontFamily: MONO, fontSize: 34, fontWeight: 600, letterSpacing: '0.14em', color: '#ffffff' }}>POSTMARK</div>
            <div style={{ fontSize: 17, color: '#a3a3a3', maxWidth: 640, lineHeight: 1.4 }}>
              A Uniswap v4 hook that charges a low fee up front and bills the adverse selection afterwards — to the counterparty who caused it.
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6, alignItems: 'flex-end' }}>
              <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.22em', color: '#737373' }}>HOOK</div>
              <div style={{ fontFamily: MONO, fontSize: 13, color: '#d4d4d4' }}>{ADDRESSES.hook}</div>
            </div>
            <div style={{ border: '1px solid #CCFF00', color: '#CCFF00', fontFamily: MONO, fontSize: 11, letterSpacing: '0.16em', padding: '8px 12px' }}>
              {state ? `LIVE · BLOCK ${state.blockNumber.toLocaleString()}` : 'LIVE · UNICHAIN SEPOLIA'}
            </div>
          </div>
        </div>

        {/* pipeline */}
        <div style={{ position: 'relative', width: 1872, height: 730 }}>
          <div style={{ position: 'absolute', top: 0, left: 0, display: 'flex', alignItems: 'flex-start', gap: 0 }}>

            <Node width={240} label="NODE 01 · INGRESS">
              <div style={{ fontFamily: MONO, fontSize: 20, fontWeight: 600, color: '#ffffff', letterSpacing: '0.04em', lineHeight: 1.25 }}>SWAP<br />ARRIVES</div>
              <Body style={{ marginTop: 16 }}>A trader swaps. They may or may not have posted a bond.</Body>
              <div style={{ marginTop: 'auto', display: 'flex', flexDirection: 'column', gap: 8 }}>
                <Chip left="BONDED" right="TIER 0–2" tone="#CCFF00" />
                <Chip left="UNBONDED" right="TIER 3" tone="#FF4D4D" />
              </div>
            </Node>

            <Arrow />

            <Node width={330} label="NODE 02 · HOOK CALLBACK">
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
                <div style={{ fontFamily: MONO, fontSize: 20, fontWeight: 600, color: '#CCFF00' }}>beforeSwap</div>
                <div style={{ fontFamily: MONO, fontSize: 13, letterSpacing: '0.18em', color: '#ffffff' }}>QUOTE</div>
              </div>
              <Body style={{ marginTop: 12 }}>Reads the payer&apos;s posted bond and reputation score, then quotes a fee.</Body>
              <div style={{ marginTop: 18, display: 'flex', flexDirection: 'column', gap: 1, background: '#262626', border: '1px solid #262626' }}>
                {fees.map((fee, t) => (
                  <div key={t} style={{ display: 'grid', gridTemplateColumns: '12px 1fr auto', alignItems: 'center', gap: 12, background: '#0a0a0a', padding: '10px 12px' }}>
                    <div style={{ width: 8, height: 8, background: TIER_SWATCH[t] }} />
                    <div style={{ fontFamily: MONO, fontSize: 13, color: '#e5e5e5' }}>
                      TIER {t}{t === 3 && <span style={{ color: '#737373', letterSpacing: '0.06em' }}> · UNBONDED</span>}
                    </div>
                    <div style={{ fontFamily: MONO, fontSize: 14, color: TIER_SWATCH[t] }}>{bps(fee)} bps</div>
                  </div>
                ))}
              </div>
              <div style={{ fontSize: 13, color: '#737373', lineHeight: 1.45, marginTop: 12 }}>
                Tier 3 is what a normal pool charges <em style={{ color: '#a3a3a3', fontStyle: 'normal' }}>everyone</em>.
              </div>
              <Footer tone="#CCFF00">THIS NODE NEVER REJECTS A SWAP</Footer>
            </Node>

            <Arrow />

            <Node width={330} label="NODE 03 · HOOK CALLBACK">
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
                <div style={{ fontFamily: MONO, fontSize: 20, fontWeight: 600, color: '#CCFF00' }}>afterSwap</div>
                <div style={{ fontFamily: MONO, fontSize: 13, letterSpacing: '0.18em', color: '#ffffff' }}>RECEIPT</div>
              </div>
              <Body style={{ marginTop: 12 }}>
                Locks <span style={{ fontFamily: MONO, color: '#ffffff' }}>{(state?.bondRatioBps ?? 200) / 100}%</span> of notional as bond and writes a receipt.
              </Body>
              <div style={{ marginTop: 18, border: '1px solid #262626', background: '#0a0a0a' }}>
                <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.2em', color: '#737373', padding: '9px 12px', borderBottom: '1px solid #262626' }}>RECEIPT · LIVE POOL</div>
                <div style={{ display: 'flex', flexDirection: 'column' }}>
                  <KV k="payer" v={receipt ? `${receipt.payer.slice(0, 8)}…${receipt.payer.slice(-4)}` : '—'} />
                  <KV k="notional" v={receipt ? amount(receipt.notional) : '—'} />
                  <KV k="exec tick" v={receipt ? String(receipt.tickAfter) : '—'} />
                  <KV k="block" v={receipt ? receipt.blockNumber.toLocaleString() : '—'} />
                </div>
              </div>
              <Footer tone="#262626" color="#737373">SUB-DUST SWAPS SKIPPED</Footer>
            </Node>

            <Arrow />

            <div style={{ width: 200, height: 420, boxSizing: 'border-box', border: '1px dashed #404040', background: '#0a0a0a', padding: 20, display: 'flex', flexDirection: 'column' }}>
              <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.22em', color: '#737373', marginBottom: 18 }}>NODE 04 · DELAY</div>
              <div style={{ fontFamily: MONO, fontSize: 15, letterSpacing: '0.16em', color: '#ffffff' }}>WAIT</div>
              <div style={{ fontFamily: MONO, fontSize: 52, fontWeight: 600, color: '#ffffff', lineHeight: 1, marginTop: 10 }}>{windowBlocks}</div>
              <div style={{ fontFamily: MONO, fontSize: 12, letterSpacing: '0.2em', color: '#737373', marginTop: 6 }}>BLOCKS</div>
              <div style={{ display: 'flex', gap: 3, marginTop: 18 }}>
                {Array.from({ length: 12 }, (_, i) => (
                  <div key={i} style={{ width: 2, height: 22, background: i < 9 ? '#262626' : '#404040' }} />
                ))}
              </div>
              <div style={{ fontSize: 13, color: '#a3a3a3', lineHeight: 1.5, marginTop: 18 }}>≈ 20 minutes on mainnet.</div>
              <div style={{ marginTop: 'auto', fontSize: 13, color: '#d4d4d4', lineHeight: 1.5, borderTop: '1px solid #262626', paddingTop: 12 }}>
                You cannot know who was informed until the price has told you.
              </div>
            </div>

            <Arrow />

            {/* node 05 — deliberately the heaviest thing on the canvas */}
            <div style={{ width: 564, height: 560, boxSizing: 'border-box', border: '2px solid #CCFF00', background: '#101010', padding: 24, display: 'flex', flexDirection: 'column' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 18 }}>
                <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.22em', color: '#CCFF00' }}>NODE 05 · SETTLEMENT</div>
                <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.16em', color: '#0a0a0a', background: '#CCFF00', padding: '5px 9px' }}>PERMISSIONLESS · CALLABLE BY ANYONE</div>
              </div>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 12 }}>
                <div style={{ fontFamily: MONO, fontSize: 30, fontWeight: 600, color: '#CCFF00' }}>settle</div>
                <div style={{ fontFamily: MONO, fontSize: 20, letterSpacing: '0.16em', color: '#ffffff' }}>THE BILL</div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr auto 1fr', alignItems: 'stretch', marginTop: 20, border: '1px solid #262626' }}>
                <div style={{ padding: 14, background: '#0a0a0a' }}>
                  <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.2em', color: '#737373' }}>MOST ADVERSE PRICE THAT PRINTED</div>
                  <div style={{ fontFamily: MONO, fontSize: 15, color: '#B026FF', marginTop: 8 }}>extremum, not average</div>
                </div>
                <div style={{ width: 44, display: 'flex', alignItems: 'center', justifyContent: 'center', background: '#0a0a0a', borderLeft: '1px solid #262626', borderRight: '1px solid #262626', fontFamily: MONO, fontSize: 18, color: '#737373' }}>−</div>
                <div style={{ padding: 14, background: '#0a0a0a' }}>
                  <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.2em', color: '#737373' }}>EXECUTION PRICE</div>
                  <div style={{ fontFamily: MONO, fontSize: 15, color: '#e5e5e5', marginTop: 8 }}>from the receipt</div>
                </div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginTop: 16 }}>
                <div style={{ fontFamily: MONO, fontSize: 11, letterSpacing: '0.2em', color: '#737373' }}>= REALIZED MARKOUT</div>
                <div style={{ flex: 1, height: 1, background: '#262626' }} />
              </div>
              <div style={{ display: 'flex', gap: 1, background: '#262626', border: '1px solid #262626', marginTop: 16 }}>
                <Cell k="CHARGE" v={`${(state?.alphaBps ?? 6000) / 10000} × markout`} />
                <Cell k="CAP" v={`${(state?.maxChargeBps ?? 100) / 100}% notional`} />
                <Cell k="DEBITED FROM" v="locked bond" />
              </div>
              <div style={{ marginTop: 'auto', paddingTop: 20 }}>
                <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.22em', color: '#737373', marginBottom: 10 }}>CHARGE SPLITS THREE WAYS</div>
                <div style={{ display: 'flex', height: 26, gap: 1 }}>
                  <div style={{ flex: 80, background: '#CCFF00' }} />
                  <div style={{ flex: 5, background: '#ffffff' }} />
                  <div style={{ flex: 15, background: '#B026FF' }} />
                </div>
                <div style={{ display: 'flex', gap: 1, marginTop: 10 }}>
                  <Split flex={80} pct="80%" label="TO LPs" tone="#CCFF00" />
                  <Split flex={5} pct="5%" label="TO CALLER" tone="#ffffff" minWidth={96} />
                  <Split flex={15} pct="15%" label="REBATE POOL · PAYS BENIGN TRADERS BACK" tone="#B026FF" minWidth={150} />
                </div>
              </div>
            </div>
          </div>

          {/* the loop that closes the system */}
          <svg width="1872" height="730" viewBox="0 0 1872 730" style={{ position: 'absolute', top: 0, left: 0, pointerEvents: 'none', overflow: 'visible' }}>
            <polyline points="1590,562 1590,672 457,672 457,438" fill="none" stroke="#B026FF" strokeWidth="2" strokeDasharray="7 6" />
            <polygon points="457,424 449,442 465,442" fill="#B026FF" />
            <circle cx="1590" cy="562" r="4" fill="#B026FF" />
          </svg>
          <div style={{ position: 'absolute', left: 828, top: 654, background: '#0a0a0a', padding: '0 14px', display: 'flex', alignItems: 'center', gap: 10 }}>
            <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.22em', color: '#B026FF' }}>FEEDBACK</div>
            <div style={{ fontFamily: MONO, fontSize: 15, color: '#ffffff', letterSpacing: '0.02em' }}>reputation updates the next quote</div>
          </div>
        </div>

        {/* measured results */}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 400px', gap: 24, marginTop: 36, alignItems: 'start' }}>
          <div style={{ border: '1px solid #262626', background: '#0d0d0d' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', padding: '16px 20px', borderBottom: '1px solid #262626' }}>
              <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.22em', color: '#737373' }}>MEASURED · 3,465 REAL MAINNET USDC/WETH SWAPS</div>
              <div style={{ fontFamily: MONO, fontSize: 13, color: '#CCFF00' }}>LP PnL 2.06× a flat 30 bps pool on identical flow</div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr 1fr 1fr', padding: '12px 20px', borderBottom: '1px solid #262626', fontFamily: MONO, fontSize: 10, letterSpacing: '0.2em', color: '#737373' }}>
              <div>TIER</div><div>REALIZED MARKOUT</div><div>FEE PAID</div><div>RATIO</div>
            </div>
            {TIER_ROWS.map((r, i) => (
              <div key={r.t} style={{ display: 'grid', gridTemplateColumns: '140px 1fr 1fr 1fr', alignItems: 'center', padding: '13px 20px', borderBottom: `1px solid ${i === TIER_ROWS.length - 1 ? '#262626' : '#171717'}`, fontFamily: MONO, fontSize: 15 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10, color: r.color }}>
                  <span style={{ width: 8, height: 8, background: r.color, display: 'inline-block' }} />{r.t}
                </div>
                <div style={{ color: '#e5e5e5' }}>{r.markout}</div>
                <div style={{ color: '#e5e5e5' }}>{r.paid}</div>
                <div style={{ color: '#737373' }}>{r.ratio}</div>
              </div>
            ))}
            <div style={{ display: 'flex', gap: 32, padding: '14px 20px', fontFamily: MONO, fontSize: 13, color: '#a3a3a3' }}>
              <div style={{ letterSpacing: '0.16em', fontSize: 10, color: '#737373', alignSelf: 'center' }}>HOOK GAS ON CHAIN</div>
              <div>+36,328 <span style={{ color: '#737373' }}>quote only</span></div>
              <div>+98,209 <span style={{ color: '#737373' }}>receipt written</span></div>
            </div>
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
            <Callout title="NO ORACLE">No oracle anywhere in this loop. Every input is a price the pool itself already printed.</Callout>
            <Callout title="SELF-ENFORCING">
              The bond <span style={{ fontFamily: MONO, color: '#ffffff' }}>({(state?.bondRatioBps ?? 200) / 100}%)</span> is always twice the maximum charge{' '}
              <span style={{ fontFamily: MONO, color: '#ffffff' }}>({(state?.maxChargeBps ?? 100) / 100}%)</span>, so walking away costs more than paying. Settlement enforces itself.
            </Callout>
          </div>
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------

function Node({ width, label, children }: { width: number; label: string; children: React.ReactNode }) {
  return (
    <div style={{ width, height: 420, boxSizing: 'border-box', border: '1px solid #262626', background: '#0d0d0d', padding: 20, display: 'flex', flexDirection: 'column' }}>
      <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.22em', color: '#737373', marginBottom: 18 }}>{label}</div>
      {children}
    </div>
  )
}

function Arrow() {
  return (
    <div style={{ width: 52, height: 420, display: 'flex', alignItems: 'center' }}>
      <div style={{ flex: 1, height: 1, background: '#CCFF00', opacity: 0.55 }} />
      <div style={{ width: 0, height: 0, borderLeft: '8px solid #CCFF00', borderTop: '5px solid transparent', borderBottom: '5px solid transparent' }} />
    </div>
  )
}

function Body({ children, style }: { children: React.ReactNode; style?: React.CSSProperties }) {
  return <div style={{ fontSize: 14, color: '#a3a3a3', lineHeight: 1.5, ...style }}>{children}</div>
}

function Chip({ left, right, tone }: { left: string; right: string; tone: string }) {
  return (
    <div style={{ border: '1px solid #262626', padding: '9px 10px', fontFamily: MONO, fontSize: 11, letterSpacing: '0.1em', color: '#d4d4d4', display: 'flex', justifyContent: 'space-between' }}>
      <span>{left}</span><span style={{ color: tone }}>{right}</span>
    </div>
  )
}

function Footer({ children, tone, color }: { children: React.ReactNode; tone: string; color?: string }) {
  return (
    <div style={{ marginTop: 'auto', border: `1px solid ${tone}`, color: color ?? tone, fontFamily: MONO, fontSize: 11, letterSpacing: '0.15em', padding: '10px 12px', textAlign: 'center' }}>
      {children}
    </div>
  )
}

function KV({ k, v }: { k: string; v: string }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, padding: '8px 12px', fontFamily: MONO, fontSize: 12 }}>
      <span style={{ color: '#737373' }}>{k}</span><span style={{ color: '#e5e5e5' }}>{v}</span>
    </div>
  )
}

function Cell({ k, v }: { k: string; v: string }) {
  return (
    <div style={{ flex: 1, background: '#0a0a0a', padding: '13px 14px' }}>
      <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.2em', color: '#737373' }}>{k}</div>
      <div style={{ fontFamily: MONO, fontSize: 20, color: '#ffffff', marginTop: 7 }}>{v}</div>
    </div>
  )
}

function Split({ flex, pct, label, tone, minWidth }: { flex: number; pct: string; label: string; tone: string; minWidth?: number }) {
  return (
    <div style={{ flex, minWidth }}>
      <div style={{ fontFamily: MONO, fontSize: 17, color: tone }}>{pct}</div>
      <div style={{ fontFamily: MONO, fontSize: 11, letterSpacing: '0.12em', color: '#a3a3a3', marginTop: 4 }}>{label}</div>
    </div>
  )
}

function Callout({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={{ borderTop: '1px solid #B026FF', background: '#0d0d0d', padding: '18px 20px' }}>
      <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: '0.22em', color: '#B026FF', marginBottom: 10 }}>{title}</div>
      <div style={{ fontSize: 15, color: '#d4d4d4', lineHeight: 1.5 }}>{children}</div>
    </div>
  )
}
