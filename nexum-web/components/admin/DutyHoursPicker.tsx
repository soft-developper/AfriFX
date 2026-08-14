'use client'
import { useState, useEffect } from 'react'
import { Clock, AlertCircle } from 'lucide-react'

const DAYS = [
  { n: 1, label: 'Mon' }, { n: 2, label: 'Tue' }, { n: 3, label: 'Wed' },
  { n: 4, label: 'Thu' }, { n: 5, label: 'Fri' }, { n: 6, label: 'Sat' },
  { n: 0, label: 'Sun' },
]

const MAX_MINUTES = 360 // 6 hours

function toHHMM(min: number) {
  const h = String(Math.floor(min / 60)).padStart(2, '0')
  const m = String(min % 60).padStart(2, '0')
  return `${h}:${m}`
}
function toMin(hhmm: string) {
  const [h, m] = hhmm.split(':').map(Number)
  return (h || 0) * 60 + (m || 0)
}

export interface DutyValue {
  dutyStartMin: number
  dutyEndMin:   number
  dutyDays:     number[]
  dutyDates:    string[]
}

/*
  Working-hours picker. Times are UTC (stored as minutes from midnight).
  Enforces the 6-hour maximum in the UI, so the admin sees the limit
  immediately rather than getting a server error.
*/
export function DutyHoursPicker({
  value, onChange,
}: { value: DutyValue | null; onChange: (v: DutyValue | null) => void }) {
  const [enabled, setEnabled] = useState(!!value)
  const [start,   setStart]   = useState(value ? toHHMM(value.dutyStartMin) : '09:00')
  const [end,     setEnd]     = useState(value ? toHHMM(value.dutyEndMin)   : '15:00')
  const [days,    setDays]    = useState<number[]>(value?.dutyDays ?? [1, 2, 3, 4, 5])
  const [dates,   setDates]   = useState<string[]>(value?.dutyDates ?? [])
  const [newDate, setNewDate] = useState('')

  const startMin = toMin(start)
  const endMin   = toMin(end)
  const span     = endMin - startMin

  const error =
    !enabled ? null
    : span <= 0 ? 'End time must be after start time'
    : span > MAX_MINUTES ? `Session cannot exceed 6 hours (currently ${(span / 60).toFixed(1)}h)`
    : (!days.length && !dates.length) ? 'Choose at least one day or a specific date'
    : null

  useEffect(() => {
    if (!enabled) { onChange(null); return }
    if (error) { onChange(null); return }
    onChange({ dutyStartMin: startMin, dutyEndMin: endMin, dutyDays: days, dutyDates: dates })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, startMin, endMin, days.join(','), dates.join(','), error])

  const toggleDay = (n: number) =>
    setDays(d => d.includes(n) ? d.filter(x => x !== n) : [...d, n])

  return (
    <div className="rounded-lg border border-app-border bg-app-bg/40 p-4">
      <label className="flex items-center gap-2 text-sm font-medium text-app-text">
        <input type="checkbox" checked={enabled}
          onChange={e => setEnabled(e.target.checked)}
          className="h-4 w-4 rounded border-app-border" />
        <Clock className="h-4 w-4 text-app-accent-text" />
        Set dispute duty hours
      </label>
      <p className="mt-1 text-xs text-app-muted">
        Sub-admins can only accept disputes during their session (max 6 hours). Times are UTC.
      </p>

      {enabled && (
        <div className="mt-4 space-y-3">
          <div className="flex items-center gap-3">
            <span className="w-12 text-xs text-app-muted">From</span>
            <input type="time" value={start} onChange={e => setStart(e.target.value)}
              className="rounded-lg border border-app-border bg-app-surface px-3 py-1.5 text-sm text-app-text" />
            <span className="w-8 text-center text-xs text-app-muted">to</span>
            <input type="time" value={end} onChange={e => setEnd(e.target.value)}
              className="rounded-lg border border-app-border bg-app-surface px-3 py-1.5 text-sm text-app-text" />
            {!error && span > 0 && (
              <span className="text-xs text-app-muted">({(span / 60).toFixed(1)}h)</span>
            )}
          </div>

          <div>
            <p className="mb-1.5 text-xs text-app-muted">Recurring days</p>
            <div className="flex flex-wrap gap-1.5">
              {DAYS.map(d => (
                <button key={d.n} type="button" onClick={() => toggleDay(d.n)}
                  className={`rounded-lg px-2.5 py-1 text-xs font-medium transition-colors ${
                    days.includes(d.n)
                      ? 'bg-app-accent text-app-on-accent'
                      : 'border border-app-border text-app-muted hover:text-app-text'}`}>
                  {d.label}
                </button>
              ))}
            </div>
          </div>

          <div>
            <p className="mb-1.5 text-xs text-app-muted">Specific dates (optional)</p>
            <div className="flex gap-2">
              <input type="date" value={newDate} onChange={e => setNewDate(e.target.value)}
                className="rounded-lg border border-app-border bg-app-surface px-3 py-1.5 text-sm text-app-text" />
              <button type="button"
                onClick={() => { if (newDate && !dates.includes(newDate)) { setDates([...dates, newDate]); setNewDate('') } }}
                className="rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-text hover:border-app-accent">
                Add
              </button>
            </div>
            {dates.length > 0 && (
              <div className="mt-2 flex flex-wrap gap-1.5">
                {dates.map(d => (
                  <span key={d}
                    className="inline-flex items-center gap-1.5 rounded-full bg-app-accent/10 px-2.5 py-1 text-xs text-app-accent-text">
                    {d}
                    <button type="button" onClick={() => setDates(dates.filter(x => x !== d))}
                      className="hover:text-app-text">×</button>
                  </span>
                ))}
              </div>
            )}
          </div>

          {error && (
            <p className="flex items-center gap-1.5 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5" /> {error}
            </p>
          )}
        </div>
      )}
    </div>
  )
}
