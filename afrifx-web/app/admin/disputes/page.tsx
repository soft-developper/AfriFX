'use client'
import { useEffect, useState } from 'react'
import { AdminShell }    from '@/components/admin/AdminShell'
import { Badge }         from '@/components/ui/badge'
import { Button }        from '@/components/ui/button'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { DisputeChat }   from '@/components/dispute/DisputeChat'
import { formatAmount }  from '@/lib/utils'
import {
  AlertTriangle, CheckCircle, ExternalLink,
  Loader2, Scale, RefreshCw, ChevronDown, ChevronUp,
  AlertCircle, X,
} from 'lucide-react'

export default function AdminDisputesPage() {
  const { admin }                     = useAdminAuth()
  const [disputes,   setDisputes]     = useState<any[]>([])
  const [loading,    setLoading]      = useState(true)
  const [filter,     setFilter]       = useState<'open'|'in_review'|'resolved'|'all'>('open')
  const [resolving,  setResolving]    = useState<string|null>(null)
  const [accepting,  setAccepting]    = useState<string|null>(null)
  const [expanded,   setExpanded]     = useState<string|null>(null)
  const [assignments, setAssignments] = useState<Record<string, any>>({})
  const [error,       setError]       = useState<string|null>(null)

  async function load() {
    setLoading(true)
    try {
      const res  = await adminFetch(`/disputes/admin/all${filter !== 'all' ? `?status=${filter}` : ''}`)
      const data = await res.json()
      const list = Array.isArray(data) ? data : []
      setDisputes(list)

      // Fetch assignments for all disputes
      const assignMap: Record<string, any> = {}
      await Promise.all(list.map(async (d: any) => {
        const id = d.id ?? d[0]
        try {
          const r = await adminFetch(`/disputes/${id}/assignment`)
          const a = await r.json()
          if (a) assignMap[id] = a
        } catch {}
      }))
      setAssignments(assignMap)
    } catch { setDisputes([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [filter])

  async function acceptDispute(disputeId: string) {
    if (!admin) return
    setAccepting(disputeId)
    try {
      const res = await adminFetch(`/disputes/${disputeId}/accept`, {
        method: 'POST',
        body:   JSON.stringify({ adminId: admin.id, adminName: admin.username }),
      })
      const data = await res.json()
      if (data.success) {
        setFilter('in_review') // switch to in_review tab
        await load()
        setExpanded(disputeId) // auto-expand to show chat
      } else {
        setError(data.error ?? 'Failed to accept dispute')
      }
    } catch (err: any) { setError(err.message ?? 'Failed to accept dispute') }
    finally { setAccepting(null) }
  }

  async function resolve(disputeId: string, resolution: string) {
    if (!confirm(`Resolve as "${resolution}"?`)) return
    setResolving(disputeId)
    try {
      await adminFetch(`/disputes/${disputeId}/resolve`, {
        method: 'PATCH',
        body:   JSON.stringify({
          resolution,
          resolvedBy: admin?.username ?? 'admin',
          notes:      `Admin resolved: ${resolution}`,
        }),
      })
      await load()
    } catch (err: any) { setError(err.message ?? 'Failed to resolve dispute') }
    finally { setResolving(null) }
  }

  const openCount     = disputes.filter(d => (d.status ?? d[4]) === 'open').length
  const inReviewCount = disputes.filter(d => (d.status ?? d[4]) === 'in_review').length
  const resolvedCount = disputes.filter(d => (d.status ?? d[4]) === 'resolved').length

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Disputes</h1>
          <p className="text-sm text-app-muted">
            {openCount} open · {inReviewCount} in review · {resolvedCount} resolved
          </p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      {error && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <span className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </span>
          <button onClick={() => setError(null)} className="shrink-0 hover:text-red-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {/* Filter */}
      <div className="mb-4 flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 w-fit">
        {(['open','in_review','resolved','all'] as const).map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-app-border text-app-text' : 'text-app-muted'}`}>
            {f.replace('_', ' ')}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-app-accent" />
        </div>
      ) : disputes.length === 0 ? (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <Scale className="mx-auto mb-2 h-8 w-8 text-app-border" />
          <p className="text-sm text-app-muted">No {filter} disputes</p>
        </div>
      ) : (
        <div className="space-y-3">
          {disputes.map((d: any) => {
            const id           = d.id            ?? d[0]
            const offerId      = d.offer_id      ?? d[1]
            const raisedBy     = d.raised_by     ?? d[2]
            const reason       = d.reason        ?? d[3]
            const status       = d.status        ?? d[4]
            const disputeType  = d.dispute_type  ?? 'maker_not_received'
            const raisedByRole = d.raised_by_role ?? 'taker'
            const createdAt    = Number(d.created_at ?? d[8] ?? 0)
            const resolution   = d.resolution_type
            const usdcAmount   = Number(d.usdc_amount   ?? 0)
            const localCcy     = d.local_currency ?? ''
            const localAmt     = Number(d.local_amount  ?? 0)
            const makerAddr    = d.maker_address  ?? ''
            const takerAddr    = d.taker_address  ?? ''

            const isOpen      = status === 'open'
            const isInReview  = status === 'in_review'
            const assignment  = assignments[id]
            const isMyCase    = assignment?.admin_id === admin?.id
            const isExpanded  = expanded === id

            return (
              <div key={id}
                className={`rounded-xl border bg-app-surface overflow-hidden
                  ${isOpen ? 'border-amber-900/50' :
                    isInReview ? 'border-app-accent/40' : 'border-app-border'}`}>

                {/* Header */}
                <div className="p-5">
                  <div className="mb-3 flex flex-wrap items-start gap-3">
                    <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full
                      ${isOpen ? 'bg-amber-900/20' : isInReview ? 'bg-app-accent/10' : 'bg-emerald-900/20'}`}>
                      {isOpen ? <AlertTriangle className="h-5 w-5 text-amber-400" />
                       : isInReview ? <Scale className="h-5 w-5 text-app-accent" />
                       : <CheckCircle className="h-5 w-5 text-emerald-400" />}
                    </div>

                    <div className="flex-1 min-w-0">
                      <div className="flex flex-wrap items-center gap-2 mb-1">
                        <Badge variant={isOpen ? 'warning' : isInReview ? 'arc' : 'success'}>
                          {status.replace('_', ' ')}
                        </Badge>
                        <Badge variant={disputeType === 'maker_silent' ? 'arc' : 'danger'}>
                          {disputeType === 'maker_silent' ? '🔇 Maker silent' : '💸 Payment not received'}
                        </Badge>
                        <Badge variant={raisedByRole === 'maker' ? 'warning' : 'arc'}>
                          By {raisedByRole}
                        </Badge>
                        {assignment && (
                          <Badge variant="success">⚖️ {assignment.admin_name}</Badge>
                        )}
                      </div>
                      <p className="text-xs text-app-muted">
                        {new Date(createdAt * 1000).toLocaleString()} ·
                        <span className="font-mono text-app-accent ml-1">{offerId?.slice(0,16)}…</span>
                      </p>
                    </div>

                    {/* Expand toggle */}
                    <button onClick={() => setExpanded(isExpanded ? null : id)}
                      className="text-app-muted hover:text-app-text">
                      {isExpanded ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                    </button>
                  </div>

                  {/* Trade details */}
                  <div className="mb-3 grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
                    <div className="rounded-lg bg-app-bg p-2">
                      <p className="text-app-muted">USDC</p>
                      <p className="font-mono font-semibold text-app-text">${formatAmount(usdcAmount)}</p>
                    </div>
                    <div className="rounded-lg bg-app-bg p-2">
                      <p className="text-app-muted">Local</p>
                      <p className="font-mono font-semibold text-app-text">{localAmt.toLocaleString()} {localCcy}</p>
                    </div>
                    <div className="rounded-lg bg-app-bg p-2">
                      <p className="text-app-muted">Maker</p>
                      <p className="font-mono text-app-text">{makerAddr.slice(0,10)}…</p>
                    </div>
                    <div className="rounded-lg bg-app-bg p-2">
                      <p className="text-app-muted">Taker</p>
                      <p className="font-mono text-app-text">{takerAddr.slice(0,10)}…</p>
                    </div>
                  </div>

                  {/* Reason */}
                  <div className="mb-3 rounded-lg bg-app-bg p-2.5 text-xs">
                    <p className="text-app-muted mb-1">Reason</p>
                    <p className="text-app-text">{reason || '—'}</p>
                  </div>

                  {/* Resolution */}
                  {resolution && (
                    <div className="mb-3 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                      Resolved: {resolution.replace(/_/g, ' ')}
                    </div>
                  )}

                  {/* Actions */}
                  <div className="flex flex-wrap gap-2">
                    {/* Accept button — for unassigned open disputes */}
                    {isOpen && !assignment && (
                      <Button size="sm" onClick={() => acceptDispute(id)}
                        disabled={accepting === id}>
                        {accepting === id
                          ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                          : <Scale className="h-3.5 w-3.5" />
                        }
                        Accept dispute — become judge
                      </Button>
                    )}

                    {/* Already assigned to another admin */}
                    {(isOpen || isInReview) && assignment && !isMyCase && (
                      <p className="text-xs text-app-muted py-1">
                        Handled by Admin {assignment.admin_name}
                      </p>
                    )}

                    {/* Resolve buttons — only for assigned admin */}
                    {isInReview && isMyCase && (
                      <>
                        <Button size="sm"
                          onClick={() => resolve(id, 'release_to_taker')}
                          disabled={resolving === id}>
                          {resolving === id ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                            : <CheckCircle className="h-3.5 w-3.5" />}
                          Release to taker
                        </Button>
                        <Button size="sm" variant="danger"
                          onClick={() => resolve(id, 'refund_maker')}
                          disabled={resolving === id}>
                          {resolving === id ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                            : <AlertTriangle className="h-3.5 w-3.5" />}
                          Refund maker
                        </Button>
                      </>
                    )}

                    <a href={`https://testnet.arcscan.app`} target="_blank" rel="noopener noreferrer"
                      className="ml-auto text-app-muted hover:text-app-accent">
                      <ExternalLink className="h-4 w-4" />
                    </a>
                  </div>
                </div>

                {/* Chat — expanded section */}
                {isExpanded && admin && (isInReview || isOpen) && isMyCase && (
                  <div className="border-t border-app-border p-4">
                    <p className="mb-2 text-xs font-medium text-app-muted">
                      ⚖️ Messages go to both parties · Request statements privately below
                    </p>
                    {/* Request statement buttons */}
                    <div className="mb-3 flex gap-2">
                      <button
                        onClick={async () => {
                          await adminFetch(`/disputes/${id}/messages`, {
                            method: 'POST',
                            body: JSON.stringify({
                              senderId: admin?.id, senderType: 'admin',
                              senderName: admin?.username,
                              content: '📋 Please upload your bank account statement for the disputed period so we can review your case.',
                              adminOnly: 0,
                            }),
                          })
                        }}
                        className="rounded-lg border border-app-accent/40 bg-app-accent/10 px-3 py-1.5 text-xs text-app-accent hover:bg-app-accent/20 transition-colors">
                        📋 Request statement from maker
                      </button>
                      <button
                        onClick={async () => {
                          await adminFetch(`/disputes/${id}/messages`, {
                            method: 'POST',
                            body: JSON.stringify({
                              senderId: admin?.id, senderType: 'admin',
                              senderName: admin?.username,
                              content: '📋 Please upload your bank transfer receipt or proof of payment so we can review your case.',
                              adminOnly: 0,
                            }),
                          })
                        }}
                        className="rounded-lg border border-app-accent/40 bg-app-accent/10 px-3 py-1.5 text-xs text-app-accent hover:bg-app-accent/20 transition-colors">
                        📋 Request statement from taker
                      </button>
                    </div>
                    <DisputeChat
                      disputeId={id}
                      senderId={admin.id}
                      senderType="admin"
                      senderName={admin.username}
                      viewerType="admin"
                      title="Three-way dispute chat"
                    />
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
