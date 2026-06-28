#!/bin/bash
# Run from ~/AfriFX:  bash fix-corridor-nomemo.sh
set -e
echo "🔧  Removing Memo from corridor — pure USDC transfers..."

# ============================================================
# Revert useCorridorSwap to direct USDC transfers
# No Memo contract — just clean ERC-20 transfers to vault
# ============================================================
cat > afrifx-web/hooks/useCorridorSwap.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { isAddress, parseUnits } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import type { CorridorQuote } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export type CorridorStep =
  | 'idle'
  | 'step1-pending' | 'step1-waiting' | 'step1-done'
  | 'step2-pending' | 'step2-waiting'
  | 'complete' | 'error'

function buildRef(): string {
  const date   = new Date().toISOString().slice(0, 10).replace(/-/g, '')
  const suffix = Math.random().toString(36).slice(2, 6).toUpperCase()
  return `AFX-${date}-${suffix}`
}

export function useCorridorSwap() {
  const { address } = useAccount()

  const [step,       setStep]       = useState<CorridorStep>('idle')
  const [error,      setError]      = useState<string | null>(null)
  const [step1Hash,  setStep1Hash]  = useState<`0x${string}` | null>(null)
  const [step2Hash,  setStep2Hash]  = useState<`0x${string}` | null>(null)
  const [corridorId, setCorridorId] = useState<string | null>(null)

  const { writeContractAsync } = useWriteContract()

  const { isSuccess: step1Settled } = useWaitForTransactionReceipt({
    hash: step1Hash ?? undefined,
  })

  const { isSuccess: step2Settled } = useWaitForTransactionReceipt({
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
      // ── STEP 1: fromCurrency → USDC ──────────────────────
      // User sends USDC equivalent of their local currency to vault
      setStep('step1-pending')

      const ref1    = buildRef()
      const usdcIn1 = quote.step1.toAmount + quote.step1.spreadFee + quote.step1.networkFee

      const hash1 = await writeContractAsync({
        address:      CONTRACTS.USDC,
        abi:          USDC_ABI,
        functionName: 'transfer',
        args:         [vault, parseUnits(usdcIn1.toFixed(6), USDC_DECIMALS)],
      })

      setStep1Hash(hash1)
      setStep('step1-waiting')

      // Record step 1
      await fetch(`${API_BASE}/transactions`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote.step1,
          walletAddress: address,
          arcTxHash:     hash1,
          reference:     ref1,
          corridorId:    quote.corridorId,
          corridorStep:  1,
        }),
      }).catch(console.error)

      // Arc is sub-second — short wait for UX clarity between steps
      await sleep(1500)
      setStep('step1-done')

      // ── STEP 2: USDC → toCurrency ─────────────────────────
      // User sends the USDC amount for step 2 to vault
      setStep('step2-pending')

      const ref2    = buildRef()
      const usdcIn2 = quote.step2.fromAmount

      const hash2 = await writeContractAsync({
        address:      CONTRACTS.USDC,
        abi:          USDC_ABI,
        functionName: 'transfer',
        args:         [vault, parseUnits(usdcIn2.toFixed(6), USDC_DECIMALS)],
      })

      setStep2Hash(hash2)
      setStep('step2-waiting')

      // Record step 2
      await fetch(`${API_BASE}/transactions`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote.step2,
          walletAddress: address,
          arcTxHash:     hash2,
          reference:     ref2,
          corridorId:    quote.corridorId,
          corridorStep:  2,
        }),
      }).catch(console.error)

      await sleep(1500)
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
    isLoading:  ['step1-pending','step1-waiting','step1-done','step2-pending','step2-waiting'].includes(step),
    isComplete: step === 'complete',
  }
}

function sleep(ms: number) {
  return new Promise(r => setTimeout(r, ms))
}
__EOF__
echo "✅  useCorridorSwap.ts — pure USDC transfers, no Memo"

# ============================================================
# Also revert useSwap to pure USDC transfer (no Memo)
# ============================================================
cat > afrifx-web/hooks/useSwap.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { isAddress, parseUnits } from 'viem'
import { CONTRACTS, USDC_DECIMALS, SPREAD_BPS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import type { Currency, SwapQuote } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

function buildRef(): string {
  const date   = new Date().toISOString().slice(0, 10).replace(/-/g, '')
  const suffix = Math.random().toString(36).slice(2, 6).toUpperCase()
  return `AFX-${date}-${suffix}`
}

export function useSwap() {
  const { address } = useAccount()
  const [isLoading, setIsLoading] = useState(false)
  const [error,     setError]     = useState<string | null>(null)
  const [txHash,    setTxHash]    = useState<`0x${string}` | null>(null)
  const [reference, setReference] = useState<string | null>(null)

  const { writeContractAsync } = useWriteContract()

  const { data: receipt, isLoading: isWaiting } = useWaitForTransactionReceipt({
    hash: txHash ?? undefined,
  })

  function buildQuote(
    fromCurrency: Currency,
    toCurrency:   Currency,
    fromAmount:   number,
    rate:         number,
  ): SwapQuote {
    const usdcAmount = fromCurrency === 'USDC' ? fromAmount : fromAmount / rate
    const spread     = usdcAmount * (SPREAD_BPS / 10_000)
    const networkFee = 0.001
    return {
      fromCurrency, toCurrency, fromAmount,
      toAmount:  usdcAmount - spread - networkFee,
      rate, spreadFee: spread, networkFee,
      deadline: Math.floor(Date.now() / 1000) + 600,
    }
  }

  async function execute(quote: SwapQuote) {
    if (!address) throw new Error('Wallet not connected')

    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault address not configured. Check NEXT_PUBLIC_AFRIFX_VAULT in .env.local')
    }

    setIsLoading(true)
    setError(null)

    try {
      const ref = buildRef()
      setReference(ref)

      const usdcIn = quote.fromCurrency === 'USDC'
        ? quote.fromAmount
        : quote.toAmount + quote.spreadFee + quote.networkFee

      // Direct USDC transfer to vault
      const hash = await writeContractAsync({
        address:      CONTRACTS.USDC,
        abi:          USDC_ABI,
        functionName: 'transfer',
        args:         [vault, parseUnits(usdcIn.toFixed(6), USDC_DECIMALS)],
      })

      setTxHash(hash)

      await fetch(`${API_BASE}/transactions`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote,
          walletAddress: address,
          arcTxHash:     hash,
          reference:     ref,
        }),
      }).catch(console.error)

      return hash
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setError(msg)
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  return {
    buildQuote, execute,
    isLoading: isLoading || isWaiting,
    error, txHash, receipt, reference,
  }
}
__EOF__
echo "✅  useSwap.ts — pure USDC transfer, no Memo"

# Re-add corridor to sidebar
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
    { href: '/convert',  icon: ArrowLeftRight, label: 'Convert'  },
    { href: '/corridor', icon: Globe,          label: 'Corridor' },
    { href: '/send',     icon: Send,           label: 'Send'     },
  ]},
  { label: 'Account', items: [
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
  ]},
  { label: 'Market', items: [
    { href: '/rates', icon: TrendingUp, label: 'Live rates' },
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
echo "✅  Sidebar — Corridor link restored"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Done. Memo removed from both hooks."
echo ""
echo "  Both Convert and Corridor now use:"
echo "  USDC.transfer(vault, amount)  ← direct, proven on Arc"
echo ""
echo "  Memo contract stays in lib/memo.ts ready to plug back"
echo "  in once Arc confirms it's live on testnet."
echo ""
echo "  Restart frontend:  cd afrifx-web && npm run dev"
echo "  Then test /corridor again."
echo "══════════════════════════════════════════════════════"
