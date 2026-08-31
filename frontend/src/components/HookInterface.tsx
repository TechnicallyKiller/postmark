'use client'

import { motion, AnimatePresence } from 'framer-motion'
import { useState } from 'react'

const connectionPaths = [
  'M 8 74 C 28 52, 38 48, 54 34 S 78 18, 96 22',
  'M 18 88 C 42 72, 54 70, 69 53 S 88 36, 100 40',
  'M 3 38 C 24 42, 31 30, 48 28 S 73 50, 98 62',
]

const cardTransition = { duration: 0.45, ease: 'easeOut' as const }
const tabVariants = {
  initial: { opacity: 0, y: 10 },
  animate: { opacity: 1, y: 0 },
  exit: { opacity: 0, y: -10, transition: { duration: 0.2 } }
}

export default function HookInterface() {
  const [activeTab, setActiveTab] = useState<'Dashboard' | 'Policy Engine' | 'Analytics'>('Dashboard')
  
  // Dashboard State
  const [payAmount, setPayAmount] = useState('1,432.50')
  const [receiveAmount, setReceiveAmount] = useState('3,507,412.25')
  const [isExpanded, setIsExpanded] = useState(false)
  const [dynamicPricing, setDynamicPricing] = useState(true)
  const [autoRebalance, setAutoRebalance] = useState(false)
  const [isSwapping, setIsSwapping] = useState(false)
  const [message, setMessage] = useState('')

  // Policy Engine State
  const [feeGuard, setFeeGuard] = useState(true)
  const [volatilityCircuit, setVolatilityCircuit] = useState(false)
  const [whitelistOnly, setWhitelistOnly] = useState(false)

  const handleSwap = () => {
    setIsSwapping(true)
    setMessage('')
    window.setTimeout(() => {
      setIsSwapping(false)
      setMessage('Quote refreshed. No wallet is connected in this visual demo.')
    }, 800)
  }

  const switchTokens = () => {
    setPayAmount(receiveAmount)
    setReceiveAmount(payAmount)
  }

  const tabs = ['Dashboard', 'Policy Engine', 'Analytics'] as const;

  return (
    <main className="min-h-screen flex flex-col bg-neutral-950 text-white overflow-hidden">
      <nav className="relative z-10 border-b border-neutral-800 px-4 py-4 md:px-6 md:py-5 lg:px-10">
        <div className="mx-auto flex max-w-7xl items-center justify-between">
          <a href="#swap" className="flex items-center gap-3" aria-label="UHI10 Hook home">
            <span className="grid size-10 place-items-center border border-neutral-700 bg-neutral-900 text-lg font-bold text-[#CCFF00]">U10</span>
            <span className="hidden sm:block"><strong className="block text-sm tracking-[0.18em]">UHI10</strong><small className="block text-[9px] tracking-[0.16em] text-neutral-500">HOOK ORCHESTRATION</small></span>
          </a>
          <div className="flex space-x-2 md:space-x-8">
            {tabs.map((tab) => (
              <button
                key={tab}
                onClick={() => setActiveTab(tab)}
                className={`relative px-2 py-2 text-[11px] md:text-sm font-bold tracking-widest transition-colors ${activeTab === tab ? 'text-white' : 'text-neutral-500 hover:text-neutral-300'}`}
              >
                {tab.toUpperCase()}
                {activeTab === tab && (
                  <motion.div layoutId="activeTabIndicator" className="absolute bottom-0 left-0 right-0 h-0.5 bg-[#CCFF00]" />
                )}
              </button>
            ))}
          </div>
          <a href="#swap" className="hidden sm:inline-block border border-[#CCFF00] bg-[#CCFF00] px-5 py-3 text-sm font-bold text-neutral-950 transition-transform hover:scale-[1.02]">Launch app <span aria-hidden="true">→</span></a>
        </div>
      </nav>

      <div className="relative flex-1 mx-auto w-full max-w-7xl px-4 py-8 md:px-6 md:py-16 lg:px-10 lg:py-24">
        <svg className="hidden md:block pointer-events-none absolute inset-0 h-full w-full opacity-70" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
          {connectionPaths.map((path, index) => <motion.path key={path} d={path} fill="none" stroke={index % 2 ? '#B026FF' : '#CCFF00'} strokeWidth="0.22" strokeDasharray="1 1" initial={{ pathLength: 0, opacity: 0 }} animate={{ pathLength: 1, opacity: 0.8 }} transition={{ duration: 1.5, delay: index * 0.25 }} />)}
        </svg>

        <AnimatePresence mode="wait">
          {activeTab === 'Dashboard' && (
            <motion.div key="Dashboard" variants={tabVariants} initial="initial" animate="animate" exit="exit" className="relative grid items-center gap-12 grid-cols-1 lg:grid-cols-[1fr_500px] lg:gap-24">
              <section id="how-it-works" className="max-w-2xl">
                <p className="mb-4 lg:mb-7 inline-flex border border-[#B026FF] bg-[#B026FF]/10 px-3 py-1 text-[10px] font-bold tracking-[0.18em] text-[#CCFF00]">ACTIVE HOOK · UHI10-0872</p>
                <h1 className="font-mono text-4xl md:text-5xl font-bold leading-[0.98] tracking-[-0.06em] lg:text-7xl">Programmable liquidity, <span className="text-[#CCFF00]">without guesswork.</span></h1>
                <p className="mt-6 md:mt-8 max-w-xl text-sm md:text-base leading-7 text-neutral-400">Route a visual swap through a Uniswap v4 hook with policy-aware fees, price protection, and liquidity controls. Every setting below is mocked locally with React state.</p>
                <div className="mt-8 flex flex-col sm:flex-row gap-4"><a href="#swap" className="bg-[#CCFF00] px-6 py-4 text-center text-sm font-bold text-neutral-950 transition-transform hover:scale-[1.02]">Configure a swap →</a><button onClick={() => setActiveTab('Policy Engine')} className="border border-neutral-700 px-6 py-4 text-sm font-bold text-white transition-colors hover:border-[#B026FF]">View hook policies</button></div>
                <div className="mt-12 grid max-w-xl grid-cols-3 border border-neutral-800 bg-neutral-900/70"><div className="p-4 md:p-5"><p className="font-mono text-xl md:text-2xl font-bold text-[#CCFF00]">12</p><p className="mt-2 text-[9px] md:text-[10px] tracking-[0.14em] text-neutral-500">POOLS ACTIVE</p></div><div className="border-x border-neutral-800 p-4 md:p-5"><p className="font-mono text-xl md:text-2xl font-bold">$8.4M</p><p className="mt-2 text-[9px] md:text-[10px] tracking-[0.14em] text-neutral-500">TVL SECURED</p></div><div className="p-4 md:p-5"><p className="font-mono text-xl md:text-2xl font-bold text-[#B026FF]">0.05%</p><p className="mt-2 text-[9px] md:text-[10px] tracking-[0.14em] text-neutral-500">FEE TIER</p></div></div>
              </section>

              <div className="relative w-full max-w-md mx-auto lg:max-w-none" id="swap">
                <div className="absolute -right-4 -top-10 hidden w-56 border border-neutral-700 bg-neutral-900/90 p-5 shadow-[0_0_36px_rgba(176,38,255,0.16)] lg:block"><p className="text-[10px] tracking-[0.18em] text-neutral-500">ACTIVE POLICIES</p><p className="mt-3 text-sm font-bold">Fee guard <span className="float-right text-[#CCFF00]">ON</span></p><p className="mt-2 text-sm font-bold">Slippage cap <span className="float-right text-[#B026FF]">0.50%</span></p></div>
                <div className="border border-neutral-700 bg-neutral-900/90 p-5 md:p-6 shadow-[0_0_42px_rgba(204,255,0,0.1)] backdrop-blur-md lg:p-8">
                  <div className="mb-6 flex items-start justify-between border-b border-neutral-800 pb-4 md:mb-7 md:pb-5"><div><p className="text-[10px] tracking-[0.2em] text-neutral-500">UHI10 ROUTER</p><h2 className="mt-2 font-mono text-xl md:text-2xl font-bold">Build a swap</h2></div><span className="border border-[#CCFF00] px-2 py-1 text-[9px] md:text-[10px] font-bold text-[#CCFF00]">MOCKED</span></div>
                  <div className="flex flex-col gap-4">
                    <label className="border border-neutral-700 bg-neutral-950 p-4 md:p-5"><span className="flex justify-between text-[10px] md:text-xs text-neutral-500"><b className="text-white">Pay</b><span>Balance 5,234.00 ETH</span></span><span className="mt-4 md:mt-5 flex items-center gap-3"><input value={payAmount} onChange={(event) => setPayAmount(event.target.value)} className="min-w-0 flex-1 bg-transparent font-mono text-2xl md:text-3xl font-bold outline-none" aria-label="Pay amount in ETH" /><b>ETH</b></span></label>
                    <button type="button" onClick={switchTokens} className="mx-auto border border-neutral-700 bg-neutral-900 px-4 py-2 text-[9px] md:text-[10px] font-bold tracking-[0.12em] text-neutral-300 transition-transform hover:scale-[1.02]" aria-label="Switch pay and receive tokens">SWITCH TOKENS</button>
                    <label className="border border-neutral-700 bg-neutral-950 p-4 md:p-5"><span className="flex justify-between text-[10px] md:text-xs text-neutral-500"><b className="text-white">Receive</b><span>Estimated output</span></span><span className="mt-4 md:mt-5 flex items-center gap-3"><input value={receiveAmount} onChange={(event) => setReceiveAmount(event.target.value)} className="min-w-0 flex-1 bg-transparent font-mono text-2xl md:text-3xl font-bold outline-none" aria-label="Receive amount in USDC" /><b>USDC</b></span></label>
                    <div className="grid gap-2 border border-neutral-800 bg-neutral-900/70 p-4 md:p-5 text-[10px] md:text-xs"><div className="flex justify-between"><span className="text-neutral-500">Exchange rate</span><b>1 ETH = 2,450.50 USDC</b></div><div className="flex justify-between"><span className="text-neutral-500">Fee tier</span><b className="text-[#CCFF00]">0.05% Fee Tier</b></div><div className="flex justify-between"><span className="text-neutral-500">Minimum received</span><b>3,489,875.18 USDC</b></div></div>
                    <button type="button" onClick={handleSwap} disabled={isSwapping} className="mt-2 bg-[#CCFF00] px-6 py-4 md:py-5 text-xs md:text-sm font-bold tracking-[0.12em] text-neutral-950 transition-transform hover:scale-[1.02] disabled:cursor-wait disabled:opacity-60">{isSwapping ? 'UPDATING QUOTE...' : 'REVIEW SWAP →'}</button>
                    {message && <p className="text-center text-[10px] md:text-xs text-neutral-400" role="status">{message}</p>}
                    <div id="dashboard-policies" className="border-t border-neutral-800 pt-5"><button type="button" onClick={() => setIsExpanded(!isExpanded)} className="flex w-full items-center justify-between text-left text-[10px] md:text-xs font-bold tracking-[0.12em]" aria-expanded={isExpanded} aria-controls="hook-parameters"><span>UHI10 HOOK PARAMETERS</span><span className="text-lg text-[#B026FF]">{isExpanded ? '−' : '+'}</span></button>{isExpanded && <div id="hook-parameters" className="mt-4 md:mt-5 grid gap-4 border border-neutral-700 bg-neutral-950 p-4 md:p-5"><p className="text-[10px] md:text-xs leading-5 text-neutral-500">Configure local policies for this mock route. No transaction will be submitted.</p><Toggle label="Dynamic pricing" detail="Adjust fees with pool volatility." enabled={dynamicPricing} onToggle={() => setDynamicPricing(!dynamicPricing)} /><Toggle label="Auto-rebalance" detail="Recenter liquidity after execution." enabled={autoRebalance} onToggle={() => setAutoRebalance(!autoRebalance)} /><label className="grid gap-2 text-[10px] md:text-xs font-bold">Price impact tolerance <input type="range" defaultValue="50" className="accent-[#B026FF]" /><span className="font-normal text-neutral-500">0.50% maximum impact</span></label></div>}</div>
                  </div>
                </div>
              </div>
            </motion.div>
          )}

          {activeTab === 'Policy Engine' && (
            <motion.div key="Policy Engine" variants={tabVariants} initial="initial" animate="animate" exit="exit" className="grid grid-cols-1 lg:grid-cols-2 gap-8 lg:gap-16">
              <div className="flex flex-col gap-6 md:gap-8">
                <div>
                  <h2 className="font-mono text-3xl font-bold lg:text-5xl">Engine Configuration</h2>
                  <p className="mt-3 md:mt-4 text-xs md:text-sm text-neutral-400">Manage real-time hook parameters for UHI10-0872.</p>
                </div>
                <div className="border border-neutral-700 bg-neutral-900/90 p-5 md:p-8">
                  <h3 className="text-[10px] tracking-[0.2em] text-neutral-500 mb-4 md:mb-6 border-b border-neutral-800 pb-3 md:pb-4">GLOBAL POLICIES</h3>
                  <div className="grid gap-5 md:gap-6">
                    <Toggle label="Dynamic Fee Guard" detail="Automatically adjust baseline fee tier based on current network volatility and block space demand." enabled={feeGuard} onToggle={() => setFeeGuard(!feeGuard)} />
                    <Toggle label="Volatility Circuit Breaker" detail="Halt trading if price moves > 5% within a single block." enabled={volatilityCircuit} onToggle={() => setVolatilityCircuit(!volatilityCircuit)} />
                    <Toggle label="Whitelist Execution" detail="Restrict swaps to approved addresses and verified MEV searchers." enabled={whitelistOnly} onToggle={() => setWhitelistOnly(!whitelistOnly)} />
                  </div>
                </div>
              </div>
              <div className="flex flex-col gap-6 md:gap-8">
                <div className="border border-neutral-700 bg-neutral-900/90 p-5 md:p-8">
                  <h3 className="text-[10px] tracking-[0.2em] text-neutral-500 mb-4 md:mb-6 border-b border-neutral-800 pb-3 md:pb-4">FEE TIERS (MOCKED)</h3>
                  <div className="grid gap-3 md:gap-4">
                    <div className="flex justify-between items-center bg-neutral-950 border border-neutral-800 p-3 md:p-4">
                      <span className="font-mono text-[10px] md:text-sm">Tier 1 (Whale)</span>
                      <span className="text-[#CCFF00] font-bold text-[10px] md:text-sm">0.01%</span>
                    </div>
                    <div className="flex justify-between items-center bg-neutral-950 border border-neutral-800 p-3 md:p-4">
                      <span className="font-mono text-[10px] md:text-sm">Tier 2 (Standard)</span>
                      <span className="text-[#B026FF] font-bold text-[10px] md:text-sm">0.05%</span>
                    </div>
                    <div className="flex justify-between items-center bg-neutral-950 border border-neutral-800 p-3 md:p-4 opacity-50">
                      <span className="font-mono text-[10px] md:text-sm">Tier 3 (Retail)</span>
                      <span className="text-white font-bold text-[10px] md:text-sm">0.15%</span>
                    </div>
                  </div>
                </div>
                <div className="border border-neutral-700 bg-neutral-900/90 p-5 md:p-8">
                  <h3 className="text-[10px] tracking-[0.2em] text-neutral-500 mb-4 md:mb-6 border-b border-neutral-800 pb-3 md:pb-4">SIMULATION LOGS</h3>
                  <div className="font-mono text-[9px] md:text-[10px] text-neutral-500 grid gap-2">
                    <p>[14:32:01] <span className="text-[#CCFF00]">SUCCESS</span> Policy matrix validated.</p>
                    <p>[14:32:05] <span className="text-white">INFO</span> Fee guard monitoring active.</p>
                    <p>[14:35:12] <span className="text-white">INFO</span> Volatility index at 0.02.</p>
                    <p>[14:41:20] <span className="text-[#B026FF]">UPDATE</span> Rebalance threshold adjusted.</p>
                  </div>
                </div>
              </div>
            </motion.div>
          )}

          {activeTab === 'Analytics' && (
            <motion.div key="Analytics" variants={tabVariants} initial="initial" animate="animate" exit="exit" className="flex flex-col gap-6 md:gap-8 lg:gap-12">
              <div className="flex flex-col gap-3 md:gap-4 text-center items-center justify-center py-4 md:py-8">
                <h2 className="font-mono text-3xl font-bold lg:text-5xl">Liquidity Analytics</h2>
                <p className="text-[10px] md:text-sm text-neutral-400 max-w-lg">Simulated historical performance and current utilization metrics across active UHI10 hooks.</p>
              </div>
              <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 md:gap-4">
                <div className="border border-neutral-800 bg-neutral-900/70 p-4 md:p-5 text-center">
                  <p className="text-[9px] md:text-[10px] tracking-[0.14em] text-neutral-500 mb-2">24H VOLUME</p>
                  <p className="font-mono text-lg md:text-3xl font-bold text-white">$142.5M</p>
                  <p className="text-[9px] md:text-[10px] text-[#CCFF00] mt-1 md:mt-2">+12.4%</p>
                </div>
                <div className="border border-neutral-800 bg-neutral-900/70 p-4 md:p-5 text-center">
                  <p className="text-[9px] md:text-[10px] tracking-[0.14em] text-neutral-500 mb-2">FEES GENERATED</p>
                  <p className="font-mono text-lg md:text-3xl font-bold text-[#CCFF00]">$71,250</p>
                  <p className="text-[9px] md:text-[10px] text-neutral-400 mt-1 md:mt-2">Avg 5 bps</p>
                </div>
                <div className="border border-neutral-800 bg-neutral-900/70 p-4 md:p-5 text-center">
                  <p className="text-[9px] md:text-[10px] tracking-[0.14em] text-neutral-500 mb-2">ACTIVE LP'S</p>
                  <p className="font-mono text-lg md:text-3xl font-bold text-white">1,402</p>
                  <p className="text-[9px] md:text-[10px] text-[#B026FF] mt-1 md:mt-2">-4.2%</p>
                </div>
                <div className="border border-neutral-800 bg-neutral-900/70 p-4 md:p-5 text-center">
                  <p className="text-[9px] md:text-[10px] tracking-[0.14em] text-neutral-500 mb-2">IMPERMANENT LOSS</p>
                  <p className="font-mono text-lg md:text-3xl font-bold text-white">0.8%</p>
                  <p className="text-[9px] md:text-[10px] text-[#CCFF00] mt-1 md:mt-2">Protected by hook</p>
                </div>
              </div>
              <div className="border border-neutral-800 bg-neutral-900/70 p-4 md:p-10 min-h-[250px] md:min-h-[300px] flex flex-col justify-between relative overflow-hidden">
                <h3 className="text-[10px] tracking-[0.2em] text-neutral-500 mb-6 md:mb-8 relative z-10">SIMULATED VOLUME CHART (7D)</h3>
                <div className="flex items-end justify-between h-32 md:h-48 gap-1 md:gap-2 relative z-10">
                   {[40, 60, 30, 80, 50, 90, 70, 40, 85, 65, 50, 75, 45, 100].map((h, i) => (
                      <div key={i} className="flex-1 bg-neutral-800 hover:bg-[#B026FF] transition-colors relative group" style={{ height: `${h}%` }}>
                        <div className="absolute -top-6 md:-top-8 left-1/2 -translate-x-1/2 opacity-0 group-hover:opacity-100 transition-opacity bg-neutral-950 border border-neutral-700 text-[8px] md:text-[9px] py-1 px-2 pointer-events-none text-white whitespace-nowrap">
                          ${(h * 1.5).toFixed(1)}M
                        </div>
                      </div>
                   ))}
                </div>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
      <footer className="border-t border-neutral-800 px-6 py-6 text-center text-[10px] tracking-[0.16em] text-neutral-500">UHI10 HOOK INTERFACE · PURE REACT VISUAL PROTOTYPE · NO WALLET OR CONTRACT CONNECTION</footer>
    </main>
  )
}

function Toggle({ label, detail, enabled, onToggle }: { label: string; detail: string; enabled: boolean; onToggle: () => void }) {
  return <div className="flex items-center justify-between gap-4"><div><p className="text-[10px] md:text-xs font-bold">{label}</p><p className="mt-1 text-[9px] md:text-[11px] text-neutral-500">{detail}</p></div><button type="button" role="switch" aria-checked={enabled} onClick={onToggle} className={`border px-3 py-2 text-[9px] md:text-[10px] font-bold transition-colors ${enabled ? 'border-[#CCFF00] bg-[#CCFF00] text-neutral-950' : 'border-neutral-700 bg-neutral-900 text-neutral-400'}`}>{enabled ? 'ON' : 'OFF'}</button></div>
}
