'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import { useAccount, useWriteContract } from 'wagmi'
import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { usePayrollBatch, useUpdateRecipient } from '@/hooks/usePayroll'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { buildMemoId, buildMemoTransferArgs } from '@/lib/memo'
import { MEMO_ADDRESS, MEMO_ABI } from '@/lib/memo'
import { formatAmount } from '@/lib/utils'
import { parseUnits } from 'viem'
import {
  ArrowLeft, CheckCircle, XCircle, Loader2,
  ExternalLink, Play, AlertCircle, Clock,
} from 'lucide-react'

export function PayrollExecuteContent() {
  const { id }           = useParams()
  const { address }      = useAccount()
  const { data: batch }  = usePayrollBatch(id as string)
  const updateRecipient  = useUpdateRecipient()
  const { writeContractAsync } = useWriteContract()

  const [executing,    setExecuting]    = useState(false)
  const [currentIdx,   setCurrentIdx]   = useState(0)
  const [errorMsg,     setErrorMsg]     = useState<string | null>(null)
  const [done,         setDone]         = useState(false)

  if (!batch) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-[#64748B]" />
    </div>
  )

  const recipients = batch!.recipients ?? []
  const sentCount  = recipients.filter(r => r.status === 'sent').length
  const pct        = recipients.length > 0 ? Math.round((sentCount / recipients.length) * 100) : 0

  async function executePayroll() {
    if (!address || executing) return
    setExecuting(true)
    setErrorMsg(null)

    const pending = recipients.filter(r => r.status === 'pending')

    for (let i = 0; i < pending.length; i++) {
      const recipient = pending[i]
      setCurrentIdx(i)
      try {
        const usdcRaw = parseUnits(recipient.amount.toFixed(6), USDC_DECIMALS)
        const memoId  = buildMemoId(`payroll-${batch!.id}-${recipient.id}`)

        // Check if Memo is available
        let hash: `0x${string}`
        try {
          const args = buildMemoTransferArgs(
            CONTRACTS.USDC,
            recipient.wallet_address as `0x${string}`,
            recipient.amount,
            USDC_DECIMALS,
            memoId,
            {
              app:  'afrifx',
              type: 'p2p-create', // reuse as generic transfer
              ref:  recipient.memo_ref ?? undefined,
            },
          )
          hash = await writeContractAsync(args)
        } catch {
          // Fallback to direct transfer
          hash = await writeContractAsync({
            address:      CONTRACTS.USDC,
            abi:          USDC_ABI,
            functionName: 'transfer',
            args:         [recipient.wallet_address as `0x${string}`, usdcRaw],
          })
        }

        await updateRecipient.mutateAsync({
          id:      recipient.id,
          batchId: batch!.id,
          status:  'sent',
          txHash:  hash,
        })
      } catch (err: any) {
        const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
        await updateRecipient.mutateAsync({
          id:      recipient.id,
          batchId: batch!.id,
          status:  'failed',
        })
        setErrorMsg(`Payment to ${recipient.name ?? recipient.wallet_address.slice(0,10)} failed: ${msg}`)
        // Continue with next recipients
      }
    }

    setExecuting(false)
    setDone(true)
  }

  const statusBadge = {
    draft:      'warning',
    processing: 'arc',
    completed:  'success',
    failed:     'danger',
  }[batch!.status] as any

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/treasury">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-[#E2E8F0]">{batch!.name}</h1>
            <Badge variant={statusBadge}>{batch!.status}</Badge>
          </div>
          <p className="text-xs text-[#64748B]">
            {batch.recipient_count} recipients · ${formatAmount(batch!.total_amount)} USDC
            · Created {new Date(batch!.created_at * 1000).toLocaleDateString()}
          </p>
        </div>
      </div>

      {/* Progress bar */}
      {(executing || batch!.status === 'completed') && (
        <div className="mb-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="mb-2 flex items-center justify-between text-xs">
            <span className="text-[#64748B]">
              {executing ? `Sending payment ${currentIdx + 1} of ${recipients.filter(r => r.status === 'pending').length}…` : 'All payments sent'}
            </span>
            <span className={`font-medium ${pct === 100 ? 'text-emerald-400' : 'text-[#E2E8F0]'}`}>
              {sentCount}/{recipients.length} · {pct}%
            </span>
          </div>
          <div className="h-2 w-full overflow-hidden rounded-full bg-[#1B2B4B]">
            <div
              className="h-full rounded-full bg-emerald-500 transition-all duration-500"
              style={{ width: `${pct}%` }}
            />
          </div>
          {executing && (
            <p className="mt-1.5 text-center text-xs text-[#64748B]">
              Do not close this tab until all payments are sent.
            </p>
          )}
        </div>
      )}

      {done && sentCount === recipients.length && (
        <div className="mb-4 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
          <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
          <p className="text-sm font-medium text-emerald-400">All payments sent successfully!</p>
          <p className="mt-1 text-xs text-emerald-600">
            ${formatAmount(batch!.total_amount)} USDC distributed to {sentCount} recipients
          </p>
        </div>
      )}

      {errorMsg && (
        <div className="mb-4 flex items-start gap-2 rounded-xl border border-red-900/50 bg-red-900/20 p-4 text-xs text-red-400">
          <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
          <div>
            <p className="font-medium">Payment failed</p>
            <p className="mt-0.5">{errorMsg}</p>
            <p className="mt-1 text-red-600">The remaining payments will continue. You can retry failed ones separately.</p>
          </div>
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-3">

        {/* Recipients table */}
        <div className="lg:col-span-2 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Recipients</p>
          <div className="space-y-2">
            {recipients.map((r, i) => (
              <div key={r.id}
                className={`flex items-center gap-3 rounded-xl p-3 transition-colors
                  ${executing && i === currentIdx && r.status === 'pending'
                    ? 'border border-[#378ADD]/40 bg-[#378ADD]/5'
                    : 'border border-[#1B2B4B] bg-[#080D1B]'}`}>

                {/* Status icon */}
                <div className="shrink-0">
                  {r.status === 'sent'    ? <CheckCircle className="h-4 w-4 text-emerald-400" />
                  : r.status === 'failed' ? <XCircle     className="h-4 w-4 text-red-400" />
                  : executing && i === currentIdx
                  ? <Loader2 className="h-4 w-4 animate-spin text-[#378ADD]" />
                  : <Clock   className="h-4 w-4 text-[#64748B]" />}
                </div>

                {/* Info */}
                <div className="flex-1 min-w-0">
                  {r.name && (
                    <p className="text-xs font-medium text-[#E2E8F0]">{r.name}</p>
                  )}
                  <p className="font-mono text-[11px] text-[#64748B] truncate">{r.wallet_address}</p>
                  {r.memo_ref && (
                    <p className="text-[10px] text-[#64748B]">{r.memo_ref}</p>
                  )}
                </div>

                {/* Amount */}
                <div className="shrink-0 text-right">
                  <p className="font-mono text-sm font-medium text-[#E2E8F0]">
                    {formatAmount(r.amount)} USDC
                  </p>
                  {r.tx_hash && (
                    <a href={`https://testnet.arcscan.app/tx/${r.tx_hash}`}
                      target="_blank" rel="noopener noreferrer"
                      className="inline-flex items-center gap-1 text-[10px] text-[#378ADD] hover:underline">
                      View tx <ExternalLink className="h-2.5 w-2.5" />
                    </a>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Action panel */}
        <div className="space-y-4">
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Execute</p>
            <div className="space-y-2 text-xs">
              {[
                ['Recipients', String(batch.recipient_count)],
                ['Total',      `${formatAmount(batch!.total_amount)} USDC`],
                ['Sent',       `${sentCount} / ${batch.recipient_count}`],
              ].map(([l,v]) => (
                <div key={l} className="flex justify-between">
                  <span className="text-[#64748B]">{l}</span>
                  <span className="font-mono text-[#E2E8F0]">{v}</span>
                </div>
              ))}
            </div>

            {batch!.status !== 'completed' && (
              <Button className="mt-4 w-full" size="lg"
                onClick={executePayroll}
                disabled={executing || done || sentCount === recipients.length}>
                {executing
                  ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
                  : sentCount > 0
                  ? `Resume (${recipients.length - sentCount} remaining)`
                  : <><Play className="h-4 w-4" /> Start payroll</>
                }
              </Button>
            )}

            {batch!.status === 'completed' && (
              <div className="mt-4 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                <CheckCircle className="h-3.5 w-3.5" />
                Payroll complete
              </div>
            )}

            <p className="mt-2 text-center text-[10px] text-[#64748B]">
              Each payment is sent individually on Arc with a unique Memo reference
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}
