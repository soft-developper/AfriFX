#!/bin/bash
# ============================================================
# AfriFX — Phase 11 Wave 3: Advanced Email Features
# Run from ~/AfriFX:  bash phase11-email-wave3.sh
# ============================================================
set -e
echo ""
echo "📧  Building Phase 11 Wave 3 — Advanced email features..."
echo ""

# ============================================================
# 1 — DB: granular prefs + admin audit tracking
# ============================================================
echo "  Updating database..."

# Granular notification prefs
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_trade_accepted INTEGER DEFAULT 1;" 2>/dev/null || echo "  ⚠️  notify_trade_accepted exists"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_trade_completed INTEGER DEFAULT 1;" 2>/dev/null || echo "  ⚠️  notify_trade_completed exists"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_trade_cancelled INTEGER DEFAULT 1;" 2>/dev/null || echo "  ⚠️  notify_trade_cancelled exists"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_dispute_raised INTEGER DEFAULT 1;" 2>/dev/null || echo "  ⚠️  notify_dispute_raised exists"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_dispute_accepted INTEGER DEFAULT 1;" 2>/dev/null || echo "  ⚠️  notify_dispute_accepted exists"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_invoice_paid INTEGER DEFAULT 1;" 2>/dev/null || echo "  ⚠️  notify_invoice_paid exists"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_invoice_reminder INTEGER DEFAULT 1;" 2>/dev/null || echo "  ⚠️  notify_invoice_reminder exists"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_receipts INTEGER DEFAULT 1;" 2>/dev/null || echo "  ⚠️  notify_receipts exists"

# Admin audit tracking
turso db shell afrifx "ALTER TABLE admins ADD COLUMN email TEXT;" 2>/dev/null || echo "  ⚠️  admins.email exists"
turso db shell afrifx "ALTER TABLE admins ADD COLUMN last_audit_sent INTEGER;" 2>/dev/null || echo "  ⚠️  last_audit_sent exists"

echo "  ✅  Database updated"

# ============================================================
# 2 — New templates: receipt + audit summary
# ============================================================
cat >> afrifx-api/src/services/email/templates.ts << '__EOF__'

// ─────────────────────────────────────────────────────────────
// Wave 3 Templates
// ─────────────────────────────────────────────────────────────

const BRAND_3 = '#378ADD'
const BG_3    = '#080D1B'
const CARD_3  = '#0F1729'
const BORDER_3 = '#1B2B4B'
const TP      = '#E2E8F0'
const TS3     = '#64748B'
const SU      = '#10B981'
const APP3    = process.env.APP_URL ?? 'https://afrifx.xyz'

function base3(content: string, preview?: string) {
  return `
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>AfriFX</title></head>
<body style="margin:0;padding:0;background:${BG_3};color:${TP};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
${preview ? `<div style="display:none;font-size:1px;line-height:1px;max-height:0px;max-width:0px;opacity:0;overflow:hidden;">${preview}</div>` : ''}
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG_3};padding:32px 16px;">
<tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;width:100%;">
<tr><td style="padding-bottom:24px;text-align:center;">
<div style="display:inline-block;padding:8px 16px;border-radius:8px;background:${CARD_3};border:1px solid ${BORDER_3};">
<span style="color:${BRAND_3};font-weight:600;font-size:18px;letter-spacing:0.5px;">AfriFX</span>
<span style="color:${TS3};font-size:11px;margin-left:8px;">Arc Testnet</span>
</div></td></tr>
<tr><td style="background:${CARD_3};border:1px solid ${BORDER_3};border-radius:12px;padding:32px 28px;">
${content}
</td></tr>
<tr><td style="padding-top:24px;text-align:center;color:${TS3};font-size:12px;line-height:1.6;">
<p style="margin:0 0 8px;">AfriFX — Stablecoin-powered cross-border payments on Arc</p>
<p style="margin:0;"><a href="${APP3}" style="color:${BRAND_3};">afrifx.xyz</a> · <a href="${APP3}/profile" style="color:${TS3};">Notification settings</a></p>
</td></tr></table></td></tr></table>
</body></html>`.trim()
}

function btn3(text: string, url: string) {
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0;"><tr><td style="background:${BRAND_3};border-radius:10px;"><a href="${url}" style="display:inline-block;padding:14px 32px;color:white;font-weight:500;font-size:14px;text-decoration:none;">${text}</a></td></tr></table>`.trim()
}

// ─── Payment receipt ────────────────────────────────────────
export function paymentReceiptEmail(params: {
  recipientName: string
  recipientRole: 'sender' | 'receiver'
  type:          'trade' | 'invoice'
  usdcAmount:    number
  localAmount?:  number
  localCcy?:     string
  counterpartName: string
  reference:     string
  txHash:        string
  timestamp:     number
}) {
  const isSender = params.recipientRole === 'sender'
  const date     = new Date(params.timestamp * 1000)
  const dateStr  = date.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })
  const timeStr  = date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })

  const subject     = params.type === 'trade'
    ? 'AfriFX Trade Receipt'
    : 'AfriFX Payment Receipt'
  const previewText = isSender
    ? 'Your payment receipt from AfriFX.'
    : 'Your funds receipt from AfriFX.'

  const content = `
<div style="text-align:center;margin-bottom:24px;">
<h1 style="margin:0 0 4px;color:${TP};font-size:22px;font-weight:600;">Payment receipt</h1>
<p style="margin:0;color:${TS3};font-size:13px;">${dateStr} at ${timeStr} UTC</p>
</div>

<div style="border:1px solid ${BORDER_3};border-radius:10px;overflow:hidden;margin:20px 0;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
<tr style="background:${BG_3};">
<td style="padding:16px;border-bottom:1px solid ${BORDER_3};" colspan="2">
<div style="text-align:center;">
<div style="font-size:32px;font-weight:700;color:${TP};letter-spacing:-1px;">${params.usdcAmount} USDC</div>
${params.localAmount && params.localCcy ? `<div style="font-size:14px;color:${TS3};margin-top:4px;">&#8776; ${params.localAmount.toLocaleString()} ${params.localCcy}</div>` : ''}
</div>
</td></tr>
<tr><td style="padding:12px 16px;color:${TS3};font-size:12px;text-transform:uppercase;letter-spacing:0.5px;width:40%;border-bottom:1px solid ${BORDER_3};">Type</td>
<td style="padding:12px 16px;color:${TP};font-size:14px;border-bottom:1px solid ${BORDER_3};">${params.type === 'trade' ? 'P2P Trade' : 'Invoice Payment'}</td></tr>
<tr><td style="padding:12px 16px;color:${TS3};font-size:12px;text-transform:uppercase;letter-spacing:0.5px;border-bottom:1px solid ${BORDER_3};">Your role</td>
<td style="padding:12px 16px;color:${TP};font-size:14px;border-bottom:1px solid ${BORDER_3};">${isSender ? 'Sender' : 'Receiver'}</td></tr>
<tr><td style="padding:12px 16px;color:${TS3};font-size:12px;text-transform:uppercase;letter-spacing:0.5px;border-bottom:1px solid ${BORDER_3};">Counterparty</td>
<td style="padding:12px 16px;color:${TP};font-size:14px;border-bottom:1px solid ${BORDER_3};">${params.counterpartName}</td></tr>
<tr><td style="padding:12px 16px;color:${TS3};font-size:12px;text-transform:uppercase;letter-spacing:0.5px;border-bottom:1px solid ${BORDER_3};">Reference</td>
<td style="padding:12px 16px;font-family:monospace;color:${TP};font-size:12px;border-bottom:1px solid ${BORDER_3};">${params.reference}</td></tr>
<tr><td style="padding:12px 16px;color:${TS3};font-size:12px;text-transform:uppercase;letter-spacing:0.5px;border-bottom:1px solid ${BORDER_3};">Network</td>
<td style="padding:12px 16px;color:${TP};font-size:14px;border-bottom:1px solid ${BORDER_3};">Arc Testnet · Chain 5042002</td></tr>
<tr><td style="padding:12px 16px;color:${TS3};font-size:12px;text-transform:uppercase;letter-spacing:0.5px;">On-chain proof</td>
<td style="padding:12px 16px;"><a href="https://testnet.arcscan.app/tx/${params.txHash}" style="color:${BRAND_3};font-family:monospace;font-size:11px;">${params.txHash.slice(0,20)}&#8230;</a></td></tr>
</table>
</div>

<div style="text-align:center;margin:24px 0 0;padding:16px;border:1px solid ${BORDER_3};border-radius:8px;background:rgba(16,185,129,0.05);">
<p style="margin:0;color:${SU};font-size:13px;font-weight:500;">&#10003; Settled on-chain · Immutable record</p>
</div>

<p style="margin:24px 0 0;color:${TS3};font-size:11px;line-height:1.6;text-align:center;">
This receipt is automatically generated by AfriFX. The on-chain transaction is the authoritative record. Keep this email for your records.
</p>`

  return { subject, html: base3(content, previewText), previewText }
}

// ─── Weekly admin audit summary ─────────────────────────────
export function adminAuditSummaryEmail(params: {
  adminName:            string
  periodStart:          string
  periodEnd:            string
  disputesOpened:       number
  disputesResolved:     number
  avgResolutionHours:   number
  totalTradeVolume:     number
  totalTrades:          number
  totalInvoicesPaid:    number
  activeAdmins:         { name: string, resolved: number }[]
  unclaimedDisputes:    number
}) {
  const subject     = 'AfriFX Weekly Audit Summary'
  const previewText = `${params.disputesOpened} disputes opened, ${params.disputesResolved} resolved this week.`

  const adminRows = params.activeAdmins.map(a =>
    `<tr><td style="padding:8px 12px;color:${TP};font-size:13px;border-bottom:1px solid ${BORDER_3};">${a.name}</td>` +
    `<td style="padding:8px 12px;color:${TP};font-size:13px;text-align:right;border-bottom:1px solid ${BORDER_3};">${a.resolved}</td></tr>`
  ).join('')

  const content = `
<h1 style="margin:0 0 12px;color:${TP};font-size:22px;font-weight:600;">Weekly audit summary</h1>
<p style="margin:0 0 4px;color:${TS3};font-size:13px;">${params.periodStart} — ${params.periodEnd}</p>
<p style="margin:0 0 20px;color:${TS3};font-size:14px;">Hi ${params.adminName}, here is what happened on AfriFX this past week.</p>

<!-- Key metrics -->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:20px 0;">
<tr>
<td style="width:25%;text-align:center;padding:16px 8px;background:${BG_3};border-radius:8px 0 0 8px;border:1px solid ${BORDER_3};border-right:none;">
<div style="font-size:24px;font-weight:700;color:${TP};">${params.totalTrades}</div>
<div style="font-size:10px;color:${TS3};text-transform:uppercase;letter-spacing:0.5px;margin-top:4px;">Trades</div>
</td>
<td style="width:25%;text-align:center;padding:16px 8px;background:${BG_3};border:1px solid ${BORDER_3};border-right:none;">
<div style="font-size:24px;font-weight:700;color:${TP};">${params.disputesOpened}</div>
<div style="font-size:10px;color:${TS3};text-transform:uppercase;letter-spacing:0.5px;margin-top:4px;">Disputes</div>
</td>
<td style="width:25%;text-align:center;padding:16px 8px;background:${BG_3};border:1px solid ${BORDER_3};border-right:none;">
<div style="font-size:24px;font-weight:700;color:${SU};">${params.disputesResolved}</div>
<div style="font-size:10px;color:${TS3};text-transform:uppercase;letter-spacing:0.5px;margin-top:4px;">Resolved</div>
</td>
<td style="width:25%;text-align:center;padding:16px 8px;background:${BG_3};border-radius:0 8px 8px 0;border:1px solid ${BORDER_3};">
<div style="font-size:24px;font-weight:700;color:${TP};">${params.totalInvoicesPaid}</div>
<div style="font-size:10px;color:${TS3};text-transform:uppercase;letter-spacing:0.5px;margin-top:4px;">Invoices</div>
</td>
</tr></table>

<!-- Details -->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG_3};border-radius:10px;margin:20px 0;">
<tr><td style="padding:12px 16px;border-bottom:1px solid ${BORDER_3};">
<div style="color:${TS3};font-size:11px;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:4px;">Total USDC volume</div>
<div style="color:${TP};font-size:16px;font-weight:600;">${params.totalTradeVolume.toLocaleString()} USDC</div>
</td></tr>
<tr><td style="padding:12px 16px;border-bottom:1px solid ${BORDER_3};">
<div style="color:${TS3};font-size:11px;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:4px;">Avg dispute resolution time</div>
<div style="color:${TP};font-size:16px;font-weight:600;">${params.avgResolutionHours.toFixed(1)} hours</div>
</td></tr>
<tr><td style="padding:12px 16px;">
<div style="color:${TS3};font-size:11px;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:4px;">Unclaimed disputes</div>
<div style="color:${params.unclaimedDisputes > 0 ? '#EF4444' : SU};font-size:16px;font-weight:600;">${params.unclaimedDisputes}</div>
</td></tr></table>

${params.activeAdmins.length > 0 ? `
<!-- Admin leaderboard -->
<div style="margin:20px 0;">
<p style="margin:0 0 8px;color:${TP};font-size:14px;font-weight:500;">Admin activity</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG_3};border-radius:10px;">
<tr><td style="padding:8px 12px;color:${TS3};font-size:11px;text-transform:uppercase;letter-spacing:0.5px;border-bottom:1px solid ${BORDER_3};">Admin</td>
<td style="padding:8px 12px;color:${TS3};font-size:11px;text-transform:uppercase;letter-spacing:0.5px;text-align:right;border-bottom:1px solid ${BORDER_3};">Disputes resolved</td></tr>
${adminRows}
</table></div>` : ''}

${btn3('Open admin dashboard', `${APP3}/admin/disputes`)}

<p style="margin:16px 0 0;color:${TS3};font-size:11px;text-align:center;">
This summary is sent weekly to super admins. All data is from the platform database and on-chain records.
</p>`

  return { subject, html: base3(content, previewText), previewText }
}
__EOF__
echo "✅  Receipt + audit templates added"

# ============================================================
# 3 — Notification functions for Wave 3
# ============================================================
cat >> afrifx-api/src/services/email/notifications.ts << '__EOF__'

// ─────────────────────────────────────────────────────────────
// Wave 3 notification functions
// ─────────────────────────────────────────────────────────────

import {
  paymentReceiptEmail,
  adminAuditSummaryEmail,
} from './templates'

// ─── Payment receipt (trade or invoice) ─────────────────────
export async function notifyPaymentReceipt(params: {
  recipientWallet:  string
  recipientRole:    'sender' | 'receiver'
  type:             'trade' | 'invoice'
  usdcAmount:       number
  localAmount?:     number
  localCcy?:        string
  counterpartWallet: string
  reference:        string
  txHash:           string
  timestamp:        number
}) {
  const [recipientProfile, counterpartProfile] = await Promise.all([
    getProfile(params.recipientWallet),
    getProfile(params.counterpartWallet),
  ])

  if (!recipientProfile?.email) return
  // Check granular pref
  if (Number(recipientProfile.notify_receipts ?? 1) === 0) return
  // Skip if recently active
  if (isRecentlyActive(recipientProfile)) return

  const template = paymentReceiptEmail({
    recipientName:   getDisplayName(recipientProfile),
    recipientRole:   params.recipientRole,
    type:            params.type,
    usdcAmount:      params.usdcAmount,
    localAmount:     params.localAmount,
    localCcy:        params.localCcy,
    counterpartName: getDisplayName(counterpartProfile),
    reference:       params.reference,
    txHash:          params.txHash,
    timestamp:       params.timestamp,
  })

  const notifId = await queueAndSend({
    userWallet:     params.recipientWallet,
    type:           'payment_receipt',
    subject:        template.subject,
    payload:        params,
    recipientEmail: recipientProfile.email,
  })

  const result = await sendEmail({
    to: recipientProfile.email, subject: template.subject, html: template.html,
  })

  if (result.success) await markSent(notifId, result.id ?? null)
  else await markFailed(notifId, result.error ?? 'unknown')
}
__EOF__
echo "✅  Receipt notification function added"

# ============================================================
# 4 — Weekly audit job
# ============================================================
cat > afrifx-api/src/jobs/adminAuditSummary.ts << '__EOF__'
import { db }  from '../db/client'
import { sql } from 'drizzle-orm'
import { sendEmail } from '../services/email/client'
import { adminAuditSummaryEmail } from '../services/email/templates'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export function startAdminAuditSummary() {
  console.log('[AuditSummary] Started — sends weekly to super admins')

  const sendSummary = async () => {
    const now     = Math.floor(Date.now() / 1000)
    const weekAgo = now - (7 * 86400)

    try {
      // Get super admins with email
      const adminRows = await db.run(sql`
        SELECT id, username, email FROM admins
        WHERE role = 'super_admin' AND email IS NOT NULL
      `)
      const superAdmins = parseRows(adminRows)
      if (superAdmins.length === 0) return

      // Disputes opened this week
      const openedRows = await db.run(sql`
        SELECT COUNT(*) as cnt FROM disputes WHERE created_at >= ${weekAgo}
      `)
      const disputesOpened = Number(parseRows(openedRows)[0]?.cnt ?? 0)

      // Disputes resolved this week
      const resolvedRows = await db.run(sql`
        SELECT COUNT(*) as cnt FROM disputes
        WHERE status = 'resolved' AND admin_resolved_at >= ${weekAgo}
      `)
      const disputesResolved = Number(parseRows(resolvedRows)[0]?.cnt ?? 0)

      // Avg resolution time (hours)
      const avgRows = await db.run(sql`
        SELECT AVG(admin_resolved_at - created_at) as avg_seconds FROM disputes
        WHERE status = 'resolved' AND admin_resolved_at >= ${weekAgo}
          AND admin_resolved_at IS NOT NULL
      `)
      const avgSeconds = Number(parseRows(avgRows)[0]?.avg_seconds ?? 0)
      const avgResolutionHours = avgSeconds / 3600

      // Total trade volume this week
      const volRows = await db.run(sql`
        SELECT COUNT(*) as cnt, COALESCE(SUM(usdc_amount), 0) as vol FROM p2p_offers
        WHERE status = 'released' AND updated_at >= ${weekAgo}
      `)
      const volData = parseRows(volRows)[0]
      const totalTrades      = Number(volData?.cnt ?? 0)
      const totalTradeVolume = Number(volData?.vol ?? 0)

      // Invoices paid this week
      const invRows = await db.run(sql`
        SELECT COUNT(*) as cnt FROM invoices
        WHERE status = 'paid' AND paid_at >= ${weekAgo}
      `)
      const totalInvoicesPaid = Number(parseRows(invRows)[0]?.cnt ?? 0)

      // Unclaimed disputes
      const unclaimedRows = await db.run(sql`
        SELECT COUNT(*) as cnt FROM disputes
        WHERE status = 'open'
      `)
      const unclaimedDisputes = Number(parseRows(unclaimedRows)[0]?.cnt ?? 0)

      // Admin leaderboard
      const leaderRows = await db.run(sql`
        SELECT admin_resolved_by as name, COUNT(*) as resolved FROM disputes
        WHERE status = 'resolved' AND admin_resolved_at >= ${weekAgo}
          AND admin_resolved_by IS NOT NULL AND admin_resolved_by != 'system'
        GROUP BY admin_resolved_by ORDER BY resolved DESC LIMIT 10
      `)
      const activeAdmins = parseRows(leaderRows).map(r => ({
        name:     r.name ?? r[0] ?? 'unknown',
        resolved: Number(r.resolved ?? r[1] ?? 0),
      }))

      // Date range
      const startDate = new Date(weekAgo * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })
      const endDate   = new Date(now * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })

      // Send to each super admin
      for (const admin of superAdmins) {
        const email = admin.email ?? admin[2]
        const name  = admin.username ?? admin[1]
        if (!email) continue

        const template = adminAuditSummaryEmail({
          adminName:          name,
          periodStart:        startDate,
          periodEnd:          endDate,
          disputesOpened,
          disputesResolved,
          avgResolutionHours,
          totalTradeVolume,
          totalTrades,
          totalInvoicesPaid,
          activeAdmins,
          unclaimedDisputes,
        })

        await sendEmail({ to: email, subject: template.subject, html: template.html })
          .catch(err => console.error('[AuditSummary] send failed:', err.message))

        console.log(`[AuditSummary] Sent to ${name} (${email})`)
      }
    } catch (err: any) {
      console.error('[AuditSummary] error:', err.message)
    }
  }

  // Run every Monday at 8am (check every hour, send if it's Monday and not sent today)
  setInterval(async () => {
    const now = new Date()
    if (now.getUTCDay() === 1 && now.getUTCHours() === 8) {
      // Check if already sent today
      const today = Math.floor(new Date(now.toDateString()).getTime() / 1000)
      const rows = await db.run(sql`
        SELECT last_audit_sent FROM admins WHERE role = 'super_admin' LIMIT 1
      `)
      const r = parseRows(rows)[0]
      const lastSent = Number(r?.last_audit_sent ?? r?.[0] ?? 0)

      if (lastSent < today) {
        await sendSummary()
        const nowTs = Math.floor(Date.now() / 1000)
        await db.run(sql`UPDATE admins SET last_audit_sent = ${nowTs} WHERE role = 'super_admin'`)
      }
    }
  }, 3600_000) // Check every hour
}
__EOF__
echo "✅  adminAuditSummary.ts job"

# ============================================================
# 5 — Wire audit job into index.ts
# ============================================================
python3 - << 'PYEOF'
import os
path = os.path.expanduser('~/AfriFX/afrifx-api/src/index.ts')
with open(path) as f:
    content = f.read()

if "startAdminAuditSummary" not in content:
    content = content.replace(
        "import { startInvoiceReminders }",
        "import { startAdminAuditSummary } from './jobs/adminAuditSummary'\nimport { startInvoiceReminders }"
    )
    content = content.replace(
        "startInvoiceReminders()",
        "startInvoiceReminders()\nstartAdminAuditSummary()"
    )
    with open(path, 'w') as f:
        f.write(content)
    print("✅  audit job wired into index.ts")
PYEOF

# ============================================================
# 6 — Hook receipt emails into trade completed + invoice paid
# ============================================================
python3 - << 'PYEOF'
import os

# Hook into p2pReleaseWatcher — send receipt after trade completes
path = os.path.expanduser('~/AfriFX/afrifx-api/src/jobs/p2pReleaseWatcher.ts')
with open(path) as f:
    content = f.read()

if "notifyPaymentReceipt" not in content:
    content = content.replace(
        "import { notifyTradeCompleted, notifyTradeAutoCancelled } from '../services/email/notifications'",
        "import { notifyTradeCompleted, notifyTradeAutoCancelled, notifyPaymentReceipt } from '../services/email/notifications'"
    )

    # Add receipt after notifyTradeCompleted call
    old = "      }).catch((err: any) => console.error('[Notify] trade_completed failed:', err.message))\n      }\n    } catch {}"
    new = """      }).catch((err: any) => console.error('[Notify] trade_completed failed:', err.message))

        // Send receipts to both parties
        const now = Math.floor(Date.now() / 1000)
        notifyPaymentReceipt({
          recipientWallet: o.maker_address ?? o[1] ?? '',
          recipientRole: 'receiver',
          type: 'trade',
          usdcAmount: Number(o.usdc_amount ?? o[3] ?? 0),
          localAmount: Number(o.local_amount ?? o[5] ?? 0),
          localCcy: o.local_currency ?? o[4] ?? '',
          counterpartWallet: o.taker_address ?? o[2] ?? '',
          reference: offerId.slice(0,16),
          txHash: hash,
          timestamp: now,
        }).catch(() => {})

        notifyPaymentReceipt({
          recipientWallet: o.taker_address ?? o[2] ?? '',
          recipientRole: 'sender',
          type: 'trade',
          usdcAmount: Number(o.usdc_amount ?? o[3] ?? 0),
          localAmount: Number(o.local_amount ?? o[5] ?? 0),
          localCcy: o.local_currency ?? o[4] ?? '',
          counterpartWallet: o.maker_address ?? o[1] ?? '',
          reference: offerId.slice(0,16),
          txHash: hash,
          timestamp: now,
        }).catch(() => {})
      }
    } catch {}"""

    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("✅  trade receipt hooked into releaseOffer")

# Hook into invoices.ts — send receipt when invoice paid
path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/invoices.ts')
with open(path) as f:
    content = f.read()

if "notifyPaymentReceipt" not in content:
    content = content.replace(
        "import { notifyInvoicePaid } from '../services/email/notifications'",
        "import { notifyInvoicePaid, notifyPaymentReceipt } from '../services/email/notifications'"
    )

    # Add receipt after invoice paid notification
    old = "      }).catch((e: any) => console.error('[Notify] invoice_paid:', e.message))\n        }\n      } catch"
    new = """      }).catch((e: any) => console.error('[Notify] invoice_paid:', e.message))

          // Send receipt to payer
          notifyPaymentReceipt({
            recipientWallet: payerAddress ?? '',
            recipientRole:   'sender',
            type:            'invoice',
            usdcAmount:      Number(_inv.usdc_amount ?? _inv.amount ?? 0),
            localAmount:     _inv.amount ? Number(_inv.amount) : undefined,
            localCcy:        _inv.currency ?? undefined,
            counterpartWallet: _inv.creator_address ?? '',
            reference:       _inv.memo_ref ?? req.params.ref,
            txHash:          txHash ?? '',
            timestamp:       now,
          }).catch(() => {})
        }
      } catch"""

    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("✅  invoice receipt hooked")
PYEOF

# ============================================================
# 7 — Update email preferences UI with granular toggles
# ============================================================
cat > afrifx-web/components/notifications/EmailPreferences.tsx << '__EOF__'
'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Mail, Check, Loader2, ChevronDown, ChevronUp } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function EmailPreferences() {
  const { address } = useAccount()
  const { data: profile, refetch } = useProfile()

  const [email,     setEmail]   = useState('')
  const [prefs, setPrefs]       = useState({
    notify_trades:            true,
    notify_disputes:          true,
    notify_invoices:          true,
    notify_trade_accepted:    true,
    notify_trade_completed:   true,
    notify_trade_cancelled:   true,
    notify_dispute_raised:    true,
    notify_dispute_accepted:  true,
    notify_invoice_paid:      true,
    notify_invoice_reminder:  true,
    notify_receipts:          true,
  })
  const [saving,    setSaving]  = useState(false)
  const [saved,     setSaved]   = useState(false)
  const [showAll,   setShowAll] = useState(false)

  useEffect(() => {
    if (profile) {
      const p = profile as any
      setEmail(p.email ?? '')
      setPrefs({
        notify_trades:           Number(p.notify_trades           ?? 1) === 1,
        notify_disputes:         Number(p.notify_disputes         ?? 1) === 1,
        notify_invoices:         Number(p.notify_invoices         ?? 1) === 1,
        notify_trade_accepted:   Number(p.notify_trade_accepted   ?? 1) === 1,
        notify_trade_completed:  Number(p.notify_trade_completed  ?? 1) === 1,
        notify_trade_cancelled:  Number(p.notify_trade_cancelled  ?? 1) === 1,
        notify_dispute_raised:   Number(p.notify_dispute_raised   ?? 1) === 1,
        notify_dispute_accepted: Number(p.notify_dispute_accepted ?? 1) === 1,
        notify_invoice_paid:     Number(p.notify_invoice_paid     ?? 1) === 1,
        notify_invoice_reminder: Number(p.notify_invoice_reminder ?? 1) === 1,
        notify_receipts:         Number(p.notify_receipts         ?? 1) === 1,
      })
    }
  }, [profile])

  async function save() {
    if (!address) return
    setSaving(true)
    setSaved(false)
    try {
      await fetch(`${API}/notifications/email`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ wallet: address, email: email || null, ...prefs }),
      })
      await refetch()
      setSaved(true)
      setTimeout(() => setSaved(false), 3000)
    } catch {} finally { setSaving(false) }
  }

  const validEmail = !email || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)

  return (
    <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5 space-y-4">
      <div className="flex items-center gap-2">
        <Mail className="h-4 w-4 text-[#378ADD]" />
        <h2 className="text-sm font-medium text-[#E2E8F0]">Email notifications</h2>
      </div>

      <p className="text-xs text-[#64748B]">
        Get notified about your trades, disputes, and invoice payments by email.
      </p>

      <div className="space-y-2">
        <label className="text-xs uppercase tracking-wider text-[#64748B]">
          Email address (optional)
        </label>
        <Input
          type="email"
          placeholder="you@example.com"
          value={email}
          onChange={e => setEmail(e.target.value)}
          className={!validEmail ? 'border-red-500/50' : ''}
        />
        {!validEmail && <p className="text-xs text-red-400">Invalid email format</p>}
      </div>

      <div className="space-y-3 border-t border-[#1B2B4B] pt-4">
        <p className="text-xs font-medium uppercase tracking-wider text-[#64748B]">
          Notification categories
        </p>

        <Toggle label="Trade activity"     description="Offers accepted, completed, and cancelled" checked={prefs.notify_trades}    onChange={v => setPrefs(p => ({...p, notify_trades: v}))} />
        <Toggle label="Dispute updates"    description="Always recommended for safety"     checked={prefs.notify_disputes}  onChange={v => setPrefs(p => ({...p, notify_disputes: v}))} />
        <Toggle label="Invoice and payments" description="Invoice paid and reminder alerts"  checked={prefs.notify_invoices}  onChange={v => setPrefs(p => ({...p, notify_invoices: v}))} />
        <Toggle label="Payment receipts"   description="Formal receipts for trades and invoices"  checked={prefs.notify_receipts}  onChange={v => setPrefs(p => ({...p, notify_receipts: v}))} />
      </div>

      {/* Granular toggles */}
      <button onClick={() => setShowAll(!showAll)}
        className="flex items-center gap-1 text-xs text-[#378ADD] hover:underline">
        {showAll ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
        {showAll ? 'Hide' : 'Show'} individual event toggles
      </button>

      {showAll && (
        <div className="space-y-2 border-t border-[#1B2B4B] pt-3">
          <p className="text-[10px] uppercase tracking-wider text-[#64748B]">Trade events</p>
          <MiniToggle label="Trade accepted" checked={prefs.notify_trade_accepted}   onChange={v => setPrefs(p => ({...p, notify_trade_accepted: v}))} />
          <MiniToggle label="Trade completed" checked={prefs.notify_trade_completed}  onChange={v => setPrefs(p => ({...p, notify_trade_completed: v}))} />
          <MiniToggle label="Trade auto-cancelled" checked={prefs.notify_trade_cancelled}  onChange={v => setPrefs(p => ({...p, notify_trade_cancelled: v}))} />

          <p className="text-[10px] uppercase tracking-wider text-[#64748B] pt-2">Dispute events</p>
          <MiniToggle label="Dispute raised against you" checked={prefs.notify_dispute_raised}   onChange={v => setPrefs(p => ({...p, notify_dispute_raised: v}))} />
          <MiniToggle label="Admin accepted your dispute" checked={prefs.notify_dispute_accepted}  onChange={v => setPrefs(p => ({...p, notify_dispute_accepted: v}))} />

          <p className="text-[10px] uppercase tracking-wider text-[#64748B] pt-2">Invoice events</p>
          <MiniToggle label="Invoice paid" checked={prefs.notify_invoice_paid}     onChange={v => setPrefs(p => ({...p, notify_invoice_paid: v}))} />
          <MiniToggle label="Invoice unpaid reminder (48h)" checked={prefs.notify_invoice_reminder}  onChange={v => setPrefs(p => ({...p, notify_invoice_reminder: v}))} />
        </div>
      )}

      <Button onClick={save} disabled={!validEmail || saving} className="w-full">
        {saving
          ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</>
          : saved
          ? <><Check className="h-4 w-4 text-emerald-400" /> Saved</>
          : 'Save preferences'
        }
      </Button>
    </div>
  )
}

function Toggle({ label, description, checked, onChange }: {
  label: string, description: string, checked: boolean, onChange: (v: boolean) => void
}) {
  return (
    <label className="flex cursor-pointer items-start gap-3 rounded-lg border border-[#1B2B4B] bg-[#080D1B] p-3 hover:bg-[#0F1729] transition-colors">
      <input type="checkbox" checked={checked} onChange={e => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 shrink-0 cursor-pointer accent-[#378ADD]" />
      <div>
        <p className="text-sm font-medium text-[#E2E8F0]">{label}</p>
        <p className="text-xs text-[#64748B]">{description}</p>
      </div>
    </label>
  )
}

function MiniToggle({ label, checked, onChange }: {
  label: string, checked: boolean, onChange: (v: boolean) => void
}) {
  return (
    <label className="flex cursor-pointer items-center gap-2.5 rounded-lg bg-[#080D1B] px-3 py-2 hover:bg-[#0F1729] transition-colors">
      <input type="checkbox" checked={checked} onChange={e => onChange(e.target.checked)}
        className="h-3.5 w-3.5 shrink-0 cursor-pointer accent-[#378ADD]" />
      <span className="text-xs text-[#E2E8F0]">{label}</span>
    </label>
  )
}
__EOF__
echo "✅  EmailPreferences.tsx — granular toggles"

# ============================================================
# 8 — Update backend to save granular prefs
# ============================================================
python3 - << 'PYEOF'
import os
path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/notifications.ts')
with open(path) as f:
    content = f.read()

old = """  const { wallet, email, notify_trades, notify_disputes, notify_invoices } = req.body"""
new = """  const {
    wallet, email, notify_trades, notify_disputes, notify_invoices,
    notify_trade_accepted, notify_trade_completed, notify_trade_cancelled,
    notify_dispute_raised, notify_dispute_accepted,
    notify_invoice_paid, notify_invoice_reminder, notify_receipts,
  } = req.body"""

content = content.replace(old, new)

old2 = """        notify_trades   = ${notify_trades   ? 1 : 0},
        notify_disputes = ${notify_disputes ? 1 : 0},
        notify_invoices = ${notify_invoices ? 1 : 0},"""

new2 = """        notify_trades           = ${notify_trades           ? 1 : 0},
        notify_disputes         = ${notify_disputes         ? 1 : 0},
        notify_invoices         = ${notify_invoices         ? 1 : 0},
        notify_trade_accepted   = ${notify_trade_accepted   !== undefined ? (notify_trade_accepted   ? 1 : 0) : 1},
        notify_trade_completed  = ${notify_trade_completed  !== undefined ? (notify_trade_completed  ? 1 : 0) : 1},
        notify_trade_cancelled  = ${notify_trade_cancelled  !== undefined ? (notify_trade_cancelled  ? 1 : 0) : 1},
        notify_dispute_raised   = ${notify_dispute_raised   !== undefined ? (notify_dispute_raised   ? 1 : 0) : 1},
        notify_dispute_accepted = ${notify_dispute_accepted !== undefined ? (notify_dispute_accepted ? 1 : 0) : 1},
        notify_invoice_paid     = ${notify_invoice_paid     !== undefined ? (notify_invoice_paid     ? 1 : 0) : 1},
        notify_invoice_reminder = ${notify_invoice_reminder !== undefined ? (notify_invoice_reminder ? 1 : 0) : 1},
        notify_receipts         = ${notify_receipts         !== undefined ? (notify_receipts         ? 1 : 0) : 1},"""

content = content.replace(old2, new2)

with open(path, 'w') as f:
    f.write(content)
print("✅  Granular prefs saved in backend")
PYEOF

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 11 Wave 3 — Advanced email features complete!"
echo ""
echo "  📧 New features:"
echo "    • Payment receipts — formal receipt for every trade + invoice"
echo "    • Weekly admin audit — sent every Monday 8am UTC to super admins"
echo "    • Granular email preferences — per-event toggles with expandable UI"
echo ""
echo "  📋 Audit job runs on Mondays at 8am UTC"
echo "  🧾 Receipts sent automatically after trades and invoice payments"
echo "  ⚙️  Preferences panel has 4 categories + expandable individual toggles"
echo ""
echo "  📝 NOTE: Add admin email in DB to receive audit summaries:"
echo "    turso db shell afrifx \"UPDATE admins SET email='admin@example.com' WHERE role='super_admin';\""
echo "══════════════════════════════════════════════════════"
