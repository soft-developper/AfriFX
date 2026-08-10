#!/usr/bin/env bash
# ============================================================
# phase3-cutover.sh
#
# THE CUTOVER - "Connect wallet" is gone. People sign in.
#
# Run AFTER phase2-wallets.sh.
#
# WHAT CHANGES
#   TopNav       RainbowKit ConnectButton -> AccountMenu (name, email,
#                copyable wallet address, sign out)
#   (app) layout wrapped in AuthGuard: no session -> /signin, and it
#                holds the UI while checking so protected content never
#                flashes to a signed-out visitor
#   Landing      "Launch app" CTAs -> /signin instead of /dashboard
#   ProfileGuard reads the account, not wagmi
#   35 files     useAccount() from wagmi -> useAccountAddress()
#
# HOW THE ADDRESS WORKS NOW
# useAccountAddress() returns the wallet Circle provisioned at sign-up,
# shaped like wagmi's useAccount so the migration was an import change
# rather than a restructure. Named useAccountAddress because useWallet
# already exists and returns balances.
#
# useWalletReady was rewritten rather than shimmed: it modelled wagmi
# connection status, which has no meaning now. "Ready" is simply
# "the account has an address".
#
# ⚠ WHAT IS **NOT** DONE - READ THIS
# 12 files still import wagmi for SIGNING: useWriteContract,
# useSignTypedData, useSwitchChain. Those are the write paths - swaps,
# escrow, transfers, payroll execution, Gateway deposits. They now have
# an address but NO connected signer, so THOSE ACTIONS WILL FAIL until
# each is migrated to Circle challenge execution.
#
# That is Phase 4, and it is per-feature work, not a find-and-replace:
# every writeContract becomes an initialize -> user approves -> poll
# handshake, the same shape as wallet provisioning in Phase 2.
#
# So after this script: sign-up, sign-in, sessions, navigation, and
# every READ path work. Writes do not. On testnet with no real users
# that is the right order; do not point production at this yet.
#
# VERIFIED: web tsc clean, `npm run build` succeeds, all routes compile.
# NOT verified: the browser flow (no browser here).
#
# Safe to re-run: writes whole files.
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-web/app/(app)/history/page.tsx")"
cat > 'afrifx-web/app/(app)/history/page.tsx' <<'AFX_L000_EOF'
'use client'
import { useEffect, useState } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
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
          <h1 className="text-xl font-semibold text-app-text">History</h1>
          <p className="text-sm text-app-muted">All your Arc transactions</p>
        </div>
        <div className="flex items-center gap-1 rounded-lg border border-app-border bg-app-surface p-1">
          {(['all','settled','pending','failed'] as StatusFilter[]).map(s => (
            <button key={s} onClick={() => setStatus(s)}
              className={`rounded-md px-3 py-1 text-xs capitalize transition-colors
                ${status === s
                  ? 'bg-app-border text-app-text'
                  : 'text-app-muted hover:text-app-text'}`}>
              {s}
            </button>
          ))}
        </div>
      </div>

      {loading && <p className="text-sm text-app-muted">Loading…</p>}
      {!loading && filtered.length === 0 && (
        <p className="text-sm text-app-muted">No transactions found.</p>
      )}

      <div className="space-y-3">
        {/* Corridor groups */}
        {Array.from(corridorGroups.entries()).map(([cid, steps]) => {
          const step1 = steps.find((s: any) => Number(s.corridor_step ?? s.corridorStep) === 1)
          const step2 = steps.find((s: any) => Number(s.corridor_step ?? s.corridorStep) === 2)
          const fromCcy = step1?.from_currency ?? step1?.fromCurrency ?? ''
          const toCcy   = step2?.to_currency   ?? step2?.toCurrency   ?? ''
          return (
            <div key={cid} className="rounded-xl border border-app-accent/20 bg-app-surface">
              <div className="flex items-center gap-2 border-b border-app-border px-4 py-2.5">
                <Badge variant="arc">Corridor</Badge>
                {step1 && step2 && (
                  <span className="flex items-center gap-1 text-xs text-app-muted">
                    {fromCcy}
                    <ArrowRight className="h-3 w-3" />
                    USDC
                    <ArrowRight className="h-3 w-3" />
                    {toCcy}
                  </span>
                )}
                <span className="ml-auto font-mono text-[10px] text-app-accent-text">{cid}</span>
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
          <div key={tx.id} className="rounded-xl border border-app-border bg-app-surface">
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
      ${isCorridorStep ? 'border-b border-app-border last:border-0' : ''}`}>
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-app-accent/10">
        <ArrowLeftRight className="h-4 w-4 text-app-accent-text" />
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-medium text-app-text">
          {isCorridorStep && step && (
            <span className="mr-1.5 text-[10px] text-app-muted">Step {step}</span>
          )}
          {fromCcy} → {toCcy}
        </p>
        <div className="flex items-center gap-2 text-[10px] text-app-muted">
          <span>{new Date(createdAt * 1000).toLocaleString()}</span>
          {ref && <span className="font-mono text-app-accent-text">{ref}</span>}
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
            <ExternalLink className="h-3 w-3 text-app-muted hover:text-app-accent-text" />
          </a>
        )}
      </div>
    </div>
  )
}
AFX_L000_EOF
echo "  ✓ afrifx-web/app/(app)/history/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/invoices/[id]/page.tsx")"
cat > 'afrifx-web/app/(app)/invoices/[id]/page.tsx' <<'AFX_L001_EOF'
'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
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
              ['Description', invoice.description ?? '-'],
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
              <p className="mt-1 text-xs text-emerald-700 dark:text-emerald-600">
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
AFX_L001_EOF
echo "  ✓ afrifx-web/app/(app)/invoices/[id]/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/invoices/page.tsx")"
cat > 'afrifx-web/app/(app)/invoices/page.tsx' <<'AFX_L002_EOF'
'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useState } from 'react'
import Link from 'next/link'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
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

function InvoicesPageInner() {
  return (
    <ClientOnly fallback={<div className="h-64 animate-pulse rounded-xl bg-app-surface" />}>
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
          <h1 className="text-xl font-semibold text-app-text">Invoices</h1>
          <p className="text-sm text-app-muted">
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
          { label: 'Total invoiced', value: `$${formatAmount(created.reduce((s,i)=>s+toUSD(i.amount,i.currency),0))}`, color: 'text-app-accent-text' },
          { label: 'Paid',           value: String(created.filter(i=>i.status==='paid').length),      color: 'text-emerald-400' },
          { label: 'Pending',        value: String(created.filter(i=>i.status==='sent').length),      color: 'text-amber-400' },
          { label: 'To pay',         value: String(received.filter(i=>i.status==='sent').length),     color: 'text-red-400' },
        ].map(({ label, value, color }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4 text-center">
            <p className={`font-mono text-2xl font-bold ${color}`}>{value}</p>
            <p className="mt-1 text-xs text-app-muted">{label}</p>
          </div>
        ))}
      </div>

      {/* Filter */}
      <div className="mb-4 flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 w-fit">
        {['all','draft','sent','paid','overdue','cancelled'].map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-app-border text-app-text' : 'text-app-muted'}`}>
            {f}
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="space-y-2">{[1,2,3].map(i=><div key={i} className="h-20 animate-pulse rounded-xl bg-app-surface"/>)}</div>
      ) : filtered.length === 0 ? (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <FileText className="mx-auto mb-2 h-8 w-8 text-app-border" />
          <p className="text-sm text-app-muted">No invoices yet</p>
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
              <div key={inv.id} className="rounded-xl border border-app-border bg-app-surface p-4">
                <div className="flex items-center gap-4">
                  <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-app-bg">
                    <FileText className="h-4 w-4 text-app-accent-text" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <p className="font-mono text-sm font-medium text-app-text">
                        {formatAmount(inv.amount)} {inv.currency}
                      </p>
                      <Badge variant={STATUS_BADGE[isOverdue ? 'overdue' : inv.status]}>
                        {isOverdue ? 'overdue' : inv.status}
                      </Badge>
                      <Badge variant={isCreator ? 'arc' : 'warning'}>
                        {isCreator ? 'Sent by you' : 'To pay'}
                      </Badge>
                    </div>
                    <p className="text-xs text-app-muted">
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
                        className="flex items-center gap-1.5 rounded-lg border border-app-border px-2.5 py-1.5 text-xs text-app-muted hover:text-app-text transition-colors">
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
                        className="text-app-muted hover:text-app-accent-text">
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

export default function InvoicesPage() {
  return (
    <SectionGuard section="invoices">
      <InvoicesPageInner />
    </SectionGuard>
  )
}
AFX_L002_EOF
echo "  ✓ afrifx-web/app/(app)/invoices/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/layout.tsx")"
cat > 'afrifx-web/app/(app)/layout.tsx' <<'AFX_L003_EOF'
import { TopNav }      from '@/components/layout/TopNav'
import { PlatformMaintenanceBanner } from '@/hooks/useMaintenance'
import { Sidebar }     from '@/components/layout/Sidebar'
import { MobileNav }   from '@/components/layout/MobileNav'
import { ProfileGuard } from '@/components/profile/ProfileGuard'
import { AuthGuard }    from '@/components/auth/AuthGuard'

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen flex-col overflow-hidden bg-app-bg">
      <TopNav />
      <PlatformMaintenanceBanner />
      <div className="flex flex-1 overflow-hidden">
        {/* Sidebar hidden on mobile, visible md+ */}
        <Sidebar />
        {/* Main content */}
        <main className="flex-1 overflow-y-auto p-4 pb-24 md:p-6 md:pb-6">
          <AuthGuard><ProfileGuard>{children}</ProfileGuard></AuthGuard>
        </main>
      </div>
      {/* Bottom nav mobile only */}
      <MobileNav />
    </div>
  )
}
AFX_L003_EOF
echo "  ✓ afrifx-web/app/(app)/layout.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/marketplace/[id]/page.tsx")"
cat > 'afrifx-web/app/(app)/marketplace/[id]/page.tsx' <<'AFX_L004_EOF'
'use client'
import { useEffect, useState, useCallback, useRef } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { useParams, useSearchParams, useRouter } from 'next/navigation'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { TimerBanner } from '@/components/p2p/TimerBanner'
import { ChatWindow } from '@/components/chat/ChatWindow'
import { OfferParties } from '@/components/p2p/OfferParties'
import { useP2P } from '@/hooks/useP2P'
import {
  ArrowLeft, CheckCircle, ExternalLink,
  Loader2, AlertCircle, ArrowRight, RefreshCw, Flag,
} from 'lucide-react'
import type { P2POffer } from '@/types'
import { useProfileByAddress } from '@/hooks/useProfile'
import { DisputeStatus } from '@/components/dispute/DisputeStatus'
import { CURRENCY_FLAG } from '@/lib/corridor'
import type { Currency } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

// Extend P2POffer with extra fields we use
interface OfferExtended extends P2POffer {
  taker_deadline?:      number | null
  maker_deadline?:      number | null
  dispute_raised?:      number
  dispute_id?:          string | null
  maker_timer_seconds?: number
  order_type?:          string
  payment_method?:      string
  account_name?:        string
  account_number?:      string
  bank_name?:           string
  payment_note?:        string
}

function normalizeOffer(row: unknown): OfferExtended | null {
  if (!row || (row as Record<string, unknown>).error) return null
  if (Array.isArray(row)) {
    return {
      id:              row[0],
      maker_address:   row[1],
      taker_address:   row[2],
      usdc_amount:     row[3],
      local_currency:  row[4],
      local_amount:    row[5],
      rate_offered:    row[6],
      status:          row[7],
      maker_confirmed: Number(row[8]),
      taker_confirmed: Number(row[9]),
      arc_tx_hash:     row[10],
      release_tx_hash: row[11],
      expires_at:      row[12],
      created_at:      row[13],
      updated_at:      row[14],
    } as OfferExtended
  }
  const r = row as Record<string, unknown>
  return {
    ...(r as unknown as P2POffer),
    maker_confirmed:     Number(r.maker_confirmed     ?? 0),
    taker_confirmed:     Number(r.taker_confirmed     ?? 0),
    taker_deadline:      r.taker_deadline  ? Number(r.taker_deadline)  : null,
    maker_deadline:      r.maker_deadline  ? Number(r.maker_deadline)  : null,
    dispute_raised:      Number(r.dispute_raised      ?? 0),
    maker_timer_seconds: Number(r.maker_timer_seconds ?? 1800),
    order_type:          (r.order_type as string) ?? 'market',
  } as OfferExtended
}

export default function OfferDetailPage() {
  const params       = useParams()
  const searchParams = useSearchParams()
  const router       = useRouter()

  // Once a trade finishes (USDC released) we briefly show the completed state,
  // then send the user to "My trades" so they aren't stranded on a static page.
  // BUT only when the trade completes WHILE WE'RE WATCHING if it was already
  // released when the page opened, the user came from My Trades to REVIEW it, so
  // we must NOT bounce them straight back out.
  const [redirectIn, setRedirectIn] = useState<number | null>(null)
  const wasReleasedOnLoadRef = useRef<boolean | null>(null)
  const { address }  = useAccount()

  const justAccepted = searchParams.get('accepted') === '1'

  const [offer,       setOffer]       = useState<OfferExtended | null>(null)
  const [loading,     setLoading]     = useState(true)
  const [notFound,    setNotFound]    = useState(false)
  const [disputing,   setDisputing]   = useState(false)
  const [disputeDone,    setDisputeDone]    = useState(false)
  const [disputeRecord,  setDisputeRecord]  = useState<{ id: string } | null>(null)

  const {
    takerConfirm, makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading: actionLoading, error, txHash,
  } = useP2P()

  // Profile hooks MUST be before any conditional returns (React rules of hooks)
  const { data: makerProfile } = useProfileByAddress(offer?.maker_address ?? null)
  const { data: takerProfile } = useProfileByAddress(offer?.taker_address ?? null)

  const load = useCallback(async () => {
    try {
      const url  = address
        ? `${API}/offers/${params.id}?wallet=${address}`
        : `${API}/offers/${params.id}`
      const res  = await fetch(url)
      if (res.status === 404) {
        if (!justAccepted) setNotFound(true)
        return
      }
      const data = await res.json()
      const norm = normalizeOffer(data)
      if (norm) {
        setOffer(norm)
        setNotFound(false)
      } else if (!justAccepted) {
        setNotFound(true)
      }
    } catch {
      if (!justAccepted) setNotFound(true)
    } finally {
      setLoading(false)
    }
  }, [params.id, justAccepted, address])

  useEffect(() => { load() }, [load])

  // Fetch dispute record when dispute is raised
  useEffect(() => {
    if (!offer?.dispute_raised || disputeRecord) return
    fetch(`${API}/disputes/offer/${offer.id}`)
      .then(r => r.json())
      .then(data => { if (data?.id) setDisputeRecord(data) })
      .catch(() => {})
  }, [offer?.dispute_raised, offer?.id])

  useEffect(() => {
    const isStillSyncing = justAccepted && !offer?.taker_address
    const interval = setInterval(load, isStillSyncing ? 2000 : 5000)
    return () => clearInterval(interval)
  }, [load, justAccepted, offer?.taker_address])

  // When the trade completes (USDC released), start a short countdown and then
  // route the involved user to "My trades". We compute involvement inline here
  // because the derived isMaker/isInvolved vars live below the early returns
  // (hooks must run before those returns).
  useEffect(() => {
    if (!offer) return

    // Record, exactly once, whether the trade was ALREADY released the first
    // time we saw the offer. If so, this is a review from My Trades no redirect.
    if (wasReleasedOnLoadRef.current === null) {
      wasReleasedOnLoadRef.current = offer.status === 'released'
    }
    if (wasReleasedOnLoadRef.current) return   // opened an already-finished trade

    if (offer.status !== 'released') return
    const me = address?.toLowerCase()
    const involved =
      (!!me && me === offer?.maker_address?.toLowerCase()) ||
      (!!me && me === offer?.taker_address?.toLowerCase()) ||
      justAccepted
    if (!involved) return

    // Start the countdown once.
    setRedirectIn(prev => (prev == null ? 5 : prev))
  }, [offer, address, justAccepted])

  // Tick the countdown down; navigate at zero.
  useEffect(() => {
    if (redirectIn == null) return
    if (redirectIn <= 0) { router.push('/my-trades'); return }
    const t = setTimeout(() => setRedirectIn(n => (n == null ? null : n - 1)), 1000)
    return () => clearTimeout(t)
  }, [redirectIn, router])

  if (loading) return (
    <div className="space-y-4">
      <div className="h-24 animate-pulse rounded-xl bg-app-surface" />
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="h-64 animate-pulse rounded-xl bg-app-surface" />
        <div className="h-64 animate-pulse rounded-xl bg-app-surface" />
      </div>
    </div>
  )

  if (notFound || !offer) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <p className="text-sm text-app-muted">Offer not found.</p>
      <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
    </div>
  )

  const offerStatus = offer.status as string

  const isMaker    = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker    = justAccepted
    ? !isMaker && !!address
    : address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId    = offer.id as `0x${string}`
  const timerSecs  = offer.maker_timer_seconds ?? 1800

  if (offerStatus === 'accepted' && !isInvolved && address) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-3">
        <p className="text-sm font-medium text-app-text">This trade is in progress.</p>
        <p className="text-xs text-app-muted">Only the two parties involved can view an active trade.</p>
        <Link href="/marketplace">
          <Button variant="outline" size="sm">← Back to marketplace</Button>
        </Link>
      </div>
    )
  }

  const statusBadgeMap: Record<string, string> = {
    open: 'warning', accepted: 'arc', released: 'success', cancelled: 'danger',
  }
  const statusBadge = (statusBadgeMap[offerStatus] ?? 'default') as
    'warning' | 'arc' | 'success' | 'danger' | 'default'

  const makerName = makerProfile?.display_name ?? makerProfile?.username ??
    (offer?.maker_address ? offer.maker_address.slice(0,8) + '…' : 'Seller')
  const takerName = takerProfile?.display_name ?? takerProfile?.username ??
    (offer?.taker_address ? offer.taker_address.slice(0,8) + '…' : 'Buyer')

  const steps = [
    { n:1, done: offerStatus !== 'open',     label: `${takerName} accepted offer`,               desc: 'USDC locked in vault' },
    { n:2, done: offerStatus !== 'open',     label: `${takerName} sends ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to ${makerName}`, desc: 'Off-chain payment' },
    { n:3, done: !!offer.taker_confirmed,     label: `${takerName} confirmed: "I sent the money"`, desc: 'Buyer window' },
    { n:4, done: !!offer.maker_confirmed,     label: `${makerName} confirmed: "I received it"`,    desc: 'Seller window' },
    { n:5, done: offerStatus === 'released',  label: 'Platform releases USDC to buyer',     desc: 'Auto within 15s' },
  ]

  const showTakerTimer = offerStatus === 'accepted' && !offer.taker_confirmed && !!offer.taker_deadline
  const showMakerTimer = offerStatus === 'accepted' && !!offer.taker_confirmed && !offer.maker_confirmed && !!offer.maker_deadline

  // Chat is for coordinating an ACTIVE trade. Once the platform has released
  // the USDC to the taker the trade is settled, so the chat is removed there
  // is nothing left to coordinate, and the page reflows to two columns.
  const showChat = isInvolved && (
    offerStatus === 'accepted' ||
    justAccepted
  ) && !!offer.taker_address

  const isSyncing = justAccepted && !offer.taker_address

  async function handleDispute(
    disputeType: 'maker_not_received' | 'maker_silent' = 'maker_silent',
    raisedByRole: 'maker' | 'taker' = 'taker',
  ) {
    if (!address || !offer) return
    setDisputing(true)
    try {
      await raiseDispute(
        offer.id,
        disputeType === 'maker_silent'
          ? 'Seller did not confirm receipt, possible non-response'
          : 'Buyer claims to have sent payment but seller did not receive it',
        disputeType,
        raisedByRole,
      )
      setDisputeDone(true)
      await load()
    } catch (_e) {}
    finally { setDisputing(false) }
  }

  const localAmountFormatted = Number(offer.local_amount).toLocaleString()
  const nowTs = Math.floor(Date.now() / 1000)

  return (
    <div>
      {/* Header */}
      <div className="mb-4 flex items-center gap-3">
        <Link href={isInvolved ? '/my-trades' : '/marketplace'}>
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-xl font-semibold text-app-text">Offer detail</h1>
            <Badge variant={statusBadge}>{offer.status}</Badge>
            <Badge variant={offer.order_type === 'limit' ? 'warning' : 'arc'}>
              {offer.order_type ?? 'market'}
            </Badge>
            {!!offer.dispute_raised && <Badge variant="danger">Disputed</Badge>}
            {isTaker && <Badge variant="success">You are the buyer</Badge>}
          </div>
          <p className="font-mono text-xs text-app-muted">{offer.id.slice(0,26)}…</p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {isSyncing && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-app-accent/30 bg-app-accent/10 px-4 py-3 text-sm text-app-accent-text">
          <Loader2 className="h-4 w-4 animate-spin shrink-0" />
          Trade accepted! Setting up your trade interface…
        </div>
      )}

      <ClientOnly>
        {showTakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={offer.taker_deadline as number}
              totalSeconds={timerSecs}
              phase="taker"
              isMine={isTaker}
            />
          </div>
        )}
        {showMakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={offer.maker_deadline as number}
              totalSeconds={timerSecs}
              phase="maker"
              isMine={isMaker}
            />
          </div>
        )}
      </ClientOnly>

      <div className={`grid gap-4 ${showChat ? 'lg:grid-cols-3' : 'lg:grid-cols-2'}`}>

        {/* Summary */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Summary</p>
          <div className="mb-4 flex items-center justify-center gap-6 rounded-lg bg-app-bg p-4">
            <div className="text-center">
              <p className="text-2xl">💵</p>
              <p className="mt-1 font-mono text-xl font-semibold text-app-text">{Number(offer.usdc_amount).toFixed(2)}</p>
              <p className="text-xs text-app-muted">USDC (escrow)</p>
            </div>
            <ArrowRight className="h-5 w-5 text-app-muted" />
            <div className="text-center">
              <p className="text-2xl">{CURRENCY_FLAG[offer.local_currency as Currency] ?? '🌍'}</p>
              <p className="mt-1 font-mono text-xl font-semibold text-app-text">{localAmountFormatted}</p>
              <p className="text-xs text-app-muted">{offer.local_currency} (to seller)</p>
            </div>
          </div>

          <OfferParties
            makerAddress={offer.maker_address}
            takerAddress={offer.taker_address}
            isMaker={isMaker}
            isTaker={isTaker}
          />

          <div className="mt-2 flex justify-between text-xs">
            <span className="text-app-muted">Rate</span>
            <span className="font-mono text-app-text">
              1 USDC = {Number(offer.rate_offered) > 0
                ? (1 / Number(offer.rate_offered)).toFixed(2) : '-'} {offer.local_currency}
            </span>
          </div>

          {offer.arc_tx_hash && (
            <div className="mt-2 flex justify-between text-xs">
              <span className="text-app-muted">Create tx</span>
              <a href={`https://testnet.arcscan.app/tx/${offer.arc_tx_hash}`}
                target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-1 font-mono text-app-accent-text hover:underline">
                {offer.arc_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
              </a>
            </div>
          )}
          {offer.release_tx_hash && (
            <div className="mt-2 flex justify-between text-xs">
              <span className="text-app-muted">Release tx</span>
              <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-1 font-mono text-emerald-400 hover:underline">
                {offer.release_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
              </a>
            </div>
          )}

          {isMaker && offerStatus === 'open' && (
            <Button variant="danger" size="sm" className="mt-4 w-full"
              onClick={async () => { await cancelOwnOffer(offerId); await load() }}
              disabled={actionLoading}>
              Cancel offer & retrieve USDC
            </Button>
          )}
        </div>

        {/* Progress + actions */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Progress</p>
          <div className="mb-4 space-y-3">
            {steps.map(({ n, label, done, desc }) => (
              <div key={n} className="flex items-start gap-3">
                <div className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold
                  ${done ? 'bg-emerald-500 text-white' : 'bg-app-border text-app-muted'}`}>
                  {done ? '✓' : n}
                </div>
                <div>
                  <p className={`text-sm font-medium ${done ? 'text-emerald-400' : 'text-app-text'}`}>{label}</p>
                  <p className="text-xs text-app-muted">{desc}</p>
                </div>
              </div>
            ))}
          </div>

          {/* Maker payout details shown to involved parties once accepted */}
          {isInvolved && offerStatus !== 'open' && offer.account_number && (
            <div className="mb-4 rounded-lg border border-app-accent/40 bg-app-accent/[0.06] p-4">
              <p className="mb-1 text-sm font-medium text-app-text">
                {isTaker ? `Send ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to:` : 'Your payout details (shown to buyer)'}
              </p>
              <p className="mb-3 text-xs text-app-muted">
                {offer.payment_method === 'mobile_money' ? 'Mobile money' : 'Bank transfer'}
              </p>
              <div className="space-y-2 text-sm">
                {[
                  ['Account name', offer.account_name],
                  [offer.payment_method === 'mobile_money' ? 'Phone number' : 'Account number', offer.account_number],
                  [offer.payment_method === 'mobile_money' ? 'Provider' : 'Bank', offer.bank_name],
                  ...(offer.payment_note ? [['Note', offer.payment_note]] : []),
                ].map(([label, val]) => (
                  <div key={label as string} className="flex items-start justify-between gap-3">
                    <span className="text-xs text-app-muted">{label}</span>
                    <span className="text-right font-medium text-app-text">{val}</span>
                  </div>
                ))}
              </div>
              {isTaker && (
                <p className="mt-3 border-t border-app-border pt-3 text-xs text-app-muted">
                  Send the exact amount, then confirm below. Only confirm after you have completed the transfer.
                </p>
              )}
            </div>
          )}

          <ClientOnly>
            <div className="space-y-3">
              {offerStatus === 'released' && (
                <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
                  <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
                  <p className="text-sm font-medium text-emerald-400">Trade complete</p>
                  <p className="mt-1 text-xs text-emerald-700 dark:text-emerald-600">USDC released to buyer</p>
                  {redirectIn != null && (
                    <div className="mt-3 border-t border-emerald-900/40 pt-3">
                      <p className="text-xs text-app-muted">
                        Taking you to your trades in {redirectIn}s…
                      </p>
                      <button
                        onClick={() => router.push('/my-trades')}
                        className="mt-2 text-xs font-medium text-emerald-400 underline underline-offset-2 hover:text-emerald-300"
                      >
                        Go to My trades now
                      </button>
                    </div>
                  )}
                </div>
              )}

              {offerStatus === 'cancelled' && (
                <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                  <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                  <p className="text-sm font-medium text-red-400">Offer cancelled</p>
                </div>
              )}

              {!!offer.dispute_raised && offerStatus === 'accepted' && (
                disputeRecord?.id ? (
                  <DisputeStatus
                    disputeId={disputeRecord.id}
                    offerId={offer.id}
                    userAddress={address ?? ''}
                    userRole={isMaker ? 'maker' : 'taker'}
                    username={undefined}
                  />
                ) : (
                  <div className="rounded-lg border border-amber-900/40 bg-amber-900/10 p-3 text-xs">
                    <p className="font-medium text-amber-400">⏳ Dispute raised, awaiting admin review</p>
                    <p className="mt-1 text-amber-600">An admin will accept and handle your dispute shortly.</p>
                  </div>
                )
              )}

              {offerStatus === 'open' && isMaker && (
                <div className="rounded-lg bg-app-bg p-3 text-center text-xs text-app-muted">
                  Waiting for a buyer to accept your offer…
                </div>
              )}

              {isSyncing && (
                <div className="flex items-center gap-2 rounded-lg border border-app-accent/30 bg-app-accent/10 px-3 py-3 text-xs text-app-accent-text">
                  <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                  <div>
                    <p className="font-medium">Offer accepted on Arc!</p>
                    <p className="mt-0.5 opacity-70">Syncing trade details…</p>
                  </div>
                </div>
              )}

              {offerStatus === 'accepted' && !isSyncing && (
                <>
                  {isTaker && !offer.taker_confirmed && (
                    <div className="rounded-lg border border-app-accent/30 bg-app-accent/10 p-3 text-xs">
                      <p className="font-medium text-app-text">Your turn, send {offer.local_currency} to {makerName}</p>
                      <p className="mt-1 text-app-muted">
                        Send <strong className="text-app-text">
                          {localAmountFormatted} {offer.local_currency}
                        </strong> via bank or mobile money, then confirm below.
                      </p>
                    </div>
                  )}

                  {isMaker && !offer.taker_confirmed && (
                    <div className="flex items-center gap-2 rounded-lg bg-app-bg p-3 text-xs text-app-muted">
                      <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                      Waiting for {takerName} to send and confirm {localAmountFormatted} {offer.local_currency}…
                    </div>
                  )}

                  {isMaker && !!offer.taker_confirmed && !offer.maker_confirmed && !offer.dispute_raised && (
                    <div className="rounded-lg border border-app-accent/30 bg-app-accent/10 p-3 text-xs">
                      <p className="font-medium text-app-text">Check your account</p>
                      <p className="mt-1 text-app-muted">
                        {takerName} says they sent <strong className="text-app-text">
                          {localAmountFormatted} {offer.local_currency}
                        </strong>. Confirm receipt to release USDC.
                      </p>
                    </div>
                  )}

                  {isTaker && (
                    <Button className="w-full"
                      onClick={async () => { await takerConfirm(offerId, timerSecs); await load() }}
                      disabled={!!offer.taker_confirmed || actionLoading}
                      variant={!!offer.taker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : !!offer.taker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Sent confirmed</>
                        : `✓ I sent ${localAmountFormatted} ${offer.local_currency} to ${makerName}`
                      }
                    </Button>
                  )}

                  {isMaker && !offer.dispute_raised && (
                    <Button className="w-full"
                      onClick={async () => { await makerConfirm(offerId); await load() }}
                      disabled={!offer.taker_confirmed || !!offer.maker_confirmed || actionLoading}
                      variant={!!offer.maker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : !!offer.maker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Receipt confirmed</>
                        : !offer.taker_confirmed
                        ? `Waiting for ${takerName} to send first…`
                        : `✓ I received ${localAmountFormatted} ${offer.local_currency}`
                      }
                    </Button>
                  )}

                  {isTaker && !!offer.taker_confirmed && !offer.maker_confirmed && !offer.dispute_raised && (
                    <div className="flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2 text-xs text-app-muted">
                      <Loader2 className="h-3.5 w-3.5 animate-spin shrink-0" />
                      Waiting for {makerName} to confirm receipt…
                    </div>
                  )}

                  {isTaker && !!offer.taker_confirmed && !offer.maker_confirmed &&
                   !offer.dispute_raised && offer.maker_deadline &&
                   offer.maker_deadline < nowTs && (
                    <div className="space-y-2">
                      <p className="text-xs text-red-400">⚠️ {makerName} has not confirmed within the agreed window.</p>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={() => handleDispute('maker_silent', 'taker')} disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : 'Raise dispute'}
                        </Button>
                      ) : (
                        <p className="text-xs text-emerald-400">✓ Dispute raised, admin will review and contact both parties.</p>
                      )}
                    </div>
                  )}

                  {/* MAKER dispute: deadline elapsed, no dispute yet */}
                  {isMaker && !!offer.taker_confirmed && !offer.maker_confirmed &&
                   !offer.dispute_raised && offer.maker_deadline &&
                   offer.maker_deadline < nowTs && (
                    <div className="space-y-2">
                      <div className="rounded-lg border border-red-900/40 bg-red-900/10 p-3 text-xs">
                        <p className="font-medium text-red-400">⚠️ {takerName} claims to have sent payment</p>
                        <p className="mt-1 text-red-600">
                          If you did not receive{' '}
                          <strong className="text-red-400">{localAmountFormatted} {offer.local_currency}</strong>,
                          raise a dispute for admin review.
                        </p>
                      </div>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={() => handleDispute('maker_not_received', 'maker')}
                          disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : "I didn't receive payment, raise dispute"}
                        </Button>
                      ) : (
                        <div className="rounded-lg bg-amber-900/20 p-3 text-xs text-amber-400">
                          ✓ Dispute raised, admin will review.
                        </div>
                      )}
                    </div>
                  )}

                  {/* Both confirmed waiting for release */}
                  {!!offer.maker_confirmed && !!offer.taker_confirmed && (
                    <div className="flex items-center gap-2 rounded-lg border border-emerald-900/30 bg-emerald-900/10 px-3 py-2.5 text-xs text-emerald-400">
                      <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      Both confirmed, releasing USDC within 15 seconds…
                    </div>
                  )}
                </>
              )}
            </div>
          </ClientOnly>

          {!!error && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
          {!!txHash && (
            <a href={`https://testnet.arcscan.app/tx/${txHash}`}
              target="_blank" rel="noopener noreferrer"
              className="mt-3 flex items-center gap-1.5 text-xs text-app-accent-text hover:underline">
              <ExternalLink className="h-3 w-3" /> View on ArcScan
            </a>
          )}
        </div>

        {showChat && offer.taker_address && (
          <ClientOnly>
            <ChatWindow
              offerId={offer.id}
              makerAddress={offer.maker_address}
              takerAddress={offer.taker_address}
              currency={offer.local_currency}
              amount={Number(offer.local_amount)}
            />
          </ClientOnly>
        )}
      </div>
    </div>
  )
}
AFX_L004_EOF
echo "  ✓ afrifx-web/app/(app)/marketplace/[id]/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/marketplace/create/CreateOfferClient.tsx")"
cat > 'afrifx-web/app/(app)/marketplace/create/CreateOfferClient.tsx' <<'AFX_L005_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useP2P, type OrderType } from '@/hooks/useP2P'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useRate } from '@/hooks/useFXRate'
import { ArrowLeft, Info, CheckCircle, TrendingUp, Sliders, AlertCircle } from 'lucide-react'
import Link from 'next/link'
import { LOCAL_CURRENCIES as CURRENCIES, CURRENCY_FLAG } from '@/lib/corridor'

const TIMER_OPTIONS = [
  { label: '30 min',  value: 1800 },
  { label: '1 hour',  value: 3600 },
  { label: '2 hours', value: 7200 },
  { label: 'Custom',  value: 0    },
]

export function CreateOfferClient() {
  const router               = useRouter()
  const { address, isConnected } = useAccount()
  const { formatted: balance }   = useUSDCBalance()

  const [orderType,     setOrderType]     = useState<OrderType>('market')
  const [localCurrency, setLocalCurrency] = useState('NGN')
  const [usdcAmount,    setUsdcAmount]    = useState('')
  const [limitOffset,   setLimitOffset]   = useState(0)
  const [timerOption,   setTimerOption]   = useState(1800)
  const [customTimer,   setCustomTimer]   = useState('')
  const [submitted,     setSubmitted]     = useState(false)

  // Payout details where the buyer sends the local-currency payment.
  const [paymentMethod, setPaymentMethod] = useState<'bank' | 'mobile_money'>('bank')
  const [accountName,   setAccountName]   = useState('')
  const [accountNumber, setAccountNumber] = useState('')
  const [bankName,      setBankName]      = useState('')
  const [paymentNote,   setPaymentNote]   = useState('')
  const payoutComplete = accountName.trim() && accountNumber.trim() && bankName.trim()

  const { createOffer, isLoading, error } = useP2P()
  const { rate: fxRate } = useRate(`${localCurrency}/USDC`)
  const marketRate = fxRate?.rate ?? 0

  const effectiveRate = orderType === 'market'
    ? marketRate
    : marketRate * (1 + limitOffset / 100)

  const localAmount = usdcAmount && effectiveRate > 0
    ? parseFloat(usdcAmount) * effectiveRate
    : 0

  // The offer locks usdcAmount of USDC from the wallet; keep a small gas buffer.
  const GAS_BUFFER    = 0.001
  const balanceNum    = parseFloat(balance) || 0
  const usdcNum       = parseFloat(usdcAmount) || 0
  const maxUsdc       = Math.max(0, balanceNum - GAS_BUFFER)
  const insufficientUsdc = usdcNum > 0 && usdcNum > maxUsdc
  function setMaxUsdc() { setUsdcAmount(maxUsdc.toFixed(6)) }

  const timerSeconds = timerOption === 0
    ? (parseInt(customTimer) || 0) * 60
    : timerOption

  const rateVsMarket = orderType === 'limit' ? limitOffset : 0

  async function handleCreate() {
    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300 || insufficientUsdc || !payoutComplete) return
    try {
      await createOffer({
        usdcAmount:        parseFloat(usdcAmount),
        localCurrency,
        localAmount,
        orderType,
        limitRate:         orderType === 'limit' ? effectiveRate : undefined,
        makerTimerSeconds: timerSeconds,
        paymentMethod,
        accountName:       accountName.trim(),
        accountNumber:     accountNumber.trim(),
        bankName:          bankName.trim(),
        paymentNote:       paymentNote.trim() || undefined,
      })
      setSubmitted(true)
      setTimeout(() => router.push('/marketplace'), 2500)
    } catch (_e) {}
  }

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-app-muted">Connect your wallet to create an offer.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-app-text">Create P2P offer</h1>
          <p className="text-sm text-app-muted">Lock USDC in escrow, perpetual until filled or cancelled.</p>
        </div>
      </div>

      <div className="w-full max-w-md space-y-4">

        {/* Order type tabs */}
        <div className="flex rounded-xl border border-app-border bg-app-surface p-1">
          <button onClick={() => setOrderType('market')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'market' ? 'bg-app-accent text-app-on-accent' : 'text-app-muted hover:text-app-text'}`}>
            <TrendingUp className="h-4 w-4" /> Market order
          </button>
          <button onClick={() => setOrderType('limit')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'limit' ? 'bg-app-accent text-app-on-accent' : 'text-app-muted hover:text-app-text'}`}>
            <Sliders className="h-4 w-4" /> Limit order
          </button>
        </div>

        {/* Description */}
        <div className="rounded-xl border border-app-border bg-app-surface p-3 text-xs text-app-muted">
          <div className="flex items-start gap-2">
            <Info className="mt-0.5 h-3.5 w-3.5 shrink-0 text-app-accent-text" />
            {orderType === 'market'
              ? 'Market order uses the live exchange rate. Local amount is calculated automatically.'
              : 'Limit order lets you set a custom rate within ±5% of the market rate.'}
          </div>
        </div>

        {/* USDC + currency */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-3 flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              USDC to lock in escrow
            </label>
            <span className="text-xs text-app-muted">
              Balance: <span className="text-app-text">{balance}</span>
              <button type="button" onClick={setMaxUsdc}
                className="ml-2 text-app-accent-text hover:underline">Max</button>
            </span>
          </div>
          <div className="flex gap-2">
            <select value={localCurrency} onChange={(e) => setLocalCurrency(e.target.value)}
              className="rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none">
              {CURRENCIES.map(c => (
                <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
              ))}
            </select>
            <Input type="number" placeholder="0.00" value={usdcAmount}
              onChange={(e) => setUsdcAmount(e.target.value)}
              className={`flex-1 font-mono text-lg ${insufficientUsdc ? 'border-red-500/50' : ''}`} />
          </div>

          {/* Insufficiency / remaining */}
          {insufficientUsdc && (
            <div className="mt-2 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              Insufficient balance, you only have {balance} USDC
            </div>
          )}
          {!insufficientUsdc && usdcNum > 0 && (
            <p className="mt-2 text-xs text-emerald-400">
              Remaining after: {(balanceNum - usdcNum).toFixed(4)} USDC
            </p>
          )}
        </div>

        {/* Rate display + limit slider */}
        {marketRate > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="mb-2 flex items-center justify-between text-xs">
              <span className="text-app-muted">Live market rate</span>
              <span className="font-mono text-app-text">1 USDC = {marketRate.toLocaleString()} {localCurrency}</span>
            </div>
            {orderType === 'limit' && (
              <div className="mt-3">
                <div className="mb-2 flex items-center justify-between text-xs">
                  <span className="text-app-muted">Your rate</span>
                  <span className={`font-medium ${limitOffset > 0 ? 'text-emerald-400' : limitOffset < 0 ? 'text-red-400' : 'text-app-text'}`}>
                    {limitOffset > 0 ? '+' : ''}{limitOffset.toFixed(1)}% · 1 USDC = {effectiveRate.toLocaleString(undefined, { maximumFractionDigits: 2 })} {localCurrency}
                  </span>
                </div>
                <input type="range" min="-5" max="5" step="0.5" value={limitOffset}
                  onChange={(e) => setLimitOffset(parseFloat(e.target.value))}
                  className="w-full accent-app-accent" />
                <div className="mt-1 flex justify-between text-[10px] text-app-muted">
                  <span>-5%</span><span>Market</span><span>+5%</span>
                </div>
              </div>
            )}
          </div>
        )}

        {/* Auto-calculated receive */}
        {localAmount > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-xs text-app-muted">You will receive</p>
                <p className="mt-1 font-mono text-2xl font-semibold text-app-text">
                  {localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                  <span className="ml-2 text-base text-app-muted">{localCurrency}</span>
                </p>
              </div>
              <Badge variant={orderType === 'market' ? 'arc' : 'warning'}>
                {orderType === 'market' ? 'Market rate' : `${limitOffset > 0 ? '+' : ''}${limitOffset}%`}
              </Badge>
            </div>
          </div>
        )}

        {/* Timer */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-3 flex items-center gap-2">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              Buyer completion window
            </label>
          </div>
          <div className="flex flex-wrap gap-2">
            {TIMER_OPTIONS.map((opt) => (
              <button key={opt.value} onClick={() => setTimerOption(opt.value)}
                className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors
                  ${timerOption === opt.value
                    ? 'bg-app-accent text-app-on-accent'
                    : 'border border-app-border text-app-muted hover:text-app-text'}`}>
                {opt.label}
              </button>
            ))}
          </div>
          {timerOption === 0 && (
            <div className="mt-3 flex items-center gap-2">
              <Input type="number" placeholder="Minutes (min 5, max 1440)"
                value={customTimer} onChange={(e) => setCustomTimer(e.target.value)}
                className="font-mono" />
              <span className="text-xs text-app-muted">min</span>
            </div>
          )}
          <p className="mt-2 text-xs text-app-muted">
            If the buyer doesn't send {localCurrency} within this window, the offer automatically cancels and USDC returns to you.
          </p>
        </div>

        {/* Payout details where the buyer sends the money */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Your payout details
          </label>
          <p className="mt-1 mb-3 text-xs text-app-muted">
            Where should the buyer send your {localCurrency}? Shown to a buyer only after they accept.
          </p>

          {/* Method toggle */}
          <div className="mb-3 flex gap-2">
            {(['bank', 'mobile_money'] as const).map((m) => (
              <button key={m} onClick={() => setPaymentMethod(m)}
                className={`flex-1 rounded-lg px-3 py-2 text-xs font-medium transition-colors
                  ${paymentMethod === m ? 'bg-app-accent text-app-on-accent' : 'border border-app-border text-app-muted hover:text-app-text'}`}>
                {m === 'bank' ? 'Bank account' : 'Mobile money'}
              </button>
            ))}
          </div>

          <div className="space-y-2.5">
            <Input placeholder="Account holder name" value={accountName}
              onChange={(e) => setAccountName(e.target.value)} />
            <Input
              placeholder={paymentMethod === 'bank' ? 'Account number' : 'Phone number'}
              value={accountNumber}
              onChange={(e) => setAccountNumber(e.target.value)} />
            <Input
              placeholder={paymentMethod === 'bank' ? 'Bank name' : 'Provider (e.g. M-Pesa, MTN)'}
              value={bankName}
              onChange={(e) => setBankName(e.target.value)} />
            <Input placeholder="Note / reference (optional)" value={paymentNote}
              onChange={(e) => setPaymentNote(e.target.value)} />
          </div>
          {!payoutComplete && (accountName || accountNumber || bankName) && (
            <p className="mt-2 text-xs text-amber-500">Fill in name, number, and bank/provider to continue.</p>
          )}
        </div>

        {/* Summary */}
        {usdcAmount && localAmount > 0 && timerSeconds > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4 text-xs">
            <p className="mb-2 font-medium text-app-text">Order summary</p>
            <div className="space-y-1.5 text-app-muted">
              {[
                ['Order type', orderType],
                ['You lock',   `${usdcAmount} USDC`],
                ['You receive', `${localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })} ${localCurrency}`],
                ['Buyer window', timerSeconds >= 3600 ? `${timerSeconds/3600}h` : `${timerSeconds/60}min`],
                ['Duration',    'Perpetual until filled or cancelled'],
                ['Platform fee', `${(parseFloat(usdcAmount) * 0.003).toFixed(4)} USDC (0.3%)`],
              ].map(([label, val]) => (
                <div key={label} className="flex justify-between">
                  <span>{label}</span>
                  <span className="text-app-text">{val}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Trade flow reminder */}
        <div className="rounded-xl border border-app-border bg-app-surface p-3 text-xs text-app-muted">
          <p className="mb-1 font-medium text-app-text">Trade flow</p>
          <ol className="space-y-0.5">
            {[
              'You lock USDC in vault escrow',
              `Buyer accepts + sends ${localCurrency} to you within the window`,
              'Buyer confirms: "I sent the money"',
              'You confirm: "I received it"',
              'Platform releases USDC to buyer',
            ].map((s, i) => (
              <li key={i} className="flex items-start gap-2">
                <span className="shrink-0 text-app-accent-text">{i+1}.</span>
                <span>{s}</span>
              </li>
            ))}
          </ol>
        </div>

        {submitted ? (
          <div className="flex items-center gap-2 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-sm text-emerald-400">
            <CheckCircle className="h-4 w-4 shrink-0" />
            Offer created! Redirecting to marketplace…
          </div>
        ) : (
          <Button className="w-full" size="lg" onClick={handleCreate}
            disabled={
              isLoading || !usdcAmount || localAmount <= 0 || timerSeconds < 300 ||
              insufficientUsdc || !payoutComplete ||
              (timerOption === 0 && (!customTimer || parseInt(customTimer) < 5))
            }>
            {isLoading
              ? 'Locking USDC in escrow…'
              : insufficientUsdc
              ? 'Insufficient USDC balance'
              : !payoutComplete
              ? 'Add your payout details'
              : `Create ${orderType} order, ${usdcAmount || '0'} USDC`}
          </Button>
        )}

        {error && (
          <div className="rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">{error}</div>
        )}
      </div>
    </div>
  )
}
AFX_L005_EOF
echo "  ✓ afrifx-web/app/(app)/marketplace/create/CreateOfferClient.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/marketplace/page.tsx")"
cat > 'afrifx-web/app/(app)/marketplace/page.tsx' <<'AFX_L006_EOF'
'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useEffect, useState } from 'react'
import { usePublicClient } from 'wagmi'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { UserDisplay } from '@/components/profile/UserDisplay'
import { useP2P } from '@/hooks/useP2P'
import { arcTestnet } from '@/lib/arc-chain'
import { Plus, Clock, Zap, ShieldCheck, Loader2, ArrowRight, CheckCircle } from 'lucide-react'
import type { P2POffer } from '@/types'
import { LOCAL_CURRENCIES, CURRENCY_FLAG } from '@/lib/corridor'
import type { Currency } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'


function normalizeOffer(row: any): P2POffer {
  if (Array.isArray(row)) {
    return {
      id: row[0], maker_address: row[1], taker_address: row[2],
      usdc_amount: Number(row[3]), local_currency: row[4],
      local_amount: Number(row[5]), rate_offered: Number(row[6]),
      status: row[7], maker_confirmed: Number(row[8] ?? 0),
      taker_confirmed: Number(row[9] ?? 0),
      arc_tx_hash: row[10], release_tx_hash: row[11],
      expires_at: Number(row[12]), created_at: Number(row[13]),
      updated_at: Number(row[14]),
      order_type: row[15] ?? 'market',
      maker_timer_seconds: Number(row[17] ?? 1800),
    } as any
  }
  return {
    ...row,
    maker_confirmed:     Number(row.maker_confirmed     ?? 0),
    taker_confirmed:     Number(row.taker_confirmed     ?? 0),
    maker_timer_seconds: Number(row.maker_timer_seconds ?? 1800),
  } as P2POffer
}

function formatTimer(secs: number): string {
  if (secs >= 7200) return `${secs / 3600}h window`
  if (secs >= 3600) return '1h window'
  return `${Math.round(secs / 60)}min window`
}

// Accept states for clear UX
type AcceptState =
  | { phase: 'idle' }
  | { phase: 'signing';     offerId: string }
  | { phase: 'confirming';  offerId: string; txHash: string }
  | { phase: 'updating_db'; offerId: string }
  | { phase: 'done';        offerId: string }

function MarketplacePageInner() {
  const { address }                    = useAccount()
  const router                         = useRouter()
  const publicClient                   = usePublicClient({ chainId: arcTestnet.id })
  const [offers,   setOffers]          = useState<P2POffer[]>([])
  const [loading,  setLoading]         = useState(true)
  const [currency, setCurrency]        = useState('all')
  const [acceptState, setAcceptState]  = useState<AcceptState>({ phase: 'idle' })
  const { acceptOffer, error: p2pErr } = useP2P()

  async function load() {
    setLoading(true)
    try {
      const url = currency === 'all' ? `${API}/offers` : `${API}/offers?currency=${currency}`
      const res = await fetch(url)
      const data = await res.json()
      setOffers(Array.isArray(data) ? data.map(normalizeOffer) : [])
    } catch { setOffers([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [currency])

  async function handleAccept(offer: P2POffer) {
    if (!address || acceptState.phase !== 'idle') return
    const timerSecs = (offer as any).maker_timer_seconds ?? 1800

    try {
      // Step 1: Sign + submit tx
      setAcceptState({ phase: 'signing', offerId: offer.id })
      const hash = await acceptOffer(offer.id as `0x${string}`, timerSecs)

      // Step 2: Wait for on-chain confirmation
      setAcceptState({ phase: 'confirming', offerId: offer.id, txHash: hash as string })
      if (publicClient) {
        await publicClient.waitForTransactionReceipt({
          hash: hash as `0x${string}`,
        })
      }

      // Step 3: Update DB immediately (don't rely on event listener timing)
      setAcceptState({ phase: 'updating_db', offerId: offer.id })
      await fetch(`${API}/offers/${offer.id}/accept`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
          takerAddress:  address,
          timerSeconds:  timerSecs,
        }),
      }).catch(() => {}) // Non-fatal, watcher will catch it

      // Step 4: DB is updated safe to redirect now
      setAcceptState({ phase: 'done', offerId: offer.id })

      // Small delay so user sees the success state
      await new Promise(r => setTimeout(r, 600))

      router.push(`/marketplace/${offer.id}?accepted=1`)
    } catch (err: any) {
      // User rejected or tx failed
      setAcceptState({ phase: 'idle' })
    }
  }

  const busyId = acceptState.phase !== 'idle' ? acceptState.offerId : null

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">P2P Marketplace</h1>
          <p className="text-sm text-app-muted">Buy USDC directly from verified traders.</p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm"><Plus className="h-4 w-4" /> Create offer</Button>
        </Link>
      </div>

      {/* Global accepting banner */}
      {acceptState.phase !== 'idle' && (
        <div className="mb-4 rounded-xl border border-app-accent/30 bg-app-accent/10 px-4 py-3">
          <div className="flex items-center gap-3">
            {acceptState.phase === 'done'
              ? <CheckCircle className="h-5 w-5 shrink-0 text-emerald-400" />
              : <Loader2 className="h-5 w-5 shrink-0 animate-spin text-app-accent-text" />
            }
            <div>
              <p className="text-sm font-medium text-app-text">
                {acceptState.phase === 'signing'     && 'Waiting for wallet signature…'}
                {acceptState.phase === 'confirming'  && 'Confirming on Arc blockchain…'}
                {acceptState.phase === 'updating_db' && 'Finalising trade setup…'}
                {acceptState.phase === 'done'        && 'Trade accepted! Redirecting…'}
              </p>
              <p className="text-xs text-app-muted">
                {acceptState.phase === 'signing'     && 'Please approve the transaction in your wallet'}
                {acceptState.phase === 'confirming'  && 'This usually takes a few seconds'}
                {acceptState.phase === 'updating_db' && 'Almost there…'}
                {acceptState.phase === 'done'        && 'Taking you to the settlement interface'}
              </p>
            </div>
          </div>
          {/* Step progress */}
          <div className="mt-3 flex items-center gap-2">
            {[
              { key: 'signing',     label: 'Sign' },
              { key: 'confirming',  label: 'Confirm' },
              { key: 'updating_db', label: 'Finalise' },
              { key: 'done',        label: 'Done' },
            ].map(({ key, label }, idx) => {
              const phases = ['signing','confirming','updating_db','done']
              const currentIdx = phases.indexOf(acceptState.phase)
              const stepIdx    = phases.indexOf(key)
              const isDone     = stepIdx < currentIdx || acceptState.phase === 'done'
              const isActive   = stepIdx === currentIdx && acceptState.phase !== 'done'
              return (
                <div key={key} className="flex items-center gap-2">
                  <div className={`flex h-6 w-6 items-center justify-center rounded-full text-[10px] font-bold transition-colors
                    ${isDone    ? 'bg-emerald-500 text-white'
                    : isActive  ? 'bg-app-accent text-app-on-accent'
                    :             'bg-app-border text-app-muted'}`}>
                    {isDone ? '✓' : idx + 1}
                  </div>
                  <span className={`text-xs ${isActive || isDone ? 'text-app-text' : 'text-app-muted'}`}>
                    {label}
                  </span>
                  {idx < 3 && <div className="h-px w-4 bg-app-border" />}
                </div>
              )
            })}
          </div>
        </div>
      )}

      {/* Trust badges */}
      <div className="mb-6 flex flex-wrap gap-3">
        {[
          { icon: ShieldCheck, label: 'USDC in escrow'   },
          { icon: Zap,         label: 'Arc settlement'   },
          { icon: Clock,       label: 'Perpetual orders' },
        ].map(({ icon: Icon, label }) => (
          <div key={label}
            className="flex items-center gap-1.5 rounded-lg border border-app-border bg-app-surface px-3 py-1.5 text-xs text-app-muted">
            <Icon className="h-3.5 w-3.5 text-app-accent-text" />{label}
          </div>
        ))}
      </div>

      {/* Filter */}
      <div className="mb-4 flex flex-wrap gap-2">
        {['all', ...LOCAL_CURRENCIES].map(c => (
          <button key={c} onClick={() => setCurrency(c)}
            className={`rounded-full px-3 py-1 text-xs transition-colors
              ${currency === c
                ? 'bg-app-accent text-app-on-accent'
                : 'border border-app-border text-app-muted hover:text-app-text'}`}>
            {c === 'all' ? 'All' : `${CURRENCY_FLAG[c as Currency]} ${c}`}
          </button>
        ))}
        <button onClick={load}
          className="ml-auto rounded-full border border-app-border px-3 py-1 text-xs text-app-muted hover:text-app-text">
          ↻ Refresh
        </button>
      </div>

      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => <div key={i} className="h-24 animate-pulse rounded-xl bg-app-surface" />)}
        </div>
      )}

      {!loading && offers.length === 0 && (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <p className="text-sm text-app-muted">No open offers right now.</p>
          <Link href="/marketplace/create">
            <Button variant="outline" size="sm" className="mt-4">
              <Plus className="h-4 w-4" /> Create the first offer
            </Button>
          </Link>
        </div>
      )}

      <div className="space-y-3">
        {offers.map((offer) => {
          const isOwn  = address?.toLowerCase() === offer.maker_address?.toLowerCase()
          const timer  = (offer as any).maker_timer_seconds ?? 1800
          const type   = (offer as any).order_type ?? 'market'
          const isBusy = busyId === offer.id

          return (
            <div key={offer.id}
              className={`rounded-xl border bg-app-surface p-4 transition-colors
                ${isBusy ? 'border-app-accent/40' : 'border-app-border'}`}>
              <div className="flex items-center gap-4">
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-app-bg text-xl">
                  {CURRENCY_FLAG[offer.local_currency as Currency] ?? '🌍'}
                </div>

                <div className="flex-1 min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <p className="font-medium text-app-text">
                      {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                      <span className="mx-1.5 text-app-muted">→</span>
                      {Number(offer.usdc_amount).toFixed(2)} USDC
                    </p>
                    {isOwn && <Badge variant="arc">Your offer</Badge>}
                    <Badge variant={type === 'limit' ? 'warning' : 'arc'}>{type}</Badge>
                  </div>
                  <div className="mt-1.5 flex flex-wrap items-center gap-3">
                    <ClientOnly fallback={<span className="text-xs text-app-muted">…</span>}>
                      <UserDisplay address={offer.maker_address} size="xs" suffix={isOwn ? '(you)' : undefined} />
                    </ClientOnly>
                    <span className="text-xs text-app-muted">·</span>
                    <span className="text-xs text-app-muted">
                      1 USDC = {Number(offer.rate_offered) > 0
                        ? (1 / Number(offer.rate_offered)).toFixed(2)
                        : '-'} {offer.local_currency}
                    </span>
                    <span className="text-xs text-app-muted">·</span>
                    <span className="flex items-center gap-1 text-xs text-app-muted">
                      <Clock className="h-3 w-3" />{formatTimer(timer)}
                    </span>
                  </div>
                </div>

                <div className="shrink-0">
                  {isOwn ? (
                    <Link href={`/marketplace/${offer.id}`}>
                      <Button variant="outline" size="sm">
                        Manage <ArrowRight className="h-3.5 w-3.5" />
                      </Button>
                    </Link>
                  ) : (
                    <ClientOnly>
                      <Button size="sm"
                        onClick={() => handleAccept(offer)}
                        disabled={!address || !!busyId}>
                        {isBusy ? (
                          <><Loader2 className="h-3.5 w-3.5 animate-spin" />
                          {acceptState.phase === 'signing'    ? 'Signing…'
                          : acceptState.phase === 'confirming' ? 'Confirming…'
                          : acceptState.phase === 'done'       ? 'Redirecting…'
                          : 'Processing…'}
                          </>
                        ) : 'Buy USDC'}
                      </Button>
                    </ClientOnly>
                  )}
                </div>
              </div>
            </div>
          )
        })}
      </div>

      {p2pErr && (
        <div className="mt-4 rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">
          {p2pErr}
        </div>
      )}
    </div>
  )
}

export default function MarketplacePage() {
  return (
    <SectionGuard section="marketplace">
      <MarketplacePageInner />
    </SectionGuard>
  )
}
AFX_L006_EOF
echo "  ✓ afrifx-web/app/(app)/marketplace/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/my-trades/page.tsx")"
cat > 'afrifx-web/app/(app)/my-trades/page.tsx' <<'AFX_L007_EOF'
'use client'
import { useEffect, useState } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { UserDisplay } from '@/components/profile/UserDisplay'
import { ArrowRight, Plus, ExternalLink } from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

function normalizeOffer(row: any): P2POffer {
  if (Array.isArray(row)) {
    return {
      id: row[0], maker_address: row[1], taker_address: row[2],
      usdc_amount: Number(row[3]), local_currency: row[4],
      local_amount: Number(row[5]), rate_offered: Number(row[6]),
      status: row[7], maker_confirmed: Number(row[8]),
      taker_confirmed: Number(row[9]), arc_tx_hash: row[10],
      release_tx_hash: row[11], expires_at: Number(row[12]),
      created_at: Number(row[13]), updated_at: Number(row[14]),
      order_type: row[15] ?? 'market',
      maker_timer_seconds: Number(row[17] ?? 1800),
    } as any
  }
  return {
    ...row,
    maker_confirmed:     Number(row.maker_confirmed     ?? 0),
    taker_confirmed:     Number(row.taker_confirmed     ?? 0),
    maker_timer_seconds: Number(row.maker_timer_seconds ?? 1800),
  } as P2POffer
}

const STATUS_BADGE: Record<string, any> = {
  open: 'warning', accepted: 'arc', released: 'success', cancelled: 'danger',
}

export default function MyTradesPage() {
  const { address, isConnected } = useAccount()
  const [offers,  setOffers]  = useState<P2POffer[]>([])
  const [loading, setLoading] = useState(true)
  const [filter,  setFilter]  = useState<'all'|'open'|'accepted'|'released'|'cancelled'>('all')

  useEffect(() => {
    if (!address) { setLoading(false); return }
    fetch(`${API}/offers/my?wallet=${address}`)
      .then(r => r.json())
      .then(data => setOffers(Array.isArray(data) ? data.map(normalizeOffer) : []))
      .catch(() => setOffers([]))
      .finally(() => setLoading(false))
  }, [address])

  const filtered = filter === 'all' ? offers : offers.filter(o => o.status === filter)

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-app-muted">Connect your wallet to view your trades.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">My trades</h1>
          <p className="text-sm text-app-muted">All your P2P trades, as buyer or seller.</p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm"><Plus className="h-4 w-4" /> New offer</Button>
        </Link>
      </div>

      {/* Filter tabs */}
      <div className="mb-4 flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 w-fit">
        {(['all','open','accepted','released','cancelled'] as const).map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-app-border text-app-text' : 'text-app-muted hover:text-app-text'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => <div key={i} className="h-24 animate-pulse rounded-xl bg-app-surface" />)}
        </div>
      )}

      {!loading && filtered.length === 0 && (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <p className="text-sm text-app-muted">No trades found.</p>
          <Link href="/marketplace/create">
            <Button variant="outline" size="sm" className="mt-4">
              <Plus className="h-4 w-4" /> Create your first offer
            </Button>
          </Link>
        </div>
      )}

      <div className="space-y-3">
        {filtered.map((offer) => {
          const isMaker  = address?.toLowerCase() === offer.maker_address?.toLowerCase()
          const isTaker  = address?.toLowerCase() === offer.taker_address?.toLowerCase()
          const myRole   = isMaker ? 'Seller' : 'Buyer'
          const otherAddr = isMaker ? offer.taker_address : offer.maker_address
          const otherRole = isMaker ? 'Buyer' : 'Seller'

          return (
            <div key={offer.id}
              className="rounded-xl border border-app-border bg-app-surface p-4">
              <div className="flex items-center gap-4">
                {/* Flag */}
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-app-bg text-xl">
                  {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
                </div>

                {/* Details */}
                <div className="flex-1 min-w-0 space-y-1.5">
                  <div className="flex flex-wrap items-center gap-2">
                    <p className="font-medium text-app-text">
                      {Number(offer.usdc_amount).toFixed(2)} USDC
                      <span className="mx-1.5 text-app-muted">↔</span>
                      {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                    </p>
                    <Badge variant="arc">{myRole}</Badge>
                    <Badge variant={STATUS_BADGE[offer.status] ?? 'default'}>{offer.status}</Badge>
                    {(offer as any).order_type && (
                      <Badge variant={(offer as any).order_type === 'limit' ? 'warning' : 'arc'}>
                        {(offer as any).order_type}
                      </Badge>
                    )}
                  </div>

                  {/* Counterparty + date */}
                  <div className="flex flex-wrap items-center gap-3">
                    <span className="text-xs text-app-muted">{otherRole}:</span>
                    <ClientOnly fallback={<span className="text-xs text-app-muted">Loading…</span>}>
                      {otherAddr
                        ? <UserDisplay address={otherAddr} size="xs" fallback="Waiting…" />
                        : <span className="text-xs text-app-muted">Waiting for buyer…</span>
                      }
                    </ClientOnly>
                    <span className="text-xs text-app-muted">·</span>
                    <span className="text-xs text-app-muted">
                      {new Date(offer.created_at * 1000).toLocaleDateString()}
                    </span>
                    {offer.release_tx_hash && (
                      <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                        target="_blank" rel="noopener noreferrer"
                        className="inline-flex items-center gap-1 text-xs text-emerald-400 hover:underline">
                        Release tx <ExternalLink className="h-3 w-3" />
                      </a>
                    )}
                  </div>
                </div>

                <Link href={`/marketplace/${offer.id}`} className="shrink-0">
                  <Button variant="outline" size="sm">
                    View <ArrowRight className="h-3.5 w-3.5" />
                  </Button>
                </Link>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
AFX_L007_EOF
echo "  ✓ afrifx-web/app/(app)/my-trades/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/profile/page.tsx")"
cat > 'afrifx-web/app/(app)/profile/page.tsx' <<'AFX_L008_EOF'
'use client'
import { EmailPreferences } from '@/components/notifications/EmailPreferences'
import { useState } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { useProfile } from '@/hooks/useProfile'
import { useQueryClient } from '@tanstack/react-query'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ClientOnly } from '@/components/ui/client-only'
import {
  Twitter, AtSign, Edit2, CheckCircle,
  Loader2, ExternalLink, Star, ShieldCheck,
  TrendingUp, AlertTriangle, Copy, Check,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export default function ProfilePage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-48 animate-pulse rounded-xl bg-app-surface" />
        <div className="h-32 animate-pulse rounded-xl bg-app-surface" />
      </div>
    }>
      <ProfileContent />
    </ClientOnly>
  )
}

function ProfileContent() {
  const { address }                    = useAccount()
  const { data: profile, refetch }     = useProfile()
  const queryClient                    = useQueryClient()

  const [editing,     setEditing]     = useState(false)
  const [displayName, setDisplayName] = useState('')
  const [bio,         setBio]         = useState('')
  const [twitter,     setTwitter]     = useState('')
  const [telegram,    setTelegram]    = useState('')
  const [showSocials, setShowSocials] = useState(true)
  const [saving,      setSaving]      = useState(false)
  const [copied,      setCopied]      = useState(false)

  function startEdit() {
    if (!profile) return
    setDisplayName(profile.display_name)
    setBio(profile.bio ?? '')
    setTwitter(profile.twitter_handle ?? '')
    setTelegram(profile.telegram_handle ?? '')
    setShowSocials(profile.show_socials)
    setEditing(true)
  }

  async function saveEdit() {
    if (!address) return
    setSaving(true)
    try {
      await fetch(`${API}/profile/${address}`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          displayName, bio,
          twitterHandle: twitter, telegramHandle: telegram, showSocials,
        }),
      })
      await queryClient.invalidateQueries({ queryKey: ['profile', address] })
      await refetch()
      setEditing(false)
    } finally { setSaving(false) }
  }

  function copyAddress() {
    if (!address) return
    navigator.clipboard.writeText(address)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  if (!profile) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-app-muted" />
      </div>
    )
  }

  // Use live counts from subquery (never 0 if trades exist)
  const makerTrades   = Number((profile as any).maker_trades   ?? 0)
  const takerTrades   = Number((profile as any).taker_trades   ?? 0)
  const totalTrades   = makerTrades + takerTrades
  const totalDisputes = Number((profile as any).total_disputes ?? profile.dispute_count ?? 0)

  // Reputation tiers
  const reputation =
    totalTrades >= 20 && totalDisputes === 0 ? 'Elite' :
    totalTrades >= 10 && totalDisputes === 0 ? 'Verified' :
    totalTrades >= 5  ? 'Trusted' :
    totalTrades >= 1  ? 'Active'  : 'New'

  const isVerified = totalTrades >= 10 && totalDisputes === 0

  const repColor = {
    Elite:    'text-amber-400',
    Verified: 'text-app-accent-text',
    Trusted:  'text-emerald-400',
    Active:   'text-emerald-400',
    New:      'text-app-muted',
  }[reputation]

  const repBg = {
    Elite:    'bg-amber-900/20 border-amber-900/40',
    Verified: 'bg-app-accent/10 border-app-accent/30',
    Trusted:  'bg-emerald-900/20 border-emerald-900/40',
    Active:   'bg-emerald-900/10 border-emerald-900/20',
    New:      'bg-app-border border-app-border',
  }[reputation]

  // Progress to next tier
  const nextTier = totalTrades < 1 ? { label: 'Active', need: 1, current: totalTrades }
    : totalTrades < 5  ? { label: 'Trusted',  need: 5,  current: totalTrades }
    : totalTrades < 10 ? { label: 'Verified', need: 10, current: totalTrades }
    : totalTrades < 20 ? { label: 'Elite',    need: 20, current: totalTrades }
    : null

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-app-text">My profile</h1>
        {!editing && (
          <Button variant="outline" size="sm" onClick={startEdit}>
            <Edit2 className="h-3.5 w-3.5" /> Edit
          </Button>
        )}
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-3">

        {/* Profile card */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex flex-col items-center gap-3 text-center">
            <ProfileAvatar
              displayName={profile.display_name}
              avatarColor={profile.avatar_color}
              size="xl"
              verified={isVerified}
            />
            {editing ? (
              <Input value={displayName} onChange={e => setDisplayName(e.target.value)}
                className="text-center" />
            ) : (
              <div>
                <div className="flex items-center justify-center gap-2">
                  <h2 className="text-lg font-semibold text-app-text">
                    {profile.display_name}
                  </h2>
                  {isVerified && <Badge variant="arc">✓ Verified</Badge>}
                </div>
                <p className="text-sm text-app-accent-text">@{profile.username}</p>
              </div>
            )}
          </div>

          {/* Bio */}
          {editing ? (
            <textarea value={bio} onChange={e => setBio(e.target.value)}
              placeholder="Add a bio…" maxLength={160} rows={3}
              className="mb-3 w-full resize-none rounded-md border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted focus:outline-none focus:ring-1 focus:ring-app-accent" />
          ) : profile.bio ? (
            <p className="mb-4 text-center text-sm text-app-muted">{profile.bio}</p>
          ) : null}

          {/* Wallet address */}
          <div className="mb-4 flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2">
            <div className="flex-1 min-w-0">
              <p className="text-[10px] text-app-muted">Wallet</p>
              <p className="truncate font-mono text-xs text-app-text">
                {address?.slice(0,10)}…{address?.slice(-6)}
              </p>
            </div>
            <button onClick={copyAddress} className="shrink-0 text-app-muted hover:text-app-text">
              {copied
                ? <Check className="h-3.5 w-3.5 text-emerald-400" />
                : <Copy className="h-3.5 w-3.5" />
              }
            </button>
            <a href={`https://testnet.arcscan.app/address/${address}`}
              target="_blank" rel="noopener noreferrer"
              className="shrink-0 text-app-muted hover:text-app-accent-text">
              <ExternalLink className="h-3.5 w-3.5" />
            </a>
          </div>

          {/* Socials */}
          {editing ? (
            <div className="space-y-2">
              <div className="relative">
                <Twitter className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-app-muted" />
                <Input value={twitter} onChange={e => setTwitter(e.target.value.replace('@',''))}
                  placeholder="Twitter handle" className="pl-8 text-sm" />
              </div>
              <div className="relative">
                <AtSign className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-app-muted" />
                <Input value={telegram} onChange={e => setTelegram(e.target.value.replace('@',''))}
                  placeholder="Telegram handle" className="pl-8 text-sm" />
              </div>
              <div className="flex items-center justify-between text-xs">
                <span className="text-app-muted">Show socials publicly</span>
                <button onClick={() => setShowSocials(!showSocials)}
                  className={`relative h-5 w-9 rounded-full transition-colors ${showSocials ? 'bg-app-accent' : 'bg-app-border'}`}>
                  <span className={`absolute top-0.5 h-4 w-4 rounded-full bg-white transition-transform ${showSocials ? 'translate-x-4' : 'translate-x-0.5'}`} />
                </button>
              </div>
            </div>
          ) : (
            <div className="space-y-1.5 text-xs text-app-muted">
              {profile.twitter_handle && (
                <a href={`https://twitter.com/${profile.twitter_handle}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-app-text">
                  <Twitter className="h-3.5 w-3.5" /> @{profile.twitter_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
              {profile.telegram_handle && (
                <a href={`https://t.me/${profile.telegram_handle}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-app-text">
                  <AtSign className="h-3.5 w-3.5" /> @{profile.telegram_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
              {!profile.twitter_handle && !profile.telegram_handle && (
                <p className="text-center">No socials added yet</p>
              )}
            </div>
          )}

          {editing && (
            <div className="mt-4 flex gap-2">
              <Button variant="outline" className="flex-1" onClick={() => setEditing(false)}>Cancel</Button>
              <Button className="flex-1" onClick={saveEdit} disabled={saving}>
                {saving ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</> : 'Save'}
              </Button>
            </div>
          )}
        </div>

        {/* Reputation + Stats */}
        <div className="lg:col-span-2 space-y-4">

          {/* Reputation banner */}
          <div className={`rounded-xl border p-5 ${repBg}`}>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <div className={`flex h-12 w-12 items-center justify-center rounded-full border ${repBg}`}>
                  <Star className={`h-6 w-6 ${repColor}`} />
                </div>
                <div>
                  <p className={`text-lg font-bold ${repColor}`}>{reputation} Trader</p>
                  <p className="text-xs text-app-muted">
                    {totalTrades} completed trade{totalTrades !== 1 ? 's' : ''} ·{' '}
                    {totalDisputes === 0
                      ? 'Clean record'
                      : `${totalDisputes} dispute${totalDisputes !== 1 ? 's' : ''}`}
                  </p>
                </div>
              </div>
              {isVerified && (
                <div className="flex items-center gap-2 rounded-full bg-app-accent/10 px-3 py-1.5 text-xs text-app-accent-text">
                  <ShieldCheck className="h-3.5 w-3.5" />
                  Verified
                </div>
              )}
            </div>

            {/* Progress to next tier */}
            {nextTier && (
              <div className="mt-4">
                <div className="mb-1 flex justify-between text-xs">
                  <span className="text-app-muted">Progress to {nextTier.label}</span>
                  <span className="text-app-text">
                    {nextTier.current}/{nextTier.need} trades
                    {totalDisputes > 0 ? ' · disputes blocking upgrade' : ''}
                  </span>
                </div>
                <div className="h-1.5 w-full overflow-hidden rounded-full bg-app-border">
                  <div
                    className={`h-full rounded-full transition-all ${repColor.replace('text-','bg-')}`}
                    style={{ width: `${Math.min(100, (nextTier.current / nextTier.need) * 100)}%` }}
                  />
                </div>
              </div>
            )}
          </div>

          {/* Stats grid */}
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {[
              {
                label: 'Total trades',
                value: String(totalTrades),
                icon:  TrendingUp,
                color: 'text-emerald-400',
                sub:   `${makerTrades} as maker · ${takerTrades} as taker`,
              },
              {
                label: 'Seller trades',
                value: String(makerTrades),
                icon:  TrendingUp,
                color: 'text-app-accent-text',
                sub:   'Offers you created',
              },
              {
                label: 'Buyer trades',
                value: String(takerTrades),
                icon:  TrendingUp,
                color: 'text-app-accent-text',
                sub:   'Offers you accepted',
              },
              {
                label: 'Disputes',
                value: String(totalDisputes),
                icon:  totalDisputes > 0 ? AlertTriangle : CheckCircle,
                color: totalDisputes > 0 ? 'text-red-400' : 'text-emerald-400',
                sub:   totalDisputes === 0 ? 'Clean record ✓' : 'Raised against you',
              },
            ].map(({ label, value, icon: Icon, color, sub }) => (
              <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4 text-center">
                <Icon className={`mx-auto mb-1 h-4 w-4 ${color}`} />
                <p className={`font-mono text-2xl font-bold ${color}`}>{value}</p>
                <p className="mt-0.5 text-xs font-medium text-app-text">{label}</p>
                <p className="mt-0.5 text-[10px] text-app-muted">{sub}</p>
              </div>
            ))}
          </div>

          {/* Shareable profile link */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-2 text-sm font-medium text-app-text">Public profile link</p>
            <div className="flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2">
              <p className="flex-1 truncate font-mono text-xs text-app-accent-text">
                {typeof window !== 'undefined' ? window.location.origin : ''}/profile/{profile.username}
              </p>
              <button
                onClick={() => navigator.clipboard.writeText(
                  `${window.location.origin}/profile/${profile.username}`
                )}
                className="shrink-0 text-xs text-app-muted hover:text-app-text">
                Copy
              </button>
            </div>
            <p className="mt-2 text-xs text-app-muted">
              Share this link so traders can verify your reputation before trading with you.
            </p>
          </div>

          {/* Email notification preferences */}
          <EmailPreferences />
        </div>
      </div>
    </div>
  )
}
AFX_L008_EOF
echo "  ✓ afrifx-web/app/(app)/profile/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/settlements/page.tsx")"
cat > 'afrifx-web/app/(app)/settlements/page.tsx' <<'AFX_L009_EOF'
'use client'
import { useState } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { useSettlementReport } from '@/hooks/usePayments'
import { useFXRates } from '@/hooks/useFXRate'
import { ClientOnly } from '@/components/ui/client-only'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { formatAmount } from '@/lib/utils'
import { Download, Loader2, TrendingUp, TrendingDown, ExternalLink } from 'lucide-react'

export default function SettlementsPage() {
  return <ClientOnly><SettlementsContent /></ClientOnly>
}

function SettlementsContent() {
  const { address }          = useAccount()
  const { data: rates = [] } = useFXRates()
  const [range,    setRange] = useState('30')
  const [activeTab, setTab]  = useState<'sent'|'received'|'invoices'|'transactions'>('sent')

  const now    = Math.floor(Date.now() / 1000)
  const fromTs = now - Number(range) * 86400

  const { data, isLoading } = useSettlementReport(fromTs, now)

  // Convert any amount to USD using live rates
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

  function downloadCSV() {
    if (!data) return
    const rows: string[] = []
    rows.push('Type,Reference,Amount,Currency,USD Equivalent,Counterparty,Date,Status,TxHash')

    data.payments.sent.forEach((p: any) => {
      rows.push([
        'Payment Sent', p.memo_ref, p.amount, p.currency,
        toUSD(p.amount, p.currency).toFixed(2),
        p.recipient_address,
        new Date(p.created_at * 1000).toISOString(),
        p.status, p.arc_tx_hash ?? '',
      ].join(','))
    })
    data.payments.received.forEach((p: any) => {
      rows.push([
        'Payment Received', p.memo_ref, p.amount, p.currency,
        toUSD(p.amount, p.currency).toFixed(2),
        p.sender_address,
        new Date(p.created_at * 1000).toISOString(),
        p.status, p.arc_tx_hash ?? '',
      ].join(','))
    })
    data.invoices.forEach((inv: any) => {
      rows.push([
        'Invoice', inv.memo_ref, inv.amount, inv.currency,
        toUSD(inv.amount, inv.currency).toFixed(2),
        inv.creator_address,
        new Date(inv.created_at * 1000).toISOString(),
        inv.status, inv.payment_tx_hash ?? '',
      ].join(','))
    })
    data.transactions.forEach((tx: any) => {
      const fromCcy = tx.from_currency ?? tx[2]
      const fromAmt = Number(tx.from_amount ?? tx[4] ?? 0)
      const toAmt   = Number(tx.to_amount ?? tx[5] ?? 0)
      const toCcy   = tx.to_currency ?? tx[3]
      const usdVal  = toCcy === 'USDC' ? toAmt : fromCcy === 'USDC' ? fromAmt : toUSD(fromAmt, fromCcy)
      rows.push([
        'FX Conversion', tx.reference ?? tx.id, fromAmt, fromCcy,
        usdVal.toFixed(2),
        'AfriFX Vault',
        new Date((Number(tx.created_at) || 0) * 1000).toISOString(),
        tx.status, tx.arc_tx_hash ?? '',
      ].join(','))
    })

    const blob = new Blob([rows.join('\n')], { type: 'text/csv' })
    const url  = URL.createObjectURL(blob)
    const a    = document.createElement('a')
    a.href     = url
    a.download = `afrifx-settlements-${new Date().toISOString().slice(0,10)}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const tabData = {
    sent:         data?.payments.sent         ?? [],
    received:     data?.payments.received     ?? [],
    invoices:     data?.invoices              ?? [],
    transactions: data?.transactions          ?? [],
  }

  // Compute USD totals from the current tab data
  const totalSentUSD     = (data?.payments.sent     ?? []).reduce((s: number, p: any) => s + toUSD(Number(p.amount), p.currency), 0)
  const totalReceivedUSD = (data?.payments.received ?? []).reduce((s: number, p: any) => s + toUSD(Number(p.amount), p.currency), 0)
  const netFlow          = totalReceivedUSD - totalSentUSD

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Settlement reports</h1>
          <p className="text-sm text-app-muted">Full payment history with USD equivalents · exportable</p>
        </div>
        <div className="flex gap-2">
          <select value={range} onChange={e => setRange(e.target.value)}
            className="rounded-lg border border-app-border bg-app-surface px-3 py-1.5 text-xs text-app-text outline-none">
            <option value="7">Last 7 days</option>
            <option value="30">Last 30 days</option>
            <option value="90">Last 90 days</option>
            <option value="365">Last year</option>
          </select>
          <Button size="sm" onClick={downloadCSV} disabled={!data}>
            <Download className="h-4 w-4" /> Export CSV
          </Button>
        </div>
      </div>

      {/* Summary cards */}
      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-3">
        {[
          {
            label: 'Total sent (USD)',
            value: `$${formatAmount(totalSentUSD)}`,
            icon:  TrendingDown,
            color: 'text-red-400',
          },
          {
            label: 'Total received (USD)',
            value: `$${formatAmount(totalReceivedUSD)}`,
            icon:  TrendingUp,
            color: 'text-emerald-400',
          },
          {
            label: 'Net position',
            value: `${netFlow >= 0 ? '+' : ''}$${formatAmount(Math.abs(netFlow))}`,
            icon:  netFlow >= 0 ? TrendingUp : TrendingDown,
            color: netFlow >= 0 ? 'text-emerald-400' : 'text-red-400',
          },
        ].map(({ label, value, icon: Icon, color }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="flex items-center justify-between">
              <p className="text-xs text-app-muted">{label}</p>
              <Icon className={`h-4 w-4 ${color}`} />
            </div>
            <p className={`mt-1 font-mono text-xl font-bold ${color}`}>
              {isLoading ? <span className="inline-block h-6 w-24 animate-pulse rounded bg-app-border" /> : value}
            </p>
          </div>
        ))}
      </div>

      {/* Tabs */}
      <div className="mb-4 flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 w-fit">
        {([
          ['sent',         'Sent'],
          ['received',     'Received'],
          ['invoices',     'Invoices'],
          ['transactions', 'FX conversions'],
        ] as const).map(([t, l]) => (
          <button key={t} onClick={() => setTab(t)}
            className={`rounded-md px-3 py-1.5 text-xs transition-colors
              ${activeTab === t ? 'bg-app-border text-app-text' : 'text-app-muted hover:text-app-text'}`}>
            {l} {data ? `(${tabData[t].length})` : ''}
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
        </div>
      ) : tabData[activeTab].length === 0 ? (
        <div className="rounded-xl border border-app-border bg-app-surface p-8 text-center text-sm text-app-muted">
          No {activeTab} in this period
        </div>
      ) : (
        <div className="rounded-xl border border-app-border bg-app-surface overflow-hidden overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-app-border text-left text-xs text-app-muted">
                <th className="px-4 py-3 font-medium">Reference</th>
                <th className="px-4 py-3 font-medium">Amount</th>
                <th className="px-4 py-3 font-medium">USD value</th>
                <th className="px-4 py-3 font-medium">Counterparty</th>
                <th className="px-4 py-3 font-medium">Date</th>
                <th className="px-4 py-3 font-medium">Status</th>
                <th className="px-4 py-3 font-medium">Tx</th>
              </tr>
            </thead>
            <tbody>
              {tabData[activeTab].map((item: any) => {
                const ref      = item.memo_ref ?? item.reference ?? (item.id ?? '').slice(0,12)
                const fromCcy  = item.from_currency ?? item[2]
                const toCcy    = item.to_currency   ?? item[3]
                const fromAmt  = Number(item.from_amount ?? item[4] ?? 0)
                const toAmt    = Number(item.to_amount   ?? item[5] ?? 0)
                const amount   = item.amount ?? fromAmt
                const currency = item.currency ?? fromCcy
                const usdVal   = activeTab === 'transactions'
                  ? (toCcy === 'USDC' ? toAmt : fromCcy === 'USDC' ? fromAmt : toUSD(fromAmt, fromCcy))
                  : toUSD(Number(amount), currency)
                const counterparty = item.recipient_address ?? item.sender_address ?? item.creator_address ?? 'AfriFX Vault'
                const date     = new Date((Number(item.created_at) || 0) * 1000).toLocaleDateString()
                const status   = item.status ?? 'settled'
                const hash     = item.arc_tx_hash ?? item.payment_tx_hash

                return (
                  <tr key={item.id} className="border-b border-app-border/50 last:border-0 hover:bg-app-bg/50 transition-colors">
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-app-accent-text">{ref}</span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-app-text">
                        {formatAmount(Number(amount))} {currency}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-emerald-400">
                        ${formatAmount(usdVal)}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-app-muted">
                        {typeof counterparty === 'string' && counterparty.startsWith('0x')
                          ? `${counterparty.slice(0,8)}…`
                          : counterparty}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-xs text-app-muted whitespace-nowrap">{date}</td>
                    <td className="px-4 py-3">
                      <Badge variant={
                        status === 'settled' || status === 'paid' ? 'success' :
                        status === 'failed'  || status === 'cancelled' ? 'danger' : 'warning'
                      }>
                        {status}
                      </Badge>
                    </td>
                    <td className="px-4 py-3">
                      {hash && (
                        <a href={`https://testnet.arcscan.app/tx/${hash}`}
                          target="_blank" rel="noopener noreferrer"
                          className="text-app-muted hover:text-app-accent-text transition-colors">
                          <ExternalLink className="h-3.5 w-3.5" />
                        </a>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
AFX_L009_EOF
echo "  ✓ afrifx-web/app/(app)/settlements/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(app)/treasury/TreasuryContent.tsx")"
cat > 'afrifx-web/app/(app)/treasury/TreasuryContent.tsx' <<'AFX_L010_EOF'
'use client'
import { useState } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useWallet } from '@/hooks/useWallet'
import { usePayrollBatches } from '@/hooks/usePayroll'
import { useTreasuryRules, useCreateRule, useToggleRule, useDeleteRule } from '@/hooks/useTreasury'
import { useFXRates } from '@/hooks/useFXRate'
import { formatAmount } from '@/lib/utils'
import { GatewayBalancePanel } from '@/components/treasury/GatewayBalancePanel'
import {
  Plus, Zap, Trash2, Pause, Play,
  AlertTriangle, ArrowRight, Users, Building2,
  ChevronDown, ChevronUp, ExternalLink,
} from 'lucide-react'

const CURRENCIES  = ['NGN','GHS','KES','ZAR','EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN:'🇳🇬',GHS:'🇬🇭',KES:'🇰🇪',ZAR:'🇿🇦',EGP:'🇪🇬'
}

export function TreasuryContent() {
  const { address }               = useAccount()
  const router                    = useRouter()
  const { data: wallet }          = useWallet()
  const { data: rules = [] }      = useTreasuryRules()
  const { data: batches = [] }    = usePayrollBatches()
  const { data: rates = [] }      = useFXRates()
  const createRule                = useCreateRule()
  const toggleRule                = useToggleRule()
  const deleteRule                = useDeleteRule()

  const [showRuleForm, setShowRuleForm] = useState(false)
  const [ruleName,     setRuleName]     = useState('')
  const [threshold,    setThreshold]    = useState('')
  const [actionType,   setActionType]   = useState<'percent'|'fixed'>('percent')
  const [actionVal,    setActionVal]    = useState('')
  const [targetCcy,    setTargetCcy]    = useState('NGN')

  const usdcBalance = wallet?.tokens.find(t => t.symbol === 'USDC')?.balance ?? 0
  const escrowLocked = wallet?.escrow.locked ?? 0
  const triggeredRules = rules.filter(r => r.status === 'triggered')

  async function handleCreateRule() {
    if (!ruleName || !threshold || !actionVal) return
    await createRule.mutateAsync({
      name:              ruleName,
      trigger_threshold: parseFloat(threshold),
      action_percent:    actionType === 'percent' ? parseFloat(actionVal) : null,
      action_amount:     actionType === 'fixed'   ? parseFloat(actionVal) : null,
      target_currency:   targetCcy,
    })
    setRuleName(''); setThreshold(''); setActionVal('')
    setShowRuleForm(false)
  }

  function getConversionAmount(rule: typeof rules[0]): number {
    if (rule.action_percent) return usdcBalance * (rule.action_percent / 100)
    return rule.action_amount ?? 0
  }

  function getLocalEquiv(usdcAmt: number, currency: string): string {
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    if (!rate) return '-'
    return (usdcAmt / rate).toLocaleString(undefined, { maximumFractionDigits: 0 })
  }

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Business Treasury</h1>
          <p className="text-sm text-app-muted">Automate conversions · manage payroll · track funds</p>
        </div>
        <Link href="/treasury/payroll">
          <Button size="sm">
            <Users className="h-4 w-4" /> New payroll
          </Button>
        </Link>
      </div>

      {/* Triggered rules alert */}
      {triggeredRules.length > 0 && (
        <div className="mb-4 rounded-xl border border-amber-900/50 bg-amber-900/20 p-4">
          <div className="flex items-start gap-3">
            <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-400" />
            <div className="flex-1">
              <p className="text-sm font-medium text-amber-400">
                {triggeredRules.length} auto-conversion rule{triggeredRules.length > 1 ? 's' : ''} triggered
              </p>
              {triggeredRules.map(r => {
                const amt = getConversionAmount(r)
                return (
                  <div key={r.id} className="mt-2 flex items-center justify-between text-xs">
                    <span className="text-amber-600">
                      "{r.name}", convert {r.action_percent ? `${r.action_percent}%` : `${r.action_amount} USDC`} to {r.target_currency}
                      {amt > 0 && ` (≈ ${getLocalEquiv(amt, r.target_currency)} ${r.target_currency})`}
                    </span>
                    <div className="flex gap-2">
                      <Link href="/convert">
                        <Button size="sm" className="h-7 text-xs">
                          Convert now <ArrowRight className="h-3 w-3" />
                        </Button>
                      </Link>
                      <Button size="sm" variant="outline" className="h-7 text-xs"
                        onClick={() => toggleRule.mutate({ id: r.id, status: 'active' })}>
                        Dismiss
                      </Button>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        </div>
      )}

      {/* Stats row */}
      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {[
          { label: 'Available USDC',   value: `$${formatAmount(usdcBalance)}`,  sub: 'ready to use'        },
          { label: 'In escrow',        value: `$${formatAmount(escrowLocked)}`, sub: 'locked in P2P offers' },
          { label: 'Active rules',     value: String(rules.filter(r => r.status === 'active').length),
            sub: 'auto-conversion rules' },
          { label: 'Payrolls run',     value: String(batches.filter(b => b.status === 'completed').length),
            sub: `$${formatAmount(batches.filter(b => b.status === 'completed').reduce((s,b) => s + b.total_amount, 0))} total paid` },
        ].map(({ label, value, sub }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4">
            <p className="text-xs text-app-muted">{label}</p>
            <p className="mt-1 font-mono text-xl font-semibold text-app-text">{value}</p>
            <p className="mt-0.5 text-xs text-app-muted">{sub}</p>
          </div>
        ))}
      </div>

      {/* Circle Gateway unified balance read-only for now. Sits above the
          existing panels because "how much can I actually spend, anywhere" is
          the first question when funding a payout. */}
      <div className="mb-4">
        <GatewayBalancePanel />
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-2">

        {/* Auto-conversion rules */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-app-text">Auto-conversion rules</p>
              <p className="text-xs text-app-muted">Trigger when USDC balance crosses a threshold</p>
            </div>
            <Button size="sm" variant="outline"
              onClick={() => setShowRuleForm(!showRuleForm)}>
              <Plus className="h-3.5 w-3.5" /> New rule
            </Button>
          </div>

          {/* Create rule form */}
          {showRuleForm && (
            <div className="mb-4 space-y-3 rounded-xl border border-app-border bg-app-bg p-4">
              <p className="text-xs font-medium text-app-text">New rule</p>
              <Input placeholder="Rule name (e.g. Convert excess NGN)"
                value={ruleName} onChange={e => setRuleName(e.target.value)} />
              <div className="flex gap-2">
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-app-muted">When USDC balance exceeds</p>
                  <Input type="number" placeholder="1000" value={threshold}
                    onChange={e => setThreshold(e.target.value)} />
                </div>
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-app-muted">Target currency</p>
                  <select value={targetCcy} onChange={e => setTargetCcy(e.target.value)}
                    className="w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none">
                    {CURRENCIES.map(c => (
                      <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
                    ))}
                  </select>
                </div>
              </div>
              <div>
                <p className="mb-1 text-[10px] text-app-muted">Convert</p>
                <div className="flex gap-2">
                  <div className="flex rounded-lg border border-app-border bg-app-surface">
                    {(['percent','fixed'] as const).map(t => (
                      <button key={t} onClick={() => setActionType(t)}
                        className={`px-3 py-1.5 text-xs transition-colors rounded-lg
                          ${actionType === t ? 'bg-app-accent text-app-on-accent' : 'text-app-muted'}`}>
                        {t === 'percent' ? '%' : 'Fixed'}
                      </button>
                    ))}
                  </div>
                  <Input type="number"
                    placeholder={actionType === 'percent' ? '30 (%)' : 'Amount (USDC)'}
                    value={actionVal} onChange={e => setActionVal(e.target.value)}
                    className="flex-1" />
                </div>
              </div>
              <div className="flex gap-2">
                <Button size="sm" variant="outline" className="flex-1"
                  onClick={() => setShowRuleForm(false)}>Cancel</Button>
                <Button size="sm" className="flex-1" onClick={handleCreateRule}
                  disabled={createRule.isPending || !ruleName || !threshold || !actionVal}>
                  {createRule.isPending ? 'Saving…' : 'Save rule'}
                </Button>
              </div>
            </div>
          )}

          {/* Rules list */}
          {rules.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Zap className="h-8 w-8 text-app-border" />
              <p className="text-sm text-app-muted">No rules yet</p>
              <p className="text-xs text-app-muted">
                Create a rule to be alerted when your balance crosses a threshold
              </p>
            </div>
          ) : (
            <div className="space-y-2">
              {rules.map(rule => {
                const amt = getConversionAmount(rule)
                return (
                  <div key={rule.id}
                    className="rounded-xl border border-app-border bg-app-bg p-3">
                    <div className="flex items-start justify-between gap-2">
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2">
                          <p className="text-sm font-medium text-app-text truncate">{rule.name}</p>
                          <Badge variant={
                            rule.status === 'triggered' ? 'warning' :
                            rule.status === 'active'    ? 'success'  : 'default'
                          }>
                            {rule.status}
                          </Badge>
                        </div>
                        <p className="mt-0.5 text-xs text-app-muted">
                          When USDC &gt; {rule.trigger_threshold.toLocaleString()} →{' '}
                          convert {rule.action_percent ? `${rule.action_percent}%` : `${rule.action_amount} USDC`} to{' '}
                          {CURRENCY_FLAG[rule.target_currency]} {rule.target_currency}
                        </p>
                        {rule.last_triggered && (
                          <p className="mt-0.5 text-[10px] text-amber-500">
                            Last triggered: {new Date(rule.last_triggered * 1000).toLocaleDateString()}
                          </p>
                        )}
                      </div>
                      <div className="flex items-center gap-1 shrink-0">
                        <button
                          onClick={() => toggleRule.mutate({
                            id: rule.id,
                            status: rule.status === 'active' ? 'paused' : 'active',
                          })}
                          className="rounded p-1.5 text-app-muted hover:text-app-text transition-colors"
                          title={rule.status === 'active' ? 'Pause' : 'Activate'}
                        >
                          {rule.status === 'active'
                            ? <Pause className="h-3.5 w-3.5" />
                            : <Play  className="h-3.5 w-3.5" />
                          }
                        </button>
                        <button
                          onClick={() => deleteRule.mutate(rule.id)}
                          className="rounded p-1.5 text-app-muted hover:text-red-400 transition-colors"
                          title="Delete rule"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* Recent payrolls */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-app-text">Recent payrolls</p>
              <p className="text-xs text-app-muted">Batch USDC payments with Memo references</p>
            </div>
            <Link href="/treasury/payroll">
              <Button size="sm" variant="outline">
                <Plus className="h-3.5 w-3.5" /> New batch
              </Button>
            </Link>
          </div>

          {batches.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Building2 className="h-8 w-8 text-app-border" />
              <p className="text-sm text-app-muted">No payrolls yet</p>
              <p className="text-xs text-app-muted">
                Send USDC to multiple wallets in one batch with unique Memo references
              </p>
              <Link href="/treasury/payroll">
                <Button size="sm" variant="outline" className="mt-2">Create first payroll</Button>
              </Link>
            </div>
          ) : (
            <div className="space-y-2">
              {batches.slice(0, 6).map(batch => (
                <Link key={batch.id} href={`/treasury/payroll/${batch.id}`}>
                  <div className="flex items-center justify-between rounded-xl border border-app-border bg-app-bg p-3 hover:border-app-accent/40 transition-colors cursor-pointer">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2">
                        <p className="text-sm font-medium text-app-text truncate">{batch.name}</p>
                        <Badge variant={
                          batch.status === 'completed'  ? 'success' :
                          batch.status === 'processing' ? 'arc'     :
                          batch.status === 'failed'     ? 'danger'  : 'warning'
                        }>
                          {batch.status}
                        </Badge>
                      </div>
                      <p className="text-xs text-app-muted">
                        {batch.recipient_count} recipients · ${formatAmount(batch.total_amount)} USDC
                        · {new Date(batch.created_at * 1000).toLocaleDateString()}
                      </p>
                    </div>
                    <ArrowRight className="h-4 w-4 shrink-0 text-app-muted" />
                  </div>
                </Link>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
AFX_L010_EOF
echo "  ✓ afrifx-web/app/(app)/treasury/TreasuryContent.tsx"

mkdir -p "$(dirname "afrifx-web/app/(auth)/profile/setup/ProfileSetupClient.tsx")"
cat > 'afrifx-web/app/(auth)/profile/setup/ProfileSetupClient.tsx' <<'AFX_L011_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { getAvatarColor } from '@/lib/avatar'
import { checkUsername } from '@/hooks/useProfile'
import { useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeftRight, CheckCircle, XCircle,
  Loader2, Sparkles, Twitter, AtSign,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function ProfileSetupClient() {
  const { address, isConnected } = useAccount()
  const router      = useRouter()
  const queryClient = useQueryClient()

  const [username,    setUsername]    = useState('')
  const [displayName, setDisplayName] = useState('')
  const [bio,         setBio]         = useState('')
  const [twitter,     setTwitter]     = useState('')
  const [telegram,    setTelegram]    = useState('')
  const [showSocials, setShowSocials] = useState(true)
  const [step,        setStep]        = useState(1)

  const [usernameState, setUsernameState] = useState<'idle'|'checking'|'available'|'taken'|'invalid'>('idle')
  const [usernameError, setUsernameError] = useState('')
  const [submitting,    setSubmitting]    = useState(false)
  const [submitError,   setSubmitError]   = useState('')

  const avatarColor = username ? getAvatarColor(username) : '#D9A441'

  useEffect(() => {
    if (!username) { setUsernameState('idle'); return }
    if (username.length < 3)  { setUsernameState('invalid'); setUsernameError('Min 3 characters'); return }
    if (username.length > 20) { setUsernameState('invalid'); setUsernameError('Max 20 characters'); return }
    if (!/^[a-zA-Z0-9_]+$/.test(username)) {
      setUsernameState('invalid'); setUsernameError('Letters, numbers, underscores only'); return
    }
    setUsernameState('checking')
    const t = setTimeout(async () => {
      const result = await checkUsername(username)
      if (result.error) { setUsernameState('invalid'); setUsernameError(result.error) }
      else if (result.available) { setUsernameState('available'); setUsernameError('') }
      else { setUsernameState('taken'); setUsernameError('This username is taken') }
    }, 500)
    return () => clearTimeout(t)
  }, [username])

  async function handleSubmit() {
    if (!address || usernameState !== 'available' || !displayName.trim()) return
    setSubmitting(true); setSubmitError('')
    try {
      const res = await fetch(`${API}/profile`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress:  address,
          username,
          displayName:    displayName.trim(),
          bio:            bio.trim() || null,
          twitterHandle:  twitter.trim() || null,
          telegramHandle: telegram.trim() || null,
          showSocials,
        }),
      })
      const data = await res.json()
      if (!res.ok) { setSubmitError(data.error ?? 'Failed'); return }

      // ── KEY FIX: write profile directly into cache ──────────
      // This means ProfileGuard sees the profile IMMEDIATELY
      // when the router navigates no refetch race condition.
      const now = Math.floor(Date.now() / 1000)
      queryClient.setQueryData(['profile', address], {
        wallet_address:  address.toLowerCase(),
        username:        username.toLowerCase(),
        display_name:    displayName.trim(),
        bio:             bio.trim() || null,
        twitter_handle:  twitter.trim() || null,
        telegram_handle: telegram.trim() || null,
        avatar_color:    data.avatarColor ?? avatarColor,
        trade_count:     0,
        dispute_count:   0,
        verified:        false,
        show_socials:    showSocials,
        created_at:      now,
        updated_at:      now,
        maker_trades:    0,
        taker_trades:    0,
      })
      // ─────────────────────────────────────────────────────────

      setStep(3)
    } catch (e: any) {
      setSubmitError(e.message)
    } finally {
      setSubmitting(false)
    }
  }

  if (!isConnected) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-app-muted">Connect your wallet first.</p>
      </div>
    )
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-12">
      <div className="mb-8 flex items-center gap-2">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-app-accent/20">
          <ArrowLeftRight className="h-5 w-5 text-app-accent-text" />
        </div>
        <span className="text-xl font-semibold text-app-text">AfriFX</span>
      </div>

      {step === 3 && (
        <div className="w-full max-w-sm text-center">
          <div className="mb-6 flex justify-center">
            <ProfileAvatar displayName={displayName} avatarColor={avatarColor} size="xl" />
          </div>
          <h1 className="mb-2 text-2xl font-semibold text-app-text">Welcome, {displayName}!</h1>
          <p className="mb-2 text-sm text-app-muted">
            Your profile <span className="text-app-accent-text">@{username}</span> is ready.
          </p>
          <p className="mb-8 text-xs text-app-muted">
            You can update your profile anytime from the sidebar.
          </p>
          <Button className="w-full" size="lg" onClick={() => router.push('/dashboard')}>
            <Sparkles className="h-4 w-4" /> Enter AfriFX
          </Button>
        </div>
      )}

      {step < 3 && (
        <div className="w-full max-w-sm">
          <div className="mb-6 text-center">
            <h1 className="text-2xl font-semibold text-app-text">Create your profile</h1>
            <p className="mt-1 text-sm text-app-muted">Your identity on AfriFX. Username is permanent.</p>
          </div>

          <div className="mb-8 flex items-center gap-2">
            {[1,2].map((s) => (
              <div key={s} className="flex items-center gap-2">
                <div className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold
                  ${step >= s ? 'bg-app-accent text-app-on-accent' : 'bg-app-border text-app-muted'}`}>
                  {step > s ? '✓' : s}
                </div>
                <span className={`text-xs ${step >= s ? 'text-app-text' : 'text-app-muted'}`}>
                  {s === 1 ? 'Identity' : 'Socials'}
                </span>
                {s < 2 && <div className="h-px w-8 bg-app-border" />}
              </div>
            ))}
          </div>

          {step === 1 && (
            <div className="space-y-4">
              <div className="flex items-center gap-4 rounded-xl border border-app-border bg-app-surface p-4">
                <ProfileAvatar displayName={displayName || username || 'A'} avatarColor={avatarColor} size="lg" />
                <div>
                  <p className="text-sm font-medium text-app-text">{displayName || 'Your name'}</p>
                  <p className="text-xs text-app-muted">{username ? `@${username}` : '@username'}</p>
                </div>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                  Username <span className="text-red-400">*</span>
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-app-muted">@</span>
                  <Input value={username}
                    onChange={(e) => setUsername(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g,''))}
                    placeholder="yourname" className="pl-7 font-mono" maxLength={20} />
                  <span className="absolute right-3 top-1/2 -translate-y-1/2">
                    {usernameState === 'checking'  && <Loader2 className="h-4 w-4 animate-spin text-app-muted" />}
                    {usernameState === 'available' && <CheckCircle className="h-4 w-4 text-emerald-400" />}
                    {(usernameState === 'taken' || usernameState === 'invalid') && <XCircle className="h-4 w-4 text-red-400" />}
                  </span>
                </div>
                {usernameState === 'available' && <p className="mt-1 text-xs text-emerald-400">@{username} is available!</p>}
                {usernameError && <p className="mt-1 text-xs text-red-400">{usernameError}</p>}
                <p className="mt-1 text-[10px] text-app-muted">3–20 chars · letters, numbers, underscores · permanent</p>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                  Display name <span className="text-red-400">*</span>
                </label>
                <Input value={displayName} onChange={(e) => setDisplayName(e.target.value)}
                  placeholder="Your full name" maxLength={40} />
                <p className="mt-1 text-[10px] text-app-muted">Shown instead of your wallet address everywhere</p>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                  Bio <span className="font-normal normal-case text-app-muted">(optional)</span>
                </label>
                <textarea value={bio} onChange={(e) => setBio(e.target.value)}
                  placeholder="Tell others about yourself…" maxLength={160} rows={3}
                  className="w-full rounded-md border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted focus:outline-none focus:ring-1 focus:ring-app-accent resize-none" />
                <p className="mt-1 text-right text-[10px] text-app-muted">{bio.length}/160</p>
              </div>

              <Button className="w-full" size="lg" onClick={() => setStep(2)}
                disabled={usernameState !== 'available' || !displayName.trim()}>
                Next, Add socials
              </Button>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-4">
              <p className="text-xs text-app-muted">
                Connect your socials so traders can verify and trust you. All optional.
              </p>

              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-app-muted">
                  <Twitter className="h-3.5 w-3.5" /> Twitter / X
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-app-muted">@</span>
                  <Input value={twitter} onChange={(e) => setTwitter(e.target.value.replace('@',''))}
                    placeholder="yourhandle" className="pl-7" />
                </div>
              </div>

              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-app-muted">
                  <AtSign className="h-3.5 w-3.5" /> Telegram
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-app-muted">@</span>
                  <Input value={telegram} onChange={(e) => setTelegram(e.target.value.replace('@',''))}
                    placeholder="yourhandle" className="pl-7" />
                </div>
              </div>

              <div className="flex items-center justify-between rounded-lg border border-app-border bg-app-surface p-3">
                <div>
                  <p className="text-sm font-medium text-app-text">Show socials publicly</p>
                  <p className="text-xs text-app-muted">Others can see your Twitter and Telegram</p>
                </div>
                <button onClick={() => setShowSocials(!showSocials)}
                  className={`relative h-6 w-11 rounded-full transition-colors ${showSocials ? 'bg-app-accent' : 'bg-app-border'}`}>
                  <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition-transform ${showSocials ? 'translate-x-5' : 'translate-x-0.5'}`} />
                </button>
              </div>

              {submitError && <p className="text-xs text-red-400">{submitError}</p>}

              <div className="flex gap-2">
                <Button variant="outline" className="flex-1" onClick={() => setStep(1)}>Back</Button>
                <Button className="flex-1" size="lg" onClick={handleSubmit} disabled={submitting}>
                  {submitting ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating…</> : 'Create profile'}
                </Button>
              </div>
              <button onClick={handleSubmit} disabled={submitting}
                className="w-full text-xs text-app-muted hover:text-app-text transition-colors">
                Skip socials →
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
AFX_L011_EOF
echo "  ✓ afrifx-web/app/(auth)/profile/setup/ProfileSetupClient.tsx"

mkdir -p "$(dirname "afrifx-web/app/page.tsx")"
cat > 'afrifx-web/app/page.tsx' <<'AFX_L012_EOF'
import Link from 'next/link'
import { AfriFXLogo } from '@/components/brand/AfriFXLogo'
import { ArrowUpRight } from 'lucide-react'
import { LandingRates } from '@/components/landing/LandingRates'
import { LandingFeatures } from '@/components/landing/LandingFeatures'
import { LandingHowItWorks } from '@/components/landing/LandingHowItWorks'
// ThemeToggle is its own 'use client' component, so it can be dropped into
// this server component without making the whole page client-side.
import { ThemeToggle } from '@/components/layout/ThemeToggle'
import { ShieldCheck, Zap, Coins } from 'lucide-react'

export const metadata = {
  title: 'AfriFX, Stablecoin FX & cross-border payments on Arc',
  description:
    'Trade USDC for local currency peer-to-peer with on-chain escrow, bridge funds across Arc, Ethereum and Base, and track live African FX rates.',
}

export default function LandingPage() {
  return (
    <div className="min-h-screen bg-app-bg text-app-text">
      <LandingHeader />
      <Hero />
      <LandingHowItWorks />
      <LandingFeatures />
      <LandingFooter />
    </div>
  )
}

function LandingHeader() {
  return (
    <header className="sticky top-0 z-40 border-b border-app-border/60 bg-app-bg/80 backdrop-blur-md">
      <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3.5 sm:px-6">
        <AfriFXLogo size="sm" href="/" />
        <nav className="flex items-center gap-1 sm:gap-4">
          <Link href="#features" className="hidden px-3 py-2 text-sm text-app-muted hover:text-app-text sm:block">Features</Link>
          <Link href="/about" className="hidden px-3 py-2 text-sm text-app-muted hover:text-app-text sm:block">About</Link>
          <Link href="/contact" className="hidden px-3 py-2 text-sm text-app-muted hover:text-app-text sm:block">Contact</Link>
          {/* Theme switch kept visible at every breakpoint (the text links
              hide on mobile, but the toggle is small enough to always fit). */}
          <ThemeToggle />
          <a
            href="/signin"
            className="inline-flex items-center gap-1.5 rounded-xl bg-app-accent px-4 py-2 text-sm font-semibold text-app-on-accent transition-transform hover:scale-[1.03]"
          >
            Launch app <ArrowUpRight className="h-4 w-4" />
          </a>
        </nav>
      </div>
    </header>
  )
}

function Hero() {
  return (
    <section className="relative overflow-hidden">
      <div className="pointer-events-none absolute inset-0 -z-10">
        <div className="absolute left-1/2 top-[-10%] h-[420px] w-[820px] -translate-x-1/2 rounded-full bg-app-accent/10 blur-[120px]" />
      </div>

      <div className="mx-auto max-w-6xl px-4 pb-20 pt-16 text-center sm:px-6 sm:pt-24">
        <span className="inline-flex items-center gap-2 rounded-full border border-app-border bg-app-surface px-4 py-1.5 text-xs font-medium text-app-muted">
          <span className="h-1.5 w-1.5 rounded-full bg-app-accent" />
          Live on Arc testnet
        </span>

        <h1 className="mx-auto mt-6 max-w-4xl text-4xl font-extrabold leading-[1.05] tracking-tight sm:text-6xl">
          Move money across Africa,
          <br className="hidden sm:block" />
          <span className="afx-gradient-text">settled in seconds.</span>
        </h1>

        <p className="mx-auto mt-6 max-w-2xl text-base leading-relaxed text-app-muted sm:text-lg">
          AfriFX is a decentralized FX and cross-border payments platform. Trade USDC for
          local currency peer-to-peer with on-chain escrow, move funds between Arc, Ethereum,
          Base and more, and track live rates across 13 African currencies.
        </p>

        <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <a
            href="/signin"
            className="inline-flex items-center gap-2 rounded-xl bg-app-accent px-6 py-3 text-base font-semibold text-app-on-accent transition-transform hover:scale-[1.03]"
          >
            Launch app <ArrowUpRight className="h-5 w-5" />
          </a>
          <Link
            href="#features"
            className="inline-flex items-center gap-2 rounded-xl border border-app-border bg-app-surface px-6 py-3 text-base font-medium text-app-text hover:border-app-accent"
          >
            Explore features
          </Link>
        </div>

        {/* Trust row */}
        <div className="mt-8 flex flex-wrap items-center justify-center gap-x-6 gap-y-2 text-xs text-app-muted">
          <span className="inline-flex items-center gap-1.5"><ShieldCheck className="h-4 w-4 text-app-accent-text" /> Non-custodial</span>
          <span className="inline-flex items-center gap-1.5"><Zap className="h-4 w-4 text-app-accent-text" /> Multi-chain USDC</span>
          <span className="inline-flex items-center gap-1.5"><Coins className="h-4 w-4 text-app-accent-text" /> Fees in USDC</span>
        </div>

        <div className="mx-auto mt-16 max-w-3xl">
          <LandingRates />
        </div>
      </div>
    </section>
  )
}

function LandingFooter() {
  return (
    <footer className="border-t border-app-border">
      <div className="mx-auto max-w-6xl px-4 py-12 sm:px-6">
        <div className="flex flex-col justify-between gap-8 sm:flex-row">
          <div className="max-w-xs">
            <AfriFXLogo size="sm" href="/" />
            <p className="mt-3 text-sm text-app-muted">
              Decentralized stablecoin FX and cross-border payments, built on Arc.
            </p>
          </div>
          <div className="flex gap-12">
            <div>
              <p className="mb-3 text-xs font-semibold uppercase tracking-wider text-app-muted">Product</p>
              <ul className="space-y-2 text-sm">
                <li><Link href="#features" className="text-app-text hover:text-app-accent-text">Features</Link></li>
                <li><a href="/signin" className="text-app-text hover:text-app-accent-text">Launch app</a></li>
              </ul>
            </div>
            <div>
              <p className="mb-3 text-xs font-semibold uppercase tracking-wider text-app-muted">Company</p>
              <ul className="space-y-2 text-sm">
                <li><Link href="/about" className="text-app-text hover:text-app-accent-text">About</Link></li>
                <li><Link href="/contact" className="text-app-text hover:text-app-accent-text">Contact</Link></li>
              </ul>
            </div>
          </div>
        </div>
        <div className="mt-10 border-t border-app-border pt-6 text-xs text-app-muted">
          © {new Date().getFullYear()} AfriFX. Stablecoin FX on Arc.
        </div>
      </div>
    </footer>
  )
}
AFX_L012_EOF
echo "  ✓ afrifx-web/app/page.tsx"

mkdir -p "$(dirname "afrifx-web/components/bridge/BridgeHistory.tsx")"
cat > 'afrifx-web/components/bridge/BridgeHistory.tsx' <<'AFX_L013_EOF'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { CheckCircle, Clock, AlertTriangle, ExternalLink, RefreshCw, Loader2 } from 'lucide-react'
import { useCompleteBridge } from '@/hooks/useCompleteBridge'
import { useAttestationStatus, finalityHint } from '@/hooks/useAttestationStatus'
import { chainByKey } from '@/lib/cctp-chains'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface BridgeRow {
  id: string
  from_chain: string
  to_chain:   string
  amount:     number
  status:     string
  burn_tx?:   string | null
  mint_tx?:   string | null
  created_at: number
}

/*
  Without this list, a bridge that outlives the page is INVISIBLE, the user has
  burned funds and no way to see what became of them. On an Ethereum-source
  bridge that's the normal case, not an edge case: finality alone takes 13-19
  minutes, far longer than anyone will sit and watch a spinner.
*/
export function BridgeHistory() {
  const { address } = useAccount()
  const [rows, setRows]       = useState<BridgeRow[]>([])
  const [loading, setLoading] = useState(false)
  const finish = useCompleteBridge()

  /*
    Which unfinished bridges are actually mintable yet? Showing a Complete
    button before Circle has attested only produces a failed click, so we check
    first and show a waiting state instead.
  */
  const pending = rows.filter(r =>
    r.status !== 'completed' && r.status !== 'failed' && !!r.burn_tx)
  const { status: attest } = useAttestationStatus(pending)

  const load = useCallback(async () => {
    if (!address) { setRows([]); return }
    setLoading(true)
    try {
      const res  = await fetch(`${API}/bridge?wallet=${address}`)
      const data = await res.json()
      setRows(Array.isArray(data) ? data : [])
    } catch { /* keep the previous list rather than blanking it */ }
    finally { setLoading(false) }
  }, [address])

  useEffect(() => { load() }, [load])

  // Refresh once a manual completion lands, so the row flips to Complete.
  useEffect(() => {
    if (finish.step === 'done') { load(); finish.reset() }
  }, [finish.step, load, finish])

  // Poll while anything is still moving, so a completed mint appears without a
  // manual refresh.
  useEffect(() => {
    const pending = rows.some(r =>
      ['attesting', 'minting', 'stranded', 'burning'].includes(r.status))
    if (!pending) return
    const t = setInterval(load, 20_000)
    return () => clearInterval(t)
  }, [rows, load])

  if (!address || (!rows.length && !loading)) return null

  const chip = (status: string) => {
    switch (status) {
      case 'completed': return { icon: CheckCircle,   cls: 'text-emerald-400', label: 'Complete' }
      case 'failed':    return { icon: AlertTriangle, cls: 'text-red-400',     label: 'Not started' }
      default:          return { icon: Clock,         cls: 'text-amber-400',   label: 'In progress' }
    }
  }

  return (
    <div className="mt-6 w-full max-w-md">
      <div className="mb-2 flex items-center justify-between">
        <h3 className="text-xs font-semibold uppercase tracking-wide text-app-muted">
          Recent bridges
        </h3>
        <button onClick={load} disabled={loading}
          className="flex items-center gap-1 text-[11px] text-app-muted hover:text-app-text">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      <div className="space-y-2">
        {rows.slice(0, 8).map(r => {
          const c = chip(r.status)
          const Icon = c.icon
          const fromC = chainByKey(r.from_chain)
          const toC   = chainByKey(r.to_chain)
          return (
            <div key={r.id} className="rounded-lg border border-app-border bg-app-surface p-3">
              <div className="flex items-center justify-between">
                <span className="text-xs text-app-text">
                  {r.amount} USDC
                  <span className="text-app-muted">
                    {' '}· {fromC?.name ?? r.from_chain} → {toC?.name ?? r.to_chain}
                  </span>
                </span>
                <span className={`flex items-center gap-1 text-[11px] ${c.cls}`}>
                  <Icon className="h-3 w-3" /> {c.label}
                </span>
              </div>

              <div className="mt-1 flex flex-wrap gap-3 text-[10px]">
                <span className="text-app-muted">
                  {new Date(r.created_at * 1000).toLocaleString()}
                </span>
                {r.burn_tx && fromC && (
                  <a href={`${fromC.explorer}/tx/${r.burn_tx}`} target="_blank" rel="noopener noreferrer"
                    className="inline-flex items-center gap-0.5 text-app-accent-text hover:underline">
                    burn <ExternalLink className="h-2 w-2" />
                  </a>
                )}
                {r.mint_tx && toC && (
                  <a href={`${toC.explorer}/tx/${r.mint_tx}`} target="_blank" rel="noopener noreferrer"
                    className="inline-flex items-center gap-0.5 text-app-accent-text hover:underline">
                    mint <ExternalLink className="h-2 w-2" />
                  </a>
                )}
              </div>

              {r.status !== 'completed' && r.status !== 'failed' && r.burn_tx && (
                <div className="mt-1.5">
                  {/* HONEST copy. The mint does NOT happen on its own: the
                      platform holds no key (non-custodial by design), so the
                      owner of the funds finishes it. Attestations never expire
                      and destinationCaller is bytes32(0), so this always works,
                      however long it has been. */}
                  <p className="text-[10px] leading-relaxed text-amber-700 dark:text-amber-200/70">
                    {attest[r.id] === 'waiting'
                      ? `Your USDC is burned and recorded. Circle is still confirming the ` +
                        `${chainByKey(r.from_chain)?.name ?? r.from_chain} transaction, after ` +
                        `which you can release it on ${chainByKey(r.to_chain)?.name ?? r.to_chain}.`
                      : `Your USDC is burned and recorded. Nothing is lost, but the final ` +
                        `step needs your signature to release it on ${chainByKey(r.to_chain)?.name ?? r.to_chain}.`}
                  </p>

                  {/* Only offer the action once Circle can actually serve the
                      attestation. 'unknown' means we could not reach Circle, so
                      we still allow the attempt rather than blocking the user. */}
                  {attest[r.id] === 'waiting' ? (
                    <p className="mt-1.5 inline-flex items-center gap-1.5 rounded-md bg-app-bg px-2.5 py-1 text-[11px] text-app-muted">
                      <Loader2 className="h-3 w-3 animate-spin" />
                      Waiting for Circle to attest, {finalityHint(r.from_chain)}
                    </p>
                  ) : (
                    <button
                      onClick={() => finish.complete(r)}
                      disabled={finish.busyId === r.id}
                      className="mt-1.5 inline-flex items-center gap-1.5 rounded-md bg-app-accent px-2.5 py-1 text-[11px] font-medium text-app-on-accent hover:opacity-90 disabled:opacity-50"
                    >
                      {finish.busyId === r.id
                        ? <><Loader2 className="h-3 w-3 animate-spin" /> Completing...</>
                        : 'Complete transfer'}
                    </button>
                  )}

                  {finish.busyId === r.id && finish.step === 'checking' && (
                    <p className="mt-1 text-[10px] text-app-muted">Checking with Circle...</p>
                  )}
                  {finish.error && finish.busyId === null && (
                    <p className="mt-1 text-[10px] text-red-700 dark:text-red-300">{finish.error}</p>
                  )}
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
AFX_L013_EOF
echo "  ✓ afrifx-web/components/bridge/BridgeHistory.tsx"

mkdir -p "$(dirname "afrifx-web/components/chat/ChatWindow.tsx")"
cat > 'afrifx-web/components/chat/ChatWindow.tsx' <<'AFX_L014_EOF'
'use client'
import { useState, useRef, useEffect, useCallback } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { MessageBubble }     from './MessageBubble'
import { QuickActions }      from './QuickActions'
import { MediaUploadButton } from './MediaUploadButton'
import { useChat }           from '@/hooks/useChat'
import { useProfileByAddress } from '@/hooks/useProfile'
import { ProfileAvatar }     from '@/components/profile/ProfileAvatar'
import { getAvatarColor }    from '@/lib/avatar'
import { shortenAddress }    from '@/lib/utils'
import type { CloudinaryUploadResult } from '@/lib/cloudinary'
import { Send, MessageSquare, ChevronDown, Shield, Lock } from 'lucide-react'

interface Props {
  offerId:      string
  makerAddress: string
  takerAddress: string
  currency:     string
  amount:       number
}

function UserChip({ address }: { address: string }) {
  const { data: profile } = useProfileByAddress(address)
  const color = profile?.avatar_color ?? getAvatarColor(address)
  const name  = profile?.display_name ?? shortenAddress(address)
  return (
    <div className="flex items-center gap-1.5">
      <ProfileAvatar displayName={name} avatarColor={color} size="xs" verified={profile?.verified} />
      <span className="text-xs text-app-text">
        {profile?.username ? `@${profile.username}` : name}
      </span>
    </div>
  )
}

export function ChatWindow({ offerId, makerAddress, takerAddress, currency, amount }: Props) {
  const { address } = useAccount()

  // Determine role client-side
  const isMaker = address?.toLowerCase() === makerAddress?.toLowerCase()
  const isTaker = address?.toLowerCase() === takerAddress?.toLowerCase()
  const isInvolved = isMaker || isTaker

  const otherAddress = isMaker ? takerAddress : makerAddress

  const { messages, role, typing, sendMessage, sendTyping } = useChat(
    isInvolved ? offerId : null
  )

  const { data: otherProfile } = useProfileByAddress(otherAddress)
  const { data: myProfile }    = useProfileByAddress(address ?? '')

  const [input,        setInput]        = useState('')
  const [sending,      setSending]      = useState(false)
  const [showActions,  setShowActions]  = useState(false)
  const [minimized,    setMinimized]    = useState(false)
  const [pendingMedia, setPendingMedia] = useState<CloudinaryUploadResult | null>(null)
  const [imagePreview, setImagePreview] = useState<string | null>(null)

  const bottomRef = useRef<HTMLDivElement>(null)
  const inputRef  = useRef<HTMLTextAreaElement>(null)

  // Auto-scroll on new messages
  useEffect(() => {
    if (!minimized) {
      bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
    }
  }, [messages, minimized])

  const otherName  = otherProfile?.display_name ?? shortenAddress(otherAddress)
  const otherColor = otherProfile?.avatar_color  ?? getAvatarColor(otherAddress)

  function getSenderName(sender: string | null | undefined): string {
    if (!sender || sender === 'system') return 'System'
    if (sender.toLowerCase() === address?.toLowerCase()) return 'You'
    return otherProfile?.display_name ?? shortenAddress(sender)
  }

  function isMe(sender: string | null | undefined): boolean {
    if (!sender || !address) return false
    return sender.toLowerCase() === address.toLowerCase()
  }

  async function handleSend() {
    if ((!input.trim() && !pendingMedia) || sending) return
    setSending(true)
    try {
      if (pendingMedia) {
        await sendMessage(
          input.trim() || pendingMedia.name,
          pendingMedia.url,
          pendingMedia.type,
          'media',
        )
        setPendingMedia(null)
        setImagePreview(null)
      } else {
        await sendMessage(input.trim())
      }
      setInput('')
    } finally { setSending(false) }
  }

  async function handleQuickAction(action: string, label: string) {
    setShowActions(false)
    setSending(true)
    try { await sendMessage(label, undefined, undefined, 'quick-action', action) }
    finally { setSending(false) }
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSend() }
    sendTyping()
  }

  function handleMediaUpload(result: CloudinaryUploadResult) {
    setPendingMedia(result)
    if (result.type === 'image') setImagePreview(result.url)
  }

  // ── Not involved: show a locked placeholder ───────────────
  if (!isInvolved) {
    return (
      <div className="flex h-[520px] flex-col items-center justify-center gap-3 rounded-2xl border border-app-border bg-app-bg">
        <div className="flex h-12 w-12 items-center justify-center rounded-full bg-app-border">
          <Lock className="h-5 w-5 text-app-muted" />
        </div>
        <p className="text-sm text-app-muted">Private trade chat</p>
      </div>
    )
  }

  // ── Wallet not yet connected / hydrating ──────────────────
  if (!address) {
    return (
      <div className="flex h-[520px] flex-col items-center justify-center gap-3 rounded-2xl border border-app-border bg-app-bg">
        <div className="h-8 w-32 animate-pulse rounded-lg bg-app-border" />
      </div>
    )
  }

  return (
    <div className={`flex flex-col rounded-2xl border border-app-border bg-app-bg shadow-2xl transition-all duration-200 ${minimized ? 'h-14' : 'h-[520px]'}`}>

      {/* ── Header ── */}
      <div
        className="flex cursor-pointer items-center gap-3 rounded-t-2xl border-b border-app-border bg-app-surface px-4 py-3"
        onClick={() => setMinimized(!minimized)}
      >
        <div className="relative">
          <ProfileAvatar displayName={otherName} avatarColor={otherColor} size="sm" verified={otherProfile?.verified} />
          <span className="absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full bg-emerald-400 ring-1 ring-app-surface" />
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <p className="truncate text-sm font-medium text-app-text">
              {otherProfile?.username ? `@${otherProfile.username}` : otherName}
            </p>
            <span className={`shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-medium
              ${isMaker ? 'bg-app-accent/20 text-app-accent-text' : 'bg-emerald-900/40 text-emerald-400'}`}>
              {isMaker ? 'Buyer' : 'Seller'}
            </span>
          </div>
          <p className="text-[10px] text-app-muted">
            {typing
              ? <span className="text-emerald-400 animate-pulse">typing…</span>
              : `${amount.toLocaleString()} ${currency} ↔ USDC`
            }
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex items-center gap-1 rounded-full bg-emerald-900/30 px-2 py-0.5 text-[10px] text-emerald-400">
            <Shield className="h-3 w-3" /> Secured
          </div>
          <ChevronDown className={`h-4 w-4 shrink-0 text-app-muted transition-transform ${minimized ? 'rotate-180' : ''}`} />
        </div>
      </div>

      {!minimized && (
        <>
          {/* ── Parties banner ── */}
          <div className="flex items-center justify-between border-b border-app-border bg-[#0A1020] px-4 py-2">
            <UserChip address={makerAddress} />
            <span className="text-[10px] text-app-muted">⇄</span>
            <UserChip address={takerAddress} />
          </div>

          {/* ── Messages ── */}
          <div className="flex-1 overflow-y-auto px-4 py-3 space-y-1">
            {messages.length === 0 && (
              <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
                <div className="flex h-12 w-12 items-center justify-center rounded-full bg-app-border">
                  <MessageSquare className="h-5 w-5 text-app-muted" />
                </div>
                <div>
                  <p className="text-sm font-medium text-app-text">Trade chat</p>
                  <p className="text-xs text-app-muted">
                    Messages are private between you and your trading partner.
                  </p>
                  <p className="mt-1 text-xs text-app-muted">
                    Use quick actions ⚡ to confirm payment status.
                  </p>
                </div>
              </div>
            )}

            {messages.map((msg) => (
              <MessageBubble
                key={msg.id}
                msg={msg}
                isMe={isMe(msg.sender)}
                senderName={getSenderName(msg.sender)}
              />
            ))}

            {/* Typing indicator */}
            {typing && (
              <div className="flex items-end gap-2">
                <ProfileAvatar displayName={otherName} avatarColor={otherColor} size="xs" />
                <div className="rounded-2xl rounded-tl-sm bg-app-border px-3 py-2">
                  <div className="flex gap-1">
                    {[0,1,2].map(i => (
                      <span key={i}
                        className="h-1.5 w-1.5 animate-bounce rounded-full bg-app-muted"
                        style={{ animationDelay: `${i * 0.15}s` }}
                      />
                    ))}
                  </div>
                </div>
              </div>
            )}

            <div ref={bottomRef} />
          </div>

          {/* ── Image preview ── */}
          {imagePreview && (
            <div className="relative mx-4 mb-2">
              <img src={imagePreview} alt="Preview" className="h-20 rounded-lg object-cover" />
              <button
                onClick={() => { setImagePreview(null); setPendingMedia(null) }}
                className="absolute -right-1 -top-1 flex h-5 w-5 items-center justify-center rounded-full bg-red-500 text-white text-xs font-bold"
              >
                ×
              </button>
            </div>
          )}

          {/* ── Quick actions ── */}
          {showActions && (
            <QuickActions onAction={handleQuickAction} disabled={sending} />
          )}

          {/* ── Input ── */}
          <div className="border-t border-app-border bg-app-surface p-3">
            <div className="flex items-end gap-2">
              <button
                onClick={() => setShowActions(!showActions)}
                title="Quick actions"
                className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full border text-sm transition-colors
                  ${showActions
                    ? 'border-app-accent bg-app-accent/10 text-app-accent-text'
                    : 'border-app-border bg-app-surface text-app-muted hover:text-app-text'}`}
              >
                ⚡
              </button>

              <MediaUploadButton
                offerId={offerId}
                onUpload={handleMediaUpload}
                disabled={sending}
              />

              <div className="flex flex-1 items-end rounded-xl border border-app-border bg-app-bg px-3 py-2">
                <textarea
                  ref={inputRef}
                  value={input}
                  onChange={(e) => { setInput(e.target.value); sendTyping() }}
                  onKeyDown={handleKeyDown}
                  placeholder="Message… (Enter to send, Shift+Enter for newline)"
                  rows={1}
                  style={{ maxHeight: '80px' }}
                  className="flex-1 resize-none bg-transparent text-sm text-app-text placeholder:text-app-muted outline-none leading-relaxed"
                />
              </div>

              <button
                onClick={handleSend}
                disabled={(!input.trim() && !pendingMedia) || sending}
                className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-app-accent text-app-on-accent transition-all hover:bg-app-accent-hover disabled:opacity-40 active:scale-95"
              >
                <Send className="h-4 w-4" />
              </button>
            </div>

            <p className="mt-1.5 text-center text-[10px] text-app-muted">
              🔒 Private · deleted automatically when trade completes
            </p>
          </div>
        </>
      )}
    </div>
  )
}
AFX_L014_EOF
echo "  ✓ afrifx-web/components/chat/ChatWindow.tsx"

mkdir -p "$(dirname "afrifx-web/components/chat/MediaUploadButton.tsx")"
cat > 'afrifx-web/components/chat/MediaUploadButton.tsx' <<'AFX_L015_EOF'
'use client'
import { useRef, useState } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { Paperclip, Loader2 } from 'lucide-react'
import { uploadToCloudinary, type CloudinaryUploadResult } from '@/lib/cloudinary'

interface Props {
  offerId:   string
  onUpload:  (result: CloudinaryUploadResult) => void
  disabled?: boolean
}

export function MediaUploadButton({ offerId, onUpload, disabled }: Props) {
  const { address }               = useAccount()
  const inputRef                  = useRef<HTMLInputElement>(null)
  const [progress,  setProgress]  = useState(0)
  const [uploading, setUploading] = useState(false)
  const [errMsg,    setErrMsg]    = useState<string | null>(null)

  async function handleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file || !address) return

    // PDF only. Bank receipts and statements are issued as PDFs; images are too
    // easily edited to be trusted as proof of payment, so they're rejected.
    // The `accept` attribute is only a hint users can bypass it in the file
    // picker so we validate here as well.
    const isPdf = file.type === 'application/pdf' ||
                  file.name.toLowerCase().endsWith('.pdf')
    if (!isPdf) {
      setErrMsg('Only PDF files are accepted. Please upload the bank-issued PDF receipt.')
      if (inputRef.current) inputRef.current.value = ''
      return
    }

    if (file.size > 10 * 1024 * 1024) {
      setErrMsg('File too large, max 10 MB')
      if (inputRef.current) inputRef.current.value = ''
      return
    }

    setUploading(true)
    setProgress(0)
    setErrMsg(null)

    try {
      const result = await uploadToCloudinary(file, offerId, address, setProgress)
      onUpload(result)
    } catch (err: any) {
      setErrMsg(err.message ?? 'Upload failed')
    } finally {
      setUploading(false)
      setProgress(0)
      if (inputRef.current) inputRef.current.value = ''
    }
  }

  return (
    <div className="relative">
      <input
        ref={inputRef}
        type="file"
        accept="application/pdf,.pdf"
        onChange={handleFile}
        className="hidden"
      />

      <button
        onClick={() => { setErrMsg(null); inputRef.current?.click() }}
        disabled={disabled || uploading}
        title="Attach a PDF receipt or statement (max 10 MB)"
        className="flex h-9 w-9 items-center justify-center rounded-full border border-app-border bg-app-surface text-app-muted transition-colors hover:border-app-accent hover:text-app-text disabled:opacity-40"
      >
        {uploading
          ? <Loader2 className="h-4 w-4 animate-spin" />
          : <Paperclip className="h-4 w-4" />
        }
      </button>

      {/* Progress bubble */}
      {uploading && (
        <div className="absolute -top-7 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full bg-app-surface border border-app-border px-2 py-0.5 text-[10px] text-app-accent-text">
          {progress}%
        </div>
      )}

      {/* Error bubble */}
      {errMsg && (
        <div className="absolute -top-7 left-0 whitespace-nowrap rounded-full bg-red-900/80 px-2 py-0.5 text-[10px] text-red-300">
          {errMsg}
        </div>
      )}
    </div>
  )
}
AFX_L015_EOF
echo "  ✓ afrifx-web/components/chat/MediaUploadButton.tsx"

mkdir -p "$(dirname "afrifx-web/components/corridor/CorridorCard.tsx")"
cat > 'afrifx-web/components/corridor/CorridorCard.tsx' <<'AFX_L016_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  ArrowRight, ArrowUpDown, CheckCircle,
  AlertCircle, Loader2, Hash, Coins
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { CurrencyInput } from '@/components/swap/CurrencyInput'
import { useRate } from '@/hooks/useFXRate'
import { useCorridorSwap } from '@/hooks/useCorridorSwap'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
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
    if (!quote || insufficientUsdc) return
    await execute(quote)
  }

  const supported = isCorridorSupported(from, to)

  // The corridor spends USDC from the wallet (step 1 sends usdcIn1, step 2
  // sends usdcIn2). Step 1 must clear first, so the wallet needs at least the
  // step-1 USDC amount. Two transfers => reserve 2x the per-tx gas buffer.
  const { formatted: usdcBalance } = useUSDCBalance()
  const balanceNum   = parseFloat(usdcBalance) || 0
  const GAS_BUFFER   = 0.001
  const usdcNeeded   = quote
    ? quote.step1.toAmount + quote.step1.spreadFee + quote.step1.networkFee
    : 0
  const maxUsdc      = Math.max(0, balanceNum - GAS_BUFFER * 2)
  const insufficientUsdc = !!quote && usdcNeeded > maxUsdc

  // Max input = the largest FROM amount whose step-1 USDC fits the balance.
  // step-1 USDC ≈ inputAmount / fromRate, so inputAmount ≈ maxUsdc * fromRate.
  function setMaxInput() {
    if (fromRateVal > 0) setAmount((maxUsdc * fromRateVal).toFixed(2))
  }

  const canSwap   = isConnected && !!quote && supported && !isLoading && !insufficientUsdc

  // Step label helper
  const stepLabel: Record<string, string> = {
    'idle':          '',
    'step1-pending': 'Confirm Step 1 in MetaMask…',
    'step1-waiting': 'Step 1 settling on Arc…',
    'step1-done':    'Step 1 complete, preparing Step 2…',
    'step2-pending': 'Confirm Step 2 in MetaMask…',
    'step2-waiting': 'Step 2 settling on Arc…',
    'complete':      'Corridor swap complete!',
    'error':         'Something went wrong',
  }

  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5 shadow-xl">

      {/* Header */}
      <div className="mb-4 flex items-center gap-2">
        <Coins className="h-4 w-4 text-app-accent-text" />
        <span className="text-sm font-medium text-app-text">Cross-border corridor</span>
        <Badge variant="arc" className="ml-auto">2-step · via USDC</Badge>
      </div>

      {/* USDC balance + Max the corridor spends USDC from the wallet */}
      {isConnected && (
        <div className="mb-2 flex items-center justify-between text-xs">
          <span className="text-app-muted">Available balance</span>
          <span className="flex items-center gap-2">
            <span className="font-mono text-app-text">{usdcBalance} USDC</span>
            <button onClick={setMaxInput} className="text-app-accent-text hover:underline">Max</button>
          </span>
        </div>
      )}

      {/* From currency */}
      <CurrencyInput
        label="You send"
        amount={amount}
        currency={from}
        onAmountChange={handleAmountChange}
        onCurrencyChange={handleFromChange}
        currencies={LOCAL_CURRENCIES.filter(c => c !== to)}
      />

      {/* USDC insufficiency / remaining */}
      {insufficientUsdc && (
        <div className="mt-2 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
          <AlertCircle className="h-3.5 w-3.5 shrink-0" />
          Needs ~{usdcNeeded.toFixed(2)} USDC, you only have {usdcBalance} USDC
        </div>
      )}
      {!insufficientUsdc && quote && usdcNeeded > 0 && (
        <p className="mt-2 text-xs text-emerald-400">
          Uses ~{usdcNeeded.toFixed(2)} USDC · remaining after: {(balanceNum - usdcNeeded).toFixed(4)} USDC
        </p>
      )}

      {/* Flip button */}
      <div className="my-1 flex justify-center">
        <button
          onClick={flip}
          className="rounded-full border border-app-border bg-app-surface p-2 text-app-muted transition-transform hover:rotate-180 hover:text-app-text"
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
        <div className="mb-4 rounded-lg bg-app-bg p-3 text-xs">
          <p className="mb-2 font-medium text-app-text">Route</p>
          <div className="flex items-center gap-2 text-app-muted">
            <span>{CURRENCY_FLAG[from]} {from}</span>
            <ArrowRight className="h-3 w-3 shrink-0" />
            <span>💵 USDC</span>
            <ArrowRight className="h-3 w-3 shrink-0" />
            <span>{CURRENCY_FLAG[to]} {to}</span>
          </div>
          <div className="mt-2 space-y-1">
            <div className="flex justify-between">
              <span className="text-app-muted">Step 1 · {from} → USDC</span>
              <span className="font-mono text-app-text">~{quote.step1.toAmount.toFixed(4)} USDC</span>
            </div>
            <div className="flex justify-between">
              <span className="text-app-muted">Step 2 · USDC → {to}</span>
              <span className="font-mono text-app-text">{quote.step2.toAmount.toFixed(2)} {to}</span>
            </div>
            <div className="flex justify-between border-t border-app-border pt-1">
              <span className="text-app-muted">Total fees</span>
              <span className="font-mono text-app-text">${quote.totalFee.toFixed(4)} USDC</span>
            </div>
            <div className="flex justify-between">
              <span className="text-app-muted">Corridor ID</span>
              <span className="font-mono text-[10px] text-app-accent-text">{quote.corridorId}</span>
            </div>
          </div>
        </div>
      )}

      {/* Step progress indicator */}
      {step !== 'idle' && (
        <div className="mb-3 rounded-lg border border-app-border bg-app-bg p-3">
          <div className="mb-2 flex items-center gap-4">
            {/* Step 1 indicator */}
            <div className="flex items-center gap-1.5">
              <div className={`flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold
                ${['step1-done','step2-pending','step2-waiting','complete'].includes(step)
                  ? 'bg-emerald-500 text-white'
                  : ['step1-pending','step1-waiting'].includes(step)
                  ? 'bg-app-accent text-app-on-accent'
                  : 'bg-app-border text-app-muted'}`}>
                {['step1-done','step2-pending','step2-waiting','complete'].includes(step) ? '✓' : '1'}
              </div>
              <span className="text-xs text-app-muted">{from} → USDC</span>
            </div>
            <ArrowRight className="h-3 w-3 text-app-border" />
            {/* Step 2 indicator */}
            <div className="flex items-center gap-1.5">
              <div className={`flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold
                ${step === 'complete'
                  ? 'bg-emerald-500 text-white'
                  : ['step2-pending','step2-waiting'].includes(step)
                  ? 'bg-app-accent text-app-on-accent'
                  : 'bg-app-border text-app-muted'}`}>
                {step === 'complete' ? '✓' : '2'}
              </div>
              <span className="text-xs text-app-muted">USDC → {to}</span>
            </div>
          </div>
          <p className="flex items-center gap-1.5 text-xs text-app-muted">
            {isLoading && <Loader2 className="h-3 w-3 animate-spin text-app-accent-text" />}
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
                <Hash className="h-3 w-3 text-emerald-700 dark:text-emerald-600" />
                <span className="font-mono text-[10px] text-emerald-700 dark:text-emerald-600">
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
AFX_L016_EOF
echo "  ✓ afrifx-web/components/corridor/CorridorCard.tsx"

mkdir -p "$(dirname "afrifx-web/components/layout/TopNav.tsx")"
cat > 'afrifx-web/components/layout/TopNav.tsx' <<'AFX_L017_EOF'
'use client'
import Link              from 'next/link'
import { ArrowLeftRight, Zap } from 'lucide-react'
import { AccountMenu }    from '@/components/auth/AccountMenu'
import { ClientOnly }     from '@/components/ui/client-only'
import { NotificationBell } from '@/components/notifications/NotificationBell'
import { ThemeToggle }     from '@/components/layout/ThemeToggle'
import { AfriFXLogo }      from '@/components/brand/AfriFXLogo'

export function TopNav() {
  return (
    <header className="flex h-14 shrink-0 items-center justify-between border-b border-app-border px-4 md:px-6">
      <div className="flex items-center gap-2.5">
        <AfriFXLogo size="sm" href="/dashboard" />
        <span className="hidden sm:inline-flex items-center gap-1 rounded-full bg-app-accent/10 px-2 py-0.5 text-[10px] font-medium text-app-accent-text">
          <Zap className="h-2.5 w-2.5" /> Arc Testnet
        </span>
      </div>

      <ClientOnly fallback={
        <div className="h-8 w-28 animate-pulse rounded-xl bg-app-border" />
      }>
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <NotificationBell />
          <AccountMenu />
        </div>
      </ClientOnly>
    </header>
  )
}
AFX_L017_EOF
echo "  ✓ afrifx-web/components/layout/TopNav.tsx"

mkdir -p "$(dirname "afrifx-web/components/notifications/EmailPreferences.tsx")"
cat > 'afrifx-web/components/notifications/EmailPreferences.tsx' <<'AFX_L018_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { useProfile } from '@/hooks/useProfile'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Mail, Check, Loader2, ChevronDown, ChevronUp } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function EmailPreferences() {
  const { address } = useAccount()
  const { data: profile, refetch } = useProfile()

  const [email,     setEmail]   = useState('')
  const [prefs, setPrefs]       = useState({
    notify_trades:            true,
    notify_disputes:          true,
    notify_invoices:          true,
    notify_trade_accepted:    true,
    notify_trade_completed:   true,
    notify_trade_cancelled:   true,
    notify_dispute_raised:    true,
    notify_dispute_accepted:  true,
    notify_invoice_paid:      true,
    notify_invoice_reminder:  true,
    notify_receipts:          true,
  })
  const [saving,    setSaving]  = useState(false)
  const [saved,     setSaved]   = useState(false)
  const [showAll,   setShowAll] = useState(false)

  useEffect(() => {
    if (profile) {
      const p = profile as any
      setEmail(p.email ?? '')
      setPrefs({
        notify_trades:           Number(p.notify_trades           ?? 1) === 1,
        notify_disputes:         Number(p.notify_disputes         ?? 1) === 1,
        notify_invoices:         Number(p.notify_invoices         ?? 1) === 1,
        notify_trade_accepted:   Number(p.notify_trade_accepted   ?? 1) === 1,
        notify_trade_completed:  Number(p.notify_trade_completed  ?? 1) === 1,
        notify_trade_cancelled:  Number(p.notify_trade_cancelled  ?? 1) === 1,
        notify_dispute_raised:   Number(p.notify_dispute_raised   ?? 1) === 1,
        notify_dispute_accepted: Number(p.notify_dispute_accepted ?? 1) === 1,
        notify_invoice_paid:     Number(p.notify_invoice_paid     ?? 1) === 1,
        notify_invoice_reminder: Number(p.notify_invoice_reminder ?? 1) === 1,
        notify_receipts:         Number(p.notify_receipts         ?? 1) === 1,
      })
    }
  }, [profile])

  async function save() {
    if (!address) return
    setSaving(true)
    setSaved(false)
    try {
      await fetch(`${API}/notifications/email`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ wallet: address, email: email || null, ...prefs }),
      })
      await refetch()
      setSaved(true)
      setTimeout(() => setSaved(false), 3000)
    } catch {} finally { setSaving(false) }
  }

  const validEmail = !email || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)

  return (
    <div className="rounded-xl border border-app-border bg-app-surface p-5 space-y-4">
      <div className="flex items-center gap-2">
        <Mail className="h-4 w-4 text-app-accent-text" />
        <h2 className="text-sm font-medium text-app-text">Email notifications</h2>
      </div>

      <p className="text-xs text-app-muted">
        Get notified about your trades, disputes, and invoice payments by email.
      </p>

      <div className="space-y-2">
        <label className="text-xs uppercase tracking-wider text-app-muted">
          Email address (optional)
        </label>
        <Input
          type="email"
          placeholder="you@example.com"
          value={email}
          onChange={e => setEmail(e.target.value)}
          className={!validEmail ? 'border-red-500/50' : ''}
        />
        {!validEmail && <p className="text-xs text-red-400">Invalid email format</p>}
      </div>

      <div className="space-y-3 border-t border-app-border pt-4">
        <p className="text-xs font-medium uppercase tracking-wider text-app-muted">
          Notification categories
        </p>

        <Toggle label="Trade activity"     description="Offers accepted, completed, and cancelled" checked={prefs.notify_trades}    onChange={v => setPrefs(p => ({...p, notify_trades: v}))} />
        <Toggle label="Dispute updates"    description="Always recommended for safety"     checked={prefs.notify_disputes}  onChange={v => setPrefs(p => ({...p, notify_disputes: v}))} />
        <Toggle label="Invoice and payments" description="Invoice paid and reminder alerts"  checked={prefs.notify_invoices}  onChange={v => setPrefs(p => ({...p, notify_invoices: v}))} />
        <Toggle label="Payment receipts"   description="Formal receipts for trades and invoices"  checked={prefs.notify_receipts}  onChange={v => setPrefs(p => ({...p, notify_receipts: v}))} />
      </div>

      {/* Granular toggles */}
      <button onClick={() => setShowAll(!showAll)}
        className="flex items-center gap-1 text-xs text-app-accent-text hover:underline">
        {showAll ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
        {showAll ? 'Hide' : 'Show'} individual event toggles
      </button>

      {showAll && (
        <div className="space-y-2 border-t border-app-border pt-3">
          <p className="text-[10px] uppercase tracking-wider text-app-muted">Trade events</p>
          <MiniToggle label="Trade accepted" checked={prefs.notify_trade_accepted}   onChange={v => setPrefs(p => ({...p, notify_trade_accepted: v}))} />
          <MiniToggle label="Trade completed" checked={prefs.notify_trade_completed}  onChange={v => setPrefs(p => ({...p, notify_trade_completed: v}))} />
          <MiniToggle label="Trade auto-cancelled" checked={prefs.notify_trade_cancelled}  onChange={v => setPrefs(p => ({...p, notify_trade_cancelled: v}))} />

          <p className="text-[10px] uppercase tracking-wider text-app-muted pt-2">Dispute events</p>
          <MiniToggle label="Dispute raised against you" checked={prefs.notify_dispute_raised}   onChange={v => setPrefs(p => ({...p, notify_dispute_raised: v}))} />
          <MiniToggle label="Admin accepted your dispute" checked={prefs.notify_dispute_accepted}  onChange={v => setPrefs(p => ({...p, notify_dispute_accepted: v}))} />

          <p className="text-[10px] uppercase tracking-wider text-app-muted pt-2">Invoice events</p>
          <MiniToggle label="Invoice paid" checked={prefs.notify_invoice_paid}     onChange={v => setPrefs(p => ({...p, notify_invoice_paid: v}))} />
          <MiniToggle label="Invoice unpaid reminder (48h)" checked={prefs.notify_invoice_reminder}  onChange={v => setPrefs(p => ({...p, notify_invoice_reminder: v}))} />
        </div>
      )}

      <Button onClick={save} disabled={!validEmail || saving} className="w-full">
        {saving
          ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</>
          : saved
          ? <><Check className="h-4 w-4 text-emerald-400" /> Saved</>
          : 'Save preferences'
        }
      </Button>
    </div>
  )
}

function Toggle({ label, description, checked, onChange }: {
  label: string, description: string, checked: boolean, onChange: (v: boolean) => void
}) {
  return (
    <label className="flex cursor-pointer items-start gap-3 rounded-lg border border-app-border bg-app-bg p-3 hover:bg-app-surface transition-colors">
      <input type="checkbox" checked={checked} onChange={e => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 shrink-0 cursor-pointer accent-app-accent" />
      <div>
        <p className="text-sm font-medium text-app-text">{label}</p>
        <p className="text-xs text-app-muted">{description}</p>
      </div>
    </label>
  )
}

function MiniToggle({ label, checked, onChange }: {
  label: string, checked: boolean, onChange: (v: boolean) => void
}) {
  return (
    <label className="flex cursor-pointer items-center gap-2.5 rounded-lg bg-app-bg px-3 py-2 hover:bg-app-surface transition-colors">
      <input type="checkbox" checked={checked} onChange={e => onChange(e.target.checked)}
        className="h-3.5 w-3.5 shrink-0 cursor-pointer accent-app-accent" />
      <span className="text-xs text-app-text">{label}</span>
    </label>
  )
}
AFX_L018_EOF
echo "  ✓ afrifx-web/components/notifications/EmailPreferences.tsx"

mkdir -p "$(dirname "afrifx-web/components/notifications/NotificationBell.tsx")"
cat > 'afrifx-web/components/notifications/NotificationBell.tsx' <<'AFX_L019_EOF'
'use client'
import { useEffect, useState, useRef } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { Bell, Check, X } from 'lucide-react'
import Link from 'next/link'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Notification {
  id:         string
  type:       string
  subject:    string
  payload:    string
  read_at:    number | null
  created_at: number
}

export function NotificationBell() {
  const { address }               = useAccount()
  const [open,         setOpen]   = useState(false)
  const [notifs,       setNotifs] = useState<Notification[]>([])
  const [unreadCount,  setCount]  = useState(0)
  const dropdownRef = useRef<HTMLDivElement>(null)

  async function loadUnreadCount() {
    if (!address) return
    try {
      const res = await fetch(`${API}/notifications/unread?wallet=${address}`)
      const data = await res.json()
      setCount(Number(data.count ?? 0))
    } catch {}
  }

  async function loadNotifs() {
    if (!address) return
    try {
      const res  = await fetch(`${API}/notifications?wallet=${address}`)
      const data = await res.json()
      setNotifs(Array.isArray(data) ? data : [])
    } catch {}
  }

  async function markRead(id: string) {
    try {
      await fetch(`${API}/notifications/${id}/read`, { method: 'PATCH' })
      await loadNotifs()
      await loadUnreadCount()
    } catch {}
  }

  async function markAllRead() {
    if (!address) return
    try {
      await fetch(`${API}/notifications/mark-all-read?wallet=${address}`, { method: 'PATCH' })
      await loadNotifs()
      await loadUnreadCount()
    } catch {}
  }

  useEffect(() => {
    if (!address) return
    loadUnreadCount()
    const interval = setInterval(loadUnreadCount, 30_000)
    return () => clearInterval(interval)
  }, [address])

  useEffect(() => {
    if (open) loadNotifs()
  }, [open])

  // Close on outside click
  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    if (open) document.addEventListener('mousedown', onClick)
    return () => document.removeEventListener('mousedown', onClick)
  }, [open])

  if (!address) return null

  const getNotifLink = (n: Notification) => {
    try {
      const p = JSON.parse(n.payload)
      if (n.type.startsWith('trade')   && p.offerId)   return `/marketplace/${p.offerId}`
      if (n.type.startsWith('dispute') && p.offerId)   return `/marketplace/${p.offerId}`
      if (n.type === 'invoice_paid'    && p.invoiceId) return `/invoices/${p.invoiceId}`
    } catch {}
    return '#'
  }

  const getIcon = (type: string) => {
    if (type.startsWith('trade'))   return '🤝'
    if (type.startsWith('dispute')) return '⚠️'
    if (type === 'invoice_paid')    return '💰'
    return '🔔'
  }

  return (
    <div className="relative" ref={dropdownRef}>
      <button onClick={() => setOpen(!open)}
        className="relative flex h-9 w-9 items-center justify-center rounded-lg border border-app-border text-app-muted hover:bg-app-surface hover:text-app-text transition-colors">
        <Bell className="h-4 w-4" />
        {unreadCount > 0 && (
          <span className="absolute -top-1 -right-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-red-500 px-1 text-[10px] font-bold text-white">
            {unreadCount > 9 ? '9+' : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <div className="absolute right-0 mt-2 w-80 rounded-xl border border-app-border bg-app-surface shadow-2xl z-50">
          <div className="flex items-center justify-between border-b border-app-border px-4 py-3">
            <p className="text-sm font-medium text-app-text">Notifications</p>
            <div className="flex items-center gap-2">
              {unreadCount > 0 && (
                <button onClick={markAllRead}
                  className="text-xs text-app-accent-text hover:underline">
                  Mark all read
                </button>
              )}
              <button onClick={() => setOpen(false)}
                className="text-app-muted hover:text-app-text">
                <X className="h-4 w-4" />
              </button>
            </div>
          </div>
          <div className="max-h-96 overflow-y-auto">
            {notifs.length === 0 ? (
              <p className="px-4 py-8 text-center text-xs text-app-muted">No notifications yet</p>
            ) : (
              notifs.map(n => {
                const link   = getNotifLink(n)
                const isUnread = !n.read_at
                return (
                  <Link key={n.id} href={link}
                    onClick={() => { markRead(n.id); setOpen(false) }}
                    className={`flex items-start gap-3 border-b border-app-border px-4 py-3 last:border-0
                      ${isUnread ? 'bg-app-accent/5' : ''} hover:bg-app-bg transition-colors`}>
                    <span className="text-lg">{getIcon(n.type)}</span>
                    <div className="flex-1 min-w-0">
                      <p className={`text-xs ${isUnread ? 'font-medium text-app-text' : 'text-app-muted'}`}>
                        {n.subject}
                      </p>
                      <p className="mt-0.5 text-[10px] text-app-muted">
                        {new Date(n.created_at * 1000).toLocaleString()}
                      </p>
                    </div>
                    {isUnread && (
                      <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-app-accent" />
                    )}
                  </Link>
                )
              })
            )}
          </div>
        </div>
      )}
    </div>
  )
}
AFX_L019_EOF
echo "  ✓ afrifx-web/components/notifications/NotificationBell.tsx"

mkdir -p "$(dirname "afrifx-web/components/profile/ProfileGuard.tsx")"
cat > 'afrifx-web/components/profile/ProfileGuard.tsx' <<'AFX_L020_EOF'
'use client'
import { useEffect } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { useRouter } from 'next/navigation'
import { useProfile } from '@/hooks/useProfile'

export function ProfileGuard({ children }: { children: React.ReactNode }) {
  const { isConnected, address } = useAccount()
  const { data: profile, isLoading } = useProfile()
  const router = useRouter()

  useEffect(() => {
    if (!isConnected || isLoading) return
    if (address && !profile) {
      router.push('/profile/setup')
    }
  }, [isConnected, isLoading, profile, address, router])

  return <>{children}</>
}
AFX_L020_EOF
echo "  ✓ afrifx-web/components/profile/ProfileGuard.tsx"

mkdir -p "$(dirname "afrifx-web/components/swap/CashOutCard.tsx")"
cat > 'afrifx-web/components/swap/CashOutCard.tsx' <<'AFX_L021_EOF'
'use client'
import { useState, useEffect, useCallback } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  Loader2, AlertCircle, CheckCircle, RefreshCw, Clock, Building2, Smartphone,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface ProviderQuote {
  provider:    string
  displayName: string
  ok:          boolean
  error?:      string
  quote?: {
    rate:       number
    destAmount: number
    feeDest?:   number
    netDest?:   number
    etaLabel?:  string
    etaSeconds?: number
  }
}

/*
  Cash out USDC to a bank account or mobile money.

  This replaces the old "convert" flow, which moved USDC to a vault and wrote a
  database row without ever delivering fiat. Two things it must get right:

  1. RECIPIENT DETAILS ARE MANDATORY. You cannot pay someone fiat without
     knowing where to send it, so the form collects them and the button stays
     disabled until they're complete. Better to block here than to take the
     USDC and fail afterwards.

  2. PROVIDER CHOICE IS THE USER'S. Quotes are shown UNRANKED with rate, fee,
     net amount and speed side by side. The best rate is often not the fastest,
     and picking a "winner" would mean quietly steering people toward whichever
     provider we favour.
*/
export function CashOutCard({
  usdcAmount, destCurrency, country,
}: {
  usdcAmount: number
  destCurrency: string
  country: string
}) {
  const { address, isConnected } = useAccount()

  const [method,        setMethod]        = useState<'bank' | 'mobile_money'>('bank')
  const [accountName,   setAccountName]   = useState('')
  const [accountNumber, setAccountNumber] = useState('')
  const [bankName,      setBankName]      = useState('')

  const [quotes,   setQuotes]   = useState<ProviderQuote[]>([])
  const [loadingQ, setLoadingQ] = useState(false)
  const [picked,   setPicked]   = useState<string | null>(null)

  const [submitting, setSubmitting] = useState(false)
  const [error,      setError]      = useState<string | null>(null)
  const [transferId, setTransferId] = useState<string | null>(null)

  const detailsComplete =
    accountName.trim() && accountNumber.trim() && bankName.trim()

  const loadQuotes = useCallback(async () => {
    if (!(usdcAmount > 0) || !destCurrency || !country) return
    setLoadingQ(true); setError(null)
    try {
      const res = await fetch(`${API}/transfers/quotes`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ usdcAmount, destCurrency, country, method }),
      })
      const data = await res.json()
      const list: ProviderQuote[] = data.quotes ?? []
      setQuotes(list)
      // Preselect the only working option, but never silently choose between
      // several: that decision belongs to the user.
      const usable = list.filter(q => q.ok)
      setPicked(usable.length === 1 ? usable[0].provider : null)
    } catch (err: any) {
      setError(err?.message ?? 'Could not load provider quotes')
    } finally { setLoadingQ(false) }
  }, [usdcAmount, destCurrency, country, method])

  useEffect(() => { loadQuotes() }, [loadQuotes])

  async function submit() {
    if (!address || !picked || !detailsComplete) return
    setSubmitting(true); setError(null)
    try {
      const res = await fetch(`${API}/transfers/cashout`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress: address,
          usdcAmount, destCurrency, country,
          provider: picked,
          recipient: {
            name: accountName.trim(),
            method,
            account: accountNumber.trim(),
            bank: bankName.trim(),
          },
        }),
      })
      const data = await res.json()
      if (!res.ok) { setError(data.error ?? 'Could not start the payout'); return }
      setTransferId(data.transferId)
    } catch (err: any) {
      setError(err?.message ?? 'Could not start the payout')
    } finally { setSubmitting(false) }
  }

  if (transferId) {
    return (
      <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4">
        <p className="flex items-center gap-1.5 text-sm font-medium text-emerald-700 dark:text-emerald-400">
          <CheckCircle className="h-4 w-4" /> Payout started
        </p>
        <p className="mt-1 text-xs text-emerald-800 dark:text-emerald-200/80">
          {usdcAmount} USDC is on its way to {accountName} as {destCurrency}.
        </p>
        <p className="mt-2 font-mono text-[10px] text-app-muted">{transferId}</p>
        <p className="mt-2 text-[11px] text-app-muted">
          You can track it under Settlements. The money arrives once the provider
          confirms, not immediately.
        </p>
      </div>
    )
  }

  const usable = quotes.filter(q => q.ok)

  return (
    <div className="space-y-4">
      {/* Provider comparison */}
      <div>
        <div className="mb-2 flex items-center justify-between">
          <p className="text-xs font-semibold text-app-text">Choose a provider</p>
          <button onClick={loadQuotes} disabled={loadingQ}
            className="flex items-center gap-1 text-[11px] text-app-muted hover:text-app-text">
            <RefreshCw className={`h-3 w-3 ${loadingQ ? 'animate-spin' : ''}`} /> Refresh
          </button>
        </div>

        {loadingQ && !quotes.length ? (
          <div className="flex items-center gap-2 rounded-lg bg-app-bg p-3 text-xs text-app-muted">
            <Loader2 className="h-3.5 w-3.5 animate-spin" /> Comparing providers...
          </div>
        ) : !usable.length ? (
          <div className="rounded-lg border border-amber-700/40 bg-amber-900/10 p-3">
            <p className="flex items-center gap-1.5 text-xs text-amber-800 dark:text-amber-400">
              <AlertCircle className="h-3.5 w-3.5" /> No provider available
            </p>
            <p className="mt-1 text-[11px] text-amber-800 dark:text-amber-200/80">
              None can currently send {destCurrency} to {country}. Your USDC has
              not been touched.
            </p>
          </div>
        ) : (
          <div className="space-y-2">
            {quotes.map(q => {
              if (!q.ok) {
                // Failures stay visible: a provider silently missing looks the
                // same as one that doesn't exist.
                return (
                  <div key={q.provider}
                    className="rounded-lg border border-app-border bg-app-bg/50 p-3 opacity-60">
                    <p className="text-xs text-app-text">{q.displayName}</p>
                    <p className="text-[10px] text-app-muted">Unavailable: {q.error}</p>
                  </div>
                )
              }
              const sel = picked === q.provider
              const net = q.quote?.netDest ?? q.quote?.destAmount ?? 0
              return (
                <button
                  key={q.provider}
                  onClick={() => setPicked(q.provider)}
                  className={`w-full rounded-lg border p-3 text-left transition-colors ${
                    sel ? 'border-app-accent bg-app-accent/5' : 'border-app-border bg-app-surface hover:border-app-accent/50'
                  }`}
                >
                  <div className="flex items-start justify-between">
                    <span className="text-xs font-medium text-app-text">{q.displayName}</span>
                    <span className="text-right">
                      <span className="block font-mono text-sm text-app-text">
                        {net.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                      </span>
                      <span className="block text-[10px] text-app-muted">{destCurrency} received</span>
                    </span>
                  </div>
                  <div className="mt-1.5 flex flex-wrap gap-3 text-[10px] text-app-muted">
                    <span>Rate {q.quote?.rate?.toLocaleString()}</span>
                    {q.quote?.feeDest != null && (
                      <span>Fee {q.quote.feeDest.toLocaleString()} {destCurrency}</span>
                    )}
                    {q.quote?.etaLabel && (
                      <span className="inline-flex items-center gap-0.5">
                        <Clock className="h-2.5 w-2.5" /> {q.quote.etaLabel}
                      </span>
                    )}
                  </div>
                </button>
              )
            })}
          </div>
        )}
      </div>

      {/* Recipient details, mandatory */}
      <div>
        <p className="mb-2 text-xs font-semibold text-app-text">Where should the money go?</p>

        <div className="mb-2 flex gap-2">
          {(['bank', 'mobile_money'] as const).map(m => (
            <button key={m} onClick={() => setMethod(m)}
              className={`flex flex-1 items-center justify-center gap-1.5 rounded-lg border py-2 text-xs ${
                method === m ? 'border-app-accent bg-app-accent/5 text-app-text'
                             : 'border-app-border text-app-muted hover:text-app-text'
              }`}>
              {m === 'bank' ? <Building2 className="h-3.5 w-3.5" /> : <Smartphone className="h-3.5 w-3.5" />}
              {m === 'bank' ? 'Bank transfer' : 'Mobile money'}
            </button>
          ))}
        </div>

        <div className="space-y-2">
          <Input placeholder="Account holder name" value={accountName}
            onChange={e => setAccountName(e.target.value)} />
          <Input
            placeholder={method === 'bank' ? 'Account number' : 'Phone number'}
            value={accountNumber} onChange={e => setAccountNumber(e.target.value)}
            className="font-mono" />
          <Input
            placeholder={method === 'bank' ? 'Bank name or code' : 'Mobile money provider'}
            value={bankName} onChange={e => setBankName(e.target.value)} />
        </div>

        <p className="mt-1.5 text-[10px] text-app-muted">
          Double-check these. Payments sent to a wrong account cannot be reversed.
        </p>
      </div>

      {error && (
        <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-3">
          <p className="flex items-center gap-1.5 text-xs font-medium text-red-800 dark:text-red-400">
            <AlertCircle className="h-3.5 w-3.5" /> Payout not started
          </p>
          <p className="mt-1 text-[11px] text-red-800 dark:text-red-300/90">{error}</p>
        </div>
      )}

      <Button className="w-full" disabled={!isConnected || !picked || !detailsComplete || submitting}
        onClick={submit}>
        {submitting ? <><Loader2 className="h-4 w-4 animate-spin" /> Starting payout...</>
          : !isConnected ? 'Connect a wallet'
          : !picked ? 'Choose a provider'
          : !detailsComplete ? 'Enter recipient details'
          : `Cash out ${usdcAmount} USDC`}
      </Button>
    </div>
  )
}
AFX_L021_EOF
echo "  ✓ afrifx-web/components/swap/CashOutCard.tsx"

mkdir -p "$(dirname "afrifx-web/components/swap/SwapCard.tsx")"
cat > 'afrifx-web/components/swap/SwapCard.tsx' <<'AFX_L022_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { ArrowUpDown, CheckCircle, AlertCircle, Loader2 } from 'lucide-react'
import { CurrencyInput } from './CurrencyInput'
import { RateDisplay } from './RateDisplay'
import { Button } from '@/components/ui/button'
import { useRate } from '@/hooks/useFXRate'
import { useSwap } from '@/hooks/useSwap'
import { LOCAL_CURRENCIES, countryForCurrency } from '@/lib/corridor'
import { CashOutCard } from './CashOutCard'  // single source of truth
import { useArcTransaction } from '@/hooks/useArcTransaction'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { SPREAD_BPS } from '@/lib/contracts'
import type { Currency } from '@/types'

const GAS_BUFFER = 0.001 // ~network fee per tx, kept aside so Max never over-spends

export function SwapCard() {
  const { isConnected } = useAccount()

  const [fromCurrency, setFromCurrency] = useState<Currency>('NGN')
  const [toCurrency,   setToCurrency]   = useState<Currency>('USDC')
  const [fromAmount,   setFromAmount]   = useState('')   // empty on load
  const [toAmount,     setToAmount]     = useState('')   // empty on load
  const [lastTx,       setLastTx]       = useState<{ hash: string; from: string; to: string } | null>(null)

  // Always resolve the LOCAL/USDC pair regardless of direction
  const localCurrency = toCurrency === 'USDC' ? fromCurrency : toCurrency

  /*
    Is this a cash-out? Only when spending USDC to receive a LOCAL currency,
    and only when we know which country to pay out in. Without a country a
    provider cannot quote, so we fall back to the original flow rather than
    showing a form that cannot succeed.
  */
  const cashOutCountry = toCurrency !== 'USDC' ? countryForCurrency(toCurrency) : undefined
  const isCashOut = fromCurrency === 'USDC' && toCurrency !== 'USDC' && !!cashOutCountry
  const pair = `${localCurrency}/USDC`

  const { rate: fxRate, isLoading: rateLoading } = useRate(pair)
  const rate   = fxRate?.rate ?? 0
  const spread = rate > 0 && fromAmount
    ? (parseFloat(fromAmount) / (toCurrency === 'USDC' ? rate : 1)) * (SPREAD_BPS / 10_000)
    : 0
  const netFee = 0.001

  const { buildQuote, execute, isLoading: swapping, error, txHash } = useSwap()
  const { isSuccess, explorerUrl } = useArcTransaction(txHash ?? undefined)
  const { formatted: usdcBalance } = useUSDCBalance()

  // USDC balance only matters when the user is SPENDING USDC (USDC → local).
  const spendingUsdc  = fromCurrency === 'USDC'
  const balanceNum    = parseFloat(usdcBalance) || 0
  const spendAmount   = parseFloat(fromAmount) || 0
  const maxSpendable  = Math.max(0, balanceNum - GAS_BUFFER)
  const insufficientUsdc = spendingUsdc && spendAmount > 0 && spendAmount > maxSpendable

  function setMaxUsdc() {
    setFromAmount(maxSpendable.toFixed(6))
  }

  // Recalculate receive amount whenever inputs change
  useEffect(() => {
    const from = parseFloat(fromAmount)
    if (!fromAmount || isNaN(from) || from <= 0 || rate === 0) {
      setToAmount('')
      return
    }

    let result: number
    if (toCurrency === 'USDC') {
      result = from / rate - spread - netFee
    } else {
      result = from * rate
    }

    setToAmount(result > 0 ? result.toFixed(toCurrency === 'USDC' ? 4 : 2) : '')
  }, [fromAmount, rate, toCurrency, spread])

  // Reset form after successful transaction
  useEffect(() => {
    if (isSuccess && txHash) {
      setLastTx({
        hash: txHash,
        from: `${parseFloat(fromAmount).toLocaleString()} ${fromCurrency}`,
        to:   `${toAmount} ${toCurrency}`,
      })
      // Reset fields
      setFromAmount('')
      setToAmount('')
    }
  }, [isSuccess, txHash])

  function flip() {
    const prevFrom   = fromCurrency
    const prevTo     = toCurrency
    const prevToAmt  = toAmount
    setFromCurrency(prevTo)
    setToCurrency(prevFrom)
    setFromAmount(prevToAmt || '')
    setToAmount('')
  }

  function handleFromAmountChange(val: string) {
    // Only allow positive numbers
    if (val === '' || /^\d*\.?\d*$/.test(val)) {
      setFromAmount(val)
      setLastTx(null) // clear success banner when user starts typing again
    }
  }

  async function handleConvert() {
    if (!isConnected || rate === 0 || !fromAmount || insufficientUsdc) return
    setLastTx(null)
    const quote = buildQuote(fromCurrency, toCurrency, parseFloat(fromAmount), rate)
    await execute(quote)
  }

  const fromCurrencies = toCurrency === 'USDC' ? LOCAL_CURRENCIES : (['USDC'] as Currency[])
  const toCurrencies   = fromCurrency === 'USDC' ? LOCAL_CURRENCIES : (['USDC', 'EURC'] as Currency[])
  const canConvert     = isConnected && rate > 0 && !!fromAmount && parseFloat(fromAmount) > 0 && !swapping && !insufficientUsdc

  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5 shadow-xl">

      {/* Live rate banner */}
      {fxRate && rate > 0 && (
        <div className="mb-4 flex items-center justify-between rounded-lg bg-app-bg px-3 py-2 text-xs">
          <span className="text-app-muted">Live rate</span>
          <span className="font-mono font-medium text-app-text">
            1 USDC = {fxRate.rate.toLocaleString()} {localCurrency}
          </span>
          <span className={fxRate.change24h >= 0 ? 'text-emerald-400' : 'text-red-400'}>
            {fxRate.change24h >= 0 ? '+' : ''}{fxRate.change24h.toFixed(2)}%
          </span>
        </div>
      )}

      {/* USDC balance + Max only when spending USDC */}
      {spendingUsdc && isConnected && (
        <div className="mb-2 flex items-center justify-between text-xs">
          <span className="text-app-muted">Available balance</span>
          <span className="flex items-center gap-2">
            <span className="font-mono text-app-text">{usdcBalance} USDC</span>
            <button onClick={setMaxUsdc} className="text-app-accent-text hover:underline">Max</button>
          </span>
        </div>
      )}

      <CurrencyInput
        label="You send"
        amount={fromAmount}
        currency={fromCurrency}
        onAmountChange={handleFromAmountChange}
        onCurrencyChange={(c) => { setFromCurrency(c); setFromAmount(''); setToAmount('') }}
        currencies={fromCurrencies}
      />

      {/* Insufficient / remaining only when spending USDC */}
      {spendingUsdc && insufficientUsdc && (
        <div className="mt-2 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
          <AlertCircle className="h-3.5 w-3.5 shrink-0" />
          Insufficient balance, you only have {usdcBalance} USDC
        </div>
      )}
      {spendingUsdc && !insufficientUsdc && spendAmount > 0 && (
        <p className="mt-2 text-xs text-emerald-400">
          Remaining after: {(balanceNum - spendAmount).toFixed(4)} USDC
        </p>
      )}

      <div className="my-1 flex justify-center">
        <button
          onClick={flip}
          className="rounded-full border border-app-border bg-app-surface p-2 text-app-muted transition-transform hover:rotate-180 hover:text-app-text"
          aria-label="Flip currencies"
        >
          <ArrowUpDown className="h-4 w-4" />
        </button>
      </div>

      <CurrencyInput
        label="You receive (estimated)"
        amount={toAmount}
        currency={toCurrency}
        onCurrencyChange={(c) => { setToCurrency(c); setToAmount('') }}
        currencies={toCurrencies}
        readOnly
        className="mb-4"
      />

      <RateDisplay
        fromCurrency={fromCurrency}
        toCurrency={toCurrency}
        rate={rate}
        spreadFee={spread}
        networkFee={netFee}
        isLoading={rateLoading || rate === 0}
      />

      {/*
        USDC to LOCAL CURRENCY is a real cash-out: it has to reach someone's
        bank account or mobile money. The old path just moved USDC to a vault
        and recorded a row, delivering nothing, so that direction now uses the
        payout flow instead. USDC-in (fiat to USDC) still uses the original
        path, since that leg is unchanged.
      */}
      {isCashOut ? (
        <div className="mt-4 border-t border-app-border pt-4">
          <CashOutCard
            usdcAmount={parseFloat(fromAmount) || 0}
            destCurrency={toCurrency}
            country={cashOutCountry!}
          />
        </div>
      ) : (
      <Button
        className="mt-4 w-full"
        size="lg"
        onClick={handleConvert}
        disabled={!canConvert}
      >
        {swapping ? (
          <><Loader2 className="h-4 w-4 animate-spin" /> Settling on Arc…</>
        ) : !isConnected ? (
          'Connect wallet to convert'
        ) : rate === 0 ? (
          'Fetching live rate…'
        ) : !fromAmount ? (
          'Enter an amount'
        ) : insufficientUsdc ? (
          'Insufficient USDC balance'
        ) : (
          `Convert ${parseFloat(fromAmount).toLocaleString()} ${fromCurrency} → ${toCurrency}`
        )}
      </Button>
      )}

      {/* Error state */}
      {error && (
        <div className="mt-3 flex items-start gap-2 rounded-lg border border-red-900/50 bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          {error}
        </div>
      )}

      {/* Success state shows last tx, clears when user types again */}
      {lastTx && (
        <a
          href={`https://testnet.arcscan.app/tx/${lastTx.hash}`}
          target="_blank"
          rel="noopener noreferrer"
          className="mt-3 flex items-start gap-2 rounded-lg border border-emerald-900/50 bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400 hover:underline"
        >
          <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          <div>
            <p className="font-medium">Conversion successful · settled on Arc</p>
            <p className="mt-0.5 text-emerald-500">
              {lastTx.from} → {lastTx.to}
            </p>
            <p className="mt-0.5 font-mono text-[10px] text-emerald-700 dark:text-emerald-600">
              {lastTx.hash.slice(0, 20)}… · View on ArcScan ↗
            </p>
          </div>
        </a>
      )}
    </div>
  )
}
AFX_L022_EOF
echo "  ✓ afrifx-web/components/swap/SwapCard.tsx"

mkdir -p "$(dirname "afrifx-web/components/treasury/GatewayBalancePanel.tsx")"
cat > 'afrifx-web/components/treasury/GatewayBalancePanel.tsx' <<'AFX_L023_EOF'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { Layers, RefreshCw, AlertCircle, Plus, ChevronDown, ChevronUp } from 'lucide-react'
import { GatewayDepositForm } from './GatewayDepositForm'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { fetchGatewayBalances, gatewayChains, isValidAddress } from '@/lib/gateway'

/*
  READ-ONLY view of the CONNECTED USER'S Circle Gateway unified balance.

  Gateway is permissionless and non-custodial, so this is a genuine user
  feature: any AfriFX user can hold one USDC balance spendable across chains.
  AfriFX's own company treasury uses the same feature with its own wallet, it
  is not special-cased.

  Stage 2 of the Gateway work: this panel only LOOKS. It cannot deposit,
  transfer or withdraw, those need a signer and are deliberately not wired up
  yet.
*/
export function GatewayBalancePanel() {
  const [showDeposit, setShowDeposit] = useState(false)
  // Collapsed by default: the chain list only grows as Gateway adds chains,
  // and most of the time the single unified figure is what matters.
  const [showChains,  setShowChains]  = useState(false)
  const [data, setData]       = useState<any>(null)
  const [error, setError]     = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  /*
    The CONNECTED USER'S wallet, not a hardcoded company address. /treasury is
    a per-user page, so each user sees their own unified balance. AfriFX's own
    company treasury is just another wallet using the same feature.
  */
  const { address } = useAccount()
  const addr = isValidAddress(address) ? address : undefined

  const load = useCallback(async () => {
    if (!addr) return
    setLoading(true); setError(null)
    const res = await fetchGatewayBalances(addr)
    if ('error' in res) setError(res.error)
    else setData(res)
    setLoading(false)
  }, [addr])

  useEffect(() => { load() }, [load])

  // No wallet connected explain rather than render an empty box.
  if (!addr) {
    return (
      <div className="rounded-xl border border-app-border bg-app-surface p-5">
        <h3 className="mb-1 flex items-center gap-2 text-sm font-semibold text-app-text">
          <Layers className="h-4 w-4 text-app-accent-text" /> Unified balance
        </h3>
        <p className="text-xs leading-relaxed text-app-muted">
          Connect your wallet to see your Circle Gateway balance, a single USDC
          balance you can spend on any supported chain, without bridging first.
        </p>
      </div>
    )
  }

  const chains = gatewayChains()

  return (
    <div className="rounded-xl border border-app-border bg-app-surface p-5">
      <div className="mb-3 flex items-start justify-between">
        <div>
          <h3 className="flex items-center gap-2 text-sm font-semibold text-app-text">
            <Layers className="h-4 w-4 text-app-accent-text" /> Unified balance
          </h3>
          <p className="mt-0.5 font-mono text-[10px] text-app-muted">{addr}</p>
        </div>
        <button onClick={load} disabled={loading}
          className="flex items-center gap-1 text-[11px] text-app-muted hover:text-app-text">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      {/* A read failure is shown as a NOTICE above the balance, not instead of
          it, the rest of the panel (and the deposit button) stays usable. */}
      {error && (
        <div className="mb-3 rounded-lg border border-amber-700/40 bg-amber-900/10 p-3">
          <p className="flex items-center gap-1.5 text-xs text-amber-400">
            <AlertCircle className="h-3.5 w-3.5" /> Couldn&apos;t read your Gateway balance
          </p>
          <p className="mt-1 text-[11px] text-amber-800 dark:text-amber-200/80">{error}</p>
          <p className="mt-1 text-[11px] text-amber-700 dark:text-amber-200/60">
            Read-only problem, no funds are affected, and you can still deposit.
          </p>
        </div>
      )}

      {(
        <>
          <div className="mb-4 rounded-lg bg-app-bg p-4">
            <p className="text-[10px] uppercase tracking-wide text-app-muted">
              Spendable on any chain
            </p>
            <p className="font-mono text-2xl text-app-text">
              {loading && !data ? '-' : (data?.total ?? 0).toLocaleString(undefined, {
                minimumFractionDigits: 2, maximumFractionDigits: 2,
              })}
              <span className="ml-1 text-sm text-app-muted">USDC</span>
            </p>
          </div>

          <button
            onClick={() => setShowChains(v => !v)}
            className="mb-2 flex w-full items-center justify-between text-[10px] font-semibold uppercase tracking-wide text-app-muted hover:text-app-text"
          >
            <span>Deposited per chain</span>
            {showChains ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
          </button>
          <div className={`space-y-1.5 ${showChains ? '' : 'hidden'}`}>
            {(data?.perChain ?? chains.map(c => ({ ...c, amount: 0 }))).map((c: any) => (
              <div key={c.key} className="flex items-center justify-between rounded-lg bg-app-bg/60 px-3 py-2">
                <span className="flex items-center gap-2 text-xs text-app-text">
                  {c.name}
                  {c.isHome || c.key === 'arc' ? (
                    <span className="rounded-full bg-app-accent/15 px-1.5 py-0.5 text-[9px] text-app-accent-text">
                      home
                    </span>
                  ) : null}
                </span>
                <span className="text-right">
                  <span className="block font-mono text-xs text-app-text">
                    {(c.amount ?? 0).toFixed(2)}
                  </span>
                  {/* Finality is the honest cost of depositing from that chain. */}
                  <span className="block text-[9px] text-app-muted">
                    deposits clear in {c.finality}
                  </span>
                </span>
              </div>
            ))}
          </div>
        </>
      )}

      {/* Deposit deliberately NOT gated on the balance read succeeding.
          Failing to READ your balance is no reason to prevent you DEPOSITING;
          an earlier version hid this button behind !error, which meant one API
          hiccup made the whole feature look absent. */}
      {(
        <div className="mt-4">
          {showDeposit ? (
            <GatewayDepositForm onDone={() => { setShowDeposit(false); load() }} />
          ) : (
            <button
              onClick={() => setShowDeposit(true)}
              className="flex w-full items-center justify-center gap-1.5 rounded-lg border border-dashed border-app-border py-2 text-xs text-app-muted hover:border-app-accent hover:text-app-text"
            >
              <Plus className="h-3.5 w-3.5" /> Add funds
            </button>
          )}
        </div>
      )}

    </div>
  )
}
AFX_L023_EOF
echo "  ✓ afrifx-web/components/treasury/GatewayBalancePanel.tsx"

mkdir -p "$(dirname "afrifx-web/components/treasury/GatewayDepositForm.tsx")"
cat > 'afrifx-web/components/treasury/GatewayDepositForm.tsx' <<'AFX_L024_EOF'
'use client'
import { useState } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { Loader2, CheckCircle, AlertTriangle, Clock, ExternalLink } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useGatewayDeposit } from '@/hooks/useGatewayDeposit'
import { useChainUsdcBalance } from '@/hooks/useChainUsdcBalance'
import { gatewayChains } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'

/*
  Deposit USDC into Gateway.

  The honest bit this UI has to get right: a deposit is NOT instantly spendable.
  It has to reach block finality first, about half a second on Arc, but 13-19
  MINUTES on Base or Ethereum. Hiding that would leave users thinking the
  feature is broken, so the wait is stated up front, per chain, before they
  commit.
*/
export function GatewayDepositForm({ onDone }: { onDone?: () => void }) {
  const { isConnected } = useAccount()
  const { step, approveTx, depositTx, error, finality, deposit, reset } = useGatewayDeposit()

  const chains = gatewayChains()
  const [chainKey, setChainKey] = useState('arc')
  const [amount, setAmount]     = useState('')

  const chain   = chains.find(c => c.key === chainKey)
  const cctp    = chainByKey(chainKey)
  const amt     = Number(amount)
  const busy    = ['switching', 'approving', 'depositing'].includes(step)

  /*
    Balance on the chain being deposited FROM.

    Without this the deposit could fail at the deposit() step AFTER the user had
    already paid gas on approve(), which is the worst kind of failure: costly
    and confusing. Checking up front turns it into a disabled button.
  */
  const { balance, loading: balLoading } = useChainUsdcBalance(chainKey)
  const insufficient = amt > 0 && amt > balance

  const canGo   = isConnected && amt > 0 && !busy && !insufficient

  const stepLabel: Record<string, string> = {
    switching:  `Switch your wallet to ${chain?.name ?? 'the chain'}`,
    approving:  'Approve USDC in your wallet (step 1 of 2)',
    depositing: 'Confirm the deposit in your wallet (step 2 of 2)',
  }

  if (step === 'done') {
    return (
      <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4">
        <p className="flex items-center gap-1.5 text-sm font-medium text-emerald-400">
          <CheckCircle className="h-4 w-4" /> Deposit submitted
        </p>
        <p className="mt-1 text-xs text-emerald-800 dark:text-emerald-200/80">
          {amount} USDC deposited from {chain?.name}.
        </p>
        {/* The wait is the thing people misunderstand, so say it plainly. */}
        <p className="mt-2 flex items-start gap-1.5 text-[11px] leading-relaxed text-amber-800 dark:text-amber-200/80">
          <Clock className="mt-0.5 h-3 w-3 shrink-0" />
          It becomes spendable once the deposit reaches finality on {chain?.name}
          about {finality}. Your balance above updates automatically.
        </p>
        {depositTx && cctp && (
          <a href={`${cctp.explorer}/tx/${depositTx}`} target="_blank" rel="noopener noreferrer"
            className="mt-2 inline-flex items-center gap-1 text-[11px] text-emerald-400 hover:underline">
            View transaction <ExternalLink className="h-2.5 w-2.5" />
          </a>
        )}
        <div className="mt-3">
          <Button size="sm" variant="outline" onClick={() => { reset(); onDone?.() }}>
            Done
          </Button>
        </div>
      </div>
    )
  }

  return (
    <div className="rounded-lg border border-app-border bg-app-bg p-4">
      <p className="mb-3 text-xs font-semibold text-app-text">Add funds to your unified balance</p>

      <label className="mb-1 block text-[11px] text-app-muted">Deposit from</label>
      <select
        value={chainKey}
        onChange={e => setChainKey(e.target.value)}
        disabled={busy}
        className="mb-1 w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => (
          <option key={c.key} value={c.key}>
            {c.name}, clears in {c.finality}
          </option>
        ))}
      </select>
      {/* Surface the trade-off at the moment of choosing, not after. */}
      <p className="mb-3 text-[10px] text-app-muted">
        {chainKey === 'arc'
          ? 'Arc finalises in about half a second, so deposits are spendable almost immediately.'
          : `Deposits from ${chain?.name} take ${chain?.finality} to become spendable.`}
      </p>

      <div className="mb-1 flex items-center justify-between">
        <label className="text-[11px] text-app-muted">Amount (USDC)</label>
        <span className="flex items-center gap-2 text-[11px]">
          <span className="text-app-muted">
            Balance:{' '}
            <span className="font-mono text-app-text">
              {balLoading ? '...' : balance.toFixed(2)}
            </span>
          </span>
          <button
            onClick={() => setAmount(String(balance))}
            disabled={busy || balance <= 0}
            className="text-app-accent-text hover:underline disabled:opacity-40"
          >
            Max
          </button>
        </span>
      </div>
      <input
        type="number" inputMode="decimal" min="0" step="0.000001"
        value={amount}
        onChange={e => setAmount(e.target.value)}
        disabled={busy}
        placeholder="0.00"
        className="mb-3 w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 font-mono text-sm text-app-text outline-none placeholder:text-app-border disabled:opacity-50"
      />

      {insufficient && (
        <p className="mb-3 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-[11px] text-red-800 dark:text-red-300">
          <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
          You only have {balance.toFixed(2)} USDC on {chain?.name}
        </p>
      )}

      <Button className="w-full" disabled={!canGo}
        onClick={() => deposit({ chainKey, amount: amt })}>
        {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Working…</>
              : !isConnected ? 'Connect a wallet'
              : insufficient ? 'Insufficient balance'
              : 'Deposit'}
      </Button>

      {busy && (
        <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
          <Loader2 className="h-3 w-3 animate-spin" />
          {stepLabel[step] ?? 'Working…'}
        </p>
      )}

      {step === 'error' && error && (
        <div className="mt-2 rounded-lg border border-red-900/50 bg-red-900/20 p-2.5">
          <p className="flex items-center gap-1.5 text-[11px] font-medium text-red-400">
            <AlertTriangle className="h-3 w-3" /> Deposit not completed
          </p>
          <p className="mt-1 text-[11px] text-red-800 dark:text-red-300/90">{error}</p>
          {approveTx && (
            <p className="mt-1 text-[10px] text-red-700 dark:text-red-300/60">
              Your approval went through but the deposit didn&apos;t, no USDC left your
              wallet. You can safely retry.
            </p>
          )}
          <Button size="sm" variant="outline" className="mt-2" onClick={reset}>Try again</Button>
        </div>
      )}
    </div>
  )
}
AFX_L024_EOF
echo "  ✓ afrifx-web/components/treasury/GatewayDepositForm.tsx"

mkdir -p "$(dirname "afrifx-web/hooks/useChat.ts")"
cat > 'afrifx-web/hooks/useChat.ts' <<'AFX_L025_EOF'
'use client'
import { useState, useEffect, useRef, useCallback } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface ChatMessage {
  id:           string
  offer_id:     string
  sender:       string | null
  content:      string | null
  media_url:    string | null
  media_type:   'image' | 'document' | 'video' | null
  msg_type:     'text' | 'media' | 'system' | 'quick-action'
  quick_action: string | null
  read_maker:   number
  read_taker:   number
  created_at:   number
}

// Normalise a raw message row (object or Turso array)
function normalizeMessage(raw: any): ChatMessage {
  const m = Array.isArray(raw)
    ? {
        id: raw[0], offer_id: raw[1], sender: raw[2], content: raw[3],
        media_url: raw[4], media_type: raw[5], msg_type: raw[6],
        quick_action: raw[7], read_maker: raw[8], read_taker: raw[9],
        created_at: raw[10],
      }
    : raw

  return {
    ...m,
    read_maker: Number(m.read_maker  ?? 0),
    read_taker: Number(m.read_taker  ?? 0),
    // Coerce created_at Turso may return string or float
    created_at: typeof m.created_at === 'string'
      ? parseInt(m.created_at, 10)
      : Number(m.created_at ?? 0),
  }
}

export function useChat(offerId: string | null) {
  const { address } = useAccount()
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [role,     setRole]     = useState<'maker'|'taker'|null>(null)
  const [typing,   setTyping]   = useState(false)
  const [error,    setError]    = useState<string|null>(null)

  const lastTsRef      = useRef(0)
  const intervalRef    = useRef<NodeJS.Timeout>()
  const typingTimerRef = useRef<NodeJS.Timeout>()

  const fetchMessages = useCallback(async () => {
    if (!offerId || !address) return
    try {
      const res  = await fetch(
        `${API}/chat/${offerId}?wallet=${address}&after=${lastTsRef.current}`
      )
      if (res.status === 403) { setError('Access denied'); return }
      if (!res.ok) return
      const data = await res.json()

      const incoming: ChatMessage[] = Array.isArray(data.messages)
        ? data.messages.map(normalizeMessage)
        : []

      if (incoming.length) {
        setMessages(prev => {
          const ids   = new Set(prev.map(m => m.id))
          const fresh = incoming.filter(m => !ids.has(m.id))
          if (!fresh.length) return prev
          const all = [...prev, ...fresh].sort((a, b) => a.created_at - b.created_at)
          // Update lastTs to the latest message's created_at
          lastTsRef.current = all[all.length - 1].created_at
          return all
        })
      }

      if (data.role) setRole(data.role)
    } catch { /* network blip, ignore */ }
  }, [offerId, address])

  const fetchTyping = useCallback(async () => {
    if (!offerId || !address) return
    try {
      const res  = await fetch(`${API}/chat/${offerId}/typing?wallet=${address}`)
      if (!res.ok) return
      const data = await res.json()
      setTyping(data.typing ?? false)
    } catch {}
  }, [offerId, address])

  // Poll every 2 seconds
  useEffect(() => {
    if (!offerId || !address) return
    fetchMessages()
    intervalRef.current = setInterval(() => {
      fetchMessages()
      fetchTyping()
    }, 2000)
    return () => clearInterval(intervalRef.current)
  }, [offerId, address, fetchMessages, fetchTyping])

  // Send typing indicator
  const sendTyping = useCallback(() => {
    if (!offerId || !address) return
    fetch(`${API}/chat/${offerId}/typing`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ wallet: address }),
    }).catch(() => {})
  }, [offerId, address])

  // Send a message
  const sendMessage = useCallback(async (
    content?:     string,
    mediaUrl?:    string,
    mediaType?:   string,
    msgType:      string = 'text',
    quickAction?: string,
  ): Promise<ChatMessage | null> => {
    if (!offerId || !address) return null
    try {
      const res  = await fetch(`${API}/chat/${offerId}`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
          wallet: address, content, mediaUrl, mediaType,
          msgType, quickAction,
        }),
      })
      const raw: ChatMessage = await res.json()
      const msg = normalizeMessage(raw)
      setMessages(prev => {
        const ids = new Set(prev.map(m => m.id))
        if (ids.has(msg.id)) return prev
        const all = [...prev, msg].sort((a, b) => a.created_at - b.created_at)
        lastTsRef.current = all[all.length - 1].created_at
        return all
      })
      return msg
    } catch (err: any) {
      setError(err.message)
      return null
    }
  }, [offerId, address])

  return { messages, role, typing, error, sendMessage, sendTyping }
}
AFX_L025_EOF
echo "  ✓ afrifx-web/hooks/useChat.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useDashboardStats.ts")"
cat > 'afrifx-web/hooks/useDashboardStats.ts' <<'AFX_L026_EOF'
'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function useDashboardStats() {
  const { address } = useAccount()
  return useQuery({
    queryKey:  ['dashboard-stats', address],
    queryFn:   async () => {
      if (!address) return null
      const res  = await fetch(`${API}/user/${address}/stats`)
      if (!res.ok) throw new Error('Failed to fetch stats')
      return res.json()
    },
    enabled:        !!address,
    refetchInterval: 30_000,
    staleTime:       15_000,
  })
}
AFX_L026_EOF
echo "  ✓ afrifx-web/hooks/useDashboardStats.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useDisputeWarnings.ts")"
cat > 'afrifx-web/hooks/useDisputeWarnings.ts' <<'AFX_L027_EOF'
'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function useDisputeWarnings() {
  const { address } = useAccount()
  return useQuery({
    queryKey: ['dispute-warnings', address],
    queryFn: async () => {
      const res  = await fetch(`${API}/user/${address}`)
      const data = await res.json()
      return Number(data.dispute_warnings ?? 0)
    },
    enabled:         !!address,
    refetchInterval: 60_000,
  })
}
AFX_L027_EOF
echo "  ✓ afrifx-web/hooks/useDisputeWarnings.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useInvoices.ts")"
cat > 'afrifx-web/hooks/useInvoices.ts' <<'AFX_L028_EOF'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface Invoice {
  id:              string
  creator_address: string
  payer_address:   string | null
  amount:          number
  currency:        string
  description:     string | null
  notes:           string | null
  due_date:        number | null
  memo_ref:        string
  status:          'draft' | 'sent' | 'paid' | 'overdue' | 'cancelled'
  payment_tx_hash: string | null
  paid_at:         number | null
  created_at:      number
  updated_at:      number
}

export function useInvoices() {
  const { address } = useAccount()
  return useQuery<Invoice[]>({
    queryKey:        ['invoices', address],
    queryFn:         async () => {
      if (!address) return []
      const res = await fetch(`${API}/invoices?wallet=${address}`)
      return res.ok ? res.json() : []
    },
    enabled:         !!address,
    refetchInterval: 10_000,
  })
}

export function useInvoice(id: string | null) {
  return useQuery<Invoice | null>({
    queryKey:        ['invoice', id],
    queryFn:         async () => {
      if (!id) return null
      const res = await fetch(`${API}/invoices/${id}`)
      return res.ok ? res.json() : null
    },
    enabled:         !!id,
    refetchInterval: 5_000,
  })
}

export function useInvoiceByRef(ref: string | null) {
  return useQuery<Invoice | null>({
    queryKey:        ['invoice-ref', ref],
    queryFn:         async () => {
      if (!ref) return null
      const res = await fetch(`${API}/invoices/ref/${ref}`)
      return res.ok ? res.json() : null
    },
    enabled:         !!ref,
    refetchInterval: 5_000,
  })
}

export function useCreateInvoice() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: {
      amount: number; currency?: string; description?: string
      notes?: string; dueDate?: number; payerAddress?: string
    }) => {
      const res = await fetch(`${API}/invoices`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ walletAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['invoices', address] }),
  })
}

export function useUpdateInvoiceStatus() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async ({ id, status, paymentTxHash, paidAt }: {
      id: string; status: string; paymentTxHash?: string; paidAt?: number
    }) => {
      const res = await fetch(`${API}/invoices/${id}/status`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status, paymentTxHash, paidAt }),
      })
      return res.json()
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['invoices', address] })
    },
  })
}
AFX_L028_EOF
echo "  ✓ afrifx-web/hooks/useInvoices.ts"

mkdir -p "$(dirname "afrifx-web/hooks/usePayments.ts")"
cat > 'afrifx-web/hooks/usePayments.ts' <<'AFX_L029_EOF'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface Payment {
  id:                string
  sender_address:    string
  recipient_address: string
  amount:            number
  currency:          string
  local_currency:    string | null
  local_amount:      number | null
  description:       string | null
  invoice_ref:       string | null
  memo_ref:          string
  status:            'pending' | 'settled' | 'failed'
  arc_tx_hash:       string | null
  created_at:        number
  settled_at:        number | null
}

export function usePayments(type?: 'sent'|'received') {
  const { address } = useAccount()
  return useQuery<Payment[]>({
    queryKey:        ['payments', address, type],
    queryFn:         async () => {
      if (!address) return []
      const q   = type ? `&type=${type}` : ''
      const res = await fetch(`${API}/payments?wallet=${address}${q}`)
      return res.ok ? res.json() : []
    },
    enabled:         !!address,
    refetchInterval: 10_000,
  })
}

export function useCreatePayment() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: {
      recipientAddress: string; amount: number; currency?: string
      localCurrency?: string; description?: string
      invoiceRef?: string; arcTxHash?: string
    }) => {
      const res = await fetch(`${API}/payments`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ senderAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['payments', address] }),
  })
}

export function useSettlementReport(fromTs?: number, toTs?: number) {
  const { address } = useAccount()
  return useQuery({
    queryKey: ['settlement-report', address, fromTs, toTs],
    queryFn:  async () => {
      if (!address) return null
      const params = new URLSearchParams({ wallet: address })
      if (fromTs) params.set('from', String(fromTs))
      if (toTs)   params.set('to',   String(toTs))
      const res = await fetch(`${API}/payments/report?${params}`)
      return res.ok ? res.json() : null
    },
    enabled: !!address,
  })
}
AFX_L029_EOF
echo "  ✓ afrifx-web/hooks/usePayments.ts"

mkdir -p "$(dirname "afrifx-web/hooks/usePayroll.ts")"
cat > 'afrifx-web/hooks/usePayroll.ts' <<'AFX_L030_EOF'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface PayrollRecipient {
  id:             string
  batch_id:       string
  name:           string | null
  wallet_address: string
  amount:         number
  currency:       string
  status:         'pending' | 'sent' | 'failed'
  tx_hash:        string | null
  memo_ref:       string | null
  created_at:     number
}

export interface PayrollBatch {
  id:              string
  wallet_address:  string
  name:            string
  description:     string | null
  total_amount:    number
  currency:        string
  recipient_count: number
  status:          'draft' | 'processing' | 'completed' | 'failed'
  executed_at:     number | null
  created_at:      number
  recipients?:     PayrollRecipient[]
}

export function usePayrollBatches() {
  const { address } = useAccount()
  return useQuery<PayrollBatch[]>({
    queryKey: ['payroll-batches', address],
    queryFn:  async () => {
      if (!address) return []
      const res = await fetch(`${API}/payroll/batches?wallet=${address}`)
      return res.ok ? res.json() : []
    },
    enabled: !!address,
  })
}

export function usePayrollBatch(id: string | null) {
  return useQuery<PayrollBatch | null>({
    queryKey: ['payroll-batch', id],
    queryFn:  async () => {
      if (!id) return null
      const res = await fetch(`${API}/payroll/batches/${id}`)
      return res.ok ? res.json() : null
    },
    enabled:         !!id,
    refetchInterval: 3000,
  })
}

export function useCreateBatch() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: {
      name: string; description?: string
      recipients: { name?: string; walletAddress: string; amount: number }[]
    }) => {
      const res = await fetch(`${API}/payroll/batches`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ walletAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['payroll-batches', address] }),
  })
}

export function useUpdateRecipient() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, status, txHash, batchId }: { id: string; status: string; txHash?: string; batchId: string }) => {
      await fetch(`${API}/payroll/recipients/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status, txHash }),
      })
    },
    onSuccess: (_d, vars) => queryClient.invalidateQueries({ queryKey: ['payroll-batch', vars.batchId] }),
  })
}
AFX_L030_EOF
echo "  ✓ afrifx-web/hooks/usePayroll.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useProfile.ts")"
cat > 'afrifx-web/hooks/useProfile.ts' <<'AFX_L031_EOF'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import type { UserProfile } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

// Fetch current user's profile
export function useProfile() {
  const { address } = useAccount()
  return useQuery<UserProfile | null>({
    queryKey:  ['profile', address],
    queryFn:   async () => {
      if (!address) return null
      const res = await fetch(`${API}/profile/wallet/${address}`)
      if (res.status === 404) return null
      if (!res.ok) throw new Error('Failed to fetch profile')
      return res.json()
    },
    enabled:       !!address,
    staleTime:     60_000,
    retry:         false,
  })
}

// Fetch any profile by username
export function useProfileByUsername(username: string | null) {
  return useQuery<UserProfile | null>({
    queryKey: ['profile-username', username],
    queryFn:  async () => {
      if (!username) return null
      const res = await fetch(`${API}/profile/${username}`)
      if (res.status === 404) return null
      if (!res.ok) throw new Error('Failed to fetch profile')
      return res.json()
    },
    enabled:   !!username,
    staleTime: 30_000,
  })
}

// Fetch profile by wallet address (for displaying other users)
export function useProfileByAddress(address: string | null | undefined) {
  return useQuery<UserProfile | null>({
    queryKey: ['profile-address', address?.toLowerCase()],
    queryFn:  async () => {
      if (!address) return null
      const res = await fetch(`${API}/profile/wallet/${address}`)
      if (res.status === 404) return null
      if (!res.ok) return null
      return res.json()
    },
    enabled:   !!address,
    staleTime: 60_000,
    retry:     false,
  })
}

// Check username availability
export async function checkUsername(username: string): Promise<{ available: boolean; error?: string }> {
  const res = await fetch(`${API}/profile/check/${username}`)
  return res.json()
}
AFX_L031_EOF
echo "  ✓ afrifx-web/hooks/useProfile.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useTreasury.ts")"
cat > 'afrifx-web/hooks/useTreasury.ts' <<'AFX_L032_EOF'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface TreasuryRule {
  id:                string
  wallet_address:    string
  name:              string
  trigger_threshold: number
  action_percent:    number | null
  action_amount:     number | null
  target_currency:   string
  status:            'active' | 'paused' | 'triggered'
  last_triggered:    number | null
  created_at:        number
}

export function useTreasuryRules() {
  const { address } = useAccount()
  return useQuery<TreasuryRule[]>({
    queryKey:        ['treasury-rules', address],
    queryFn:         async () => {
      if (!address) return []
      const res = await fetch(`${API}/treasury/rules?wallet=${address}`)
      return res.ok ? res.json() : []
    },
    enabled:         !!address,
    refetchInterval: 60_000,
  })
}

export function useCreateRule() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: Omit<TreasuryRule, 'id'|'wallet_address'|'status'|'last_triggered'|'created_at'>) => {
      const res = await fetch(`${API}/treasury/rules`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ walletAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['treasury-rules', address] }),
  })
}

export function useToggleRule() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async ({ id, status }: { id: string; status: string }) => {
      await fetch(`${API}/treasury/rules/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status }),
      })
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['treasury-rules', address] }),
  })
}

export function useDeleteRule() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (id: string) => {
      await fetch(`${API}/treasury/rules/${id}`, { method: 'DELETE' })
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['treasury-rules', address] }),
  })
}
AFX_L032_EOF
echo "  ✓ afrifx-web/hooks/useTreasury.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useUSDCBalance.ts")"
cat > 'afrifx-web/hooks/useUSDCBalance.ts' <<'AFX_L033_EOF'
'use client'
import { useReadContract } from 'wagmi'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { CONTRACTS } from '@/lib/contracts'
import { USDC_ABI, formatUSDC } from '@/lib/usdc'

export function useUSDCBalance() {
  const { address, isConnected } = useAccount()

  const { data: rawBalance, isLoading, refetch } = useReadContract({
    address: CONTRACTS.USDC,
    abi: USDC_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: isConnected && !!address, refetchInterval: 10_000 },
  })

  const formatted = rawBalance !== undefined ? formatUSDC(rawBalance) : '0.00'

  return { rawBalance, formatted, isLoading, refetch }
}
AFX_L033_EOF
echo "  ✓ afrifx-web/hooks/useUSDCBalance.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useWallet.ts")"
cat > 'afrifx-web/hooks/useWallet.ts' <<'AFX_L034_EOF'
'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface TokenBalance {
  symbol:   string
  name:     string
  balance:  number
  usdValue: number
  color:    string
  address:  string
}

export interface WalletData {
  tokens:       TokenBalance[]
  escrow:       { locked: number; openOffers: number; activeOffers: number }
  p2p:          { completed: number; totalVolume: number }
  localEquiv:   { currency: string; flag: string; rate: number; amount: number }[]
  transactions: {
    id: string; fromCurrency: string; toCurrency: string
    fromAmount: number; toAmount: number
    status: string; arcTxHash: string | null
    reference: string | null; createdAt: number
  }[]
}

export function useWallet() {
  const { address } = useAccount()
  return useQuery<WalletData | null>({
    queryKey:        ['wallet', address],
    queryFn:         async () => {
      if (!address) return null
      const res = await fetch(`${API}/wallet/${address}`)
      if (!res.ok) throw new Error('Failed to fetch wallet')
      return res.json()
    },
    enabled:         !!address,
    refetchInterval: 30_000,
    staleTime:       15_000,
  })
}
AFX_L034_EOF
echo "  ✓ afrifx-web/hooks/useWallet.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useWalletReady.ts")"
cat > 'afrifx-web/hooks/useWalletReady.ts' <<'AFX_L035_EOF'
'use client'
import { useAccountAddress } from '@/hooks/useAccountAddress'

/*
  Whether the user's wallet is usable.

  Previously this modelled wagmi connection state, because the wallet was
  something the user connected and the provider could be briefly unready
  right after login. That no longer applies: the wallet is provisioned by
  Circle at sign-up, so "ready" simply means the account has an address.

  `isEmbedded` is always true now - every wallet is a Circle
  user-controlled wallet - and is kept so callers that show recovery
  nudges keep working without a change.
*/
export function useWalletReady() {
  const { address, isLoading } = useAccountAddress()

  const ready = Boolean(address) && !isLoading

  return {
    ready,
    isEmbedded: true,
    status: isLoading ? 'connecting' : ready ? 'connected' : 'disconnected',
  }
}
AFX_L035_EOF
echo "  ✓ afrifx-web/hooks/useWalletReady.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useAccountAddress.ts")"
cat > 'afrifx-web/hooks/useAccountAddress.ts' <<'AFX_L036_EOF'
'use client'

/**
 * The signed-in user's wallet address.
 *
 * Replaces `useAccount()` from wagmi as the source of the address. The
 * wallet is now provisioned by Circle at sign-up rather than connected
 * by the user, so the address comes from their account.
 *
 * Deliberately shaped like wagmi's useAccount so feature code can be
 * migrated by changing the import rather than restructuring:
 *
 *   - import { useAccount } from 'wagmi'
 *   + import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
 *
 * SCOPE: reading the address only. Signing still goes through Circle
 * challenges, so anything using useWriteContract, useSignTypedData or
 * useSwitchChain needs a real migration, not this shim (Phase 4).
 *
 * Named useAccountAddress rather than useWallet because useWallet
 * already exists and returns balances.
 */

import { useAuth } from '@/hooks/useAuth'

export interface AccountAddressState {
  /** Lowercase 0x address, or undefined before the wallet is provisioned. */
  address:     `0x${string}` | undefined
  /** True once the account has a wallet. Mirrors wagmi's isConnected. */
  isConnected: boolean
  /** True while the session is still being confirmed on load. */
  isLoading:   boolean
}

export function useAccountAddress(): AccountAddressState {
  const { account, loading } = useAuth()
  const address = account?.walletAddress ?? undefined

  return {
    address:     address as `0x${string}` | undefined,
    isConnected: Boolean(address),
    isLoading:   loading,
  }
}
AFX_L036_EOF
echo "  ✓ afrifx-web/hooks/useAccountAddress.ts"

mkdir -p "$(dirname "afrifx-web/components/auth/AuthGuard.tsx")"
cat > 'afrifx-web/components/auth/AuthGuard.tsx' <<'AFX_L037_EOF'
'use client'

/**
 * Gate for the signed-in app.
 *
 * Sends anyone without a session to /signin, and anyone whose wallet
 * never finished provisioning back to finish it, rather than dropping
 * them into a dashboard that cannot work.
 */

import { useEffect } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import { Loader2 } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'

export function AuthGuard({ children }: { children: React.ReactNode }) {
  const { account, loading } = useAuth()
  const router   = useRouter()
  const pathname = usePathname()

  useEffect(() => {
    if (loading) return
    if (!account) {
      // Remember where they were headed so sign-in can return them.
      const next = pathname && pathname !== '/dashboard'
        ? `?next=${encodeURIComponent(pathname)}`
        : ''
      router.replace(`/signin${next}`)
    }
  }, [account, loading, pathname, router])

  // Hold the UI while the session is confirmed. Rendering children first
  // would flash protected content to a signed-out visitor.
  if (loading || !account) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-app-muted" />
      </div>
    )
  }

  return <>{children}</>
}
AFX_L037_EOF
echo "  ✓ afrifx-web/components/auth/AuthGuard.tsx"

mkdir -p "$(dirname "afrifx-web/components/auth/AccountMenu.tsx")"
cat > 'afrifx-web/components/auth/AccountMenu.tsx' <<'AFX_L038_EOF'
'use client'

/**
 * The signed-in account chip in the top bar.
 *
 * Replaces the wallet connect button. People no longer connect a wallet:
 * they sign in, and the wallet is created for them, so the top bar shows
 * who they are rather than asking them to bring something.
 */

import { useState, useRef, useEffect } from 'react'
import Link from 'next/link'
import { User, LogOut, Copy, Check, Loader2 } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'

export function AccountMenu() {
  const { account, loading, signOut } = useAuth()
  const [open,   setOpen]   = useState(false)
  const [copied, setCopied] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  // Close on outside click and on Escape, so the menu never traps focus.
  useEffect(() => {
    if (!open) return
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onClick)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onClick)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  if (loading) {
    return <div className="h-8 w-24 animate-pulse rounded-xl bg-app-border" />
  }

  if (!account) {
    return (
      <Link href="/signin"
        className="rounded-xl bg-app-accent px-3 py-1.5 text-xs font-medium text-app-on-accent hover:bg-app-accent-hover">
        Sign in
      </Link>
    )
  }

  const initials = `${account.firstName?.[0] ?? ''}${account.lastName?.[0] ?? ''}`.toUpperCase()
  const address  = account.walletAddress

  async function copyAddress() {
    if (!address) return
    await navigator.clipboard.writeText(address).catch(() => {})
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }

  return (
    <div className="relative" ref={ref}>
      <button onClick={() => setOpen(o => !o)}
        aria-haspopup="menu" aria-expanded={open}
        className="flex items-center gap-2 rounded-xl border border-app-border px-2 py-1.5 hover:bg-app-surface">
        <span className="flex h-6 w-6 items-center justify-center rounded-full bg-app-accent/20 text-[10px] font-semibold text-app-accent-text">
          {initials || <User className="h-3 w-3" />}
        </span>
        <span className="hidden max-w-[10rem] truncate text-xs text-app-text sm:inline">
          {account.username}
        </span>
      </button>

      {open && (
        <div role="menu"
          className="absolute right-0 z-50 mt-2 w-60 rounded-xl border border-app-border bg-app-surface p-1 shadow-lg">
          <div className="border-b border-app-border px-3 py-2.5">
            <p className="truncate text-sm font-medium text-app-text">
              {account.firstName} {account.lastName}
            </p>
            <p className="truncate text-[11px] text-app-muted">{account.email}</p>

            {address ? (
              <button onClick={copyAddress}
                className="mt-2 flex w-full items-center gap-1.5 rounded-lg bg-app-bg px-2 py-1.5 text-left font-mono text-[10px] text-app-muted hover:text-app-text">
                {copied
                  ? <><Check className="h-3 w-3 shrink-0 text-emerald-500" /> Copied</>
                  : <><Copy className="h-3 w-3 shrink-0" /> {address.slice(0, 10)}…{address.slice(-6)}</>}
              </button>
            ) : (
              // Wallet setup didn't finish. Say so plainly and give them
              // the way to fix it rather than showing an empty space.
              <p className="mt-2 flex items-center gap-1.5 text-[10px] text-amber-500">
                <Loader2 className="h-3 w-3 animate-spin" /> Wallet setup unfinished
              </p>
            )}
          </div>

          <Link href="/profile" onClick={() => setOpen(false)} role="menuitem"
            className="flex items-center gap-2 rounded-lg px-3 py-2 text-xs text-app-text hover:bg-app-bg">
            <User className="h-3.5 w-3.5" /> Profile
          </Link>
          <button onClick={() => { setOpen(false); void signOut() }} role="menuitem"
            className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-xs text-app-text hover:bg-app-bg">
            <LogOut className="h-3.5 w-3.5" /> Sign out
          </button>
        </div>
      )}
    </div>
  )
}
AFX_L038_EOF
echo "  ✓ afrifx-web/components/auth/AccountMenu.tsx"

echo ""
echo "→ Done."
echo ""
echo "NEXT:"
echo "  cd afrifx-web && npm install && npx tsc --noEmit && npm run build"
echo ""
echo "  Then open the app. You should see a Sign in button, not Connect wallet."
echo "  Sign up at /signup, and the top bar should show your name and address."
echo ""
echo "  Reminder: write actions (swap, send, escrow, payroll execute) will"
echo "  fail until Phase 4 migrates them to Circle challenge signing."
echo ""
