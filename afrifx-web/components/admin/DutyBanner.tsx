'use client'
import { useEffect, useState, useCallback } from 'react'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Clock, CheckCircle2, Loader2, AlertCircle } from 'lucide-react'

interface DutyState {
  hasWindow:   boolean
  inWindow:    boolean
  onDuty:      boolean
  windowStart?: number
  windowEnd?:   number
  nextStart?:   number
  role?:        string
}

function fmt(ts?: number) {
  if (!ts) return '—'
  return new Date(ts * 1000).toLocaleString()
}

/*
  Shows the sub-admin their duty session state and the "Resume duty" control.
  Being inside the window is NOT enough — they must resume to accept disputes.
  Super admins bypass the duty system entirely, so nothing renders for them.
*/
export function DutyBanner() {
  const [state, setState]   = useState<DutyState | null>(null)
  const [busy, setBusy]     = useState(false)
  const [error, setError]   = useState<string | null>(null)

  const load = useCallback(async () => {
    try {
      const r = await adminFetch('/admin/manage/duty/status')
      setState(await r.json())
    } catch { /* leave as-is */ }
  }, [])

  useEffect(() => {
    load()
    const t = setInterval(load, 60_000) // refresh each minute
    return () => clearInterval(t)
  }, [load])

  async function resume() {
    setBusy(true); setError(null)
    try {
      const r = await adminFetch('/admin/manage/duty/resume', { method: 'POST' })
      const d = await r.json()
      if (!r.ok) setError(d?.error ?? 'Could not resume duty')
      else await load()
    } catch {
      setError('Could not resume duty')
    } finally { setBusy(false) }
  }

  // Super admins aren't gated; no banner for them.
  if (!state || state.role === 'super_admin') return null

  // No hours assigned — tell them, since they won't be able to take disputes.
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

  // On duty — the good state.
  if (state.onDuty) {
    return (
      <div className="mb-6 flex items-start gap-3 rounded-xl border border-emerald-500/40 bg-emerald-500/[0.07] p-4">
        <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-400" />
        <div>
          <p className="text-sm font-medium text-app-text">You're on duty</p>
          <p className="mt-0.5 text-xs text-app-muted">
            You can accept disputes until {fmt(state.windowEnd)}. Disputes you've already
            accepted can be finished even after your session ends.
          </p>
        </div>
      </div>
    )
  }

  // In window but not resumed — the actionable state.
  if (state.inWindow) {
    return (
      <div className="mb-6 rounded-xl border border-app-accent/40 bg-app-accent/[0.07] p-4">
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-start gap-3">
            <Clock className="mt-0.5 h-4 w-4 shrink-0 text-app-accent-text" />
            <div>
              <p className="text-sm font-medium text-app-text">Your session is open</p>
              <p className="mt-0.5 text-xs text-app-muted">
                {fmt(state.windowStart)} — {fmt(state.windowEnd)}. Resume duty to start
                accepting disputes.
              </p>
              {error && <p className="mt-1.5 text-xs text-red-400">{error}</p>}
            </div>
          </div>
          <button onClick={resume} disabled={busy}
            className="shrink-0 rounded-lg bg-app-accent px-4 py-2 text-sm font-semibold text-app-on-accent hover:bg-app-accent-hover disabled:opacity-60">
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Resume duty'}
          </button>
        </div>
      </div>
    )
  }

  // Outside the window.
  return (
    <div className="mb-6 flex items-start gap-3 rounded-xl border border-app-border bg-app-surface p-4">
      <Clock className="mt-0.5 h-4 w-4 shrink-0 text-app-muted" />
      <div>
        <p className="text-sm font-medium text-app-text">Off duty</p>
        <p className="mt-0.5 text-xs text-app-muted">
          {state.nextStart
            ? <>Your next session starts {fmt(state.nextStart)}.</>
            : <>No upcoming session scheduled.</>}
          {' '}You can't accept new disputes until then.
        </p>
      </div>
    </div>
  )
}
