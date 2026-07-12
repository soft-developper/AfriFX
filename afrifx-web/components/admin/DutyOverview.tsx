'use client'
import { useEffect, useState, useCallback } from 'react'
import { adminFetch } from '@/hooks/useAdminAuth'
import { useNow, countdown, formatWindow } from '@/lib/duty'
import { DutyHoursPicker, type DutyValue } from '@/components/admin/DutyHoursPicker'
import {
  Loader2, CalendarClock, CheckCircle2, Clock, Timer,
  MinusCircle, Pencil, X, Trash2,
} from 'lucide-react'

interface Row {
  id: string
  username: string
  email: string
  accountStatus: string
  hasWindow: boolean
  startMin?: number
  endMin?: number
  days?: number[]
  dates?: string[]
  inWindow?: boolean
  onDuty?: boolean
  windowStart?: number | null
  windowEnd?: number | null
  nextStart?: number | null
}

/*
  Every sub-admin's working-hour session, with live status — and the controls
  to SET, CHANGE or CLEAR their hours in place (no delete-and-re-invite needed).
  The sub-admin is emailed whenever their hours change.
*/
export function DutyOverview() {
  const [rows, setRows]       = useState<Row[]>([])
  const [loading, setLoading] = useState(true)
  const [editing, setEditing] = useState<string | null>(null)
  const [draft, setDraft]     = useState<DutyValue | null>(null)
  const [busy, setBusy]       = useState<string | null>(null)
  const [error, setError]     = useState<string | null>(null)
  const now = useNow()

  const load = useCallback(() =>
    adminFetch('/admin/manage/duty/overview')
      .then(r => r.json())
      .then(d => setRows(Array.isArray(d) ? d : []))
      .catch(() => {})
      .finally(() => setLoading(false))
  , [])

  useEffect(() => {
    load()
    const t = setInterval(load, 60_000)
    return () => clearInterval(t)
  }, [load])

  function startEdit(r: Row) {
    setError(null)
    setEditing(r.id)
    setDraft(r.hasWindow && r.startMin != null && r.endMin != null
      ? { dutyStartMin: r.startMin, dutyEndMin: r.endMin,
          dutyDays: r.days ?? [], dutyDates: r.dates ?? [] }
      : null)
  }

  async function save(id: string) {
    if (!draft) { setError('Set a valid window first'); return }
    setBusy(id); setError(null)
    try {
      const r = await adminFetch(`/admin/manage/admins/${id}/duty`, {
        method: 'PATCH', body: JSON.stringify(draft),
      })
      const d = await r.json()
      if (!r.ok) { setError(d?.error ?? 'Could not save hours'); return }
      setEditing(null); setDraft(null)
      await load()
    } catch { setError('Could not save hours') }
    finally { setBusy(null) }
  }

  async function clearHours(id: string, username: string) {
    if (!confirm(`Remove ${username}'s working hours? They won't be able to accept disputes until hours are set again.`)) return
    setBusy(id); setError(null)
    try {
      const r = await adminFetch(`/admin/manage/admins/${id}/duty`, {
        method: 'PATCH', body: JSON.stringify({ clear: true }),
      })
      if (!r.ok) { const d = await r.json(); setError(d?.error ?? 'Could not clear hours'); return }
      setEditing(null); setDraft(null)
      await load()
    } catch { setError('Could not clear hours') }
    finally { setBusy(null) }
  }

  if (loading) {
    return (
      <div className="flex h-24 items-center justify-center">
        <Loader2 className="h-5 w-5 animate-spin text-app-accent-text" />
      </div>
    )
  }

  if (!rows.length) {
    return (
      <div className="rounded-xl border border-app-border bg-app-surface p-8 text-center">
        <CalendarClock className="mx-auto mb-2 h-7 w-7 text-app-border" />
        <p className="text-sm text-app-muted">No sub-admins yet</p>
      </div>
    )
  }

  const rank = (r: Row) => r.onDuty ? 0 : r.inWindow ? 1 : r.hasWindow ? 2 : 3
  const sorted = [...rows].sort((a, b) => rank(a) - rank(b))

  return (
    <div className="space-y-2">
      {sorted.map(r => {
        const schedule = r.hasWindow && r.startMin != null && r.endMin != null
          ? formatWindow(r.startMin, r.endMin, r.days ?? [], r.dates ?? [])
          : null

        let badge: { label: string; cls: string; icon: any }
        let timer: { label: string; value: string; cls: string } | null = null

        if (!r.hasWindow) {
          badge = { label: 'No hours set', cls: 'bg-app-border/50 text-app-muted', icon: MinusCircle }
        } else if (r.onDuty && r.windowEnd) {
          badge = { label: 'On duty', cls: 'bg-emerald-500/15 text-emerald-400', icon: CheckCircle2 }
          const left = r.windowEnd - now
          timer = { label: 'Ends in', value: left > 0 ? countdown(left) : 'Ending…', cls: 'text-emerald-400' }
        } else if (r.inWindow && r.windowEnd) {
          badge = { label: 'Session open — not resumed', cls: 'bg-app-accent/15 text-app-accent-text', icon: Clock }
          const left = r.windowEnd - now
          timer = { label: 'Time left', value: left > 0 ? countdown(left) : '—', cls: 'text-app-accent-text' }
        } else {
          badge = { label: 'Off duty', cls: 'bg-app-border/50 text-app-muted', icon: Timer }
          if (r.nextStart) {
            const until = r.nextStart - now
            timer = { label: 'Next session in', value: until > 0 ? countdown(until) : 'Starting…', cls: 'text-app-text' }
          }
        }

        const Icon = badge.icon
        const isEditing = editing === r.id

        return (
          <div key={r.id}
            className={`rounded-xl border bg-app-surface p-4 ${
              r.onDuty ? 'border-emerald-500/40' :
              r.inWindow ? 'border-app-accent/40' : 'border-app-border'}`}>

            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="min-w-0">
                <p className="flex flex-wrap items-center gap-2 text-sm font-medium text-app-text">
                  {r.username}
                  <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-medium ${badge.cls}`}>
                    <Icon className="h-3 w-3" /> {badge.label}
                  </span>
                </p>
                <p className="mt-0.5 truncate text-xs text-app-muted">
                  {schedule ?? 'No working hours assigned — cannot accept disputes'}
                </p>
              </div>

              <div className="flex items-center gap-4">
                {timer && !isEditing && (
                  <div className="text-right">
                    <p className="text-[10px] uppercase tracking-wider text-app-muted">{timer.label}</p>
                    <p className={`font-mono text-base font-semibold ${timer.cls}`}>{timer.value}</p>
                  </div>
                )}
                <button
                  onClick={() => isEditing ? (setEditing(null), setDraft(null)) : startEdit(r)}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-app-border px-2.5 py-1.5 text-xs text-app-text hover:border-app-accent">
                  {isEditing ? <><X className="h-3.5 w-3.5" /> Cancel</> : <><Pencil className="h-3.5 w-3.5" /> {r.hasWindow ? 'Edit hours' : 'Set hours'}</>}
                </button>
              </div>
            </div>

            {isEditing && (
              <div className="mt-4 border-t border-app-border pt-4">
                <DutyHoursPicker key={r.id} value={draft} onChange={setDraft} />
                {error && <p className="mt-2 text-xs text-red-400">{error}</p>}
                <div className="mt-3 flex flex-wrap gap-2">
                  <button onClick={() => save(r.id)} disabled={busy === r.id || !draft}
                    className="inline-flex items-center gap-1.5 rounded-lg bg-app-accent px-3 py-1.5 text-xs font-semibold text-app-on-accent hover:bg-app-accent-hover disabled:opacity-60">
                    {busy === r.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : 'Save hours'}
                  </button>
                  {r.hasWindow && (
                    <button onClick={() => clearHours(r.id, r.username)} disabled={busy === r.id}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-red-500/40 px-3 py-1.5 text-xs font-medium text-red-400 hover:bg-red-500/10 disabled:opacity-60">
                      <Trash2 className="h-3.5 w-3.5" /> Remove hours
                    </button>
                  )}
                </div>
                <p className="mt-2 text-xs text-app-muted">
                  {r.username} will be emailed about the change.
                </p>
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}
