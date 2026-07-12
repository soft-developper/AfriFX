#!/bin/bash
# ============================================================
# AfriFX -- Dispute duty sessions, STAGE A (backend)
#
# Sub-admins can only accept disputes while ON DUTY. Rules implemented:
#   * The general admin sets a sub-admin's WORKING HOURS when inviting them.
#     Max 6 hours. Recurring weekdays + optional specific dates. (UTC)
#   * ~3 minutes before the session opens, the sub-admin gets an EMAIL.
#   * They must click "Resume duty" -- being inside the window is NOT enough.
#   * Only an ON-DUTY sub-admin can ACCEPT a dispute (super admin bypasses).
#   * If the window ends while they hold a dispute they can still FINISH it;
#     the gate only blocks accepting NEW ones.
#   * When the window elapses the session is closed and a SESSION LOG is
#     finalised (disputes accepted/resolved, actions taken) for the general
#     admin to review. Never-resumed sessions are marked 'missed'.
#
# Files:
#   duty-sessions-schema.sql  -- working-hours columns + admin_duty_sessions (RUN vs DB)
#   src/lib/duty.ts           -- window logic, validation, isOnDuty/resumeDuty
#   src/jobs/dutyScheduler.ts -- cron: 3-min reminder emails + close/log sessions
#   adminManage.ts            -- invite accepts working hours; /duty/status,
#                                /duty/resume, /duty/sessions endpoints
#   disputes.ts               -- accept endpoint GATED behind on-duty
#   index.ts                  -- registers the duty scheduler
#
# Stage B (the admin/sub-admin UI) comes next.
#
# Run from ~/AfriFX:  bash duty-sessions-stageA.sh
# ============================================================
set -e
echo ""
echo "Installing dispute duty sessions (backend)..."
echo ""

mkdir -p "afrifx-api"
cat > "afrifx-api/duty-sessions-schema.sql" << 'AFX_EOF'
-- ============================================================
-- Dispute duty sessions — sub-admin working hours + duty tracking
--
-- 1) Working hours live ON the admin record (set by the general admin when
--    inviting them). Max 6 hours, recurring daily, with optional specific dates.
-- 2) admin_duty_sessions records each actual shift: when they clicked
--    "resume duty", when it ended, and what they did — this is the session log
--    the general admin reviews.
--
-- SQLite/libSQL has no "ADD COLUMN IF NOT EXISTS": if a column already exists
-- that line errors harmlessly, the rest still apply. Run individually if needed.
-- Run:  turso db shell <your-db-name> < afrifx-api/duty-sessions-schema.sql
-- ============================================================

-- Working hours on the admin record.
-- duty_start_min / duty_end_min: minutes from midnight UTC (e.g. 540 = 09:00 UTC).
-- Max span enforced in app code (6h = 360 min).
ALTER TABLE admins ADD COLUMN duty_start_min   INTEGER;         -- 0..1439, UTC
ALTER TABLE admins ADD COLUMN duty_end_min     INTEGER;         -- 0..1439, UTC
ALTER TABLE admins ADD COLUMN duty_days        TEXT;            -- CSV of 0..6 (Sun..Sat), e.g. '1,2,3,4,5'
ALTER TABLE admins ADD COLUMN duty_dates       TEXT;            -- optional CSV of 'YYYY-MM-DD' specific dates
ALTER TABLE admins ADD COLUMN duty_notified_at INTEGER;         -- last time we sent the 3-min heads-up

CREATE TABLE IF NOT EXISTS admin_duty_sessions (
  id                TEXT PRIMARY KEY,
  admin_id          TEXT NOT NULL,
  admin_name        TEXT NOT NULL,

  -- The scheduled window this session belongs to (unix seconds)
  window_start      INTEGER NOT NULL,
  window_end        INTEGER NOT NULL,

  -- Actual duty
  resumed_at        INTEGER,                -- when they clicked "resume duty"
  ended_at          INTEGER,                -- when the window elapsed / they clocked off
  status            TEXT NOT NULL DEFAULT 'scheduled',
                    -- scheduled | on_duty | ended | missed

  -- Session log (what they did) — filled when the session ends
  disputes_accepted INTEGER DEFAULT 0,
  disputes_resolved INTEGER DEFAULT 0,
  actions_count     INTEGER DEFAULT 0,
  log_sent          INTEGER DEFAULT 0,      -- 1 once summarised to the admin dashboard

  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_duty_admin   ON admin_duty_sessions (admin_id);
CREATE INDEX IF NOT EXISTS idx_duty_status  ON admin_duty_sessions (status);
CREATE INDEX IF NOT EXISTS idx_duty_window  ON admin_duty_sessions (window_start, window_end);
AFX_EOF
echo "  afrifx-api/duty-sessions-schema.sql"

mkdir -p "afrifx-api/src/lib"
cat > "afrifx-api/src/lib/duty.ts" << 'AFX_EOF'
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
AFX_EOF
echo "  afrifx-api/src/lib/duty.ts"

mkdir -p "afrifx-api/src/jobs"
cat > "afrifx-api/src/jobs/dutyScheduler.ts" << 'AFX_EOF'
// ============================================================
// Duty scheduler — runs every minute and does two jobs:
//
//  1) REMINDER: ~3 minutes before a sub-admin's session opens, email them that
//     it's their turn to work. Sent once per window (duty_notified_at guards).
//
//  2) CLOSE: when a session's window elapses, mark it ended and finalise the
//     session log (disputes accepted/resolved during the shift), which the
//     general admin reviews. Sessions never resumed are marked 'missed'.
//
// Note: a sub-admin whose window ends mid-dispute keeps that dispute (they can
// finish it) — the gate only blocks ACCEPTING new ones, which isOnDuty() does.
// ============================================================

import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'
import { sendEmail } from '../services/email/client'
import { getAdminWindow, windowAt, nextWindowStart, _parseRows as parseRows } from '../lib/duty'

const val = (row: any, key: string, i: number) => Array.isArray(row) ? row[i] : row[key]

export function startDutyScheduler() {
  console.log('[DutyScheduler] ✅ Started — duty reminders + session close, every minute')
  cron.schedule('* * * * *', tick)
  setTimeout(tick, 10_000)
}

async function tick() {
  const now = Math.floor(Date.now() / 1000)
  try {
    await sendUpcomingReminders(now)
    await closeElapsedSessions(now)
  } catch (err: any) {
    console.error('[DutyScheduler] error:', err?.message)
  }
}

// ── 1. Email sub-admins ~3 minutes before their session opens ────────────────
async function sendUpcomingReminders(now: number) {
  const admins = parseRows(await db.run(sql`
    SELECT id, username, email, duty_start_min, duty_end_min,
           duty_days, duty_dates, duty_notified_at
    FROM admins
    WHERE role = 'sub_admin' AND status = 'active'
      AND duty_start_min IS NOT NULL`))

  for (const a of admins) {
    const id       = val(a, 'id', 0)
    const username = val(a, 'username', 1)
    const email    = val(a, 'email', 2)
    const notified = Number(val(a, 'duty_notified_at', 7) ?? 0)

    const w = await getAdminWindow(id)
    if (!w) continue

    const nextStart = nextWindowStart(w, now)
    if (!nextStart) continue

    const secondsUntil = nextStart - now
    // Fire in the 3-minutes-out window (cron runs each minute, so a 60s band).
    if (secondsUntil > 180 || secondsUntil <= 120) continue
    // Already told them about THIS window?
    if (notified >= nextStart - 600) continue

    const startsAt = new Date(nextStart * 1000).toUTCString()
    const endsAt   = new Date((nextStart + (w.endMin - w.startMin) * 60) * 1000).toUTCString()

    try {
      await sendEmail({
        to: email,
        subject: '🕒 Your AfriFX duty session starts in 3 minutes',
        html: `
          <p>Hi ${username},</p>
          <p>Your dispute-handling session is about to begin.</p>
          <p><strong>Starts:</strong> ${startsAt}<br/>
             <strong>Ends:</strong> ${endsAt}</p>
          <p>Open your admin dashboard and click <strong>Resume duty</strong> to go
             on duty. You can only accept new disputes while on duty.</p>
          <p>— AfriFX</p>`,
      })
      await db.run(sql`
        UPDATE admins SET duty_notified_at = ${now} WHERE id = ${id}`)

      // Pre-create the scheduled session row so the log exists even if they
      // never resume (it'll be marked 'missed' when the window elapses).
      const winEnd = nextStart + (w.endMin - w.startMin) * 60
      const exists = parseRows(await db.run(sql`
        SELECT id FROM admin_duty_sessions
        WHERE admin_id = ${id} AND window_start = ${nextStart} LIMIT 1`))
      if (!exists.length) {
        await db.run(sql`
          INSERT INTO admin_duty_sessions
            (id, admin_id, admin_name, window_start, window_end,
             status, created_at, updated_at)
          VALUES
            (${randomUUID()}, ${id}, ${username}, ${nextStart}, ${winEnd},
             'scheduled', ${now}, ${now})`)
      }
    } catch (err: any) {
      console.error(`[DutyScheduler] reminder failed for ${username}:`, err?.message)
    }
  }
}

// ── 2. Close sessions whose window has elapsed, finalising the log ───────────
async function closeElapsedSessions(now: number) {
  const open = parseRows(await db.run(sql`
    SELECT id, admin_id, admin_name, window_start, window_end, status, resumed_at
    FROM admin_duty_sessions
    WHERE status IN ('scheduled', 'on_duty') AND window_end <= ${now}
    LIMIT 100`))

  for (const s of open) {
    const id       = val(s, 'id', 0)
    const adminId  = val(s, 'admin_id', 1)
    const resumed  = val(s, 'resumed_at', 6)
    const status   = val(s, 'status', 5)

    // Never resumed → the shift was missed.
    const finalStatus = (status === 'on_duty' || resumed) ? 'ended' : 'missed'

    // Count the admin's audited actions during the window, for the log.
    const wStart = val(s, 'window_start', 3)
    const wEnd   = val(s, 'window_end', 4)
    let actions = 0
    try {
      const rows = parseRows(await db.run(sql`
        SELECT COUNT(*) AS c FROM admin_audit_log
        WHERE admin_id = ${adminId}
          AND created_at >= ${wStart} AND created_at <= ${wEnd}`))
      const r = rows[0]
      actions = Number(r ? (Array.isArray(r) ? r[0] : r.c) : 0)
    } catch { /* count is best-effort */ }

    await db.run(sql`
      UPDATE admin_duty_sessions
      SET status = ${finalStatus}, ended_at = ${wEnd},
          actions_count = ${actions}, log_sent = 1, updated_at = ${now}
      WHERE id = ${id}`)
  }
}
AFX_EOF
echo "  afrifx-api/src/jobs/dutyScheduler.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/adminManage.ts" << 'AFX_EOF'
import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'
import {
  requireAdmin, requirePermission,
  hashPassword, normalizeAdmin, logAction,
} from '../lib/adminAuth'
import { PERMISSIONS, ALL_PERMISSIONS, PERMISSION_META } from '../lib/permissions'
import { releasePlatform, cancelPlatform } from '../services/platformWallet'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// All routes require admin auth
router.use(requireAdmin)

// ══════════════════════════════════════════════════════════
// PERMISSIONS META — for building UI
// ══════════════════════════════════════════════════════════
router.get('/permissions', (_req, res) => {
  res.json({
    all:  ALL_PERMISSIONS,
    meta: PERMISSION_META,
  })
})

// ══════════════════════════════════════════════════════════
// DASHBOARD OVERVIEW
// ══════════════════════════════════════════════════════════
router.get('/overview', requirePermission(PERMISSIONS.VIEW_DASHBOARD), async (_req, res) => {
  try {
    const now   = Math.floor(Date.now() / 1000)
    const day   = 86400
    const week  = day * 7

    // Live rates for USD conversion
    const { getCachedRates } = await import('../services/rateOracle')
    const rateList = getCachedRates()
    const rates: Record<string, number> = {}
    for (const r of rateList) rates[r.pair] = r.rate

    // Convert any amount to USD using live rates
    function toUSD(amount: number, currency: string): number {
      if (!amount || amount <= 0) return 0
      if (currency === 'USDC' || currency === 'USD') return amount
      if (currency === 'EURC') return amount * (rates['EURC/USDC'] ? 1 / rates['EURC/USDC'] : 1.09)
      const rate = rates[`${currency}/USDC`]
      return rate && rate > 0 ? amount / rate : 0
    }

    // USD value of a transaction — always use the USDC side if present
    function txUSD(fromCcy: string, toCcy: string, fromAmt: number, toAmt: number): number {
      if (toCcy   === 'USDC') return toAmt
      if (fromCcy === 'USDC') return fromAmt
      return toUSD(fromAmt, fromCcy)
    }

    // All transactions with USD volume
    const txRows = await db.run(
      sql`SELECT from_currency, to_currency, from_amount, to_amount, spread_fee, created_at
          FROM transactions`
    )
    const txs = parseRows(txRows).map((r: any) => {
      const fromCcy = r.from_currency ?? r[0]
      const toCcy   = r.to_currency   ?? r[1]
      const fromAmt = Number(r.from_amount ?? r[2] ?? 0)
      const toAmt   = Number(r.to_amount   ?? r[3] ?? 0)
      const fee     = Number(r.spread_fee  ?? r[4] ?? 0)
      const ts      = Number(r.created_at  ?? r[5] ?? 0)
      return {
        usdVol:    txUSD(fromCcy, toCcy, fromAmt, toAmt),
        usdFee:    toUSD(fee, fromCcy),
        createdAt: ts,
      }
    })

    // P2P released volume (USDC = USD)
    const p2pVolRows = await db.run(
      sql`SELECT SUM(usdc_amount) as vol FROM p2p_offers WHERE status = 'released'`
    )
    const pvr = parseRows(p2pVolRows)
    const p2pVol = Number(pvr[0]?.vol ?? pvr[0]?.[0] ?? 0)

    const totalVolume = txs.reduce((s, t) => s + t.usdVol, 0) + p2pVol
    const totalTxs    = txs.length
    const totalFees   = txs.reduce((s, t) => s + t.usdFee, 0)

    // P2P stats
    const p2pRows = await db.run(sql`SELECT status, COUNT(*) as cnt FROM p2p_offers GROUP BY status`)
    const p2pStats: Record<string, number> = {}
    for (const r of parseRows(p2pRows)) {
      p2pStats[r.status ?? r[0]] = Number(r.cnt ?? r[1] ?? 0)
    }

    // Open disputes
    const dispRows = await db.run(sql`SELECT COUNT(*) as cnt FROM disputes WHERE status = 'open'`)
    const dr = parseRows(dispRows)
    const openDisputes = Number(dr[0]?.cnt ?? dr[0]?.[0] ?? 0)

    // Total users
    const userRows = await db.run(sql`SELECT COUNT(*) as cnt FROM profiles`)
    const usr = parseRows(userRows)
    const totalUsers = Number(usr[0]?.cnt ?? usr[0]?.[0] ?? 0)

    // New users this week
    const newUserRows = await db.run(
      sql`SELECT COUNT(*) as cnt FROM profiles WHERE created_at > ${now - week}`
    )
    const nur = parseRows(newUserRows)
    const newUsersWeek = Number(nur[0]?.cnt ?? nur[0]?.[0] ?? 0)

    // Volume chart (last 14 days) — correct day alignment, USD values
    const recentTxRows = await db.run(
      sql`SELECT from_currency, to_currency, from_amount, to_amount, created_at
          FROM transactions WHERE created_at > ${now - day * 14}`
    )
    const recentTxs = parseRows(recentTxRows).map((r: any) => ({
      usdVol:    txUSD(r.from_currency??r[0], r.to_currency??r[1], Number(r.from_amount??r[2]), Number(r.to_amount??r[3])),
      createdAt: Number(r.created_at ?? r[4]),
    }))

    const recentP2PRows = await db.run(
      sql`SELECT usdc_amount, created_at FROM p2p_offers
          WHERE status = 'released' AND created_at > ${now - day * 14}`
    )
    const recentP2P = parseRows(recentP2PRows).map((r: any) => ({
      usdVol:    Number(r.usdc_amount ?? r[0]),
      createdAt: Number(r.created_at  ?? r[1]),
    }))

    const chartData = Array.from({ length: 14 }, (_, i) => {
      const daysAgo  = 13 - i
      const dayEnd   = now - daysAgo * day
      const dayStart = dayEnd - day
      const label    = daysAgo === 0
        ? 'Today'
        : new Date(dayStart * 1000).toLocaleDateString([], { month: 'short', day: 'numeric' })

      const txVol  = recentTxs.filter(t => t.createdAt >= dayStart && t.createdAt < dayEnd).reduce((s,t)=>s+t.usdVol,0)
      const p2pV   = recentP2P.filter(t => t.createdAt >= dayStart && t.createdAt < dayEnd).reduce((s,t)=>s+t.usdVol,0)
      return { label, volume: parseFloat((txVol + p2pV).toFixed(2)) }
    })

    res.json({
      totalVolume:  parseFloat(totalVolume.toFixed(2)),
      totalTxs,
      totalFees:    parseFloat(totalFees.toFixed(2)),
      p2p: {
        open:      p2pStats.open      ?? 0,
        accepted:  p2pStats.accepted  ?? 0,
        released:  p2pStats.released  ?? 0,
        cancelled: p2pStats.cancelled ?? 0,
      },
      openDisputes,
      totalUsers,
      newUsersWeek,
      chartData,
    })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// ══════════════════════════════════════════════════════════
// SUB-ADMIN MANAGEMENT
// ══════════════════════════════════════════════════════════

// GET /admin/manage/admins — list all admins
router.get('/admins', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (_req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT id, username, email, wallet_address, role, permissions,
                 status, suspended_until, created_by, last_login, created_at
          FROM admins ORDER BY created_at DESC`
    )
    const admins = parseRows(rows).map(r => {
      const a = normalizeAdmin(Array.isArray(r) ? [
        r[0], r[1], r[2], '', r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], 0
      ] : { ...r, password_hash: '' })
      delete (a as any).password_hash
      return a
    })
    res.json(admins)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/admins — create sub-admin
router.post('/admins', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const admin = (req as any).admin
  const {
    username, email, password, walletAddress, permissions,
    dutyStartMin, dutyEndMin, dutyDays, dutyDates,
  } = req.body

  if (!username || !email || !password) {
    return res.status(400).json({ error: 'username, email, password and wallet address required' })
  }
  if (password.length < 8) {
    return res.status(400).json({ error: 'Password must be at least 8 characters' })
  }

  // Working hours (the sub-admin's dispute duty session). Optional at invite —
  // if any duty field is supplied, the whole window must be valid (max 6h).
  const wantsDuty = dutyStartMin != null || dutyEndMin != null ||
                    (dutyDays?.length) || (dutyDates?.length)
  if (wantsDuty) {
    const { validateWindow } = await import('../lib/duty')
    const err = validateWindow({
      startMin: dutyStartMin, endMin: dutyEndMin,
      days: dutyDays ?? [], dates: dutyDates ?? [],
    })
    if (err) return res.status(400).json({ error: err })
  }

  try {
    // Check uniqueness
    const existing = await db.run(
      sql`SELECT id FROM admins
          WHERE LOWER(username) = ${username.toLowerCase()}
             OR LOWER(email) = ${email.toLowerCase()} LIMIT 1`
    )
    if (parseRows(existing).length) {
      return res.status(409).json({ error: 'Username or email already exists' })
    }

    // Validate permissions are real
    const validPerms = (permissions ?? []).filter((p: string) => ALL_PERMISSIONS.includes(p as any))

    const id   = randomUUID()
    const now  = Math.floor(Date.now() / 1000)
    const hash = await hashPassword(password)

    await db.run(
      sql`INSERT INTO admins
          (id, username, email, password_hash, wallet_address,
           role, permissions, status, created_by, created_at, updated_at,
           duty_start_min, duty_end_min, duty_days, duty_dates)
          VALUES
          (${id}, ${username.toLowerCase()}, ${email.toLowerCase()},
           ${hash}, ${walletAddress?.toLowerCase() ?? null},
           'sub_admin', ${JSON.stringify(validPerms)},
           'active', ${admin.id}, ${now}, ${now},
           ${wantsDuty ? dutyStartMin : null}, ${wantsDuty ? dutyEndMin : null},
           ${wantsDuty ? (dutyDays ?? []).join(',') : null},
           ${wantsDuty ? (dutyDates ?? []).join(',') : null})`
    )

    await logAction(admin.id, admin.username, 'create_sub_admin', 'admin', id,
      `Created sub-admin '${username}' with ${validPerms.length} permissions` +
      (wantsDuty ? ` and a duty window` : ''), req.ip)

    res.status(201).json({ id, username, permissions: validPerms })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /admin/manage/admins/:id — update permissions / status
router.patch('/admins/:id', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const admin = (req as any).admin
  const { permissions, status, suspendedUntil, walletAddress } = req.body
  const now = Math.floor(Date.now() / 1000)

  try {
    // Prevent editing super admins
    const targetRows = await db.run(sql`SELECT role, username FROM admins WHERE id = ${req.params.id} LIMIT 1`)
    const tr = parseRows(targetRows)
    if (!tr.length) return res.status(404).json({ error: 'Admin not found' })
    const targetRole = tr[0].role ?? tr[0][0]
    const targetName = tr[0].username ?? tr[0][1]
    if (targetRole === 'super_admin') {
      return res.status(403).json({ error: 'Cannot modify a super admin' })
    }

    const validPerms = permissions
      ? (permissions as string[]).filter(p => ALL_PERMISSIONS.includes(p as any))
      : null

    await db.run(
      sql`UPDATE admins SET
            permissions     = COALESCE(${validPerms ? JSON.stringify(validPerms) : null}, permissions),
            status          = COALESCE(${status ?? null}, status),
            suspended_until = ${suspendedUntil ?? null},
            wallet_address  = COALESCE(${walletAddress?.toLowerCase() ?? null}, wallet_address),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )

    const actionDesc = status === 'suspended'
      ? `Suspended sub-admin '${targetName}'${suspendedUntil ? ` until ${new Date(suspendedUntil * 1000).toLocaleDateString()}` : ''}`
      : status === 'active'
      ? `Reactivated sub-admin '${targetName}'`
      : `Updated permissions for sub-admin '${targetName}'`

    await logAction(admin.id, admin.username, 'update_sub_admin', 'admin', req.params.id,
      actionDesc, req.ip)

    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// DELETE /admin/manage/admins/:id — remove sub-admin
router.delete('/admins/:id', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const admin = (req as any).admin
  try {
    const targetRows = await db.run(sql`SELECT role, username FROM admins WHERE id = ${req.params.id} LIMIT 1`)
    const tr = parseRows(targetRows)
    if (!tr.length) return res.status(404).json({ error: 'Admin not found' })
    if ((tr[0].role ?? tr[0][0]) === 'super_admin') {
      return res.status(403).json({ error: 'Cannot delete a super admin' })
    }
    const targetName = tr[0].username ?? tr[0][1]

    await db.run(sql`DELETE FROM admins WHERE id = ${req.params.id}`)
    await logAction(admin.id, admin.username, 'delete_sub_admin', 'admin', req.params.id,
      `Removed sub-admin '${targetName}'`, req.ip)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// USER LOGIN DATA MANAGEMENT (admins can reset passwords etc.)
// ══════════════════════════════════════════════════════════

// PATCH /admin/manage/admins/:id/credentials — change username/email/password
router.patch('/admins/:id/credentials', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const admin = (req as any).admin
  const { username, email, newPassword } = req.body
  const now = Math.floor(Date.now() / 1000)

  try {
    const updates: any = { updated_at: now }
    const changes: string[] = []

    if (username) {
      const dup = await db.run(
        sql`SELECT id FROM admins WHERE LOWER(username) = ${username.toLowerCase()} AND id != ${req.params.id} LIMIT 1`
      )
      if (parseRows(dup).length) return res.status(409).json({ error: 'Username taken' })
      await db.run(sql`UPDATE admins SET username = ${username.toLowerCase()}, updated_at = ${now} WHERE id = ${req.params.id}`)
      changes.push('username')
    }
    if (email) {
      const dup = await db.run(
        sql`SELECT id FROM admins WHERE LOWER(email) = ${email.toLowerCase()} AND id != ${req.params.id} LIMIT 1`
      )
      if (parseRows(dup).length) return res.status(409).json({ error: 'Email taken' })
      await db.run(sql`UPDATE admins SET email = ${email.toLowerCase()}, updated_at = ${now} WHERE id = ${req.params.id}`)
      changes.push('email')
    }
    if (newPassword) {
      if (newPassword.length < 8) return res.status(400).json({ error: 'Password must be at least 8 characters' })
      const hash = await hashPassword(newPassword)
      await db.run(sql`UPDATE admins SET password_hash = ${hash}, updated_at = ${now} WHERE id = ${req.params.id}`)
      changes.push('password')
    }

    await logAction(admin.id, admin.username, 'update_credentials', 'admin', req.params.id,
      `Changed ${changes.join(', ')}`, req.ip)

    res.json({ success: true, changed: changes })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// OFFERS MANAGEMENT
// ══════════════════════════════════════════════════════════

// GET /admin/manage/offers — all offers with filters
router.get('/offers', requirePermission(PERMISSIONS.MANAGE_OFFERS), async (req, res) => {
  const status = req.query.status as string
  try {
    const rows = status
      ? await db.run(sql`SELECT * FROM p2p_offers WHERE status = ${status} ORDER BY created_at DESC LIMIT 100`)
      : await db.run(sql`SELECT * FROM p2p_offers ORDER BY created_at DESC LIMIT 100`)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/offers/:id/release — force release to taker
router.post('/offers/:id/release', requirePermission(PERMISSIONS.MANAGE_OFFERS), async (req, res) => {
  const admin = (req as any).admin
  const offerId = req.params.id as `0x${string}`
  try {
    const hash = await releasePlatform(offerId)
    const now  = Math.floor(Date.now() / 1000)
    await db.run(
      sql`UPDATE p2p_offers SET status = 'released', release_tx_hash = ${hash}, updated_at = ${now} WHERE id = ${offerId}`
    )
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`).catch(() => {})
    await logAction(admin.id, admin.username, 'force_release_offer', 'offer', offerId,
      `Force released offer — tx ${hash.slice(0,14)}`, req.ip)
    res.json({ success: true, txHash: hash })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/offers/:id/cancel — force cancel, refund maker
router.post('/offers/:id/cancel', requirePermission(PERMISSIONS.MANAGE_OFFERS), async (req, res) => {
  const admin = (req as any).admin
  const offerId = req.params.id as `0x${string}`
  const { reason } = req.body
  try {
    const hash = await cancelPlatform(offerId, reason ?? 'Admin cancelled')
    const now  = Math.floor(Date.now() / 1000)
    await db.run(
      sql`UPDATE p2p_offers SET status = 'cancelled', updated_at = ${now} WHERE id = ${offerId}`
    )
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`).catch(() => {})
    await logAction(admin.id, admin.username, 'force_cancel_offer', 'offer', offerId,
      `Force cancelled offer: ${reason ?? 'no reason'} — tx ${hash.slice(0,14)}`, req.ip)
    res.json({ success: true, txHash: hash })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// DISPUTE RESOLUTION
// ══════════════════════════════════════════════════════════

// GET /admin/manage/disputes
router.get('/disputes', requirePermission(PERMISSIONS.RESOLVE_DISPUTES), async (req, res) => {
  const status = (req.query.status as string) ?? 'open'
  try {
    const rows = await db.run(
      sql`SELECT d.*, o.usdc_amount, o.local_currency, o.local_amount,
                 o.maker_address, o.taker_address, o.status as offer_status
          FROM disputes d
          LEFT JOIN p2p_offers o ON o.id = d.offer_id
          WHERE d.status = ${status}
          ORDER BY d.created_at DESC LIMIT 100`
    )
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/disputes/:id/resolve — release to taker OR refund maker
router.post('/disputes/:id/resolve', requirePermission(PERMISSIONS.RESOLVE_DISPUTES), async (req, res) => {
  const admin = (req as any).admin
  const { resolution, offerId, reason } = req.body // resolution: 'release' | 'refund'

  if (!['release','refund'].includes(resolution)) {
    return res.status(400).json({ error: 'resolution must be release or refund' })
  }

  try {
    const now = Math.floor(Date.now() / 1000)
    let hash: string

    if (resolution === 'release') {
      hash = await releasePlatform(offerId as `0x${string}`)
      await db.run(sql`UPDATE p2p_offers SET status = 'released', release_tx_hash = ${hash}, updated_at = ${now} WHERE id = ${offerId}`)
    } else {
      hash = await cancelPlatform(offerId as `0x${string}`, reason ?? 'Dispute resolved — refund')
      await db.run(sql`UPDATE p2p_offers SET status = 'cancelled', updated_at = ${now} WHERE id = ${offerId}`)
    }

    await db.run(
      sql`UPDATE disputes SET status = ${`resolved_${resolution}`}, settled_at = ${now}, resolved_by = ${admin.username} WHERE id = ${req.params.id}`
    ).catch(() => {})
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`).catch(() => {})

    await logAction(admin.id, admin.username, 'resolve_dispute', 'dispute', req.params.id,
      `Resolved dispute via ${resolution} — tx ${hash.slice(0,14)}. Reason: ${reason ?? 'none'}`, req.ip)

    res.json({ success: true, txHash: hash, resolution })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// USER MANAGEMENT
// ══════════════════════════════════════════════════════════

// GET /admin/manage/users — search/list users
router.get('/users', requirePermission(PERMISSIONS.MANAGE_USERS), async (req, res) => {
  const search = (req.query.search as string)?.toLowerCase()
  try {
    const rows = search
      ? await db.run(sql`SELECT * FROM profiles
          WHERE LOWER(username) LIKE ${'%'+search+'%'}
             OR LOWER(wallet_address) LIKE ${'%'+search+'%'}
             OR LOWER(display_name) LIKE ${'%'+search+'%'}
          ORDER BY created_at DESC LIMIT 50`)
      : await db.run(sql`SELECT * FROM profiles ORDER BY created_at DESC LIMIT 50`)

    // Enrich with trade counts
    const users = []
    for (const r of parseRows(rows)) {
      const u = Array.isArray(r) ? {
        wallet_address: r[0], username: r[1], display_name: r[2],
        verified: r[9], created_at: r[11],
      } : r
      const tradeRows = await db.run(
        sql`SELECT COUNT(*) as cnt FROM p2p_offers
            WHERE (LOWER(maker_address) = ${u.wallet_address.toLowerCase()}
               OR LOWER(taker_address) = ${u.wallet_address.toLowerCase()})
              AND status = 'released'`
      )
      const tc = parseRows(tradeRows)
      users.push({ ...u, trades: Number(tc[0]?.cnt ?? tc[0]?.[0] ?? 0) })
    }
    res.json(users)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/users/:address/suspend
router.post('/users/:address/suspend', requirePermission(PERMISSIONS.SUSPEND_USERS), async (req, res) => {
  const admin = (req as any).admin
  const { reason, until } = req.body
  const addr = req.params.address.toLowerCase()
  try {
    // Add suspended flag to profiles (create column on the fly if missing handled by migration)
    await db.run(
      sql`UPDATE profiles SET suspended = 1, suspended_until = ${until ?? null}, suspend_reason = ${reason ?? null} WHERE LOWER(wallet_address) = ${addr}`
    ).catch(async () => {
      // Column might not exist yet — add it
      await db.run(sql`ALTER TABLE profiles ADD COLUMN suspended INTEGER DEFAULT 0`).catch(() => {})
      await db.run(sql`ALTER TABLE profiles ADD COLUMN suspended_until INTEGER`).catch(() => {})
      await db.run(sql`ALTER TABLE profiles ADD COLUMN suspend_reason TEXT`).catch(() => {})
      await db.run(sql`UPDATE profiles SET suspended = 1, suspended_until = ${until ?? null}, suspend_reason = ${reason ?? null} WHERE LOWER(wallet_address) = ${addr}`)
    })
    await logAction(admin.id, admin.username, 'suspend_user', 'user', addr,
      `Suspended user: ${reason ?? 'no reason'}`, req.ip)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/users/:address/unsuspend
router.post('/users/:address/unsuspend', requirePermission(PERMISSIONS.SUSPEND_USERS), async (req, res) => {
  const admin = (req as any).admin
  const addr = req.params.address.toLowerCase()
  try {
    await db.run(
      sql`UPDATE profiles SET suspended = 0, suspended_until = NULL, suspend_reason = NULL WHERE LOWER(wallet_address) = ${addr}`
    ).catch(() => {})
    await logAction(admin.id, admin.username, 'unsuspend_user', 'user', addr,
      'Unsuspended user', req.ip)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// DISPUTE DUTY SESSIONS
// ══════════════════════════════════════════════════════════

// GET /duty/status — the calling admin's current duty state (for their dashboard)
router.get('/duty/status', async (req: any, res) => {
  try {
    const { dutyStatus } = await import('../lib/duty')
    const admin = req.admin
    if (!admin) return res.status(401).json({ error: 'Not authenticated' })
    const st = await dutyStatus(admin.id)
    res.json({ ...st, role: admin.role })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /duty/resume — sub-admin clicks "resume duty" to go on duty
router.post('/duty/resume', async (req: any, res) => {
  try {
    const { resumeDuty } = await import('../lib/duty')
    const admin = req.admin
    if (!admin) return res.status(401).json({ error: 'Not authenticated' })
    const r = await resumeDuty(admin.id, admin.username)
    if (!r.ok) return res.status(400).json({ error: r.error })
    await logAction(admin.id, admin.username, 'resume_duty', 'duty', admin.id,
      'Resumed duty for scheduled session')
    res.json({ success: true, windowEnd: r.windowEnd })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /duty/sessions — session logs for the general admin to review.
// Most recent first; optionally filter by ?admin=<id>.
router.get('/duty/sessions', requirePermission(PERMISSIONS.VIEW_AUDIT_LOG), async (req, res) => {
  const adminFilter = req.query.admin as string | undefined
  try {
    const rows = adminFilter
      ? await db.run(sql`SELECT * FROM admin_duty_sessions WHERE admin_id = ${adminFilter}
                         ORDER BY window_start DESC LIMIT 100`)
      : await db.run(sql`SELECT * FROM admin_duty_sessions
                         ORDER BY window_start DESC LIMIT 100`)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// AUDIT LOG VIEWER
// ══════════════════════════════════════════════════════════
router.get('/audit', requirePermission(PERMISSIONS.VIEW_AUDIT_LOG), async (req, res) => {
  const adminFilter = req.query.admin as string
  try {
    const rows = adminFilter
      ? await db.run(sql`SELECT * FROM admin_audit_log WHERE admin_id = ${adminFilter} ORDER BY created_at DESC LIMIT 200`)
      : await db.run(sql`SELECT * FROM admin_audit_log ORDER BY created_at DESC LIMIT 200`)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /audit/grouped — audit trail grouped by admin account.
// Super admin(s) first, then sub-admins. Each group carries that admin's
// own actions, so the log reads per-person instead of one interleaved list.
router.get('/audit/grouped', requirePermission(PERMISSIONS.VIEW_AUDIT_LOG), async (_req, res) => {
  try {
    // All known admins (so an admin with zero actions still shows, empty).
    const adminRows = await db.run(
      sql`SELECT id, name, email, role FROM admins ORDER BY created_at ASC`)
    const admins = parseRows(adminRows).map((r: any) => Array.isArray(r)
      ? { id: r[0], name: r[1], email: r[2], role: r[3] }
      : { id: r.id, name: r.name, email: r.email, role: r.role })

    // Recent audit entries (cap generous; grouping happens below).
    const logRows = await db.run(
      sql`SELECT * FROM admin_audit_log ORDER BY created_at DESC LIMIT 1000`)
    const logs = parseRows(logRows).map((r: any) => Array.isArray(r)
      ? { id: r[0], admin_id: r[1], admin_name: r[2], action: r[3],
          target_type: r[4], target_id: r[5], details: r[6],
          ip_address: r[7], created_at: r[8] }
      : r)

    // Bucket by admin_id.
    const byAdmin = new Map<string, any[]>()
    for (const l of logs) {
      const key = l.admin_id ?? 'unknown'
      if (!byAdmin.has(key)) byAdmin.set(key, [])
      byAdmin.get(key)!.push(l)
    }

    const groups = admins.map((a: any) => ({
      admin:   a,
      logs:    byAdmin.get(a.id) ?? [],
      count:   (byAdmin.get(a.id) ?? []).length,
      lastAt:  (byAdmin.get(a.id) ?? [])[0]?.created_at ?? null,
    }))

    // Any logs whose admin no longer exists (deleted sub-admin) — keep them
    // visible rather than silently dropping history.
    const knownIds = new Set(admins.map((a: any) => a.id))
    const orphanLogs = logs.filter((l: any) => !knownIds.has(l.admin_id))
    if (orphanLogs.length) {
      const byName = new Map<string, any[]>()
      for (const l of orphanLogs) {
        const key = l.admin_name ?? 'Removed admin'
        if (!byName.has(key)) byName.set(key, [])
        byName.get(key)!.push(l)
      }
      for (const [name, ls] of byName) {
        groups.push({
          admin:  { id: ls[0].admin_id, name, email: '', role: 'removed' },
          logs:   ls, count: ls.length, lastAt: ls[0]?.created_at ?? null,
        })
      }
    }

    // Super admin(s) first, then the rest by most-recent activity.
    groups.sort((a: any, b: any) => {
      const aSuper = a.admin.role === 'super_admin' ? 0 : 1
      const bSuper = b.admin.role === 'super_admin' ? 0 : 1
      if (aSuper !== bSuper) return aSuper - bSuper
      return (b.lastAt ?? 0) - (a.lastAt ?? 0)
    })

    res.json({ groups, totalActions: logs.length })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// ANALYTICS
// ══════════════════════════════════════════════════════════
router.get('/analytics', requirePermission(PERMISSIONS.VIEW_ANALYTICS), async (_req, res) => {
  try {
    // Live rates for USD conversion
    const { getCachedRates } = await import('../services/rateOracle')
    const rateList = getCachedRates()
    const rates: Record<string, number> = {}
    for (const r of rateList) rates[r.pair] = r.rate

    function txUSD(fromCcy: string, toCcy: string, fromAmt: number, toAmt: number): number {
      if (toCcy   === 'USDC') return toAmt
      if (fromCcy === 'USDC') return fromAmt
      if (fromCcy === 'EURC') return fromAmt * (rates['EURC/USDC'] ? 1 / rates['EURC/USDC'] : 1.09)
      const rate = rates[`${fromCcy}/USDC`]
      return rate && rate > 0 ? fromAmt / rate : 0
    }

    // Volume by corridor — all rows then group in JS for USD conversion
    const corridorRows = await db.run(
      sql`SELECT from_currency, to_currency, from_amount, to_amount
          FROM transactions`
    )

    const corridorMap: Record<string, { volume: number; count: number }> = {}
    for (const r of parseRows(corridorRows)) {
      const fromCcy = r.from_currency ?? r[0]
      const toCcy   = r.to_currency   ?? r[1]
      const fromAmt = Number(r.from_amount ?? r[2] ?? 0)
      const toAmt   = Number(r.to_amount   ?? r[3] ?? 0)
      const pair    = `${fromCcy}/${toCcy}`
      const usd     = txUSD(fromCcy, toCcy, fromAmt, toAmt)
      if (!corridorMap[pair]) corridorMap[pair] = { volume: 0, count: 0 }
      corridorMap[pair].volume += usd
      corridorMap[pair].count++
    }

    const corridors = Object.entries(corridorMap)
      .map(([pair, d]) => ({
        pair,
        volume: parseFloat(d.volume.toFixed(2)),
        count:  d.count,
      }))
      .sort((a, b) => b.volume - a.volume)
      .slice(0, 10)

    // P2P vs direct split — both in USD
    const directRows = await db.run(
      sql`SELECT from_currency, to_currency, from_amount, to_amount FROM transactions`
    )
    let directVol = 0
    let directCnt = 0
    for (const r of parseRows(directRows)) {
      directVol += txUSD(r.from_currency??r[0], r.to_currency??r[1], Number(r.from_amount??r[2]), Number(r.to_amount??r[3]))
      directCnt++
    }

    const p2pRows = await db.run(
      sql`SELECT COUNT(*) as cnt, SUM(usdc_amount) as vol FROM p2p_offers WHERE status = 'released'`
    )
    const pr = parseRows(p2pRows)

    res.json({
      corridors,
      split: {
        direct: { count: directCnt, volume: parseFloat(directVol.toFixed(2)) },
        p2p:    {
          count:  Number(pr[0]?.cnt ?? pr[0]?.[0] ?? 0),
          volume: parseFloat(Number(pr[0]?.vol ?? pr[0]?.[1] ?? 0).toFixed(2)),
        },
      },
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
AFX_EOF
echo "  afrifx-api/src/routes/adminManage.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/disputes.ts" << 'AFX_EOF'
import { Router }     from 'express'
import { notifyDisputeRaised, notifyAdminsOfNewDispute, notifyDisputeAccepted, notifyAdminMessage } from '../services/email/notifications'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'
import multer         from 'multer'
import { uploadBuffer } from '../lib/cloudinary'

const router = Router()

// Multer — hold the file in memory, then stream it to Cloudinary
const upload = multer({
  storage: multer.memoryStorage(),
  limits:  { fileSize: 10 * 1024 * 1024 }, // 10 MB
  fileFilter: (_req, file, cb) => {
    const allowed = [
      'image/jpeg', 'image/png', 'image/webp', 'image/gif',
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    ]
    cb(null, allowed.includes(file.mimetype))
  },
})

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// GET /disputes?wallet=0x — disputes involving a wallet
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(sql`
      SELECT d.*, o.usdc_amount, o.local_currency, o.local_amount,
             o.maker_address, o.taker_address, o.status as offer_status
      FROM disputes d
      JOIN p2p_offers o ON o.id = d.offer_id
      WHERE LOWER(o.maker_address) = ${wallet}
         OR LOWER(o.taker_address) = ${wallet}
      ORDER BY d.created_at DESC LIMIT 50
    `)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/offer/:offerId — dispute for a specific offer
router.get('/offer/:offerId', async (req, res) => {
  try {
    const rows = await db.run(sql`
      SELECT * FROM disputes WHERE offer_id = ${req.params.offerId} LIMIT 1
    `)
    const r = parseRows(rows)
    res.json(r.length ? r[0] : null)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes — raise a dispute
// dispute_type: 'maker_not_received' | 'maker_silent'
// raised_by_role: 'maker' | 'taker'
router.post('/', async (req, res) => {
  const {
    offerId, raisedBy, reason,
    disputeType = 'maker_not_received',
    raisedByRole = 'taker',
  } = req.body

  if (!offerId || !raisedBy) {
    return res.status(400).json({ error: 'offerId and raisedBy required' })
  }

  const now = Math.floor(Date.now() / 1000)
  // Auto-release 24h from now if dispute is maker_silent
  const autoReleaseAt = null // No auto-release when dispute raised — admin must resolve

  try {
    // Check offer exists and is in accepted state
    const offerRows = await db.run(sql`
      SELECT id, status, taker_confirmed, maker_confirmed,
             maker_address, taker_address
      FROM p2p_offers WHERE id = ${offerId} LIMIT 1
    `)
    const offers = parseRows(offerRows)
    if (!offers.length) return res.status(404).json({ error: 'Offer not found' })

    const offer = offers[0]
    const offerStatus    = offer.status         ?? offer[1]
    const takerConfirmed = Number(offer.taker_confirmed ?? offer[3])
    const makerAddress   = (offer.maker_address ?? offer[5])?.toLowerCase()
    const takerAddress   = (offer.taker_address ?? offer[6])?.toLowerCase()
    const raisedByLower  = raisedBy.toLowerCase()

    // Validate: offer must be accepted
    if (offerStatus !== 'accepted') {
      return res.status(400).json({ error: 'Can only dispute accepted offers' })
    }

    // Validate: taker must have confirmed sending before any dispute
    if (!takerConfirmed) {
      return res.status(400).json({ error: 'Taker must confirm sending before raising a dispute' })
    }

    // Validate: wallet must be involved
    if (raisedByLower !== makerAddress && raisedByLower !== takerAddress) {
      return res.status(403).json({ error: 'Not involved in this offer' })
    }

    // Check no existing open dispute
    const existRows = await db.run(sql`
      SELECT id FROM disputes
      WHERE offer_id = ${offerId} AND status = 'open' LIMIT 1
    `)
    if (parseRows(existRows).length) {
      return res.status(400).json({ error: 'Dispute already open for this offer' })
    }

    const id = randomUUID()
    await db.run(sql`
      INSERT INTO disputes
        (id, offer_id, raised_by, reason, status,
         dispute_type, raised_by_role, auto_release_at,
         auto_settle_at, created_at)
      VALUES
        (${id}, ${offerId}, ${raisedByLower}, ${reason ?? ''},
         'open', ${disputeType}, ${raisedByRole},
         ${autoReleaseAt},
         ${now + 86400}, ${now})
    `)

    // Mark offer as disputed
    await db.run(sql`
      UPDATE p2p_offers SET dispute_raised = 1, updated_at = ${now}
      WHERE id = ${offerId}
    `)

    // Determine other party
    const otherPartyWallet = raisedByLower === makerAddress ? takerAddress : makerAddress

    // Fire notification (non-blocking)
    // Alert all admins with resolve_disputes permission
    notifyAdminsOfNewDispute({
      raisedByWallet: raisedByLower,
      raisedByRole:   raisedByRole as 'maker' | 'taker',
      disputeType:    disputeType as 'maker_silent' | 'maker_not_received',
      usdcAmount:     Number(offer.usdc_amount ?? 0),
      localAmount:    Number(offer.local_amount ?? 0),
      localCcy:       offer.local_currency ?? '',
      disputeId:      id,
    }).catch((err: any) => console.error('[Notify] admin_alert:', err.message))

    notifyDisputeRaised({
      raisedByWallet:   raisedByLower,
      otherPartyWallet: otherPartyWallet ?? '',
      raisedByRole:     raisedByRole as 'maker' | 'taker',
      disputeType:      disputeType as 'maker_silent' | 'maker_not_received',
      offerId,
      disputeId:        id,
    }).catch(err => console.error('[Notify] dispute_raised failed:', err.message))

    res.status(201).json({ id, autoReleaseAt })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/admin/all — admin: all disputes with offer details
router.get('/admin/all', async (req, res) => {
  const status = req.query.status as string
  try {
    const rows = await db.run(sql`
      SELECT d.*,
             o.usdc_amount, o.local_currency, o.local_amount,
             o.maker_address, o.taker_address, o.status as offer_status,
             o.taker_confirmed, o.maker_confirmed
      FROM disputes d
      JOIN p2p_offers o ON o.id = d.offer_id
      ${status ? sql`WHERE d.status = ${status}` : sql``}
      ORDER BY d.created_at DESC LIMIT 100
    `)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /disputes/:id/resolve — admin resolves dispute
// resolution: 'release_to_taker' | 'refund_maker' | 'escalate'
router.patch('/:id/resolve', async (req, res) => {
  const { resolution, resolvedBy, notes } = req.body
  if (!resolution || !resolvedBy) {
    return res.status(400).json({ error: 'resolution and resolvedBy required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    // Get dispute + offer
    const dRows = await db.run(sql`
      SELECT d.*, o.id as oid FROM disputes d
      JOIN p2p_offers o ON o.id = d.offer_id
      WHERE d.id = ${req.params.id} LIMIT 1
    `)
    const dr = parseRows(dRows)
    if (!dr.length) return res.status(404).json({ error: 'Dispute not found' })
    const dispute  = dr[0]
    const offerId  = dispute.offer_id ?? dispute[1]

    // Update dispute
    await db.run(sql`
      UPDATE disputes SET
        status      = 'resolved',
        resolution_type = ${resolution},
        admin_resolved_by = ${resolvedBy},
        admin_notes = ${notes ?? null},
        admin_resolved_at = ${now}
      WHERE id = ${req.params.id}
    `)

    // Count this resolution against the resolver's active duty session (for the
    // session log the general admin reviews). No-op if they aren't on duty
    // (e.g. super admin, or a sub-admin finishing a dispute after their window).
    await db.run(sql`
      UPDATE admin_duty_sessions
      SET disputes_resolved = COALESCE(disputes_resolved, 0) + 1, updated_at = ${now}
      WHERE admin_name = ${resolvedBy} AND status = 'on_duty'`)

    // Update offer based on resolution
    if (resolution === 'release_to_taker') {
      // Mark maker_confirmed so p2pReleaseWatcher picks it up
      await db.run(sql`
        UPDATE p2p_offers SET
          maker_confirmed = 1,
          updated_at      = ${now}
        WHERE id = ${offerId}
      `)
    } else if (resolution === 'refund_maker') {
      // Cancel offer → p2pReleaseWatcher Job1 handles refund
      await db.run(sql`
        UPDATE p2p_offers SET
          status     = 'cancelled',
          updated_at = ${now}
        WHERE id = ${offerId}
      `)
    }

    res.json({ success: true, resolution })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router

// ── Dispute Assignment ─────────────────────────────────────

// POST /disputes/:id/accept — admin accepts to handle dispute
// GATED: only a sub-admin who is ON DUTY (inside their scheduled working hours
// AND has clicked "resume duty") may accept. Super admins bypass the gate.
router.post('/:id/accept', async (req, res) => {
  const { adminId, adminName } = req.body
  if (!adminId || !adminName) {
    return res.status(400).json({ error: 'adminId and adminName required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    // ── Duty gate ──────────────────────────────────────────
    const roleRows = await db.run(
      sql`SELECT role FROM admins WHERE id = ${adminId} LIMIT 1`)
    const rr   = parseRows(roleRows)[0]
    const role = rr ? (Array.isArray(rr) ? rr[0] : rr.role) : null

    if (role !== 'super_admin') {
      const { isOnDuty } = await import('../lib/duty')
      const duty = await isOnDuty(adminId)
      if (!duty.onDuty) {
        return res.status(403).json({
          error: duty.reason ?? 'You must be on duty to accept a dispute',
          code:  'not_on_duty',
        })
      }
    }

    // Check not already assigned
    const existing = await db.run(sql`
      SELECT id FROM dispute_assignments WHERE dispute_id = ${req.params.id} LIMIT 1
    `)
    if (parseRows(existing).length) {
      return res.status(400).json({ error: 'Dispute already accepted by another admin' })
    }

    const { randomUUID } = await import('crypto')
    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_assignments (id, dispute_id, admin_id, admin_name, accepted_at)
      VALUES (${id}, ${req.params.id}, ${adminId}, ${adminName}, ${now})
    `)

    // Count this acceptance against the admin's current duty session (for the log).
    await db.run(sql`
      UPDATE admin_duty_sessions
      SET disputes_accepted = COALESCE(disputes_accepted, 0) + 1, updated_at = ${now}
      WHERE admin_id = ${adminId} AND status = 'on_duty'`)

    // Update dispute status to 'in_review'
    await db.run(sql`
      UPDATE disputes SET status = 'in_review', updated_at = ${now}
      WHERE id = ${req.params.id}
    `)

    // Fetch offer_id from dispute
    const dRows = await db.run(sql`SELECT offer_id FROM disputes WHERE id = ${req.params.id} LIMIT 1`)
    const dr = parseRows(dRows)[0]

    if (dr) {
      notifyDisputeAccepted({
        disputeId: req.params.id,
        offerId:   dr.offer_id ?? dr[0],
        adminName,
      }).catch((err: any) => console.error('[Notify] dispute_accepted:', err.message))
    }

    res.json({ success: true, adminName })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/:id/assignment — get assigned admin for a dispute
router.get('/:id/assignment', async (req, res) => {
  try {
    const rows = await db.run(sql`
      SELECT * FROM dispute_assignments WHERE dispute_id = ${req.params.id} LIMIT 1
    `)
    const r = parseRows(rows)
    res.json(r.length ? r[0] : null)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Dispute Messages ───────────────────────────────────────

// GET /disputes/:id/messages?viewerType=admin|maker|taker
router.get('/:id/messages', async (req, res) => {
  const viewerType = req.query.viewerType as string ?? 'user'
  const isAdmin    = viewerType === 'admin'
  try {
    // Admins see all messages; users only see non-admin-only messages
    const rows = await db.run(
      isAdmin
        ? sql`SELECT * FROM dispute_messages WHERE dispute_id = ${req.params.id} ORDER BY created_at ASC`
        : sql`SELECT * FROM dispute_messages WHERE dispute_id = ${req.params.id} AND admin_only = 0 ORDER BY created_at ASC`
    )
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes/:id/messages — send a message
router.post('/:id/messages', async (req, res) => {
  const { senderId, senderType, senderName, content, adminOnly = 0 } = req.body
  if (!senderId || !senderType || !content) {
    return res.status(400).json({ error: 'senderId, senderType, content required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    const { randomUUID } = await import('crypto')
    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_messages
        (id, dispute_id, sender_id, sender_type, sender_name,
         content, admin_only, created_at)
      VALUES
        (${id}, ${req.params.id}, ${senderId}, ${senderType},
         ${senderName ?? null}, ${content}, ${adminOnly ? 1 : 0}, ${now})
    `)

    // If admin sent a message, notify both parties (rate-limited)
    if (senderType === 'admin' && !adminOnly) {
      const dRows = await db.run(sql`
        SELECT o.id as offer_id, o.maker_address, o.taker_address
        FROM disputes d
        JOIN p2p_offers o ON o.id = d.offer_id
        WHERE d.id = ${req.params.id} LIMIT 1
      `)
      const d = parseRows(dRows)[0]
      if (d) {
        const offerId = d.offer_id ?? d[0]
        const parties = [d.maker_address ?? d[1], d.taker_address ?? d[2]].filter(Boolean)
        for (const wallet of parties) {
          notifyAdminMessage({
            recipientWallet: wallet,
            adminName:       senderName ?? 'Admin',
            offerId,
            disputeId:       req.params.id,
          }).catch((err: any) => console.error('[Notify] admin_message:', err.message))
        }
      }
    }

    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes/:id/messages/document — upload a supporting document
// Accepts multipart form-data (field name "file"), stores it on Cloudinary,
// and records the resulting URL as an admin-only dispute message.
router.post('/:id/messages/document', upload.single('file'), async (req, res) => {
  const { senderId, senderType, senderName } = req.body
  if (!senderId) return res.status(400).json({ error: 'senderId required' })
  if (!req.file) return res.status(400).json({ error: 'No file provided' })

  if (!process.env.CLOUDINARY_CLOUD_NAME) {
    return res.status(500).json({ error: 'File storage is not configured on the server' })
  }

  const now = Math.floor(Date.now() / 1000)
  try {
    const uploaded = await uploadBuffer(
      req.file.buffer,
      req.file.originalname,
      req.file.mimetype,
      `dispute-${req.params.id}`,
    )

    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_messages
        (id, dispute_id, sender_id, sender_type, sender_name,
         content, is_document, doc_url, doc_name, admin_only, created_at)
      VALUES
        (${id}, ${req.params.id}, ${senderId}, ${senderType ?? 'user'},
         ${senderName ?? null},
         'Supporting document submitted',
         1, ${uploaded.url}, ${uploaded.name}, 1, ${now})
    `)
    res.status(201).json({ id, docUrl: uploaded.url, docName: uploaded.name })
  } catch (err: any) {
    console.error('[Disputes] Document upload failed:', err.message)
    res.status(500).json({ error: 'Upload failed: ' + err.message })
  }
})

// GET /disputes/:id/archive — full archived dispute for super-admin audit
router.get('/:id/archive', async (req, res) => {
  try {
    const [disputeRows, msgRows, assignRows] = await Promise.all([
      db.run(sql`SELECT d.*, o.usdc_amount, o.local_currency, o.local_amount, o.maker_address, o.taker_address FROM disputes d JOIN p2p_offers o ON o.id = d.offer_id WHERE d.id = ${req.params.id} LIMIT 1`),
      db.run(sql`SELECT * FROM dispute_messages WHERE dispute_id = ${req.params.id} ORDER BY created_at ASC`),
      db.run(sql`SELECT * FROM dispute_assignments WHERE dispute_id = ${req.params.id} LIMIT 1`),
    ])
    res.json({
      dispute:    parseRows(disputeRows)[0] ?? null,
      messages:   parseRows(msgRows),
      assignment: parseRows(assignRows)[0] ?? null,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})
AFX_EOF
echo "  afrifx-api/src/routes/disputes.ts"

mkdir -p "afrifx-api/src"
cat > "afrifx-api/src/index.ts" << 'AFX_EOF'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { corsMiddleware }         from './middleware/cors'
import { rateLimitMiddleware }    from './middleware/rateLimit'
import { errorHandler }           from './middleware/errorHandler'
import ratesRouter                from './routes/rates'
import transactionsRouter         from './routes/transactions'
import userRouter                 from './routes/user'
import offersRouter               from './routes/offers'
import profileRouter              from './routes/profile'
import chatRouter                 from './routes/chat'
import walletRouter               from './routes/wallet'
import treasuryRouter             from './routes/treasury'
import payrollRouter              from './routes/payroll'
import notificationsRouter         from './routes/notifications'
import disputesRouter              from './routes/disputes'
import invoicesRouter              from './routes/invoices'
import paymentsRouter              from './routes/payments'
import { cleanExpiredSessions } from './services/auth/adminAuth'
import adminAuthRouter            from './routes/adminAuth'
import adminManageRouter          from './routes/adminManage'
import contentRouter              from './routes/content'
import { startRatePoller }        from './jobs/ratePoller'
import { startEventListener }     from './services/eventListener'
import { startAdminAuditSummary } from './jobs/adminAuditSummary'
import { startInvoiceReminders }  from './jobs/invoiceReminders'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'
import { startTreasuryChecker }   from './jobs/treasuryChecker'
import { startTxSettler }         from './jobs/txSettler'
import { startDutyScheduler }     from './jobs/dutyScheduler'
import { seedSuperAdmin }         from './lib/seedAdmin'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

app.use(corsMiddleware)

app.use(express.json())
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => res.json({ status: 'ok', ts: Date.now() }))

app.use('/rates',          ratesRouter)
app.use('/transactions',   transactionsRouter)
app.use('/user',           userRouter)
app.use('/offers',         offersRouter)
app.use('/profile',        profileRouter)
app.use('/chat',           chatRouter)
app.use('/wallet',         walletRouter)
app.use('/treasury',       treasuryRouter)
app.use('/payroll',        payrollRouter)
app.use('/notifications', notificationsRouter)
app.use('/disputes',       disputesRouter)
app.use('/invoices',       invoicesRouter)
app.use('/payments',       paymentsRouter)
app.use('/content',        contentRouter)
app.use('/admin-auth',     adminAuthRouter)
app.use('/admin/manage',   adminManageRouter)

app.use(errorHandler)

app.listen(PORT, async () => {
  console.log(`\n🚀  AfriFX API · http://localhost:${PORT}`)
  await seedSuperAdmin()
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
startInvoiceReminders()
startAdminAuditSummary()

  // Clean expired admin sessions every hour
  setInterval(() => cleanExpiredSessions().catch(() => {}), 3600_000)
  startTreasuryChecker()
  startTxSettler()
  startDutyScheduler()
})
AFX_EOF
echo "  afrifx-api/src/index.ts"

echo ""
echo "Done. NEXT STEPS (order matters):"
echo ""
echo "  1) Add the DB columns + table (run ONCE against your Turso database):"
echo "       turso db shell <your-db-name> < afrifx-api/duty-sessions-schema.sql"
echo "     (SQLite has no ADD COLUMN IF NOT EXISTS -- if a column already exists"
echo "      that line errors harmlessly; the rest still apply.)"
echo ""
echo "  2) Typecheck + deploy the API:"
echo "       cd afrifx-api && npx tsc --noEmit"
echo ""
echo "  3) Commit + push:"
echo "       git add -A && git commit -m 'Admin: dispute duty sessions (backend)'"
echo "       git push"
echo ""
echo "  NOTE: existing sub-admins have NO working hours set, so they cannot"
echo "  accept disputes until you set their hours. Super admins are unaffected"
echo "  (they bypass the duty gate). Stage B adds the UI to set hours + resume duty."
