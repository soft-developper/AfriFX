'use client'
import { useState, useEffect, useCallback } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import {
  Wrench, Loader2, AlertTriangle, CheckCircle2, Globe,
  ArrowLeftRight, Send, Store, FileText, Building2, CreditCard,
} from 'lucide-react'

interface Row {
  section: string
  enabled: boolean
  message: string | null
  eta: string | null
  enabled_by: string | null
  enabled_at: number | null
}

const META: Record<string, { label: string; desc: string; icon: any }> = {
  platform:    { label: 'Whole platform', desc: 'Takes every section below offline at once', icon: Globe },
  convert:     { label: 'Convert',        desc: 'Currency conversions', icon: ArrowLeftRight },
  corridor:    { label: 'Corridor',       desc: 'Cross-border swaps',   icon: ArrowLeftRight },
  send:        { label: 'Send',           desc: 'Wallet transfers',     icon: Send },
  marketplace: { label: 'Marketplace',    desc: 'P2P offers and trades', icon: Store },
  invoices:    { label: 'Invoices',       desc: 'Invoices and payments', icon: FileText },
  treasury:    { label: 'Treasury',       desc: 'Business treasury',    icon: Building2 },
  payroll:     { label: 'Payroll',        desc: 'Batch payouts',        icon: CreditCard },
}

export default function AdminMaintenance() {
  const [rows, setRows]       = useState<Row[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy]       = useState<string | null>(null)
  const [error, setError]     = useState<string | null>(null)
  const [editing, setEditing] = useState<string | null>(null)
  const [msg, setMsg]         = useState('')
  const [eta, setEta]         = useState('')

  const load = useCallback(() =>
    adminFetch('/maintenance')
      .then(r => r.json())
      .then(d => setRows(d?.sections ?? []))
      .catch(() => {})
      .finally(() => setLoading(false))
  , [])

  useEffect(() => { load() }, [load])

  async function toggle(section: string, enabled: boolean) {
    // Taking something down is destructive to user experience confirm it.
    if (enabled) {
      const what = section === 'platform' ? 'the WHOLE PLATFORM' : `"${META[section]?.label ?? section}"`
      if (!confirm(
        `Take ${what} offline?\n\n` +
        `Users won't be able to start new actions there. Trades already in ` +
        `progress will still complete normally.`
      )) return
    }

    setBusy(section); setError(null)
    try {
      const r = await adminFetch(`/maintenance/${section}`, {
        method: 'PUT',
        body: JSON.stringify({
          enabled,
          message: enabled ? (msg.trim() || null) : null,
          eta:     enabled ? (eta.trim() || null) : null,
        }),
      })
      if (!r.ok) {
        const d = await r.json().catch(() => ({}))
        setError(d?.error ?? 'Could not update')
        return
      }
      setEditing(null); setMsg(''); setEta('')
      await load()
    } catch { setError('Could not update') }
    finally { setBusy(null) }
  }

  if (loading) {
    return (
      <AdminShell>
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
        </div>
      </AdminShell>
    )
  }

  const platform = rows.find(r => r.section === 'platform')
  const sections = rows.filter(r => r.section !== 'platform')
  const anyDown  = rows.some(r => r.enabled)

  return (
    <AdminShell>
      <div className="mb-4 flex items-baseline justify-between">
        <h1 className="text-xl font-semibold text-app-text">Maintenance</h1>
        <span className="text-xs text-app-muted">Takes effect immediately · no deploy needed</span>
      </div>

      {anyDown ? (
        <div className="mb-5 flex items-start gap-2.5 rounded-xl border border-amber-500/40 bg-amber-500/[0.07] p-4">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-400" />
          <div>
            <p className="text-sm font-medium text-app-text">Maintenance is active</p>
            <p className="mt-0.5 text-xs text-app-muted">
              Users can't start new actions in the affected sections. In-flight trades
              still complete, and admins (you) can still use everything.
            </p>
          </div>
        </div>
      ) : (
        <div className="mb-5 flex items-start gap-2.5 rounded-xl border border-emerald-500/40 bg-emerald-500/[0.07] p-4">
          <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-400" />
          <p className="text-sm text-app-text">All systems operational</p>
        </div>
      )}

      {error && (
        <div className="mb-4 rounded-xl border border-red-500/40 bg-red-500/[0.07] p-3">
          <p className="text-sm text-red-400">{error}</p>
        </div>
      )}

      <div className="space-y-2">
        {[platform, ...sections].filter(Boolean).map(r => {
          const row = r as Row
          const m = META[row.section] ?? { label: row.section, desc: '', icon: Wrench }
          const Icon = m.icon
          const isPlatform = row.section === 'platform'
          const isEditing = editing === row.section

          return (
            <div key={row.section}
              className={`rounded-xl border p-4 ${
                row.enabled
                  ? 'border-amber-500/40 bg-amber-500/[0.06]'
                  : isPlatform
                    ? 'border-app-accent/30 bg-app-surface'
                    : 'border-app-border bg-app-surface'}`}>

              <div className="flex flex-wrap items-center justify-between gap-3">
                <div className="flex items-start gap-3">
                  <span className={`inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-xl ${
                    row.enabled ? 'bg-amber-500/15 text-amber-400' : 'bg-app-border/50 text-app-muted'}`}>
                    <Icon className="h-4 w-4" />
                  </span>
                  <div>
                    <p className="flex items-center gap-2 text-sm font-medium text-app-text">
                      {m.label}
                      {row.enabled && (
                        <span className="rounded-full bg-amber-500/15 px-2 py-0.5 text-[10px] font-medium text-amber-400">
                          Offline
                        </span>
                      )}
                    </p>
                    <p className="mt-0.5 text-xs text-app-muted">
                      {row.enabled && row.enabled_by
                        ? <>Taken down by {row.enabled_by}
                            {row.enabled_at && ` · ${new Date(row.enabled_at * 1000).toLocaleString()}`}
                            {row.eta && ` · ETA: ${row.eta}`}</>
                        : m.desc}
                    </p>
                    {row.enabled && row.message && (
                      <p className="mt-1.5 rounded-lg bg-app-bg/60 px-2.5 py-1.5 text-xs text-app-text">
                        "{row.message}"
                      </p>
                    )}
                  </div>
                </div>

                <div className="flex gap-2">
                  {row.enabled ? (
                    <button onClick={() => toggle(row.section, false)} disabled={busy === row.section}
                      className="rounded-lg bg-emerald-500/15 px-3 py-1.5 text-xs font-medium text-emerald-400 hover:bg-emerald-500/25 disabled:opacity-60">
                      {busy === row.section
                        ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        : 'Restore service'}
                    </button>
                  ) : (
                    <button
                      onClick={() => isEditing ? setEditing(null) : (setEditing(row.section), setMsg(''), setEta(''))}
                      className="rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-text hover:border-amber-500/50">
                      {isEditing ? 'Cancel' : 'Take offline'}
                    </button>
                  )}
                </div>
              </div>

              {isEditing && !row.enabled && (
                <div className="mt-4 space-y-2 border-t border-app-border pt-4">
                  <input value={msg} onChange={e => setMsg(e.target.value)}
                    placeholder="Message shown to users (optional, a sensible default is used)"
                    className="w-full rounded-lg border border-app-border bg-app-bg px-3 py-2 text-xs text-app-text outline-none focus:ring-1 focus:ring-app-accent" />
                  <input value={eta} onChange={e => setEta(e.target.value)}
                    placeholder='Expected back (optional), e.g. "04:00 UTC"'
                    className="w-full rounded-lg border border-app-border bg-app-bg px-3 py-2 text-xs text-app-text outline-none focus:ring-1 focus:ring-app-accent" />
                  <button onClick={() => toggle(row.section, true)} disabled={busy === row.section}
                    className="inline-flex items-center gap-1.5 rounded-lg bg-amber-500/20 px-3 py-1.5 text-xs font-semibold text-amber-400 hover:bg-amber-500/30 disabled:opacity-60">
                    {busy === row.section
                      ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      : <><Wrench className="h-3.5 w-3.5" /> Confirm, take {m.label.toLowerCase()} offline</>}
                  </button>
                </div>
              )}
            </div>
          )
        })}
      </div>

      <p className="mt-5 text-xs text-app-muted">
        While a section is offline: users can't start new actions there, but trades
        already in progress can still be confirmed, cancelled, disputed and discussed
        so nobody's funds get stranded. Admins bypass maintenance, so you can verify
        the upgrade before restoring service.
      </p>
    </AdminShell>
  )
}
