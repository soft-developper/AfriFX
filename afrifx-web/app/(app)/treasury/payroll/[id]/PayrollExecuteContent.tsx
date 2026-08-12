'use client'
// ============================================================
// PayrollExecuteContent - execute a batch from the platform float.
//
// HYBRID CUSTODY (Phase 7c). The employer does NOT sign each payout. They
// click Execute once; the backend pays every recipient from the pre-funded
// MPC float and this screen POLLS the batch to show progress. No wagmi, no
// per-recipient signing, no Gateway - all of that moved server-side.
//
// The backend enforces the safety rules (balance gate, idempotency, resume);
// the client's job is just to start it and reflect progress.
// ============================================================

import { useState, useEffect, useCallback } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { usePayrollBatch } from '@/hooks/usePayroll'
import { formatAmount } from '@/lib/utils'
import {
  ArrowLeft, CheckCircle, XCircle, Loader2,
  ExternalLink, Play, AlertCircle,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function PayrollExecuteContent() {
  const { id } = useParams()
  const { data: batch, refetch } = usePayrollBatch(id as string)

  const [starting, setStarting] = useState(false)
  const [error,    setError]    = useState<string | null>(null)
  const [floatBal, setFloatBal] = useState<number | null>(null)

  const recipients = batch?.recipients ?? []
  const paidCount  = recipients.filter(r => r.status === 'paid' || r.status === 'sent').length
  const failCount  = recipients.filter(r => r.status === 'failed').length
  const owed       = recipients
    .filter(r => r.status === 'pending' || r.status === 'processing')
    .reduce((s, r) => s + Number(r.amount), 0)

  const batchStatus = batch?.status
  const isProcessing = batchStatus === 'processing'
  const isDone       = batchStatus === 'completed'
  const isPartial    = batchStatus === 'partial'

  // Load the float balance so we can warn before starting rather than fail.
  const loadFloat = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/payroll/disbursement/status`)
      const data = await res.json().catch(() => ({}))
      setFloatBal(typeof data.balance === 'number' ? data.balance : null)
    } catch { setFloatBal(null) }
  }, [])
  useEffect(() => { loadFloat() }, [loadFloat])

  // While the batch is processing, poll it for progress.
  useEffect(() => {
    if (!isProcessing) return
    const t = setInterval(() => { refetch(); loadFloat() }, 3000)
    return () => clearInterval(t)
  }, [isProcessing, refetch, loadFloat])

  const execute = useCallback(async () => {
    if (!batch) return
    setStarting(true); setError(null)
    try {
      const res  = await fetch(`${API}/payroll/batches/${batch.id}/execute`, { method: 'POST' })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) {
        setError(data.error ?? 'Could not start the payout')
        return
      }
      await refetch()
    } catch (err: any) {
      setError(err?.message ?? 'Could not start the payout')
    } finally {
      setStarting(false)
    }
  }, [batch, refetch])

  if (!batch) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-app-muted" />
    </div>
  )

  const insufficientFloat = floatBal !== null && owed > 0 && floatBal < owed

  const statusBadge = {
    draft:      'secondary',
    processing: 'default',
    completed:  'default',
    partial:    'destructive',
  }[String(batch.status)] as any

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/treasury/payroll">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-lg font-semibold text-app-text">{batch.name}</h1>
            <Badge variant={statusBadge}>{batch.status}</Badge>
          </div>
          {batch.description && (
            <p className="text-sm text-app-muted">{batch.description}</p>
          )}
        </div>
      </div>

      {/* Summary */}
      <div className="mb-4 grid grid-cols-3 gap-3">
        <div className="rounded-xl border border-app-border bg-app-surface p-3">
          <p className="text-[11px] text-app-muted">Recipients</p>
          <p className="font-mono text-sm text-app-text">{recipients.length}</p>
        </div>
        <div className="rounded-xl border border-app-border bg-app-surface p-3">
          <p className="text-[11px] text-app-muted">Total</p>
          <p className="font-mono text-sm text-app-text">{formatAmount(batch.total_amount)} USDC</p>
        </div>
        <div className="rounded-xl border border-app-border bg-app-surface p-3">
          <p className="text-[11px] text-app-muted">Float balance</p>
          <p className="font-mono text-sm text-app-text">
            {floatBal === null ? '—' : `${floatBal.toLocaleString()} USDC`}
          </p>
        </div>
      </div>

      {/* Progress line */}
      {(isProcessing || isDone || isPartial) && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-app-border bg-app-surface px-4 py-3">
          {isProcessing
            ? <Loader2 className="h-4 w-4 animate-spin text-app-accent-text" />
            : isPartial
            ? <AlertCircle className="h-4 w-4 text-amber-500" />
            : <CheckCircle className="h-4 w-4 text-emerald-500" />}
          <span className="text-sm text-app-text">
            {isProcessing ? `Paying… ${paidCount} of ${recipients.length} done`
             : isPartial  ? `Completed with ${failCount} failed. Re-run to retry the rest.`
             :              `All ${recipients.length} payments sent`}
          </span>
        </div>
      )}

      {insufficientFloat && !isProcessing && (
        <p className="mb-3 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
          <AlertCircle className="h-3.5 w-3.5 shrink-0" />
          Float has {floatBal} USDC but {owed} USDC is owed. Top up the float on the payroll page first.
        </p>
      )}
      {error && (
        <p className="mb-3 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">{error}</p>
      )}

      {/* Execute / resume button */}
      {!isDone && (
        <Button
          className="mb-4 w-full"
          disabled={starting || isProcessing || owed <= 0 || insufficientFloat}
          onClick={execute}>
          {starting || isProcessing
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Processing…</>
            : isPartial
            ? <><Play className="h-4 w-4" /> Retry remaining ({formatAmount(owed)} USDC)</>
            : <><Play className="h-4 w-4" /> Pay {recipients.length} recipients ({formatAmount(owed)} USDC)</>}
        </Button>
      )}

      {/* Recipient list */}
      <div className="overflow-hidden rounded-xl border border-app-border">
        {recipients.map((r, i) => (
          <div key={r.id ?? i}
            className="flex items-center justify-between border-b border-app-border px-4 py-3 last:border-0">
            <div className="min-w-0">
              <p className="truncate text-sm text-app-text">{r.name || 'Recipient'}</p>
              <p className="truncate font-mono text-[11px] text-app-muted">{r.wallet_address}</p>
            </div>
            <div className="flex items-center gap-3">
              <span className="font-mono text-sm text-app-text">{formatAmount(r.amount)} USDC</span>
              {r.tx_hash
                ? <a href={`https://testnet.arcscan.app/tx/${r.tx_hash}`}
                     target="_blank" rel="noopener noreferrer"
                     className="text-app-muted hover:text-app-text">
                    <ExternalLink className="h-4 w-4" />
                  </a>
                : (r.status === 'paid' || r.status === 'sent') ? <CheckCircle className="h-4 w-4 text-emerald-400" />
                : r.status === 'failed'     ? <XCircle className="h-4 w-4 text-red-400" />
                : r.status === 'processing' ? <Loader2 className="h-4 w-4 animate-spin text-app-accent-text" />
                : <span className="text-[11px] text-app-muted">pending</span>}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
