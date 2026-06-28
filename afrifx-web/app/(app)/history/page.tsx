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
                    {step1.fromCurrency ?? ''}
                    <ArrowRight className="h-3 w-3" />
                    USDC
                    <ArrowRight className="h-3 w-3" />
                    {step2.toCurrency ?? ''}
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
          {tx.fromCurrency ?? ''} → {tx.toCurrency ?? ''}
        </p>
        <div className="flex items-center gap-2 text-[10px] text-[#64748B]">
          <span>{new Date(Number(tx.createdAt ?? 0) * 1000).toLocaleString()}</span>
          {tx.reference && (
            <span className="font-mono text-[#378ADD]">{tx.reference}</span>
          )}
        </div>
      </div>
      <div className="shrink-0 text-right">
        <p className="font-mono text-sm text-red-400">
          -{Number(tx.fromAmount ?? 0).toLocaleString()} {tx.fromCurrency ?? ''}
        </p>
        <p className="font-mono text-sm text-emerald-400">
          +{Number(tx.toAmount ?? 0).toFixed(4)} {tx.toCurrency ?? ''}
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
