#!/bin/bash
# ============================================================
# AfriFX -- Admin broadcasts, STAGE 1 (backend)
#
# Mass / targeted email from the general admin, delivered via Resend.
#
# AUDIENCES:  sub_admins | all_users | selected (pick people) | filtered
#             (has_disputes, active_traders)
#
# AUTHENTICITY: every email is branded -- gold AfriFX mark + wordmark, a
#   "Message from <admin name> / Administrator - AfriFX" block, the recipient's
#   OWN name in the greeting, and a signed sign-off. So it reads unmistakably
#   as a real platform email.
#
# CONSENT (important): your users opted into TRANSACTIONAL alerts (trades /
#   disputes / invoices), not announcements. So broadcasts add:
#     * profiles.notify_broadcasts  -- an opt-out we ALWAYS honour for users
#     * an unsubscribe link in every user email (public, no login needed)
#     * unsubscribing stops ANNOUNCEMENTS only -- essential trade/dispute
#       alerts still go through
#   Sub-admins are staff: internal mail, no opt-out, no unsubscribe link.
#   This also protects deliverability -- spam complaints against your domain
#   would damage your transactional email too.
#
# Every broadcast is recorded (recipients, delivered, failed, opted-out) and
# written to the admin audit log.
#
# Stage 2 (the admin UI) comes next.
#
# Run from ~/AfriFX:  bash broadcasts-stage1-backend.sh
# ============================================================
set -e
echo ""
echo "Installing admin broadcasts (backend)..."
echo ""

mkdir -p "afrifx-api"
cat > "afrifx-api/broadcasts-schema.sql" << 'AFX_EOF'
-- ============================================================
-- Admin broadcasts — mass / targeted email from the general admin
--
-- Two things:
--   1) A broadcast opt-out on profiles. Users opted into TRANSACTIONAL alerts
--      (trades / disputes / invoices) — a general broadcast is a different
--      category, so they get an explicit opt-out which we always honour.
--      Defaults to 1 (opted in) so existing users still receive announcements,
--      but every broadcast email carries an unsubscribe link.
--   2) A record of every broadcast sent, for the audit trail + delivery stats.
--
-- SQLite/libSQL has no "ADD COLUMN IF NOT EXISTS": if a column already exists
-- that statement errors harmlessly. Run the ALTERs individually if needed.
-- Run:  turso db shell <your-db-name> < afrifx-api/broadcasts-schema.sql
-- ============================================================

-- 1) Broadcast opt-out (users). 1 = will receive broadcasts, 0 = opted out.
ALTER TABLE profiles ADD COLUMN notify_broadcasts INTEGER DEFAULT 1;

-- An unguessable token so a user can unsubscribe from an email link without
-- being logged in. Generated lazily on first broadcast.
ALTER TABLE profiles ADD COLUMN unsubscribe_token TEXT;

-- 2) Broadcast history
CREATE TABLE IF NOT EXISTS admin_broadcasts (
  id              TEXT PRIMARY KEY,
  sent_by_id      TEXT NOT NULL,          -- admin id
  sent_by_name    TEXT NOT NULL,          -- shown in the email header

  audience        TEXT NOT NULL,          -- 'sub_admins' | 'all_users' | 'selected' | 'filtered'
  audience_detail TEXT,                   -- JSON: filter used, or list of recipients

  subject         TEXT NOT NULL,
  body            TEXT NOT NULL,          -- the admin's message (plain text / light markup)

  recipients      INTEGER DEFAULT 0,      -- how many we attempted
  delivered       INTEGER DEFAULT 0,
  failed          INTEGER DEFAULT 0,
  skipped_optout  INTEGER DEFAULT 0,      -- honoured opt-outs (users, not sub-admins)

  status          TEXT NOT NULL DEFAULT 'sending',  -- sending | sent | failed
  error           TEXT,

  created_at      INTEGER NOT NULL,
  completed_at    INTEGER
);

CREATE INDEX IF NOT EXISTS idx_broadcasts_sender ON admin_broadcasts (sent_by_id);
CREATE INDEX IF NOT EXISTS idx_broadcasts_time   ON admin_broadcasts (created_at);
AFX_EOF
echo "  afrifx-api/broadcasts-schema.sql"

mkdir -p "afrifx-api/src/services/email"
cat > "afrifx-api/src/services/email/broadcast-template.ts" << 'AFX_EOF'
// AfriFX broadcast email template — the branded shell for admin announcements.
//
// Uses the CURRENT gold brand (the older transactional templates in
// templates.ts still use the pre-rebrand blue; those are left alone here).
//
// Every broadcast carries the marks of an authentic platform email:
//   * the AfriFX wordmark + hexagon mark in the header
//   * the sending admin's name and role, so it's clear who it's from
//   * the recipient's own name in the greeting
//   * a footer explaining WHY they received it, plus a working unsubscribe link

const GOLD        = '#D9A441'
const GOLD_BRIGHT = '#EAC15C'
const BG          = '#12100B'
const CARD        = '#1C1810'
const BORDER      = '#2A2418'
const TEXT        = '#F2E9D8'
const MUTED       = '#9C8A6E'

const APP_URL = process.env.APP_URL ?? 'https://afrifx.xyz'

export interface BroadcastTemplateParams {
  recipientName:  string      // personalises the greeting
  senderName:     string      // the admin who sent it
  senderRole:     string      // e.g. 'Administrator'
  subject:        string
  body:           string      // the admin's message (plain text; newlines honoured)
  unsubscribeUrl?: string     // omitted for sub-admin recipients (internal mail)
  isInternal?:    boolean     // true when sent to sub-admins
}

// Turn the admin's plain-text message into safe HTML paragraphs.
// We escape everything, then honour blank-line paragraphs and single newlines.
function renderBody(text: string): string {
  const esc = (s: string) => s
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')

  return esc(text)
    .split(/\n{2,}/)
    .map(p => `<p style="margin:0 0 16px;color:${TEXT};font-size:15px;line-height:1.6;">${p.replace(/\n/g, '<br/>')}</p>`)
    .join('')
}

export function broadcastEmail(p: BroadcastTemplateParams): { subject: string; html: string } {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${p.subject}</title>
</head>
<body style="margin:0;padding:0;background:${BG};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG};padding:32px 16px;">
  <tr><td align="center">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;">

      <!-- Header: brand mark + wordmark -->
      <tr><td align="center" style="padding-bottom:24px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td style="vertical-align:middle;padding-right:10px;">
              <svg width="34" height="35" viewBox="0 0 120 124" xmlns="http://www.w3.org/2000/svg">
                <path d="M60 4 L112 34 L112 90 L60 120 L8 90 L8 34 Z" fill="none" stroke="${GOLD}" stroke-width="8" stroke-linejoin="round"/>
                <g fill="none" stroke="${TEXT}" stroke-width="9" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M36 88 L52 40 L68 88"/><path d="M43 70 L61 70"/>
                </g>
                <g fill="none" stroke="${GOLD}" stroke-width="9" stroke-linecap="round">
                  <path d="M74 52 L96 84"/><path d="M96 52 L74 84"/>
                </g>
              </svg>
            </td>
            <td style="vertical-align:middle;">
              <span style="font-size:24px;font-weight:800;letter-spacing:-0.5px;color:${GOLD_BRIGHT};">Afri</span><span style="font-size:24px;font-weight:800;letter-spacing:-0.5px;color:${GOLD};">FX</span>
            </td>
          </tr>
        </table>
      </td></tr>

      <!-- Card -->
      <tr><td style="background:${CARD};border:1px solid ${BORDER};border-radius:14px;padding:28px 26px;">

        <!-- Who it's from — an authenticity signal -->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-bottom:20px;">
          <tr><td style="padding-bottom:14px;border-bottom:1px solid ${BORDER};">
            <p style="margin:0;font-size:11px;text-transform:uppercase;letter-spacing:1.2px;color:${MUTED};">
              ${p.isInternal ? 'Internal message from' : 'Message from'}
            </p>
            <p style="margin:4px 0 0;font-size:15px;font-weight:600;color:${GOLD_BRIGHT};">
              ${p.senderName}
            </p>
            <p style="margin:2px 0 0;font-size:12px;color:${MUTED};">
              ${p.senderRole} · AfriFX
            </p>
          </td></tr>
        </table>

        <!-- Greeting with the recipient's own name -->
        <p style="margin:0 0 18px;font-size:15px;color:${TEXT};">
          Hi ${p.recipientName},
        </p>

        <!-- The admin's message -->
        ${renderBody(p.body)}

        <!-- Sign-off -->
        <p style="margin:24px 0 0;padding-top:18px;border-top:1px solid ${BORDER};font-size:14px;color:${MUTED};">
          — ${p.senderName}<br/>
          <span style="font-size:12px;">${p.senderRole}, AfriFX</span>
        </p>
      </td></tr>

      <!-- Footer -->
      <tr><td style="padding-top:20px;text-align:center;">
        <p style="margin:0 0 8px;font-size:11px;color:${MUTED};line-height:1.5;">
          ${p.isInternal
            ? 'You received this because you are an AfriFX sub-administrator.'
            : 'You received this because you have an account on AfriFX.'}
        </p>
        <p style="margin:0 0 10px;font-size:11px;color:${MUTED};">
          <a href="${APP_URL}" style="color:${GOLD};text-decoration:none;">afrifx.xyz</a>
          ${p.unsubscribeUrl ? `
            &nbsp;·&nbsp;
            <a href="${p.unsubscribeUrl}" style="color:${MUTED};text-decoration:underline;">
              Unsubscribe from announcements
            </a>` : ''}
        </p>
        <p style="margin:0;font-size:10px;color:${MUTED};">
          ${p.unsubscribeUrl
            ? 'Unsubscribing stops announcements only — you will still receive essential alerts about your own trades and disputes.'
            : ''}
        </p>
      </td></tr>

    </table>
  </td></tr>
</table>
</body>
</html>`

  return { subject: p.subject, html }
}
AFX_EOF
echo "  afrifx-api/src/services/email/broadcast-template.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/broadcasts.ts" << 'AFX_EOF'
// ============================================================
// Admin broadcasts — mass / targeted email from the general admin.
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

  // Staff — always receive internal mail (no opt-out).
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

  // Users — opt-out honoured.
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

// ── GET /broadcasts/audience/:audience — preview the recipient count ────────
router.get('/audience/:audience', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
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

// ── GET /broadcasts/users — list users (for "selected" audience picker) ─────
router.get('/users', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (_req, res) => {
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

// ── POST /broadcasts — send ────────────────────────────────────────────────
router.post('/', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req: any, res) => {
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
      `Broadcast "${subject.trim()}" to ${audience} — ${delivered} delivered, ${failed} failed, ${skipped} opted out`)

  } catch (err: any) {
    await db.run(sql`
      UPDATE admin_broadcasts SET status = 'failed', error = ${err.message}
      WHERE id = ${id}`).catch(() => {})
    if (!res.headersSent) res.status(500).json({ error: err.message })
  }
})

// ── GET /broadcasts — history ──────────────────────────────────────────────
router.get('/', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (_req, res) => {
  try {
    const rows = parseRows(await db.run(sql`
      SELECT * FROM admin_broadcasts ORDER BY created_at DESC LIMIT 50`))
    res.json(rows)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
AFX_EOF
echo "  afrifx-api/src/routes/broadcasts.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/profile.ts" << 'AFX_EOF'
import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'

const router = Router()

// ── Broadcast unsubscribe (PUBLIC — reached from an email link, no login) ───
// Honours the opt-out we promise in every broadcast footer. Only affects
// ANNOUNCEMENTS; the user still receives essential alerts about their own
// trades, disputes and invoices.
router.post('/unsubscribe/:token', async (req, res) => {
  try {
    const rows = await db.run(sql`
      SELECT wallet_address, username FROM profiles
      WHERE unsubscribe_token = ${req.params.token} LIMIT 1`)
    const r = Array.isArray((rows as any).rows) ? (rows as any).rows : (Array.isArray(rows) ? rows : [])
    if (!r.length) return res.status(404).json({ error: 'This unsubscribe link is not valid.' })

    await db.run(sql`
      UPDATE profiles SET notify_broadcasts = 0
      WHERE unsubscribe_token = ${req.params.token}`)

    res.json({
      success: true,
      message: 'You have been unsubscribed from AfriFX announcements. You will still receive essential alerts about your own trades and disputes.',
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

const RESERVED = [
  'admin','afrifx','support','help','root','system','platform',
  'api','www','app','mail','dev','test','null','undefined',
]

const AVATAR_COLORS = [
  '#378ADD','#10B981','#8B5CF6','#F59E0B',
  '#EF4444','#EC4899','#14B8A6','#F97316',
  '#06B6D4','#84CC16','#A855F7','#FB923C',
]

function deriveColor(username: string): string {
  let hash = 0
  for (let i = 0; i < username.length; i++) {
    hash = username.charCodeAt(i) + ((hash << 5) - hash)
  }
  return AVATAR_COLORS[Math.abs(hash) % AVATAR_COLORS.length]
}

function validateUsername(u: string): string | null {
  if (!u) return 'Username is required'
  if (u.length < 3)  return 'Username must be at least 3 characters'
  if (u.length > 20) return 'Username must be 20 characters or less'
  if (!/^[a-zA-Z0-9_]+$/.test(u)) return 'Only letters, numbers and underscores allowed'
  if (RESERVED.includes(u.toLowerCase())) return 'This username is reserved'
  return null
}

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// Normalise a profile row — handles both array and object rows
// Includes live trade counts from subqueries
function normalizeProfile(row: any) {
  if (Array.isArray(row)) {
    return {
      wallet_address:  row[0],
      username:        row[1],
      display_name:    row[2],
      bio:             row[3],
      twitter_handle:  row[4],
      telegram_handle: row[5],
      avatar_color:    row[6],
      trade_count:     Number(row[7]  ?? 0),
      dispute_count:   Number(row[8]  ?? 0),
      verified:        !!row[9],
      show_socials:    !!row[10],
      created_at:      Number(row[11] ?? 0),
      updated_at:      Number(row[12] ?? 0),
      maker_trades:    Number(row[13] ?? 0),
      taker_trades:    Number(row[14] ?? 0),
      total_disputes:  Number(row[15] ?? 0),
    }
  }
  return {
    ...row,
    verified:       !!row.verified,
    show_socials:   !!row.show_socials,
    trade_count:    Number(row.trade_count    ?? 0),
    dispute_count:  Number(row.dispute_count  ?? 0),
    maker_trades:   Number(row.maker_trades   ?? 0),
    taker_trades:   Number(row.taker_trades   ?? 0),
    total_disputes: Number(row.total_disputes ?? 0),
  }
}

// Shared subquery for live trade + dispute counts
const PROFILE_QUERY = (whereClause: ReturnType<typeof sql>) => sql`
  SELECT p.*,
    (SELECT COUNT(*)
     FROM p2p_offers
     WHERE LOWER(maker_address) = LOWER(p.wallet_address)
       AND status = 'released') AS maker_trades,
    (SELECT COUNT(*)
     FROM p2p_offers
     WHERE LOWER(taker_address) = LOWER(p.wallet_address)
       AND status = 'released') AS taker_trades,
    (SELECT COUNT(*)
     FROM disputes
     WHERE LOWER(raised_by) != LOWER(p.wallet_address)
       AND offer_id IN (
         SELECT id FROM p2p_offers
         WHERE LOWER(maker_address) = LOWER(p.wallet_address)
       )) AS total_disputes
  FROM profiles p
  WHERE ${whereClause}
  LIMIT 1
`

// GET /profile/check/:username
router.get('/check/:username', async (req, res) => {
  const username = req.params.username.toLowerCase()
  const err      = validateUsername(username)
  if (err) return res.json({ available: false, error: err })
  try {
    const rows = await db.run(
      sql`SELECT wallet_address FROM profiles WHERE LOWER(username) = ${username} LIMIT 1`
    )
    const r = parseRows(rows)
    res.json({ available: r.length === 0 })
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

// GET /profile/wallet/:address — by wallet address (includes live trade counts)
router.get('/wallet/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  try {
    const rows = await db.run(sql`
      SELECT p.*,
        (SELECT COUNT(*)
         FROM p2p_offers
         WHERE LOWER(maker_address) = ${addr}
           AND status = 'released') AS maker_trades,
        (SELECT COUNT(*)
         FROM p2p_offers
         WHERE LOWER(taker_address) = ${addr}
           AND status = 'released') AS taker_trades,
        (SELECT COUNT(*)
         FROM disputes d
         JOIN p2p_offers o ON o.id = d.offer_id
         WHERE LOWER(o.maker_address) = ${addr}
           AND LOWER(d.raised_by) != ${addr}) AS total_disputes
      FROM profiles p
      WHERE LOWER(p.wallet_address) = ${addr}
      LIMIT 1
    `)
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Profile not found' })
    res.json(normalizeProfile(r[0]))
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

// GET /profile/:username — by username (public)
router.get('/:username', async (req, res) => {
  const username = req.params.username.toLowerCase()
  try {
    const rows = await db.run(sql`
      SELECT p.*,
        (SELECT COUNT(*)
         FROM p2p_offers
         WHERE LOWER(maker_address) = LOWER(p.wallet_address)
           AND status = 'released') AS maker_trades,
        (SELECT COUNT(*)
         FROM p2p_offers
         WHERE LOWER(taker_address) = LOWER(p.wallet_address)
           AND status = 'released') AS taker_trades,
        (SELECT COUNT(*)
         FROM disputes d
         JOIN p2p_offers o ON o.id = d.offer_id
         WHERE LOWER(o.maker_address) = LOWER(p.wallet_address)
           AND LOWER(d.raised_by) != LOWER(p.wallet_address)) AS total_disputes
      FROM profiles p
      WHERE LOWER(p.username) = ${username}
      LIMIT 1
    `)
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Profile not found' })
    const profile = normalizeProfile(r[0])
    if (!profile.show_socials) {
      profile.twitter_handle  = null
      profile.telegram_handle = null
    }
    res.json(profile)
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

// POST /profile — create
router.post('/', async (req, res) => {
  const {
    walletAddress, username, displayName,
    bio, twitterHandle, telegramHandle, showSocials,
  } = req.body

  const err = validateUsername(username)
  if (err) return res.status(400).json({ error: err })
  if (!displayName?.trim()) return res.status(400).json({ error: 'Display name is required' })
  if (!walletAddress)        return res.status(400).json({ error: 'Wallet address is required' })

  const now   = Math.floor(Date.now() / 1000)
  const color = deriveColor(username.toLowerCase())

  try {
    const existing = await db.run(
      sql`SELECT wallet_address FROM profiles
          WHERE LOWER(username) = ${username.toLowerCase()} LIMIT 1`
    )
    const r = parseRows(existing)
    if (r.length) return res.status(409).json({ error: 'Username already taken' })

    await db.run(
      sql`INSERT INTO profiles
          (wallet_address, username, display_name, bio,
           twitter_handle, telegram_handle, avatar_color,
           show_socials, created_at, updated_at)
          VALUES
          (${walletAddress.toLowerCase()}, ${username.toLowerCase()},
           ${displayName.trim()}, ${bio?.trim() || null},
           ${twitterHandle?.replace('@','').trim() || null},
           ${telegramHandle?.replace('@','').trim() || null},
           ${color}, ${showSocials !== false ? 1 : 0},
           ${now}, ${now})`
    )
    res.status(201).json({ username: username.toLowerCase(), avatarColor: color })
  } catch (e: any) {
    if (e.message?.includes('UNIQUE')) {
      return res.status(409).json({ error: 'Username already taken' })
    }
    res.status(500).json({ error: e.message })
  }
})

// PATCH /profile/:address — update
router.patch('/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  const {
    displayName, bio, twitterHandle, telegramHandle, showSocials,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE profiles SET
            display_name    = COALESCE(${displayName?.trim()  ?? null}, display_name),
            bio             = COALESCE(${bio?.trim()          ?? null}, bio),
            twitter_handle  = COALESCE(${twitterHandle?.replace('@','').trim() ?? null}, twitter_handle),
            telegram_handle = COALESCE(${telegramHandle?.replace('@','').trim() ?? null}, telegram_handle),
            show_socials    = COALESCE(${showSocials !== undefined ? (showSocials ? 1 : 0) : null}, show_socials),
            updated_at      = ${now}
          WHERE LOWER(wallet_address) = ${addr}`
    )
    res.json({ success: true })
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

export default router
AFX_EOF
echo "  afrifx-api/src/routes/profile.ts"

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
import broadcastsRouter           from './routes/broadcasts'
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
app.use('/admin/broadcasts', broadcastsRouter)

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
echo "  1) Add the DB columns + table. Run these INDIVIDUALLY (the two ALTERs"
echo "     may already exist on a re-run -- a 'duplicate column' error there is"
echo "     harmless, just move on):"
echo ""
echo "     turso db shell <db> \"ALTER TABLE profiles ADD COLUMN notify_broadcasts INTEGER DEFAULT 1;\""
echo "     turso db shell <db> \"ALTER TABLE profiles ADD COLUMN unsubscribe_token TEXT;\""
echo "     turso db shell <db> < afrifx-api/broadcasts-schema.sql   # for the table + indexes"
echo ""
echo "  2) cd afrifx-api && npx tsc --noEmit"
echo ""
echo "  3) git add -A && git commit -m 'Admin broadcasts: backend + branded template'"
echo "     git push"
echo ""
echo "  Nothing is exposed in the UI yet -- stage 2 adds the admin interface."
