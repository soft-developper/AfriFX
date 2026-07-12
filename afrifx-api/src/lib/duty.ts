// ============================================================
// Dispute duty sessions.
//
// Rules (per spec):
//  * A sub-admin's working hours are set by the general admin at invite time.
//    Max 6 hours. Recurring on chosen weekdays, plus optional specific dates.
//  * Being INSIDE the window is not enough — the sub-admin must click
//    "resume duty" to actually go on duty.
//  * Only an ON-DUTY sub-admin can ACCEPT a new dispute.
//  * If their window ends while they hold a dispute, they may finish it,
//    but cannot accept new ones (enforced at the accept endpoint only).
// ============================================================

import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'

export const MAX_DUTY_MINUTES = 360 // 6 hours

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}
const val = (row: any, key: string, i: number) => Array.isArray(row) ? row[i] : row[key]

export interface DutyWindow {
  startMin: number      // minutes from midnight UTC
  endMin:   number
  days:     number[]    // 0..6 (Sun..Sat)
  dates:    string[]    // 'YYYY-MM-DD' specific dates
}

// Validate a proposed window. Returns an error string, or null if OK.
export function validateWindow(w: Partial<DutyWindow>): string | null {
  const { startMin, endMin } = w
  if (startMin == null || endMin == null) return 'Working hours are required'
  if (startMin < 0 || startMin > 1439 || endMin < 0 || endMin > 1439) {
    return 'Working hours must be within a single day'
  }
  const span = endMin - startMin
  if (span <= 0) return 'End time must be after start time'
  if (span > MAX_DUTY_MINUTES) return 'Working session cannot exceed 6 hours'
  if ((!w.days || !w.days.length) && (!w.dates || !w.dates.length)) {
    return 'Choose at least one recurring day or a specific date'
  }
  return null
}

// Is `at` (unix seconds) inside this admin's scheduled window today?
// Returns the window's [start,end] in unix seconds if so, else null.
export function windowAt(w: DutyWindow, at: number): { start: number; end: number } | null {
  const d       = new Date(at * 1000)
  const dow     = d.getUTCDay()
  const iso     = d.toISOString().slice(0, 10) // YYYY-MM-DD (UTC)
  const scheduledToday =
    (w.days?.includes(dow) ?? false) || (w.dates?.includes(iso) ?? false)
  if (!scheduledToday) return null

  const midnight = Math.floor(Date.UTC(
    d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), 0, 0, 0) / 1000)
  const start = midnight + w.startMin * 60
  const end   = midnight + w.endMin   * 60
  if (at < start || at >= end) return null
  return { start, end }
}

// Read an admin's window from the admins row.
export async function getAdminWindow(adminId: string): Promise<DutyWindow | null> {
  const rows = parseRows(await db.run(sql`
    SELECT duty_start_min, duty_end_min, duty_days, duty_dates
    FROM admins WHERE id = ${adminId} LIMIT 1`))
  const r = rows[0]
  if (!r) return null
  const startMin = val(r, 'duty_start_min', 0)
  const endMin   = val(r, 'duty_end_min', 1)
  if (startMin == null || endMin == null) return null
  const daysRaw  = val(r, 'duty_days', 2) ?? ''
  const datesRaw = val(r, 'duty_dates', 3) ?? ''
  return {
    startMin: Number(startMin),
    endMin:   Number(endMin),
    days:     String(daysRaw).split(',').filter(Boolean).map(Number),
    dates:    String(datesRaw).split(',').filter(Boolean),
  }
}

// The heart of the gate: is this admin ON DUTY right now?
// Requires BOTH: inside their scheduled window AND they clicked "resume duty".
export async function isOnDuty(adminId: string): Promise<{
  onDuty: boolean; reason?: string; windowEnd?: number
}> {
  const now = Math.floor(Date.now() / 1000)

  const w = await getAdminWindow(adminId)
  if (!w) return { onDuty: false, reason: 'No working hours set for this account' }

  const win = windowAt(w, now)
  if (!win) return { onDuty: false, reason: 'Outside your scheduled working hours' }

  // Must have an active session they resumed.
  const rows = parseRows(await db.run(sql`
    SELECT id, status, resumed_at FROM admin_duty_sessions
    WHERE admin_id = ${adminId} AND window_start = ${win.start}
      AND status = 'on_duty' LIMIT 1`))
  if (!rows.length) {
    return { onDuty: false, reason: 'You have not resumed duty for this session' }
  }
  return { onDuty: true, windowEnd: win.end }
}

// Sub-admin clicks "resume duty". Only valid inside their window.
export async function resumeDuty(adminId: string, adminName: string): Promise<{
  ok: boolean; error?: string; windowEnd?: number
}> {
  const now = Math.floor(Date.now() / 1000)
  const w = await getAdminWindow(adminId)
  if (!w) return { ok: false, error: 'No working hours set for this account' }

  const win = windowAt(w, now)
  if (!win) return { ok: false, error: 'You can only resume duty during your scheduled hours' }

  // Already on duty for this window? Idempotent.
  const existing = parseRows(await db.run(sql`
    SELECT id, status FROM admin_duty_sessions
    WHERE admin_id = ${adminId} AND window_start = ${win.start} LIMIT 1`))

  if (existing.length) {
    const id = val(existing[0], 'id', 0)
    const st = val(existing[0], 'status', 1)
    if (st === 'on_duty') return { ok: true, windowEnd: win.end }
    if (st === 'ended')   return { ok: false, error: 'This session has already ended' }
    await db.run(sql`
      UPDATE admin_duty_sessions
      SET status = 'on_duty', resumed_at = ${now}, updated_at = ${now}
      WHERE id = ${id}`)
    return { ok: true, windowEnd: win.end }
  }

  await db.run(sql`
    INSERT INTO admin_duty_sessions
      (id, admin_id, admin_name, window_start, window_end,
       resumed_at, status, created_at, updated_at)
    VALUES
      (${randomUUID()}, ${adminId}, ${adminName}, ${win.start}, ${win.end},
       ${now}, 'on_duty', ${now}, ${now})`)
  return { ok: true, windowEnd: win.end }
}

// Current session state for a sub-admin's dashboard.
export async function dutyStatus(adminId: string): Promise<{
  hasWindow: boolean
  inWindow:  boolean
  onDuty:    boolean
  windowStart?: number
  windowEnd?:   number
  nextStart?:   number
}> {
  const now = Math.floor(Date.now() / 1000)
  const w = await getAdminWindow(adminId)
  if (!w) return { hasWindow: false, inWindow: false, onDuty: false }

  const win = windowAt(w, now)
  if (!win) {
    return { hasWindow: true, inWindow: false, onDuty: false,
             nextStart: nextWindowStart(w, now) ?? undefined }
  }
  const rows = parseRows(await db.run(sql`
    SELECT status FROM admin_duty_sessions
    WHERE admin_id = ${adminId} AND window_start = ${win.start} LIMIT 1`))
  const onDuty = rows.length ? val(rows[0], 'status', 0) === 'on_duty' : false
  return { hasWindow: true, inWindow: true, onDuty,
           windowStart: win.start, windowEnd: win.end }
}

// Next time this window opens (searching forward up to 14 days).
export function nextWindowStart(w: DutyWindow, from: number): number | null {
  for (let i = 0; i < 14; i++) {
    const probe = from + i * 86400
    const d   = new Date(probe * 1000)
    const dow = d.getUTCDay()
    const iso = d.toISOString().slice(0, 10)
    if (!(w.days?.includes(dow) || w.dates?.includes(iso))) continue
    const midnight = Math.floor(Date.UTC(
      d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), 0, 0, 0) / 1000)
    const start = midnight + w.startMin * 60
    if (start > from) return start
  }
  return null
}

export { parseRows as _parseRows }

// Human-readable schedule, for emails and the audit log.
// e.g. "Mon-Fri · 09:00-15:00 UTC (6h)"
const DAY_LABEL = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
export function formatWindowText(
  startMin: number, endMin: number, days: number[], dates: string[] = [],
): string {
  const hhmm = (m: number) =>
    `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`
  const span = ((endMin - startMin) / 60).toFixed(1).replace(/\.0$/, '')
  const order = [1, 2, 3, 4, 5, 6, 0]
  const sorted = order.filter(d => days?.includes(d))
  const dayPart = sorted.length
    ? sorted.map(d => DAY_LABEL[d]).join(', ')
    : (dates?.length ? `${dates.length} specific date${dates.length === 1 ? '' : 's'}` : '—')
  return `${dayPart} · ${hhmm(startMin)}-${hhmm(endMin)} UTC (${span}h)`
}
