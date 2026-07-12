'use client'
import { useEffect, useState } from 'react'
import { adminFetch } from '@/hooks/useAdminAuth'
import { useNow, countdown, formatWindow } from '@/lib/duty'
import { Loader2, CalendarClock, CheckCircle2, Clock, Timer, MinusCircle } from 'lucide-react'

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
  Every sub-admin's working-hour session, with live status, for the general
  admin. Shows who is on duty right now, who has an open session they haven't
  resumed, and a ticking countdown to everyone else's next session.
*/
export function DutyOverview() {
  const [rows, setRows]       = useState<Row[]>([])
  const [loading, setLoading] = useState(true)
  const now = useNow()

  useEffect(() => {
    const load = () =>
      adminFetch('/admin/manage/duty/overview')
        .then(r => r.json())
        .then(d => setRows(Array.isArray(d) ? d : []))
        .catch(() => {})
        .finally(() => setLoading(false))
    load()
    const t = setInterval(load, 60_000)   // re-sync each minute
    return () => clearInterval(t)
  }, [])

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

  // On-duty first, then open-but-not-resumed, then the rest.
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
        return (
          <div key={r.id}
            className={`flex flex-wrap items-center justify-between gap-3 rounded-xl border bg-app-surface p-4 ${
              r.onDuty ? 'border-emerald-500/40' :
              r.inWindow ? 'border-app-accent/40' : 'border-app-border'}`}>

            <div className="min-w-0">
              <p className="flex items-center gap-2 text-sm font-medium text-app-text">
                {r.username}
                <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-medium ${badge.cls}`}>
                  <Icon className="h-3 w-3" /> {badge.label}
                </span>
              </p>
              <p className="mt-0.5 truncate text-xs text-app-muted">
                {schedule ?? 'No working hours assigned — cannot accept disputes'}
              </p>
            </div>

            {timer && (
              <div className="text-right">
                <p className="text-[10px] uppercase tracking-wider text-app-muted">{timer.label}</p>
                <p className={`font-mono text-base font-semibold ${timer.cls}`}>{timer.value}</p>
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}
