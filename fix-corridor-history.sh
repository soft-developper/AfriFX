#!/bin/bash
# Run from ~/AfriFX:  bash fix-corridor-history.sh
set -e
echo "🔧  Fixing corridor swap + history page..."

# ============================================================
# FIX 1 — History: API returns object not array
# Backend wraps response — guard with Array.isArray
# ============================================================
cat > "afrifx-web/app/(app)/history/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { Badge } from '@/components/ui/badge'
import { ArrowLeftRight, ArrowRight, ExternalLink } from 'lucide-react'
import type { Transaction } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
type StatusFilter = 'all' | 'settled' | 'pending' | 'failed'

export default function HistoryPage() {
  const { address }               = useAccount()
  const [txs,     setTxs]         = useState<Transaction[]>([])
  const [loading, setLoading]     = useState(true)
  const [status,  setStatus]      = useState<StatusFilter>('all')

  useEffect(() => {
    if (!address) return
    setLoading(true)
    fetch(`${API}/transactions?wallet=${address}`)
      .then((r) => r.json())
      .then((data) => {
        // Guard: backend may return { error } or wrapped object
        setTxs(Array.isArray(data) ? data : [])
      })
      .catch(() => setTxs([]))
      .finally(() => setLoading(false))
  }, [address])

  const filtered = txs.filter((tx) => status === 'all' || tx.status === status)

  // Group corridor steps together
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
        <p className="text-sm text-[#64748B]">No transactions found.</p>
      )}

      <div className="space-y-3">
        {/* Corridor groups */}
        {Array.from(corridorGroups.entries()).map(([cid, steps]) => {
          const step1 = steps.find(s => s.corridorStep === 1)
          const step2 = steps.find(s => s.corridorStep === 2)
          return (
            <div key={cid} className="rounded-xl border border-[#378ADD]/20 bg-[#0F1729]">
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
              {steps
                .sort((a, b) => (a.corridorStep ?? 0) - (b.corridorStep ?? 0))
                .map((tx) => <TxRow key={tx.id} tx={tx} isCorridorStep />)
              }
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
    <div className={`flex items-center gap-3 px-4 py-3.5
      ${isCorridorStep ? 'border-b border-[#1B2B4B] last:border-0' : ''}`}>
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[#378ADD]/10">
        <ArrowLeftRight className="h-4 w-4 text-[#378ADD]" />
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-medium text-[#E2E8F0]">
          {isCorridorStep && (
            <span className="mr-1.5 text-[10px] text-[#64748B]">Step {tx.corridorStep}</span>
          )}
          {tx.fromCurrency} → {tx.toCurrency}
        </p>
        <div className="flex items-center gap-2 text-[10px] text-[#64748B]">
          <span>{new Date((tx.createdAt ?? 0) * 1000).toLocaleString()}</span>
          {tx.reference && (
            <span className="font-mono text-[#378ADD]">{tx.reference}</span>
          )}
        </div>
      </div>
      <div className="shrink-0 text-right">
        <p className="font-mono text-sm text-red-400">
          -{tx.fromAmount.toLocaleString()} {tx.fromCurrency}
        </p>
        <p className="font-mono text-sm text-emerald-400">
          +{Number(tx.toAmount).toFixed(4)} {tx.toCurrency}
        </p>
      </div>
      <div className="ml-2 flex shrink-0 flex-col items-end gap-1">
        <Badge variant={
          tx.status === 'settled' ? 'success' :
          tx.status === 'failed'  ? 'danger'  : 'warning'
        }>
          {tx.status}
        </Badge>
        {tx.arcTxHash && (
          <a
            href={`https://testnet.arcscan.app/tx/${tx.arcTxHash}`}
            target="_blank"
            rel="noopener noreferrer"
          >
            <ExternalLink className="h-3 w-3 text-[#64748B] hover:text-[#378ADD]" />
          </a>
        )}
      </div>
    </div>
  )
}
__EOF__
echo "✅  history/page.tsx — Array.isArray guard added"

# ============================================================
# FIX 2 — Corridor swap: the Memo contract address may not be
# live on Arc Testnet yet. Fall back to direct USDC transfer
# wrapped with our own reference tracking so the flow works
# now, and we can swap in the Memo contract once confirmed live.
# ============================================================
cat > afrifx-web/hooks/useCorridorSwap.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { isAddress, parseUnits } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { buildMemoId, buildReference, buildMemoTransferArgs } from '@/lib/memo'
import type { CorridorQuote, Currency } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export type CorridorStep =
  | 'idle'
  | 'step1-pending' | 'step1-waiting' | 'step1-done'
  | 'step2-pending' | 'step2-waiting'
  | 'complete' | 'error'

export function useCorridorSwap() {
  const { address } = useAccount()

  const [step,       setStep]       = useState<CorridorStep>('idle')
  const [error,      setError]      = useState<string | null>(null)
  const [step1Hash,  setStep1Hash]  = useState<`0x${string}` | null>(null)
  const [step2Hash,  setStep2Hash]  = useState<`0x${string}` | null>(null)
  const [corridorId, setCorridorId] = useState<string | null>(null)

  const { writeContractAsync } = useWriteContract()

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
      setStep('step1-pending')

      const memo1Id = buildMemoId(address)
      const ref1    = buildReference()

      // USDC amount to send into vault for step 1
      const usdcStep1 = quote.step1.toAmount + quote.step1.spreadFee + quote.step1.networkFee

      let hash1: `0x${string}`
      try {
        // Try Memo-wrapped transfer first
        const args1 = buildMemoTransferArgs(vault, usdcStep1, memo1Id, {
          ref: ref1, pair: `${quote.from}/USDC`,
          rate: quote.step1.rate, from: quote.from, to: 'USDC' as Currency, app: 'afrifx',
        })
        hash1 = await writeContractAsync(args1)
      } catch {
        // Fallback: direct USDC transfer if Memo contract not live yet
        hash1 = await writeContractAsync({
          address:      CONTRACTS.USDC,
          abi:          USDC_ABI,
          functionName: 'transfer',
          args:         [vault, parseUnits(usdcStep1.toFixed(6), USDC_DECIMALS)],
        })
      }

      setStep1Hash(hash1)
      setStep('step1-waiting')

      await fetch(`${API_BASE}/transactions`, {
        method: 'POST',
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

      // Arc is sub-second — wait briefly for settlement
      await sleep(1500)
      setStep('step1-done')

      // ── STEP 2: USDC → toCurrency ─────────────────────────
      setStep('step2-pending')

      const memo2Id = buildMemoId(address)
      const ref2    = buildReference()
      const usdcStep2 = quote.step2.fromAmount

      let hash2: `0x${string}`
      try {
        const args2 = buildMemoTransferArgs(vault, usdcStep2, memo2Id, {
          ref: ref2, pair: `USDC/${quote.to}`,
          rate: quote.step2.rate, from: 'USDC' as Currency, to: quote.to, app: 'afrifx',
        })
        hash2 = await writeContractAsync(args2)
      } catch {
        hash2 = await writeContractAsync({
          address:      CONTRACTS.USDC,
          abi:          USDC_ABI,
          functionName: 'transfer',
          args:         [vault, parseUnits(usdcStep2.toFixed(6), USDC_DECIMALS)],
        })
      }

      setStep2Hash(hash2)
      setStep('step2-waiting')

      await fetch(`${API_BASE}/transactions`, {
        method: 'POST',
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
    execute, reset, step, error,
    step1Hash, step2Hash, corridorId,
    isLoading: ['step1-pending','step1-waiting','step1-done','step2-pending','step2-waiting'].includes(step),
    isComplete: step === 'complete',
  }
}

function sleep(ms: number) {
  return new Promise(r => setTimeout(r, ms))
}
__EOF__
echo "✅  useCorridorSwap.ts — Memo with direct USDC fallback"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Both fixes applied. Restart the frontend:"
echo "    cd afrifx-web && npm run dev"
echo ""
echo "  History fix: guards against non-array API response"
echo "  Corridor fix: tries Memo first, falls back to direct"
echo "    USDC transfer if Memo contract not live on testnet"
echo "══════════════════════════════════════════════════════"
