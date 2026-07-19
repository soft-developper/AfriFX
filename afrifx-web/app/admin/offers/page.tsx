'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Loader2, ExternalLink, RefreshCw, AlertCircle, X } from 'lucide-react'

const FLAGS: Record<string,string> = { NGN:'🇳🇬',GHS:'🇬🇭',KES:'🇰🇪',ZAR:'🇿🇦',EGP:'🇪🇬' }

function norm(r: any) {
  if (Array.isArray(r)) return {
    id: r[0], maker_address: r[1], taker_address: r[2], usdc_amount: r[3],
    local_currency: r[4], local_amount: r[5], status: r[7],
    maker_confirmed: r[8], taker_confirmed: r[9], created_at: r[13],
  }
  return r
}

export default function AdminOffers() {
  const [offers,  setOffers]  = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [filter,  setFilter]  = useState('all')
  const [busy,    setBusy]    = useState<string|null>(null)
  const [error,   setError]   = useState<string|null>(null)

  async function load() {
    setLoading(true)
    const q = filter === 'all' ? '' : `?status=${filter}`
    const res = await adminFetch(`/admin/manage/offers${q}`)
    const data = await res.json()
    setOffers(Array.isArray(data) ? data.map(norm) : [])
    setLoading(false)
  }

  useEffect(() => { load() }, [filter])

  async function forceRelease(id: string) {
    if (!confirm('Force release USDC to the buyer? This is irreversible.')) return
    setBusy(id)
    try {
      const res = await adminFetch(`/admin/manage/offers/${id}/release`, { method: 'POST' })
      if (res.ok) await load()
      else setError((await res.json()).error ?? 'Failed to release offer')
    } finally { setBusy(null) }
  }

  async function forceCancel(id: string) {
    const reason = prompt('Reason for cancellation (refunds maker):')
    if (reason === null) return
    setBusy(id)
    try {
      const res = await adminFetch(`/admin/manage/offers/${id}/cancel`, {
        method: 'POST', body: JSON.stringify({ reason }),
      })
      if (res.ok) await load()
      else setError((await res.json()).error ?? 'Failed to cancel offer')
    } finally { setBusy(null) }
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-app-text">Offers management</h1>
        <button onClick={load} className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
          <RefreshCw className="h-3 w-3" /> Refresh
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

      <div className="mb-4 flex gap-2">
        {['all','open','accepted','released','cancelled'].map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-full px-3 py-1 text-xs capitalize transition-colors
              ${filter === f ? 'bg-app-accent text-app-on-accent' : 'border border-app-border text-app-muted'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent-text" /></div>
      ) : (
        <div className="space-y-2">
          {offers.map(o => (
            <div key={o.id} className="rounded-xl border border-app-border bg-app-surface p-4">
              <div className="flex items-center gap-4">
                <div className="flex h-9 w-9 items-center justify-center rounded-full bg-app-bg text-lg">
                  {FLAGS[o.local_currency] ?? '🌍'}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <p className="text-sm font-medium text-app-text">
                      {Number(o.usdc_amount).toFixed(2)} USDC ↔ {Number(o.local_amount).toLocaleString()} {o.local_currency}
                    </p>
                    <Badge variant={
                      o.status === 'released' ? 'success' :
                      o.status === 'accepted' ? 'arc' :
                      o.status === 'cancelled' ? 'danger' : 'warning'
                    }>{o.status}</Badge>
                  </div>
                  <p className="font-mono text-[10px] text-app-muted">
                    {o.id.slice(0,20)}… · maker {o.maker_address?.slice(0,8)}…
                    {o.taker_address && ` · taker ${o.taker_address.slice(0,8)}…`}
                  </p>
                </div>
                {o.status === 'accepted' && (
                  <div className="flex gap-2">
                    <Button size="sm" onClick={() => forceRelease(o.id)} disabled={busy === o.id}>
                      {busy === o.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : 'Force release'}
                    </Button>
                    <Button size="sm" variant="danger" onClick={() => forceCancel(o.id)} disabled={busy === o.id}>
                      Cancel
                    </Button>
                  </div>
                )}
              </div>
            </div>
          ))}
          {offers.length === 0 && <p className="py-8 text-center text-sm text-app-muted">No offers found</p>}
        </div>
      )}
    </AdminShell>
  )
}
