'use client'
import { useEffect, useState } from 'react'

/*
  Shared duty helpers: a live ticking countdown, plus formatters for
  working-hour windows. Times are stored in UTC minutes-from-midnight.
*/

// Ticks every second so countdowns update live.
export function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), intervalMs)
    return () => clearInterval(t)
  }, [intervalMs])
  return now
}

// "2h 14m 09s" drops the hours segment when zero.
export function countdown(seconds: number): string {
  if (seconds <= 0) return '0s'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = seconds % 60
  if (h > 0) return `${h}h ${String(m).padStart(2, '0')}m ${String(s).padStart(2, '0')}s`
  if (m > 0) return `${m}m ${String(s).padStart(2, '0')}s`
  return `${s}s`
}

// 540 -> "09:00"
export function hhmm(min: number): string {
  const h = String(Math.floor(min / 60)).padStart(2, '0')
  const m = String(min % 60).padStart(2, '0')
  return `${h}:${m}`
}

const DAY_LABEL = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

// [1,2,3,4,5] -> "Mon–Fri" (collapses runs), else "Mon, Wed, Fri"
export function formatDays(days: number[]): string {
  if (!days?.length) return '-'
  const order = [1, 2, 3, 4, 5, 6, 0] // Mon-first
  const sorted = order.filter(d => days.includes(d))
  if (!sorted.length) return '-'
  if (sorted.length === 1) return DAY_LABEL[sorted[0]]

  // Collapse contiguous runs in Mon-first order.
  const parts: string[] = []
  let runStart = 0
  for (let i = 1; i <= sorted.length; i++) {
    const contiguous =
      i < sorted.length &&
      order.indexOf(sorted[i]) === order.indexOf(sorted[i - 1]) + 1
    if (!contiguous) {
      const a = sorted[runStart], b = sorted[i - 1]
      parts.push(runStart === i - 1
        ? DAY_LABEL[a]
        : (i - 1 - runStart === 1
            ? `${DAY_LABEL[a]}, ${DAY_LABEL[b]}`
            : `${DAY_LABEL[a]}–${DAY_LABEL[b]}`))
      runStart = i
    }
  }
  return parts.join(', ')
}

// "Mon–Fri · 09:00–15:00 UTC (6h)"
export function formatWindow(startMin: number, endMin: number, days: number[], dates: string[] = []): string {
  const span = ((endMin - startMin) / 60).toFixed(1).replace(/\.0$/, '')
  const dayPart = days?.length ? formatDays(days) : (dates?.length ? `${dates.length} date${dates.length === 1 ? '' : 's'}` : '-')
  return `${dayPart} · ${hhmm(startMin)}–${hhmm(endMin)} UTC (${span}h)`
}
