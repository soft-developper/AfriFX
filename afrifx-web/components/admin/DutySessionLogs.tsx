'use client'
import { useEffect, useState } from 'react'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Loader2, CalendarClock, CheckCircle2, XCircle, Clock } from 'lucide-react'

interface Session {
  id: string
  admin_id: string
  admin_name: string
  window_start: number
  window_end: number
  resumed_at: number | null
  ended_at: number | null
  status: string
  disputes_accepted: number
  disputes_resolved: number
  actions_count: number
}

const STATUS: Record<string, { label: string; cls: string; icon: any }> = {
  scheduled: { label: 'Scheduled', cls: 'text-app-muted',    icon: Clock },
  on_duty:   { label: 'On duty',   cls: 'text-emerald-400',  icon: CheckCircle2 },
  ended:     { label: 'Completed', cls: 'text-app-accent-text', icon: CheckCircle2 },
  missed:    { label: 'Missed',    cls: 'text-red-400',      icon: XCircle },
}

const fmt = (ts?: number | null) =>
  ts ? new Date(ts * 1000).toLocaleString() : '—'

/*
  Session logs — how each sub-admin worked their shift. Shown to the general
  admin so they can confirm whether people resumed duty, what they handled,
  and who missed their session.
*/
export function DutySessionLogs() {
  const [sessions, setSessions] = useState<Session[]>([])
  const [loading, setLoading]   = useState(true)

  useEffect(() => {
    adminFetch('/admin/manage/duty/sessions')
      .then(r => r.json())
      .then(d => setSessions(Array.isArray(d)
        ? d.map((r: any) => Array.isArray(r) ? {
            id: r[0], admin_id: r[1], admin_name: r[2],
            window_start: r[3], window_end: r[4],
            resumed_at: r[5], ended_at: r[6], status: r[7],
            disputes_accepted: r[8], disputes_resolved: r[9], actions_count: r[10],
          } : r)
        : []))
      .catch(() => {})
      .finally(() => setLoading(false))
  }, [])

  if (loading) {
    return (
      <div className="flex h-24 items-center justify-center">
        <Loader2 className="h-5 w-5 animate-spin text-app-accent-text" />
      </div>
    )
  }

  if (!sessions.length) {
    return (
      <div className="rounded-xl border border-app-border bg-app-surface p-8 text-center">
        <CalendarClock className="mx-auto mb-2 h-7 w-7 text-app-border" />
        <p className="text-sm text-app-muted">No duty sessions yet</p>
        <p className="mt-0.5 text-xs text-app-muted">
          Sessions appear once sub-admins have working hours assigned.
        </p>
      </div>
    )
  }

  return (
    <div className="overflow-hidden rounded-xl border border-app-border bg-app-surface">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-app-border text-left text-xs text-app-muted">
              <th className="px-4 py-3 font-medium">Sub-admin</th>
              <th className="px-4 py-3 font-medium">Session window</th>
              <th className="px-4 py-3 font-medium">Resumed</th>
              <th className="px-4 py-3 font-medium">Status</th>
              <th className="px-4 py-3 text-right font-medium">Accepted</th>
              <th className="px-4 py-3 text-right font-medium">Resolved</th>
              <th className="px-4 py-3 text-right font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {sessions.map(s => {
              const meta = STATUS[s.status] ?? STATUS.scheduled
              const Icon = meta.icon
              return (
                <tr key={s.id} className="border-b border-app-border/50 last:border-0">
                  <td className="px-4 py-3 font-medium text-app-text">{s.admin_name}</td>
                  <td className="whitespace-nowrap px-4 py-3 text-xs text-app-muted">
                    {fmt(s.window_start)}
                    <span className="mx-1">→</span>
                    {new Date(Number(s.window_end) * 1000).toLocaleTimeString()}
                  </td>
                  <td className="whitespace-nowrap px-4 py-3 text-xs text-app-muted">
                    {fmt(s.resumed_at)}
                  </td>
                  <td className="px-4 py-3">
                    <span className={`inline-flex items-center gap-1.5 text-xs font-medium ${meta.cls}`}>
                      <Icon className="h-3.5 w-3.5" /> {meta.label}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right font-mono text-xs text-app-text">
                    {s.disputes_accepted ?? 0}
                  </td>
                  <td className="px-4 py-3 text-right font-mono text-xs text-app-text">
                    {s.disputes_resolved ?? 0}
                  </td>
                  <td className="px-4 py-3 text-right font-mono text-xs text-app-muted">
                    {s.actions_count ?? 0}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}
