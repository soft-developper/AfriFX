'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { Badge } from '@/components/ui/badge'
import { ArrowLeftRight, ArrowRight, ExternalLink } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
type StatusFilter = 'all' | 'settled' | 'pending' | 'failed'

export default function HistoryPage() {
  const { address }           = useAccount()
  const [txs,     setTxs]     = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [status,  setStatus]  = useState<StatusFilter>('all')

  useEffect(() => {
    if (!address) return
    setLoading(true)
    fetch(`${API}/transactions?wallet=${address}`)
      .then(r => r.json())
      .then(data => setTxs(Array.isArray(data) ? data : []))
      .catch(() => setTxs([]))
      .finally(() => setLoading(false))
  }, [address])

  const filtered: any[] = txs.filter(
    tx => status === 'all' || tx.status === status
  )

  // Group corridor steps together
  const corridorGroups = new Map<string, any[]>()
  const standalone: any[] = [];

  filtered.forEach(tx => {
    const cid = tx.corridor_id ?? tx.corridorId
    if (cid) {
      const group = corridorGroups.get(cid) ?? []
      group.push(tx)
      corridorGroups.set(cid, group)
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
          {(['all','settled','pending','failed'] as StatusFilter[]).map(s => (
            <button key={s} onClick={() => setStatus(s)}
              className={`rounded-md px-3 py-1 text-xs capitalize transition-colors
                ${status === s
                  ? 'bg-[#1B2B4B] text-[#E2E8F0]'
                  : 'text-[#64748B] hover:text-[#E2E8F0]'}`}>
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
          const step1 = steps.find((s: any) => Number(s.corridor_step ?? s.corridorStep) === 1)
          const step2 = steps.find((s: any) => Number(s.corridor_step ?? s.corridorStep) === 2)
          const fromCcy = step1?.from_currency ?? step1?.fromCurrency ?? ''
          const toCcy   = step2?.to_currency   ?? step2?.toCurrency   ?? ''
          return (
            <div key={cid} className="rounded-xl border border-[#378ADD]/20 bg-[#0F1729]">
              <div className="flex items-center gap-2 border-b border-[#1B2B4B] px-4 py-2.5">
                <Badge variant="arc">Corridor</Badge>
                {step1 && step2 && (
                  <span className="flex items-center gap-1 text-xs text-[#64748B]">
                    {fromCcy}
                    <ArrowRight className="h-3 w-3" />
                    USDC
                    <ArrowRight className="h-3 w-3" />
                    {toCcy}
                  </span>
                )}
                <span className="ml-auto font-mono text-[10px] text-[#378ADD]">{cid}</span>
              </div>
              {steps
                .sort((a: any, b: any) =>
                  Number(a.corridor_step ?? a.corridorStep ?? 0) -
                  Number(b.corridor_step ?? b.corridorStep ?? 0)
                )
                .map((tx: any) => <TxRow key={tx.id} tx={tx} isCorridorStep />)
              }
            </div>
          )
        })}

        {/* Standalone */}
        {standalone.map((tx: any) => (
          <div key={tx.id} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729]">
            <TxRow tx={tx} />
          </div>
        ))}
      </div>
    </div>
  )
}

function TxRow({ tx, isCorridorStep = false }: { tx: any; isCorridorStep?: boolean }) {
  const fromCcy   = tx.from_currency ?? tx.fromCurrency  ?? ''
  const toCcy     = tx.to_currency   ?? tx.toCurrency    ?? ''
  const fromAmt   = Number(tx.from_amount  ?? tx.fromAmount  ?? 0)
  const toAmt     = Number(tx.to_amount    ?? tx.toAmount    ?? 0)
  const createdAt = Number(tx.created_at   ?? tx.createdAt   ?? 0)
  const step      = tx.corridor_step ?? tx.corridorStep
  const ref       = tx.reference     ?? tx.memo_id        ?? ''
  const hash      = tx.arc_tx_hash   ?? tx.arcTxHash      ?? ''
  const status    = tx.status        ?? 'pending'

  return (
    <div className={`flex items-center gap-3 px-4 py-3.5
      ${isCorridorStep ? 'border-b border-[#1B2B4B] last:border-0' : ''}`}>
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[#378ADD]/10">
        <ArrowLeftRight className="h-4 w-4 text-[#378ADD]" />
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-medium text-[#E2E8F0]">
          {isCorridorStep && step && (
            <span className="mr-1.5 text-[10px] text-[#64748B]">Step {step}</span>
          )}
          {fromCcy} → {toCcy}
        </p>
        <div className="flex items-center gap-2 text-[10px] text-[#64748B]">
          <span>{new Date(createdAt * 1000).toLocaleString()}</span>
          {ref && <span className="font-mono text-[#378ADD]">{ref}</span>}
        </div>
      </div>
      <div className="shrink-0 text-right">
        <p className="font-mono text-sm text-red-400">
          -{fromAmt.toLocaleString(undefined, { maximumFractionDigits: 4 })} {fromCcy}
        </p>
        <p className="font-mono text-sm text-emerald-400">
          +{toAmt.toFixed(4)} {toCcy}
        </p>
      </div>
      <div className="ml-2 flex shrink-0 flex-col items-end gap-1">
        <Badge variant={
          status === 'settled' ? 'success' :
          status === 'failed'  ? 'danger'  : 'warning'
        }>
          {status}
        </Badge>
        {hash && (
          <a href={`https://testnet.arcscan.app/tx/${hash}`}
            target="_blank" rel="noopener noreferrer">
            <ExternalLink className="h-3 w-3 text-[#64748B] hover:text-[#378ADD]" />
          </a>
        )}
      </div>
    </div>
  )
}
