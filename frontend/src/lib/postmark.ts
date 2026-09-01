import { createPublicClient, defineChain, http, type Address, type Hex } from 'viem'

export type { Address } from 'viem'

/**
 * Live Postmark deployment on Unichain Sepolia.
 *
 * Every address below was verified on chain rather than taken from forge's broadcast log — that
 * log's contract labels do not correspond to its addresses (it reported the ScoreRegistry as the
 * hook). The hook's low 14 bits are 0x10c0, which is how v4 encodes
 * AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP.
 */
export const CHAIN_ID = 1301
export const RPC_URL = 'https://sepolia.unichain.org'
export const EXPLORER = 'https://unichain-sepolia.blockscout.com'

export const ADDRESSES = {
  hook: '0xdB86D5Fd78174d6ACE2EB268DB12F29C335A10C0',
  vault: '0x0F1bf92EE0C79F7Ca5C1e30E9412aD5BFF45c7C8',
  registry: '0x9872b13257E958c2F7E4DcCc3F96b3C70c8e050c',
  poolManager: '0x00B036B58a818B1BC34d502D3fE730Db729e62AC',
} as const satisfies Record<string, Address>

export const POOL_ID = '0xcdeaf3cf7e1fd1332eece659d1832f331a2808582e1bb11a3c363304b23ee885' as Hex
export const VANILLA_POOL_ID = '0xcfd1b3e91e47f87be5c35a9f2fc182736a5ff8fc430d5dad870f333ee4f6d1b0' as Hex

export const unichainSepolia = defineChain({
  id: CHAIN_ID,
  name: 'Unichain Sepolia',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: 'Blockscout', url: EXPLORER } },
  testnet: true,
})

export const client = createPublicClient({
  chain: unichainSepolia,
  transport: http(RPC_URL, { batch: true }),
})

export const hookAbi = [
  { type: 'function', name: 'W', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint40' }] },
  { type: 'function', name: 'ALPHA', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'BOND_RATIO_BPS', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'MAX_CHARGE_BPS', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'emergencyMode', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'guardian', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'tierFee', stateMutability: 'view', inputs: [{ type: 'uint8' }], outputs: [{ type: 'uint24' }] },
  { type: 'function', name: 'receiptCount', stateMutability: 'view', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'uint256' }] },
  {
    type: 'function', name: 'poolConfig', stateMutability: 'view',
    inputs: [{ type: 'bytes32' }],
    outputs: [{ name: 'registered', type: 'bool' }, { name: 'bondCurrency', type: 'address' }],
  },
  {
    type: 'function', name: 'getReceipt', stateMutability: 'view',
    inputs: [{ type: 'bytes32' }, { type: 'uint256' }],
    outputs: [{
      type: 'tuple',
      components: [
        { name: 'payer', type: 'address' },
        { name: 'notional', type: 'uint96' },
        { name: 'blockNumber', type: 'uint32' },
        { name: 'tickAfter', type: 'int24' },
        { name: 'flags', type: 'uint8' },
      ],
    }],
  },
] as const

export const registryAbi = [
  { type: 'function', name: 'tierOf', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'bool' }], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'scoreOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'int256' }] },
  { type: 'function', name: 'settledCountOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint32' }] },
] as const

export const vaultAbi = [
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'lockedOf', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'withdrawCooldownBlocks', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint32' }] },
] as const

// ---------------------------------------------------------------------------

export type Receipt = {
  id: number
  payer: Address
  notional: bigint
  blockNumber: number
  tickAfter: number
  zeroForOne: boolean
  tier: number
  settled: boolean
}

export type Payer = {
  address: Address
  tier: number
  score: number      // EWMA of realized markout, in bps of notional
  settled: number
  bond: bigint
  locked: bigint
  receipts: number
  openNotional: bigint
}

export type PoolState = {
  blockNumber: bigint
  registered: boolean
  bondCurrency: Address
  windowBlocks: number
  alphaBps: number
  bondRatioBps: number
  maxChargeBps: number
  cooldownBlocks: number
  emergencyMode: boolean
  guardian: Address
  tierFees: number[]   // pips
  receiptCount: number
  receipts: Receipt[]
  payers: Payer[]
}

/**
 * Read the whole live picture.
 *
 * Payers are derived from the receipts themselves rather than from `FeeQuoted` logs. That is
 * deliberate: public endpoints cap `eth_getLogs` ranges hard, and by the time anyone opens this the
 * events will be far behind head. Reading `receiptCount` and looping `getReceipt` is a handful of
 * calls, works at any age, and cannot fall out of range.
 */
export async function readPoolState(): Promise<PoolState> {
  const hook = { address: ADDRESSES.hook as Address, abi: hookAbi } as const

  const [blockNumber, config, windowBlocks, alpha, bondRatio, maxCharge, emergency, guardian, cooldown, count] =
    await Promise.all([
      client.getBlockNumber(),
      client.readContract({ ...hook, functionName: 'poolConfig', args: [POOL_ID] }),
      client.readContract({ ...hook, functionName: 'W' }),
      client.readContract({ ...hook, functionName: 'ALPHA' }),
      client.readContract({ ...hook, functionName: 'BOND_RATIO_BPS' }),
      client.readContract({ ...hook, functionName: 'MAX_CHARGE_BPS' }),
      client.readContract({ ...hook, functionName: 'emergencyMode' }),
      client.readContract({ ...hook, functionName: 'guardian' }),
      client.readContract({ address: ADDRESSES.vault, abi: vaultAbi, functionName: 'withdrawCooldownBlocks' }),
      client.readContract({ ...hook, functionName: 'receiptCount', args: [POOL_ID] }),
    ])

  const tierFees = await Promise.all(
    [0, 1, 2, 3].map((t) => client.readContract({ ...hook, functionName: 'tierFee', args: [t] })),
  )

  const n = Number(count)
  const raw = await Promise.all(
    Array.from({ length: n }, (_, i) =>
      client.readContract({ ...hook, functionName: 'getReceipt', args: [POOL_ID, BigInt(i)] }),
    ),
  )

  const receipts: Receipt[] = raw.map((r, i) => ({
    id: i,
    payer: r.payer,
    notional: r.notional,
    blockNumber: Number(r.blockNumber),
    tickAfter: r.tickAfter,
    // flags: bit 0 is zeroForOne, bits 1-2 carry the tier quoted at swap time.
    zeroForOne: (r.flags & 1) === 1,
    tier: (r.flags >> 1) & 0x3,
    // A settled receipt is deleted in place, so the payer slot reads zero.
    settled: r.payer === '0x0000000000000000000000000000000000000000',
  }))

  const bondCurrency = config[1]
  const unique = [...new Set(receipts.filter((r) => !r.settled).map((r) => r.payer))]

  const payers: Payer[] = await Promise.all(
    unique.map(async (address) => {
      const [bond, locked, score, settled] = await Promise.all([
        client.readContract({ address: ADDRESSES.vault, abi: vaultAbi, functionName: 'balanceOf', args: [address, bondCurrency] }),
        client.readContract({ address: ADDRESSES.vault, abi: vaultAbi, functionName: 'lockedOf', args: [address, bondCurrency] }),
        client.readContract({ address: ADDRESSES.registry, abi: registryAbi, functionName: 'scoreOf', args: [address] }),
        client.readContract({ address: ADDRESSES.registry, abi: registryAbi, functionName: 'settledCountOf', args: [address] }),
      ])
      const tier = await client.readContract({
        address: ADDRESSES.registry, abi: registryAbi, functionName: 'tierOf', args: [address, bond > 0n],
      })
      const mine = receipts.filter((r) => !r.settled && r.payer === address)
      return {
        address,
        tier,
        // Score is stored WAD-scaled: 1e18 == one bp of realized markout.
        score: Number(score) / 1e18,
        settled: Number(settled),
        bond,
        locked,
        receipts: mine.length,
        openNotional: mine.reduce((a, r) => a + r.notional, 0n),
      }
    }),
  )

  payers.sort((a, b) => b.score - a.score || Number(b.openNotional - a.openNotional))

  return {
    blockNumber,
    registered: config[0],
    bondCurrency,
    windowBlocks: Number(windowBlocks),
    alphaBps: Number(alpha),
    bondRatioBps: Number(bondRatio),
    maxChargeBps: Number(maxCharge),
    cooldownBlocks: Number(cooldown),
    emergencyMode: emergency,
    guardian,
    tierFees: tierFees.map(Number),
    receiptCount: n,
    receipts,
    payers,
  }
}

/** Look up any address against the live registry and vault. */
export async function readAddress(address: Address, bondCurrency: Address) {
  const [bond, locked, score, settled] = await Promise.all([
    client.readContract({ address: ADDRESSES.vault, abi: vaultAbi, functionName: 'balanceOf', args: [address, bondCurrency] }),
    client.readContract({ address: ADDRESSES.vault, abi: vaultAbi, functionName: 'lockedOf', args: [address, bondCurrency] }),
    client.readContract({ address: ADDRESSES.registry, abi: registryAbi, functionName: 'scoreOf', args: [address] }),
    client.readContract({ address: ADDRESSES.registry, abi: registryAbi, functionName: 'settledCountOf', args: [address] }),
  ])
  const tier = await client.readContract({
    address: ADDRESSES.registry, abi: registryAbi, functionName: 'tierOf', args: [address, bond > 0n],
  })
  return { address, tier, score: Number(score) / 1e18, settled: Number(settled), bond, locked }
}

// --- formatting -------------------------------------------------------------

export const TIER_COLOR = ['#CCFF00', '#9BE600', '#FFA23A', '#FF4D4D']
export const TIER_NAME = ['Proven benign', 'Low markout', 'Bonded entry', 'Unbonded / toxic']

export function short(a: string, n = 6) {
  return `${a.slice(0, n)}…${a.slice(-4)}`
}

export function bps(pips: number) {
  return pips / 100
}

/**
 * 18-decimal amount to a readable string, kept significant rather than fixed-width.
 *
 * A fixed number of decimals is wrong for this data: the testnet pool's numbers are tiny, and at
 * four decimals a real charge ceiling of 0.00000996 renders as "0" — which reads as "this cannot
 * cost anything" rather than "this is a small number". So the formatter keeps `sig` significant
 * digits wherever the value happens to sit, and only ever returns 0 for an actual zero.
 */
export function amount(v: bigint, sig = 3) {
  if (v === 0n) return '0'
  const neg = v < 0n
  const abs = neg ? -v : v
  const whole = abs / 10n ** 18n
  const fracDigits = (abs % 10n ** 18n).toString().padStart(18, '0')

  let out: string
  if (whole > 0n) {
    const dp = Math.max(0, sig - whole.toString().length)
    const frac = fracDigits.slice(0, dp).replace(/0+$/, '')
    out = frac ? `${whole}.${frac}` : `${whole}`
  } else {
    // Pure fraction: skip the leading zeros, then keep `sig` digits after the first significant one.
    const lead = fracDigits.search(/[1-9]/)
    const frac = fracDigits.slice(0, lead + sig).replace(/0+$/, '')
    out = `0.${frac}`
  }
  return neg ? `-${out}` : out
}
