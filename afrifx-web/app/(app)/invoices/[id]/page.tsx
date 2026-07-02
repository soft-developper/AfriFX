'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { useAccount } from 'wagmi'
import { useInvoice, useUpdateInvoiceStatus } from '@/hooks/useInvoices'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { formatAmount } from '@/lib/utils'
import {
  ArrowLeft, Copy, Check, ExternalLink,
  FileText, Send, Loader2, CheckCircle, X,
} from 'lucide-react'

export default function InvoiceDetailPage() {
  return <ClientOnly><InvoiceDetail /></ClientOnly>
}

function InvoiceDetail() {
  const { id }                      = useParams()
  const { address }                 = useAccount()
  const { data: invoice }           = useInvoice(id as string)
  const updateStatus                = useUpdateInvoiceStatus()
  const [copied, setCopied]         = useState(false)

  if (!invoice) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
    </div>
  )

  const payLink   = `${typeof window !== 'undefined' ? window.location.origin : ''}/pay/${invoice.memo_ref}`
  const isCreator = invoice.creator_address.toLowerCase() === address?.toLowerCase()

  function copy() {
    navigator.clipboard.writeText(payLink)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  async function cancel() {
    if (!confirm('Cancel this invoice?')) return
    await updateStatus.mutateAsync({ id: invoice!.id, status: 'cancelled' })
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/invoices">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-app-text">Invoice</h1>
            <Badge variant={invoice.status === 'paid' ? 'success' : invoice.status === 'cancelled' ? 'danger' : 'arc'}>
              {invoice.status}
            </Badge>
          </div>
          <p className="font-mono text-xs text-app-accent-text">{invoice.memo_ref}</p>
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        {/* Details */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Invoice details</p>
          <div className="space-y-3">
            <div className="flex justify-between items-center rounded-lg bg-app-bg px-4 py-3">
              <span className="text-xs text-app-muted">Amount</span>
              <span className="font-mono text-lg font-bold text-app-text">
                {formatAmount(invoice.amount)} {invoice.currency}
              </span>
            </div>
            {[
              ['Description', invoice.description ?? '—'],
              ['Reference',   invoice.memo_ref],
              ['Created',     new Date(invoice.created_at * 1000).toLocaleString()],
              ['Due',         invoice.due_date ? new Date(invoice.due_date * 1000).toLocaleDateString() : 'No deadline'],
              ['Payer',       invoice.payer_address ? invoice.payer_address.slice(0,10)+'…' : 'Open (anyone)'],
            ].map(([label, value]) => (
              <div key={label} className="flex justify-between text-xs">
                <span className="text-app-muted">{label}</span>
                <span className="font-mono text-app-text">{value}</span>
              </div>
            ))}
            {invoice.notes && (
              <div className="rounded-lg bg-app-bg p-3 text-xs">
                <p className="mb-1 text-app-muted">Notes</p>
                <p className="text-app-text whitespace-pre-wrap">{invoice.notes}</p>
              </div>
            )}
          </div>
        </div>

        {/* Share + status */}
        <div className="space-y-4">
          {invoice.status === 'paid' ? (
            <div className="rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-5 text-center">
              <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
              <p className="font-medium text-emerald-400">Invoice paid!</p>
              <p className="mt-1 text-xs text-emerald-600">
                Paid {invoice.paid_at ? new Date(invoice.paid_at * 1000).toLocaleString() : ''}
              </p>
              {invoice.payment_tx_hash && (
                <a href={`https://testnet.arcscan.app/tx/${invoice.payment_tx_hash}`}
                  target="_blank" rel="noopener noreferrer"
                  className="mt-3 inline-flex items-center gap-1.5 text-xs text-app-accent-text hover:underline">
                  <ExternalLink className="h-3.5 w-3.5" /> View on ArcScan
                </a>
              )}
            </div>
          ) : invoice.status !== 'cancelled' && isCreator && (
            <div className="rounded-xl border border-app-border bg-app-surface p-5">
              <p className="mb-3 text-sm font-medium text-app-text">Payment link</p>
              <div className="mb-3 flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2.5">
                <p className="flex-1 truncate font-mono text-xs text-app-accent-text">{payLink}</p>
                <button onClick={copy} className="shrink-0 text-app-muted hover:text-app-text">
                  {copied ? <Check className="h-3.5 w-3.5 text-emerald-400" /> : <Copy className="h-3.5 w-3.5" />}
                </button>
              </div>
              <p className="text-xs text-app-muted">
                Share this link with your payer. They visit it, connect their wallet, and pay on-chain.
              </p>
              {invoice.status === 'draft' && (
                <Button className="mt-3 w-full" size="sm"
                  onClick={() => updateStatus.mutateAsync({ id: invoice.id, status: 'sent' })}>
                  <Send className="h-3.5 w-3.5" /> Mark as sent
                </Button>
              )}
            </div>
          )}

          {isCreator && !['paid','cancelled'].includes(invoice.status) && (
            <Button variant="danger" size="sm" className="w-full" onClick={cancel}>
              <X className="h-4 w-4" /> Cancel invoice
            </Button>
          )}

          {!isCreator && invoice.status === 'sent' && (
            <Link href={`/pay/${invoice.memo_ref}`}>
              <Button className="w-full">Pay this invoice</Button>
            </Link>
          )}
        </div>
      </div>
    </div>
  )
}
