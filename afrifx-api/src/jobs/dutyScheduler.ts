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
