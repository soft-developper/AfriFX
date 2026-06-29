'use client'
import { useEffect, useState } from 'react'
import { AdminShell }   from '@/components/admin/AdminShell'
import { Badge }        from '@/components/ui/badge'
import { Button }       from '@/components/ui/button'
import { adminFetch }   from '@/hooks/useAdminAuth'
import { formatAmount } from '@/lib/utils'
import {
  AlertTriangle, CheckCircle, ExternalLink,
  Loader2, ShieldCheck, RefreshCw, Scale,
} from 'lucide-react'

function parseField(row: any, key: string, idx: number) {
  return row[key] ?? row[idx]
}

export default function AdminDisputesPage() {
  const [disputes, setDisputes] = useState<any[]>([])
  const [loading,  setLoading]  = useState(true)
  const [filter,   setFilter]   = useState<'open'|'resolved'|'all'>('open')
  const [resolving, setResolving] = useState<string|null>(null)

  async function load() {
    setLoading(true)
    try {
      const res  = await adminFetch(`/disputes/admin/all?status=${filter === 'all' ? '' : filter}`)
      const data = await res.json()
      setDisputes(Array.isArray(data) ? data : [])
    } catch { setDisputes([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [filter])

  async function resolve(disputeId: string, offerId: string, resolution: string) {
    if (!confirm(`Resolve as "${resolution}"?`)) return
    setResolving(disputeId)
    try {
      await adminFetch(`/disputes/${disputeId}/resolve`, {
        method: 'PATCH',
        body: JSON.stringify({
          resolution,
          resolvedBy: 'admin',
          notes: `Admin resolved: ${resolution}`,
        }),
      })
      await load()
    } catch (err: any) {
      alert('Failed: ' + err.message)
    } finally {
      setResolving(null)
    }
  }

  const openCount     = disputes.filter(d => (d.status ?? d[4]) === 'open').length
  const resolvedCount = disputes.filter(d => (d.status ?? d[4]) === 'resolved').length

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Disputes</h1>
          <p className="text-sm text-[#64748B]">
            {openCount} open · {resolvedCount} resolved
          </p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      {/* Filter */}
      <div className="mb-4 flex gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1 w-fit">
        {(['open','resolved','all'] as const).map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B]'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
        </div>
      ) : disputes.length === 0 ? (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <Scale className="mx-auto mb-2 h-8 w-8 text-[#1B2B4B]" />
          <p className="text-sm text-[#64748B]">No {filter} disputes</p>
        </div>
      ) : (
        <div className="space-y-3">
          {disputes.map((d: any) => {
            const id           = d.id           ?? d[0]
            const offerId      = d.offer_id     ?? d[1]
            const raisedBy     = d.raised_by    ?? d[2]
            const reason       = d.reason       ?? d[3]
            const status       = d.status       ?? d[4]
            const disputeType  = d.dispute_type ?? d[5] ?? 'maker_not_received'
            const raisedByRole = d.raised_by_role ?? d[6] ?? 'taker'
            const autoRelease  = d.auto_release_at ?? d[7]
            const createdAt    = Number(d.created_at ?? d[8] ?? 0)
            const resolution   = d.resolution   ?? d[9]
            const usdcAmount   = Number(d.usdc_amount   ?? d[10] ?? 0)
            const localCcy     = d.local_currency ?? d[11] ?? ''
            const localAmt     = Number(d.local_amount  ?? d[12] ?? 0)
            const makerAddr    = d.maker_address  ?? d[13] ?? ''
            const takerAddr    = d.taker_address  ?? d[14] ?? ''

            const isOpen      = status === 'open'
            const now         = Math.floor(Date.now() / 1000)
            const timeLeft    = autoRelease ? autoRelease - now : null
            const hoursLeft   = timeLeft && timeLeft > 0
              ? Math.ceil(timeLeft / 3600)
              : null

            return (
              <div key={id}
                className={`rounded-xl border bg-[#0F1729] p-5
                  ${isOpen ? 'border-amber-900/50' : 'border-[#1B2B4B]'}`}>
                <div className="mb-3 flex flex-wrap items-start gap-3">
                  {/* Icon */}
                  <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full
                    ${isOpen ? 'bg-amber-900/20' : 'bg-emerald-900/20'}`}>
                    {isOpen
                      ? <AlertTriangle className="h-5 w-5 text-amber-400" />
                      : <CheckCircle   className="h-5 w-5 text-emerald-400" />
                    }
                  </div>

                  {/* Info */}
                  <div className="flex-1 min-w-0">
                    <div className="flex flex-wrap items-center gap-2 mb-1">
                      <Badge variant={isOpen ? 'warning' : 'success'}>{status}</Badge>
                      <Badge variant={disputeType === 'maker_silent' ? 'arc' : 'danger'}>
                        {disputeType === 'maker_silent'
                          ? '🔇 Maker silent'
                          : '💸 Payment not received'}
                      </Badge>
                      <Badge variant={raisedByRole === 'maker' ? 'warning' : 'arc'}>
                        Raised by {raisedByRole}
                      </Badge>
                    </div>

                    <p className="text-xs text-[#64748B]">
                      {new Date(createdAt * 1000).toLocaleString()} ·
                      Offer: <span className="font-mono text-[#378ADD]">{offerId?.slice(0,16)}…</span>
                    </p>
                  </div>

                  {/* ArcScan */}
                  <a href={`https://testnet.arcscan.app`} target="_blank" rel="noopener noreferrer"
                    className="text-[#64748B] hover:text-[#378ADD]">
                    <ExternalLink className="h-4 w-4" />
                  </a>
                </div>

                {/* Trade details */}
                <div className="mb-3 grid grid-cols-2 gap-3 text-xs sm:grid-cols-4">
                  <div className="rounded-lg bg-[#080D1B] p-2.5">
                    <p className="text-[#64748B]">USDC in escrow</p>
                    <p className="font-mono font-semibold text-[#E2E8F0]">${formatAmount(usdcAmount)}</p>
                  </div>
                  <div className="rounded-lg bg-[#080D1B] p-2.5">
                    <p className="text-[#64748B]">Local amount</p>
                    <p className="font-mono font-semibold text-[#E2E8F0]">
                      {localAmt.toLocaleString()} {localCcy}
                    </p>
                  </div>
                  <div className="rounded-lg bg-[#080D1B] p-2.5">
                    <p className="text-[#64748B]">Maker</p>
                    <p className="font-mono text-[#E2E8F0]">{makerAddr.slice(0,10)}…</p>
                  </div>
                  <div className="rounded-lg bg-[#080D1B] p-2.5">
                    <p className="text-[#64748B]">Taker</p>
                    <p className="font-mono text-[#E2E8F0]">{takerAddr.slice(0,10)}…</p>
                  </div>
                </div>

                {/* Reason */}
                <div className="mb-3 rounded-lg bg-[#080D1B] p-3 text-xs">
                  <p className="text-[#64748B] mb-1">Dispute reason</p>
                  <p className="text-[#E2E8F0]">{reason || '—'}</p>
                </div>

                {/* Auto-release countdown */}
                {isOpen && disputeType === 'maker_silent' && hoursLeft && (
                  <div className="mb-3 flex items-center gap-2 rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 px-3 py-2 text-xs text-[#378ADD]">
                    <Loader2 className="h-3.5 w-3.5 animate-spin shrink-0" />
                    Auto-releases to taker in ~{hoursLeft}h if unresolved
                  </div>
                )}

                {/* Resolution */}
                {!isOpen && resolution && (
                  <div className="mb-3 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                    <ShieldCheck className="h-3.5 w-3.5 shrink-0" />
                    Resolved: {resolution.replace(/_/g, ' ')}
                  </div>
                )}

                {/* Admin actions */}
                {isOpen && (
                  <div className="flex flex-wrap gap-2">
                    <Button size="sm"
                      onClick={() => resolve(id, offerId, 'release_to_taker')}
                      disabled={resolving === id}>
                      {resolving === id
                        ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        : <CheckCircle className="h-3.5 w-3.5" />}
                      Release USDC to taker
                    </Button>
                    <Button size="sm" variant="danger"
                      onClick={() => resolve(id, offerId, 'refund_maker')}
                      disabled={resolving === id}>
                      {resolving === id
                        ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        : <AlertTriangle className="h-3.5 w-3.5" />}
                      Refund USDC to maker
                    </Button>
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </AdminShell>
  )
}
