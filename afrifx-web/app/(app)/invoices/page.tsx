'use client'
import { useState } from 'react'
import Link from 'next/link'
import { useAccount } from 'wagmi'
import { useInvoices } from '@/hooks/useInvoices'
import { useFXRates } from '@/hooks/useFXRate'
import { useUpdateInvoiceStatus } from '@/hooks/useInvoices'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { formatAmount } from '@/lib/utils'
import {
  Plus, Copy, Check, ExternalLink,
  FileText, Send, ArrowRight, Loader2,
} from 'lucide-react'

const STATUS_BADGE: Record<string, any> = {
  draft:     'default',
  sent:      'arc',
  paid:      'success',
  overdue:   'danger',
  cancelled: 'danger',
}

export default function InvoicesPage() {
  return (
    <ClientOnly fallback={<div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />}>
      <InvoicesContent />
    </ClientOnly>
  )
}

function InvoicesContent() {
  const { address }               = useAccount()
  const { data: invoices = [], isLoading } = useInvoices()
  const { data: rates = [] }      = useFXRates()
  const updateStatus              = useUpdateInvoiceStatus()
  const [copied, setCopied]       = useState<string|null>(null)
  const [filter, setFilter]       = useState('all')

  // Convert any invoice amount to USD using live rates
  function toUSD(amount: number, currency: string): number {
    if (!amount) return 0
    if (currency === 'USDC' || currency === 'USD') return amount
    if (currency === 'EURC') {
      const r = rates.find(r => r.pair === 'EURC/USDC')?.rate
      return r ? amount / r : amount * 1.09
    }
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    return rate && rate > 0 ? amount / rate : 0
  }

  const filtered = filter === 'all'
    ? invoices
    : invoices.filter(i => i.status === filter)

  const created  = invoices.filter(i => i.creator_address.toLowerCase() === address?.toLowerCase())
  const received = invoices.filter(i => i.payer_address?.toLowerCase() === address?.toLowerCase())

  function copyPayLink(memoRef: string) {
    const url = `${window.location.origin}/pay/${memoRef}`
    navigator.clipboard.writeText(url)
    setCopied(memoRef)
    setTimeout(() => setCopied(null), 2000)
  }

  async function markSent(id: string) {
    await updateStatus.mutateAsync({ id, status: 'sent' })
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Invoices</h1>
          <p className="text-sm text-[#64748B]">
            {created.length} created · {received.length} to pay
          </p>
        </div>
        <Link href="/invoices/create">
          <Button size="sm"><Plus className="h-4 w-4" /> New invoice</Button>
        </Link>
      </div>

      {/* Summary cards */}
      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {[
          { label: 'Total invoiced', value: `$${formatAmount(created.reduce((s,i)=>s+toUSD(i.amount,i.currency),0))}`, color: 'text-[#378ADD]' },
          { label: 'Paid',           value: String(created.filter(i=>i.status==='paid').length),      color: 'text-emerald-400' },
          { label: 'Pending',        value: String(created.filter(i=>i.status==='sent').length),      color: 'text-amber-400' },
          { label: 'To pay',         value: String(received.filter(i=>i.status==='sent').length),     color: 'text-red-400' },
        ].map(({ label, value, color }) => (
          <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-center">
            <p className={`font-mono text-2xl font-bold ${color}`}>{value}</p>
            <p className="mt-1 text-xs text-[#64748B]">{label}</p>
          </div>
        ))}
      </div>

      {/* Filter */}
      <div className="mb-4 flex gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1 w-fit">
        {['all','draft','sent','paid','overdue','cancelled'].map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B]'}`}>
            {f}
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="space-y-2">{[1,2,3].map(i=><div key={i} className="h-20 animate-pulse rounded-xl bg-[#0F1729]"/>)}</div>
      ) : filtered.length === 0 ? (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <FileText className="mx-auto mb-2 h-8 w-8 text-[#1B2B4B]" />
          <p className="text-sm text-[#64748B]">No invoices yet</p>
          <Link href="/invoices/create">
            <Button variant="outline" size="sm" className="mt-3">Create your first invoice</Button>
          </Link>
        </div>
      ) : (
        <div className="space-y-2">
          {filtered.map(inv => {
            const isCreator = inv.creator_address.toLowerCase() === address?.toLowerCase()
            const isPayer   = inv.payer_address?.toLowerCase() === address?.toLowerCase()
            const isOverdue = inv.due_date && inv.due_date < Math.floor(Date.now()/1000) && inv.status === 'sent'
            return (
              <div key={inv.id} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
                <div className="flex items-center gap-4">
                  <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[#080D1B]">
                    <FileText className="h-4 w-4 text-[#378ADD]" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <p className="font-mono text-sm font-medium text-[#E2E8F0]">
                        {formatAmount(inv.amount)} {inv.currency}
                      </p>
                      <Badge variant={STATUS_BADGE[isOverdue ? 'overdue' : inv.status]}>
                        {isOverdue ? 'overdue' : inv.status}
                      </Badge>
                      <Badge variant={isCreator ? 'arc' : 'warning'}>
                        {isCreator ? 'Sent by you' : 'To pay'}
                      </Badge>
                    </div>
                    <p className="text-xs text-[#64748B]">
                      {inv.memo_ref} · {inv.description ?? 'No description'}
                      {inv.due_date && ` · Due ${new Date(inv.due_date*1000).toLocaleDateString()}`}
                    </p>
                  </div>
                  <div className="flex shrink-0 items-center gap-2">
                    {isCreator && inv.status === 'draft' && (
                      <Button size="sm" variant="outline" onClick={() => markSent(inv.id)}>
                        <Send className="h-3.5 w-3.5" /> Send
                      </Button>
                    )}
                    {isCreator && inv.status !== 'paid' && inv.status !== 'cancelled' && (
                      <button onClick={() => copyPayLink(inv.memo_ref)}
                        className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-2.5 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors">
                        {copied === inv.memo_ref ? <Check className="h-3.5 w-3.5 text-emerald-400" /> : <Copy className="h-3.5 w-3.5" />}
                        {copied === inv.memo_ref ? 'Copied!' : 'Copy link'}
                      </button>
                    )}
                    {isPayer && inv.status === 'sent' && (
                      <Link href={`/pay/${inv.memo_ref}`}>
                        <Button size="sm">Pay now <ArrowRight className="h-3.5 w-3.5" /></Button>
                      </Link>
                    )}
                    {inv.payment_tx_hash && (
                      <a href={`https://testnet.arcscan.app/tx/${inv.payment_tx_hash}`}
                        target="_blank" rel="noopener noreferrer"
                        className="text-[#64748B] hover:text-[#378ADD]">
                        <ExternalLink className="h-4 w-4" />
                      </a>
                    )}
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
