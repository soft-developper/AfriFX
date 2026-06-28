#!/bin/bash
# ============================================================
# AfriFX Phase 2 — Multi-Corridor Two-Step Flow
# Run from ~/AfriFX:  bash phase2-corridor.sh
# ============================================================
set -e
echo ""
echo "🌍  Building Phase 2 — Multi-Corridor Flow..."
echo ""

# ============================================================
# 1 — New types for corridor flow
# ============================================================
cat > afrifx-web/types/index.ts << '__EOF__'
export type Currency = 'USDC' | 'EURC' | 'NGN' | 'GHS' | 'KES' | 'ZAR' | 'EGP'

export interface FXRate {
  pair:      string
  rate:      number
  change24h: number
  source:    string
  fetchedAt: number
}

export interface SwapQuote {
  fromCurrency: Currency
  toCurrency:   Currency
  fromAmount:   number
  toAmount:     number
  rate:         number
  spreadFee:    number
  networkFee:   number
  deadline:     number
}

export interface CorridorQuote {
  corridorId:  string          // CRD-YYYYMMDD-XXXX
  from:        Currency
  to:          Currency
  inputAmount: number
  step1:       SwapQuote       // local → USDC
  step2:       SwapQuote       // USDC → local
  totalFee:    number          // combined spread + network fees
  estimatedAt: number
}

export interface Transaction {
  id:            string
  walletAddress: string
  fromCurrency:  Currency
  toCurrency:    Currency
  fromAmount:    number
  toAmount:      number
  spreadFee:     number
  networkFee:    number
  arcTxHash:     string | null
  memoId:        string | null
  reference:     string | null
  corridorId:    string | null  // links two-step corridor transactions
  corridorStep:  number | null  // 1 or 2
  status:        'pending' | 'settled' | 'failed'
  settledAt:     number | null
  createdAt:     number
}

export interface UserStats {
  walletAddress: string
  usdcBalance:   string
  volume30d:     number
  txCount:       number
}
__EOF__
echo "✅  types/index.ts — CorridorQuote type added"

# ============================================================
# 2 — New lib/corridor.ts — corridor logic + routing
# ============================================================
cat > afrifx-web/lib/corridor.ts << '__EOF__'
// Multi-corridor routing for Phase 2
// All local→local swaps route through USDC as the middle leg.
// Arc settles each leg independently in <1s.

import { SPREAD_BPS } from './contracts'
import type { Currency, SwapQuote, CorridorQuote } from '@/types'

export const LOCAL_CURRENCIES: Currency[] = ['NGN', 'GHS', 'KES', 'ZAR', 'EGP']

export const CURRENCY_LABELS: Record<Currency, string> = {
  NGN:  'Nigerian Naira',
  GHS:  'Ghanaian Cedi',
  KES:  'Kenyan Shilling',
  ZAR:  'South African Rand',
  EGP:  'Egyptian Pound',
  USDC: 'USD Coin',
  EURC: 'Euro Coin',
}

export const CURRENCY_FLAG: Record<Currency, string> = {
  NGN:  '🇳🇬',
  GHS:  '🇬🇭',
  KES:  '🇰🇪',
  ZAR:  '🇿🇦',
  EGP:  '🇪🇬',
  USDC: '💵',
  EURC: '🇪🇺',
}

// All supported corridors (local → local via USDC)
export const CORRIDORS: [Currency, Currency][] = [
  ['NGN', 'GHS'],
  ['NGN', 'KES'],
  ['NGN', 'ZAR'],
  ['NGN', 'EGP'],
  ['GHS', 'KES'],
  ['GHS', 'ZAR'],
  ['GHS', 'EGP'],
  ['KES', 'ZAR'],
  ['KES', 'EGP'],
  ['ZAR', 'EGP'],
]

export function isCorridorSupported(from: Currency, to: Currency): boolean {
  return CORRIDORS.some(
    ([a, b]) => (a === from && b === to) || (a === to && b === from)
  )
}

export function buildCorridorId(): string {
  const date   = new Date().toISOString().slice(0, 10).replace(/-/g, '')
  const suffix = Math.random().toString(36).slice(2, 6).toUpperCase()
  return `CRD-${date}-${suffix}`
}

/**
 * Build a two-step corridor quote.
 * Step 1: fromCurrency → USDC  (at fromRate)
 * Step 2: USDC → toCurrency    (at toRate)
 */
export function buildCorridorQuote(
  from:        Currency,
  to:          Currency,
  inputAmount: number,
  fromRate:    number,  // how many FROM units = 1 USDC
  toRate:      number,  // how many TO units = 1 USDC
): CorridorQuote {
  const corridorId = buildCorridorId()
  const now        = Math.floor(Date.now() / 1000)
  const deadline   = now + 600

  // Step 1: from → USDC
  const usdcFromStep1 = inputAmount / fromRate
  const spread1       = usdcFromStep1 * (SPREAD_BPS / 10_000)
  const netFee1       = 0.001
  const usdcAfterStep1 = usdcFromStep1 - spread1 - netFee1

  const step1: SwapQuote = {
    fromCurrency: from,
    toCurrency:   'USDC',
    fromAmount:   inputAmount,
    toAmount:     usdcAfterStep1,
    rate:         fromRate,
    spreadFee:    spread1,
    networkFee:   netFee1,
    deadline,
  }

  // Step 2: USDC → to  (using USDC received from step 1)
  const spread2        = usdcAfterStep1 * (SPREAD_BPS / 10_000)
  const netFee2        = 0.001
  const usdcForStep2   = usdcAfterStep1 - spread2 - netFee2
  const localReceived  = usdcForStep2 * toRate

  const step2: SwapQuote = {
    fromCurrency: 'USDC',
    toCurrency:   to,
    fromAmount:   usdcAfterStep1,
    toAmount:     localReceived,
    rate:         toRate,
    spreadFee:    spread2,
    networkFee:   netFee2,
    deadline,
  }

  return {
    corridorId,
    from,
    to,
    inputAmount,
    step1,
    step2,
    totalFee: spread1 + netFee1 + spread2 + netFee2,
    estimatedAt: now,
  }
}
__EOF__
echo "✅  lib/corridor.ts — corridor routing + quote builder"

# ============================================================
# 3 — New hook: useCorridorSwap.ts
# ============================================================
cat > afrifx-web/hooks/useCorridorSwap.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { isAddress } from 'viem'
import { CONTRACTS, USDC_DECIMALS, SPREAD_BPS } from '@/lib/contracts'
import { buildMemoId, buildReference, buildMemoTransferArgs } from '@/lib/memo'
import type { CorridorQuote, Currency } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export type CorridorStep = 'idle' | 'step1-pending' | 'step1-waiting' |
                           'step1-done' | 'step2-pending' | 'step2-waiting' |
                           'complete' | 'error'

export function useCorridorSwap() {
  const { address } = useAccount()

  const [step,       setStep]       = useState<CorridorStep>('idle')
  const [error,      setError]      = useState<string | null>(null)
  const [step1Hash,  setStep1Hash]  = useState<`0x${string}` | null>(null)
  const [step2Hash,  setStep2Hash]  = useState<`0x${string}` | null>(null)
  const [corridorId, setCorridorId] = useState<string | null>(null)

  const { writeContractAsync } = useWriteContract()

  const { isSuccess: step1Success } = useWaitForTransactionReceipt({
    hash: step1Hash ?? undefined,
  })

  const { isSuccess: step2Success } = useWaitForTransactionReceipt({
    hash: step2Hash ?? undefined,
  })

  async function execute(quote: CorridorQuote) {
    if (!address) throw new Error('Wallet not connected')

    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault address not configured')
    }

    setError(null)
    setCorridorId(quote.corridorId)

    try {
      // ── STEP 1: from → USDC ──────────────────────────────
      setStep('step1-pending')

      const memo1Id  = buildMemoId(address)
      const ref1     = buildReference()

      const step1Args = buildMemoTransferArgs(
        vault,
        quote.step1.toAmount + quote.step1.spreadFee + quote.step1.networkFee,
        memo1Id,
        {
          ref:  ref1,
          pair: `${quote.from}/USDC`,
          rate: quote.step1.rate,
          from: quote.from,
          to:   'USDC' as Currency,
          app:  'afrifx',
        },
      )

      const hash1 = await writeContractAsync(step1Args)
      setStep1Hash(hash1)
      setStep('step1-waiting')

      // Record step 1 in backend
      await fetch(`${API_BASE}/transactions`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote.step1,
          walletAddress: address,
          arcTxHash:     hash1,
          memoId:        memo1Id,
          reference:     ref1,
          corridorId:    quote.corridorId,
          corridorStep:  1,
        }),
      }).catch(console.error)

      // Wait for Arc to settle step 1 (sub-second — poll receipt)
      await waitForReceipt(hash1)
      setStep('step1-done')

      // ── STEP 2: USDC → to ────────────────────────────────
      setStep('step2-pending')

      const memo2Id  = buildMemoId(address)
      const ref2     = buildReference()

      const step2Args = buildMemoTransferArgs(
        vault,
        quote.step2.fromAmount,
        memo2Id,
        {
          ref:  ref2,
          pair: `USDC/${quote.to}`,
          rate: quote.step2.rate,
          from: 'USDC' as Currency,
          to:   quote.to,
          app:  'afrifx',
        },
      )

      const hash2 = await writeContractAsync(step2Args)
      setStep2Hash(hash2)
      setStep('step2-waiting')

      // Record step 2 in backend
      await fetch(`${API_BASE}/transactions`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote.step2,
          walletAddress: address,
          arcTxHash:     hash2,
          memoId:        memo2Id,
          reference:     ref2,
          corridorId:    quote.corridorId,
          corridorStep:  2,
        }),
      }).catch(console.error)

      await waitForReceipt(hash2)
      setStep('complete')

    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setError(msg)
      setStep('error')
      throw err
    }
  }

  function reset() {
    setStep('idle')
    setError(null)
    setStep1Hash(null)
    setStep2Hash(null)
    setCorridorId(null)
  }

  return {
    execute,
    reset,
    step,
    error,
    step1Hash,
    step2Hash,
    corridorId,
    isLoading: ['step1-pending','step1-waiting','step2-pending','step2-waiting'].includes(step),
    isComplete: step === 'complete',
  }
}

// Poll Arc for receipt — resolves fast due to sub-second finality
async function waitForReceipt(hash: `0x${string}`, maxAttempts = 20): Promise<void> {
  for (let i = 0; i < maxAttempts; i++) {
    await new Promise(r => setTimeout(r, 500))
    try {
      const res = await fetch(`https://rpc.testnet.arc.network`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0', id: 1,
          method: 'eth_getTransactionReceipt',
          params: [hash],
        }),
      })
      const json = await res.json()
      if (json.result && json.result.status === '0x1') return
    } catch {}
  }
}
__EOF__
echo "✅  hooks/useCorridorSwap.ts — two-step corridor executor"

# ============================================================
# 4 — New component: CorridorCard.tsx
# ============================================================
mkdir -p afrifx-web/components/corridor

cat > afrifx-web/components/corridor/CorridorCard.tsx << '__EOF__'
'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import {
  ArrowRight, ArrowUpDown, CheckCircle,
  AlertCircle, Loader2, Hash, Coins
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { CurrencyInput } from '@/components/swap/CurrencyInput'
import { useRate } from '@/hooks/useFXRate'
import { useCorridorSwap } from '@/hooks/useCorridorSwap'
import {
  LOCAL_CURRENCIES, CURRENCY_FLAG, CURRENCY_LABELS,
  buildCorridorQuote, isCorridorSupported,
} from '@/lib/corridor'
import type { Currency } from '@/types'

export function CorridorCard() {
  const { isConnected } = useAccount()

  const [from,      setFrom]      = useState<Currency>('NGN')
  const [to,        setTo]        = useState<Currency>('KES')
  const [amount,    setAmount]    = useState('')
  const [quote,     setQuote]     = useState<ReturnType<typeof buildCorridorQuote> | null>(null)

  // Fetch both rates
  const { rate: fromRate } = useRate(`${from}/USDC`)
  const { rate: toRate   } = useRate(`${to}/USDC`)

  const fromRateVal = fromRate?.rate ?? 0
  const toRateVal   = toRate?.rate   ?? 0
  const ratesReady  = fromRateVal > 0 && toRateVal > 0

  const {
    execute, reset,
    step, error,
    step1Hash, step2Hash, corridorId,
    isLoading, isComplete,
  } = useCorridorSwap()

  // Recalculate quote when inputs change
  useEffect(() => {
    const amt = parseFloat(amount)
    if (!amount || isNaN(amt) || amt <= 0 || !ratesReady) {
      setQuote(null); return
    }
    setQuote(buildCorridorQuote(from, to, amt, fromRateVal, toRateVal))
  }, [amount, from, to, fromRateVal, toRateVal])

  // Reset quote when user changes amount after completion
  function handleAmountChange(val: string) {
    if (val === '' || /^\d*\.?\d*$/.test(val)) {
      setAmount(val)
      if (isComplete) reset()
    }
  }

  function handleFromChange(c: Currency) {
    if (c === to) setTo(from) // auto-swap if same selected
    setFrom(c)
    setAmount('')
    setQuote(null)
    reset()
  }

  function handleToChange(c: Currency) {
    if (c === from) setFrom(to)
    setTo(c)
    setAmount('')
    setQuote(null)
    reset()
  }

  function flip() {
    setFrom(to)
    setTo(from)
    setAmount('')
    setQuote(null)
    reset()
  }

  async function handleExecute() {
    if (!quote) return
    await execute(quote)
  }

  const supported = isCorridorSupported(from, to)
  const canSwap   = isConnected && !!quote && supported && !isLoading

  // Step label helper
  const stepLabel: Record<string, string> = {
    'idle':          '',
    'step1-pending': 'Confirm Step 1 in MetaMask…',
    'step1-waiting': 'Step 1 settling on Arc…',
    'step1-done':    'Step 1 complete — preparing Step 2…',
    'step2-pending': 'Confirm Step 2 in MetaMask…',
    'step2-waiting': 'Step 2 settling on Arc…',
    'complete':      'Corridor swap complete!',
    'error':         'Something went wrong',
  }

  return (
    <div className="w-full max-w-md rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-5 shadow-xl">

      {/* Header */}
      <div className="mb-4 flex items-center gap-2">
        <Coins className="h-4 w-4 text-[#378ADD]" />
        <span className="text-sm font-medium text-[#E2E8F0]">Cross-border corridor</span>
        <Badge variant="arc" className="ml-auto">2-step · via USDC</Badge>
      </div>

      {/* From currency */}
      <CurrencyInput
        label="You send"
        amount={amount}
        currency={from}
        onAmountChange={handleAmountChange}
        onCurrencyChange={handleFromChange}
        currencies={LOCAL_CURRENCIES.filter(c => c !== to)}
      />

      {/* Flip button */}
      <div className="my-1 flex justify-center">
        <button
          onClick={flip}
          className="rounded-full border border-[#1B2B4B] bg-[#0F1729] p-2 text-[#64748B] transition-transform hover:rotate-180 hover:text-[#E2E8F0]"
        >
          <ArrowUpDown className="h-4 w-4" />
        </button>
      </div>

      {/* To currency */}
      <CurrencyInput
        label="Recipient receives (estimated)"
        amount={quote ? quote.step2.toAmount.toFixed(2) : ''}
        currency={to}
        onCurrencyChange={handleToChange}
        currencies={LOCAL_CURRENCIES.filter(c => c !== from)}
        readOnly
        className="mb-4"
      />

      {/* Route breakdown */}
      {quote && (
        <div className="mb-4 rounded-lg bg-[#080D1B] p-3 text-xs">
          <p className="mb-2 font-medium text-[#E2E8F0]">Route</p>
          <div className="flex items-center gap-2 text-[#64748B]">
            <span>{CURRENCY_FLAG[from]} {from}</span>
            <ArrowRight className="h-3 w-3 shrink-0" />
            <span>💵 USDC</span>
            <ArrowRight className="h-3 w-3 shrink-0" />
            <span>{CURRENCY_FLAG[to]} {to}</span>
          </div>
          <div className="mt-2 space-y-1">
            <div className="flex justify-between">
              <span className="text-[#64748B]">Step 1 · {from} → USDC</span>
              <span className="font-mono text-[#E2E8F0]">~{quote.step1.toAmount.toFixed(4)} USDC</span>
            </div>
            <div className="flex justify-between">
              <span className="text-[#64748B]">Step 2 · USDC → {to}</span>
              <span className="font-mono text-[#E2E8F0]">{quote.step2.toAmount.toFixed(2)} {to}</span>
            </div>
            <div className="flex justify-between border-t border-[#1B2B4B] pt-1">
              <span className="text-[#64748B]">Total fees</span>
              <span className="font-mono text-[#E2E8F0]">${quote.totalFee.toFixed(4)} USDC</span>
            </div>
            <div className="flex justify-between">
              <span className="text-[#64748B]">Corridor ID</span>
              <span className="font-mono text-[10px] text-[#378ADD]">{quote.corridorId}</span>
            </div>
          </div>
        </div>
      )}

      {/* Step progress indicator */}
      {step !== 'idle' && (
        <div className="mb-3 rounded-lg border border-[#1B2B4B] bg-[#080D1B] p-3">
          <div className="mb-2 flex items-center gap-4">
            {/* Step 1 indicator */}
            <div className="flex items-center gap-1.5">
              <div className={`flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold
                ${['step1-done','step2-pending','step2-waiting','complete'].includes(step)
                  ? 'bg-emerald-500 text-white'
                  : ['step1-pending','step1-waiting'].includes(step)
                  ? 'bg-[#378ADD] text-white'
                  : 'bg-[#1B2B4B] text-[#64748B]'}`}>
                {['step1-done','step2-pending','step2-waiting','complete'].includes(step) ? '✓' : '1'}
              </div>
              <span className="text-xs text-[#64748B]">{from} → USDC</span>
            </div>
            <ArrowRight className="h-3 w-3 text-[#1B2B4B]" />
            {/* Step 2 indicator */}
            <div className="flex items-center gap-1.5">
              <div className={`flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold
                ${step === 'complete'
                  ? 'bg-emerald-500 text-white'
                  : ['step2-pending','step2-waiting'].includes(step)
                  ? 'bg-[#378ADD] text-white'
                  : 'bg-[#1B2B4B] text-[#64748B]'}`}>
                {step === 'complete' ? '✓' : '2'}
              </div>
              <span className="text-xs text-[#64748B]">USDC → {to}</span>
            </div>
          </div>
          <p className="flex items-center gap-1.5 text-xs text-[#64748B]">
            {isLoading && <Loader2 className="h-3 w-3 animate-spin text-[#378ADD]" />}
            {step === 'complete' && <CheckCircle className="h-3 w-3 text-emerald-400" />}
            {step === 'error' && <AlertCircle className="h-3 w-3 text-red-400" />}
            {stepLabel[step]}
          </p>
        </div>
      )}

      {/* Main button */}
      {!isComplete && (
        <Button
          className="w-full"
          size="lg"
          onClick={handleExecute}
          disabled={!canSwap || isLoading}
        >
          {isLoading ? (
            <><Loader2 className="h-4 w-4 animate-spin" />
              {step === 'step1-pending' || step === 'step1-waiting'
                ? 'Step 1 of 2 · settling…'
                : 'Step 2 of 2 · settling…'}
            </>
          ) : !isConnected ? (
            'Connect wallet'
          ) : !amount ? (
            'Enter an amount'
          ) : !supported ? (
            'Corridor not supported'
          ) : !ratesReady ? (
            'Fetching rates…'
          ) : (
            `Send ${parseFloat(amount || '0').toLocaleString()} ${from} → ${to}`
          )}
        </Button>
      )}

      {/* Error */}
      {error && (
        <div className="mt-3 flex items-start gap-2 rounded-lg border border-red-900/50 bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          <div>
            <p>{error}</p>
            <button onClick={reset} className="mt-1 underline hover:no-underline">Try again</button>
          </div>
        </div>
      )}

      {/* Success */}
      {isComplete && (
        <div className="mt-3 rounded-lg border border-emerald-900/50 bg-emerald-900/20 px-3 py-3">
          <div className="flex items-start gap-2">
            <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-emerald-400" />
            <div className="flex-1 text-xs">
              <p className="font-medium text-emerald-400">
                Corridor complete · {CURRENCY_FLAG[from]} {from} → {CURRENCY_FLAG[to]} {to}
              </p>
              <p className="mt-0.5 text-emerald-500">
                Sent {parseFloat(amount).toLocaleString()} {from} ·
                Received ~{quote?.step2.toAmount.toFixed(2)} {to}
              </p>
              <div className="mt-1.5 flex items-center gap-1">
                <Hash className="h-3 w-3 text-emerald-600" />
                <span className="font-mono text-[10px] text-emerald-600">
                  {corridorId}
                </span>
              </div>
              <div className="mt-1 space-y-0.5">
                {step1Hash && (
                  <a href={`https://testnet.arcscan.app/tx/${step1Hash}`} target="_blank"
                    rel="noopener noreferrer"
                    className="block font-mono text-[10px] text-emerald-700 hover:underline">
                    Step 1 · {step1Hash.slice(0, 18)}… ↗
                  </a>
                )}
                {step2Hash && (
                  <a href={`https://testnet.arcscan.app/tx/${step2Hash}`} target="_blank"
                    rel="noopener noreferrer"
                    className="block font-mono text-[10px] text-emerald-700 hover:underline">
                    Step 2 · {step2Hash.slice(0, 18)}… ↗
                  </a>
                )}
              </div>
              <button
                onClick={() => { reset(); setAmount(''); setQuote(null) }}
                className="mt-2 rounded-md bg-emerald-900/40 px-3 py-1 text-emerald-400 hover:bg-emerald-900/60"
              >
                New corridor swap
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  components/corridor/CorridorCard.tsx — full two-step UI"

# ============================================================
# 5 — New page: /corridor
# ============================================================
mkdir -p "afrifx-web/app/(app)/corridor"

cat > "afrifx-web/app/(app)/corridor/page.tsx" << '__EOF__'
import { CorridorCard } from '@/components/corridor/CorridorCard'
import { ClientOnly } from '@/components/ui/client-only'

export const metadata = { title: 'Corridor — AfriFX' }

function CorridorSkeleton() {
  return (
    <div className="w-full max-w-md rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-5">
      <div className="mb-4 h-6 w-40 animate-pulse rounded bg-[#1B2B4B]" />
      <div className="mb-2 h-20 animate-pulse rounded-lg bg-[#1B2B4B]" />
      <div className="my-2 flex justify-center">
        <div className="h-8 w-8 animate-pulse rounded-full bg-[#1B2B4B]" />
      </div>
      <div className="mb-4 h-20 animate-pulse rounded-lg bg-[#1B2B4B]" />
      <div className="h-12 animate-pulse rounded-lg bg-[#1B2B4B]" />
    </div>
  )
}

export default function CorridorPage() {
  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-[#E2E8F0]">Cross-border corridor</h1>
        <p className="text-sm text-[#64748B]">
          Send between African currencies in two steps via USDC.
          Both legs settle on Arc in under 1 second each.
        </p>
      </div>

      {/* Supported corridors info */}
      <div className="mb-6 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
        <p className="mb-2 text-xs font-medium text-[#E2E8F0]">Supported corridors</p>
        <div className="flex flex-wrap gap-2">
          {[
            'NGN → GHS', 'NGN → KES', 'NGN → ZAR', 'NGN → EGP',
            'GHS → KES', 'GHS → ZAR', 'KES → ZAR',
          ].map((c) => (
            <span key={c} className="rounded-full bg-[#080D1B] px-2.5 py-1 text-xs text-[#64748B]">
              {c}
            </span>
          ))}
          <span className="rounded-full bg-[#080D1B] px-2.5 py-1 text-xs text-[#64748B]">
            + all reverse pairs
          </span>
        </div>
      </div>

      <ClientOnly fallback={<CorridorSkeleton />}>
        <CorridorCard />
      </ClientOnly>
    </div>
  )
}
__EOF__
echo "✅  app/(app)/corridor/page.tsx"

# ============================================================
# 6 — Add Corridor to Sidebar nav
# ============================================================
cat > afrifx-web/components/layout/Sidebar.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History,
  LayoutDashboard, TrendingUp, Globe
} from 'lucide-react'
import { cn } from '@/lib/utils'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',   icon: ArrowLeftRight, label: 'Convert'   },
    { href: '/corridor',  icon: Globe,          label: 'Corridor'  },
    { href: '/send',      icon: Send,           label: 'Send'      },
  ]},
  { label: 'Account', items: [
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
  ]},
  { label: 'Market', items: [
    { href: '/rates',     icon: TrendingUp, label: 'Live rates' },
  ]},
]

export function Sidebar() {
  const pathname = usePathname()

  return (
    <aside className="w-52 shrink-0 border-r border-[#1B2B4B] py-4">
      {nav.map((section) => (
        <div key={section.label} className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
            {section.label}
          </p>
          {section.items.map(({ href, icon: Icon, label }) => {
            const active = pathname === href
            return (
              <Link
                key={href}
                href={href}
                className={cn(
                  'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
                  active
                    ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                    : 'text-[#64748B] hover:bg-[#0F1729] hover:text-[#E2E8F0]'
                )}
              >
                <Icon className="h-4 w-4 shrink-0" />
                {label}
              </Link>
            )
          })}
        </div>
      ))}
    </aside>
  )
}
__EOF__
echo "✅  Sidebar — Corridor link added"

# ============================================================
# 7 — Add corridorId + corridorStep to backend schema + Turso
# ============================================================
cat > afrifx-api/src/db/schema.ts << '__EOF__'
import { sqliteTable, text, integer, real } from 'drizzle-orm/sqlite-core'

export const transactions = sqliteTable('transactions', {
  id:            text('id').primaryKey(),
  walletAddress: text('wallet_address').notNull(),
  fromCurrency:  text('from_currency').notNull(),
  toCurrency:    text('to_currency').notNull(),
  fromAmount:    real('from_amount').notNull(),
  toAmount:      real('to_amount').notNull(),
  spreadFee:     real('spread_fee').notNull(),
  networkFee:    real('network_fee').notNull().default(0.001),
  arcTxHash:     text('arc_tx_hash'),
  memoId:        text('memo_id'),
  reference:     text('reference'),
  corridorId:    text('corridor_id'),    // links both steps of a corridor swap
  corridorStep:  integer('corridor_step'), // 1 or 2
  status:        text('status').notNull().default('pending'),
  settledAt:     integer('settled_at'),
  createdAt:     integer('created_at').notNull(),
})

export const fxRates = sqliteTable('fx_rates', {
  id:        integer('id').primaryKey({ autoIncrement: true }),
  pair:      text('pair').notNull(),
  rate:      real('rate').notNull(),
  change24h: real('change_24h').notNull().default(0),
  source:    text('source').notNull(),
  fetchedAt: integer('fetched_at').notNull(),
})

export const users = sqliteTable('users', {
  walletAddress: text('wallet_address').primaryKey(),
  volume30d:     real('volume_30d').notNull().default(0),
  txCount:       integer('tx_count').notNull().default(0),
  createdAt:     integer('created_at').notNull(),
})
__EOF__
echo "✅  db/schema.ts — corridorId + corridorStep columns added"

# Add new columns to Turso
echo "  Adding corridor columns to Turso..."
turso db shell afrifx "ALTER TABLE transactions ADD COLUMN corridor_id TEXT;" 2>/dev/null && \
  echo "  ✅  corridor_id added" || echo "  ℹ️   corridor_id may already exist"

turso db shell afrifx "ALTER TABLE transactions ADD COLUMN corridor_step INTEGER;" 2>/dev/null && \
  echo "  ✅  corridor_step added" || echo "  ℹ️   corridor_step may already exist"

# ============================================================
# 8 — Update history page to show corridor grouping
# ============================================================
cat > "afrifx-web/app/(app)/history/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { Badge } from '@/components/ui/badge'
import { ArrowLeftRight, ArrowRight, ExternalLink, Filter } from 'lucide-react'
import type { Transaction } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type StatusFilter = 'all' | 'settled' | 'pending' | 'failed'

export default function HistoryPage() {
  const { address } = useAccount()
  const [txs,       setTxs]       = useState<Transaction[]>([])
  const [loading,   setLoading]   = useState(true)
  const [status,    setStatus]    = useState<StatusFilter>('all')

  useEffect(() => {
    if (!address) return
    fetch(`${API}/transactions?wallet=${address}`)
      .then((r) => r.json())
      .then(setTxs)
      .catch(console.error)
      .finally(() => setLoading(false))
  }, [address])

  const filtered = txs.filter((tx) => status === 'all' || tx.status === status)

  // Group corridor transactions together
  const corridorGroups = new Map<string, Transaction[]>()
  const standalone: Transaction[] = []

  filtered.forEach((tx) => {
    if (tx.corridorId) {
      const group = corridorGroups.get(tx.corridorId) ?? []
      group.push(tx)
      corridorGroups.set(tx.corridorId, group)
    } else {
      standalone.push(tx)
    }
  })

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">History</h1>
          <p className="text-sm text-[#64748B]">All your Arc transactions</p>
        </div>
        {/* Status filter */}
        <div className="flex items-center gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1">
          {(['all','settled','pending','failed'] as StatusFilter[]).map((s) => (
            <button
              key={s}
              onClick={() => setStatus(s)}
              className={`rounded-md px-3 py-1 text-xs capitalize transition-colors
                ${status === s
                  ? 'bg-[#1B2B4B] text-[#E2E8F0]'
                  : 'text-[#64748B] hover:text-[#E2E8F0]'}`}
            >
              {s}
            </button>
          ))}
        </div>
      </div>

      {loading && <p className="text-sm text-[#64748B]">Loading…</p>}
      {!loading && filtered.length === 0 && (
        <p className="text-sm text-[#64748B]">No transactions yet.</p>
      )}

      <div className="space-y-3">

        {/* Corridor groups */}
        {Array.from(corridorGroups.entries()).map(([cid, steps]) => {
          const step1 = steps.find(s => s.corridorStep === 1)
          const step2 = steps.find(s => s.corridorStep === 2)
          return (
            <div key={cid} className="rounded-xl border border-[#378ADD]/20 bg-[#0F1729]">
              {/* Corridor header */}
              <div className="flex items-center gap-2 border-b border-[#1B2B4B] px-4 py-2.5">
                <Badge variant="arc">Corridor</Badge>
                {step1 && step2 && (
                  <span className="flex items-center gap-1 text-xs text-[#64748B]">
                    {step1.fromCurrency}
                    <ArrowRight className="h-3 w-3" />
                    USDC
                    <ArrowRight className="h-3 w-3" />
                    {step2.toCurrency}
                  </span>
                )}
                <span className="ml-auto font-mono text-[10px] text-[#378ADD]">{cid}</span>
              </div>
              {/* Steps */}
              {steps.sort((a,b) => (a.corridorStep??0) - (b.corridorStep??0)).map((tx) => (
                <TxRow key={tx.id} tx={tx} isCorridorStep />
              ))}
            </div>
          )
        })}

        {/* Standalone transactions */}
        {standalone.map((tx) => (
          <div key={tx.id} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729]">
            <TxRow tx={tx} />
          </div>
        ))}
      </div>
    </div>
  )
}

function TxRow({ tx, isCorridorStep = false }: { tx: Transaction; isCorridorStep?: boolean }) {
  return (
    <div className={`flex items-center gap-3 px-4 py-3.5 ${isCorridorStep ? 'border-b border-[#1B2B4B] last:border-0' : ''}`}>
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[#378ADD]/10">
        <ArrowLeftRight className="h-4 w-4 text-[#378ADD]" />
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-medium text-[#E2E8F0]">
          {isCorridorStep && <span className="mr-1 text-[10px] text-[#64748B]">Step {tx.corridorStep}</span>}
          {tx.fromCurrency} → {tx.toCurrency}
        </p>
        <div className="flex items-center gap-2 text-[10px] text-[#64748B]">
          <span>{new Date(tx.createdAt * 1000).toLocaleString()}</span>
          {tx.reference && (
            <span className="font-mono text-[#378ADD]">{tx.reference}</span>
          )}
        </div>
      </div>
      <div className="text-right shrink-0">
        <p className="font-mono text-sm text-red-400">
          -{tx.fromAmount.toLocaleString()} {tx.fromCurrency}
        </p>
        <p className="font-mono text-sm text-emerald-400">
          +{tx.toAmount.toFixed(4)} {tx.toCurrency}
        </p>
      </div>
      <div className="ml-2 flex shrink-0 flex-col items-end gap-1">
        <Badge variant={tx.status === 'settled' ? 'success' : tx.status === 'failed' ? 'danger' : 'warning'}>
          {tx.status}
        </Badge>
        {tx.arcTxHash && (
          <a href={`https://testnet.arcscan.app/tx/${tx.arcTxHash}`} target="_blank" rel="noopener noreferrer">
            <ExternalLink className="h-3 w-3 text-[#64748B] hover:text-[#378ADD]" />
          </a>
        )}
      </div>
    </div>
  )
}
__EOF__
echo "✅  history/page.tsx — corridor grouping + status filter"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 2 Multi-Corridor complete!"
echo ""
echo "  New route:  /corridor"
echo "  New files:"
echo "    afrifx-web/lib/corridor.ts"
echo "    afrifx-web/hooks/useCorridorSwap.ts"
echo "    afrifx-web/components/corridor/CorridorCard.tsx"
echo "    afrifx-web/app/(app)/corridor/page.tsx"
echo ""
echo "  Updated:"
echo "    Sidebar — Corridor link added"
echo "    History — corridor grouping + status filter"
echo "    Turso   — corridor_id + corridor_step columns"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
