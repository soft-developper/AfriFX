'use client'
import { useEffect, useState, useCallback } from 'react'
import { adminFetch } from '@/hooks/useAdminAuth'
import { useNow, countdown, formatWindow } from '@/lib/duty'
import { Clock, CheckCircle2, Loader2, AlertCircle, Timer } from 'lucide-react'

interface DutyState {
  hasWindow:   boolean
  inWindow:    boolean
  onDuty:      boolean
  windowStart?: number
  windowEnd?:   number
  nextStart?:   number
  role?:        string
  startMin?:    number
  endMin?:      number
  days?:        number[]
  dates?:       string[]
}

/*
  A sub-admin's own duty session, with a LIVE countdown:
    - on duty        -> time remaining in this session
    - session open   -> "Resume duty" (required) + time remaining to use it
    - off duty       -> ticking countdown to their next session
  Super admins bypass the duty system, so nothing renders for them.
*/
export function DutyBanner() {
  const [state, setState] = useState<DutyState | null>(null)
  const [busy, setBusy]   = useState(false)
  const [error, setError] = useState<string | null>(null)
  const now = useNow()

  const load = useCallback(async () => {
    try {
      const r = await adminFetch('/admin/manage/duty/status')
      setState(await r.json())
    } catch { /* keep last state */ }
  }, [])

  useEffect(() => {
    load()
    const t = setInterval(load, 60_000) // re-sync with server each minute
    return () => clearInterval(t)
  }, [load])

  async function resume() {
    setBusy(true); setError(null)
    try {
      const r = await adminFetch('/admin/manage/duty/resume', { method: 'POST' })
      const d = await r.json()
      if (!r.ok) setError(d?.error ?? 'Could not resume duty')
      else await load()
    } catch { setError('Could not resume duty') }
    finally { setBusy(false) }
  }

  if (!state || state.role === 'super_admin') return null

  const schedule = state.hasWindow && state.startMin != null && state.endMin != null
    ? formatWindow(state.startMin, state.endMin, state.days ?? [], state.dates ?? [])
    : null

  // No hours assigned.
  if (!state.hasWindow) {
    return (
      <div className="mb-6 flex items-start gap-3 rounded-xl border border-app-border bg-app-surface p-4">
        <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-app-muted" />
        <div>
          <p className="text-sm font-medium text-app-text">No duty hours assigned</p>
          <p className="mt-0.5 text-xs text-app-muted">
            You can't accept disputes until an admin assigns your working hours.
          </p>
        </div>
      </div>
    )
  }

  // ON DUTY show time remaining, ticking.
  if (state.onDuty && state.windowEnd) {
    const left = state.windowEnd - now
    return (
      <div className="mb-6 rounded-xl border border-emerald-500/40 bg-emerald-500/[0.07] p-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-start gap-3">
            <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-400" />
            <div>
              <p className="text-sm font-medium text-app-text">You're on duty</p>
              <p className="mt-0.5 text-xs text-app-muted">{schedule}</p>
            </div>
          </div>
          <div className="text-right">
            <p className="text-[10px] uppercase tracking-wider text-app-muted">Session ends in</p>
            <p className="font-mono text-lg font-semibold text-emerald-400">
              {left > 0 ? countdown(left) : 'Ending…'}
            </p>
          </div>
        </div>
        <p className="mt-3 border-t border-emerald-500/20 pt-2.5 text-xs text-app-muted">
          Disputes you've already accepted can still be finished after your session ends
          you just can't accept new ones.
        </p>
      </div>
    )
  }

  // IN WINDOW, NOT RESUMED the actionable state.
  if (state.inWindow && state.windowEnd) {
    const left = state.windowEnd - now
    return (
      <div className="mb-6 rounded-xl border border-app-accent/40 bg-app-accent/[0.07] p-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-start gap-3">
            <Clock className="mt-0.5 h-4 w-4 shrink-0 text-app-accent-text" />
            <div>
              <p className="text-sm font-medium text-app-text">Your session is open</p>
              <p className="mt-0.5 text-xs text-app-muted">{schedule}</p>
              {error && <p className="mt-1.5 text-xs text-red-400">{error}</p>}
            </div>
          </div>
          <div className="flex items-center gap-4">
            <div className="text-right">
              <p className="text-[10px] uppercase tracking-wider text-app-muted">Time left</p>
              <p className="font-mono text-lg font-semibold text-app-accent-text">
                {left > 0 ? countdown(left) : '-'}
              </p>
            </div>
            <button onClick={resume} disabled={busy}
              className="shrink-0 rounded-lg bg-app-accent px-4 py-2 text-sm font-semibold text-app-on-accent hover:bg-app-accent-hover disabled:opacity-60">
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Resume duty'}
            </button>
          </div>
        </div>
        <p className="mt-3 border-t border-app-accent/20 pt-2.5 text-xs text-app-muted">
          Click <strong className="text-app-text">Resume duty</strong> to start accepting disputes.
        </p>
      </div>
    )
  }

  // OFF DUTY ticking countdown to the next session.
  const until = state.nextStart ? state.nextStart - now : null
  return (
    <div className="mb-6 rounded-xl border border-app-border bg-app-surface p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-start gap-3">
          <Timer className="mt-0.5 h-4 w-4 shrink-0 text-app-muted" />
          <div>
            <p className="text-sm font-medium text-app-text">Off duty</p>
            <p className="mt-0.5 text-xs text-app-muted">{schedule}</p>
          </div>
        </div>
        {until != null && until > 0 ? (
          <div className="text-right">
            <p className="text-[10px] uppercase tracking-wider text-app-muted">Next session in</p>
            <p className="font-mono text-lg font-semibold text-app-text">{countdown(until)}</p>
            <p className="text-[10px] text-app-muted">
              {state.nextStart ? new Date(state.nextStart * 1000).toLocaleString() : ''}
            </p>
          </div>
        ) : (
          <p className="text-xs text-app-muted">No upcoming session scheduled</p>
        )}
      </div>
      <p className="mt-3 border-t border-app-border pt-2.5 text-xs text-app-muted">
        You can't accept new disputes until your session opens.
      </p>
    </div>
  )
}
