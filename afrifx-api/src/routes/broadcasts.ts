// ============================================================
// Admin broadcasts mass / targeted email from the general admin.
//
// Audiences:  sub_admins | all_users | selected | filtered
// Opt-out:    honoured for USERS (profiles.notify_broadcasts). Sub-admins are
//             staff and always receive internal mail.
// Every user email carries an unsubscribe link; sub-admin mail does not.
// ============================================================

import { Router } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID, randomBytes } from 'crypto'
import { requireAdmin, requirePermission, logAction } from '../lib/adminAuth'
import { PERMISSIONS } from '../lib/permissions'
import { sendEmail } from '../services/email/client'
import { broadcastEmail } from '../services/email/broadcast-template'

const router = Router()
router.use(requireAdmin)

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}
const val = (row: any, key: string, i: number) => Array.isArray(row) ? row[i] : row[key]
const APP_URL = process.env.APP_URL ?? 'https://afrifx.xyz'

interface Recipient {
  email: string
  name:  string
  wallet?: string
  optedOut?: boolean
  token?: string
}

// ── Audience resolution ─────────────────────────────────────
async function resolveAudience(
  audience: string, detail: any,
): Promise<{ recipients: Recipient[]; internal: boolean }> {

  // Staff always receive internal mail (no opt-out).
  if (audience === 'sub_admins') {
    const rows = parseRows(await db.run(sql`
      SELECT username, email FROM admins
      WHERE role = 'sub_admin' AND is_active = 1 AND email IS NOT NULL`))
    return {
      internal: true,
      recipients: rows.map(r => ({
        email: val(r, 'email', 1),
        name:  val(r, 'username', 0),
      })).filter(r => !!r.email),
    }
  }

  // Users opt-out honoured.
  let rows: any[] = []

  if (audience === 'all_users') {
    rows = parseRows(await db.run(sql`
      SELECT wallet_address, username, display_name, email,
             notify_broadcasts, unsubscribe_token
      FROM profiles WHERE email IS NOT NULL AND email != ''`))

  } else if (audience === 'selected') {
    const wallets: string[] = (detail?.wallets ?? []).map((w: string) => w.toLowerCase())
    if (!wallets.length) return { internal: false, recipients: [] }
    // Fetch all with an email, then filter in JS (keeps the SQL simple/safe).
    const all = parseRows(await db.run(sql`
      SELECT wallet_address, username, display_name, email,
             notify_broadcasts, unsubscribe_token
      FROM profiles WHERE email IS NOT NULL AND email != ''`))
    rows = all.filter(r =>
      wallets.includes(String(val(r, 'wallet_address', 0)).toLowerCase()))

  } else if (audience === 'filtered') {
    const f = detail?.filter as string
    if (f === 'has_disputes') {
      rows = parseRows(await db.run(sql`
        SELECT p.wallet_address, p.username, p.display_name, p.email,
               p.notify_broadcasts, p.unsubscribe_token
        FROM profiles p
        WHERE p.email IS NOT NULL AND p.email != ''
          AND LOWER(p.wallet_address) IN (
            SELECT LOWER(maker_address) FROM p2p_offers WHERE dispute_raised = 1
            UNION
            SELECT LOWER(taker_address) FROM p2p_offers WHERE dispute_raised = 1
          )`))
    } else if (f === 'active_traders') {
      rows = parseRows(await db.run(sql`
        SELECT p.wallet_address, p.username, p.display_name, p.email,
               p.notify_broadcasts, p.unsubscribe_token
        FROM profiles p
        WHERE p.email IS NOT NULL AND p.email != ''
          AND LOWER(p.wallet_address) IN (
            SELECT LOWER(maker_address) FROM p2p_offers
            UNION
            SELECT LOWER(taker_address) FROM p2p_offers WHERE taker_address IS NOT NULL
          )`))
    } else {
      return { internal: false, recipients: [] }
    }
  } else {
    return { internal: false, recipients: [] }
  }

  return {
    internal: false,
    recipients: rows.map(r => ({
      wallet:   val(r, 'wallet_address', 0),
      name:     val(r, 'display_name', 2) || val(r, 'username', 1) || 'there',
      email:    val(r, 'email', 3),
      optedOut: Number(val(r, 'notify_broadcasts', 4) ?? 1) === 0,
      token:    val(r, 'unsubscribe_token', 5) ?? undefined,
    })).filter(r => !!r.email),
  }
}

// ── GET /broadcasts/audience/:audience preview the recipient count ────────
router.get('/audience/:audience', requirePermission(PERMISSIONS.SEND_BROADCASTS), async (req, res) => {
  try {
    const detail = req.query.filter ? { filter: req.query.filter } : {}
    const { recipients, internal } = await resolveAudience(req.params.audience, detail)
    const willReceive = internal ? recipients.length : recipients.filter(r => !r.optedOut).length
    res.json({
      total:     recipients.length,
      willSend:  willReceive,
      optedOut:  recipients.length - willReceive,
      internal,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── GET /broadcasts/users list users (for "selected" audience picker) ─────
router.get('/users', requirePermission(PERMISSIONS.SEND_BROADCASTS), async (_req, res) => {
  try {
    const rows = parseRows(await db.run(sql`
      SELECT wallet_address, username, display_name, email, notify_broadcasts
      FROM profiles WHERE email IS NOT NULL AND email != ''
      ORDER BY username ASC LIMIT 500`))
    res.json(rows.map(r => ({
      wallet:   val(r, 'wallet_address', 0),
      username: val(r, 'username', 1),
      name:     val(r, 'display_name', 2),
      email:    val(r, 'email', 3),
      optedOut: Number(val(r, 'notify_broadcasts', 4) ?? 1) === 0,
    })))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── POST /broadcasts send ────────────────────────────────────────────────
router.post('/', requirePermission(PERMISSIONS.SEND_BROADCASTS), async (req: any, res) => {
  const admin = req.admin
  const { audience, detail, subject, body } = req.body

  if (!audience || !subject?.trim() || !body?.trim()) {
    return res.status(400).json({ error: 'audience, subject and body are required' })
  }

  const now = Math.floor(Date.now() / 1000)
  const id  = randomUUID()

  try {
    const { recipients, internal } = await resolveAudience(audience, detail)
    if (!recipients.length) {
      return res.status(400).json({ error: 'That audience has no reachable recipients' })
    }

    const toSend  = internal ? recipients : recipients.filter(r => !r.optedOut)
    const skipped = recipients.length - toSend.length

    if (!toSend.length) {
      return res.status(400).json({ error: 'Every recipient in that audience has opted out' })
    }

    await db.run(sql`
      INSERT INTO admin_broadcasts
        (id, sent_by_id, sent_by_name, audience, audience_detail,
         subject, body, recipients, skipped_optout, status, created_at)
      VALUES
        (${id}, ${admin.id}, ${admin.username}, ${audience},
         ${JSON.stringify(detail ?? {})}, ${subject.trim()}, ${body.trim()},
         ${toSend.length}, ${skipped}, 'sending', ${now})`)

    // Respond immediately; delivery continues in the background.
    res.status(202).json({
      id, sending: toSend.length, skippedOptOut: skipped,
    })

    // ── Deliver ───────────────────────────────────────────
    let delivered = 0, failed = 0
    const senderRole = admin.role === 'super_admin' ? 'Administrator' : 'Sub-administrator'

    for (const r of toSend) {
      try {
        // Users get an unsubscribe link; staff don't.
        let unsubscribeUrl: string | undefined
        if (!internal && r.wallet) {
          let token = r.token
          if (!token) {
            token = randomBytes(24).toString('hex')
            await db.run(sql`
              UPDATE profiles SET unsubscribe_token = ${token}
              WHERE LOWER(wallet_address) = LOWER(${r.wallet})`)
          }
          unsubscribeUrl = `${APP_URL}/unsubscribe?token=${token}`
        }

        const tpl = broadcastEmail({
          recipientName: r.name,
          senderName:    admin.username,
          senderRole:    senderRole,
          subject:       subject.trim(),
          body:          body.trim(),
          unsubscribeUrl,
          isInternal:    internal,
        })

        const result = await sendEmail({ to: r.email, subject: tpl.subject, html: tpl.html })
        if ((result as any)?.success !== false) delivered++
        else failed++
      } catch {
        failed++
      }
    }

    await db.run(sql`
      UPDATE admin_broadcasts
      SET delivered = ${delivered}, failed = ${failed},
          status = ${failed && !delivered ? 'failed' : 'sent'},
          completed_at = ${Math.floor(Date.now() / 1000)}
      WHERE id = ${id}`)

    await logAction(admin.id, admin.username, 'send_broadcast', 'broadcast', id,
      `Broadcast "${subject.trim()}" to ${audience}, ${delivered} delivered, ${failed} failed, ${skipped} opted out`)

  } catch (err: any) {
    await db.run(sql`
      UPDATE admin_broadcasts SET status = 'failed', error = ${err.message}
      WHERE id = ${id}`).catch(() => {})
    if (!res.headersSent) res.status(500).json({ error: err.message })
  }
})

// ── GET /broadcasts history ──────────────────────────────────────────────
router.get('/', requirePermission(PERMISSIONS.SEND_BROADCASTS), async (_req, res) => {
  try {
    const rows = parseRows(await db.run(sql`
      SELECT * FROM admin_broadcasts ORDER BY created_at DESC LIMIT 50`))
    res.json(rows)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
