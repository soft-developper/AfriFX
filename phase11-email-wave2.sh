#!/bin/bash
# ============================================================
# AfriFX — Phase 11 Wave 2: Polish Emails
# Run from ~/AfriFX:  bash phase11-email-wave2.sh
# ============================================================
set -e
echo ""
echo "📧  Building Phase 11 Wave 2 — Polish emails..."
echo ""

# ============================================================
# 1 — DB: track email rate limits + reminders
# ============================================================
turso db shell afrifx "
CREATE TABLE IF NOT EXISTS email_rate_limits (
  key         TEXT PRIMARY KEY,
  last_sent   INTEGER NOT NULL
);" && echo "  ✅  email_rate_limits table"

turso db shell afrifx "ALTER TABLE invoices ADD COLUMN reminder_sent_at INTEGER;" 2>/dev/null || echo "  ⚠️  reminder_sent_at may exist"

# ============================================================
# 2 — Add 6 new email templates
# ============================================================
cat >> afrifx-api/src/services/email/templates.ts << '__EOF__'

// ─────────────────────────────────────────────────────────────
// Wave 2 Templates
// ─────────────────────────────────────────────────────────────

const BRAND_2       = '#378ADD'
const BG_2          = '#080D1B'
const CARD_2        = '#0F1729'
const BORDER_2      = '#1B2B4B'
const TEXT_PRI      = '#E2E8F0'
const TEXT_SEC      = '#64748B'
const SUCCESS_2     = '#10B981'
const WARNING_2     = '#F59E0B'
const APP_URL_2     = process.env.APP_URL ?? 'https://afrifx.xyz'

function base2(content: string, preview?: string) {
  return `
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>AfriFX</title></head>
<body style="margin:0;padding:0;background:${BG_2};color:${TEXT_PRI};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
${preview ? `<div style="display:none;font-size:1px;line-height:1px;max-height:0px;max-width:0px;opacity:0;overflow:hidden;">${preview}</div>` : ''}
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG_2};padding:32px 16px;">
<tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;width:100%;">
<tr><td style="padding-bottom:24px;text-align:center;">
<div style="display:inline-block;padding:8px 16px;border-radius:8px;background:${CARD_2};border:1px solid ${BORDER_2};">
<span style="color:${BRAND_2};font-weight:600;font-size:18px;letter-spacing:0.5px;">AfriFX</span>
<span style="color:${TEXT_SEC};font-size:11px;margin-left:8px;">Arc Testnet</span>
</div></td></tr>
<tr><td style="background:${CARD_2};border:1px solid ${BORDER_2};border-radius:12px;padding:32px 28px;">
${content}
</td></tr>
<tr><td style="padding-top:24px;text-align:center;color:${TEXT_SEC};font-size:12px;line-height:1.6;">
<p style="margin:0 0 8px;">AfriFX — Stablecoin-powered cross-border payments on Arc</p>
<p style="margin:0;">
<a href="${APP_URL_2}" style="color:${BRAND_2};">afrifx.xyz</a> ·
<a href="${APP_URL_2}/profile" style="color:${TEXT_SEC};">Notification settings</a>
</p></td></tr>
</table></td></tr></table>
</body></html>`.trim()
}

function btn2(text: string, url: string) {
  return `
<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0;">
<tr><td style="background:${BRAND_2};border-radius:10px;">
<a href="${url}" style="display:inline-block;padding:14px 32px;color:white;font-weight:500;font-size:14px;text-decoration:none;">${text}</a>
</td></tr></table>`.trim()
}

function card2(rows: { label: string, value: string }[]) {
  return `
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG_2};border-radius:10px;margin:20px 0;">
${rows.map((r, i) => `
<tr><td style="padding:12px 16px;${i < rows.length - 1 ? `border-bottom:1px solid ${BORDER_2};` : ''}">
<div style="color:${TEXT_SEC};font-size:11px;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:4px;">${r.label}</div>
<div style="color:${TEXT_PRI};font-size:14px;font-weight:500;">${r.value}</div>
</td></tr>`).join('')}
</table>`.trim()
}

// ─── 1. Welcome email ───────────────────────────────────────
export function welcomeEmail(params: { username: string, displayName: string }) {
  const subject = 'Welcome to AfriFX'
  const preview = 'Your account is ready. Here is how to get started.'

  const content = `
<h1 style="margin:0 0 12px;color:${TEXT_PRI};font-size:22px;font-weight:600;line-height:1.3;">
Welcome to AfriFX 👋
</h1>
<p style="margin:0 0 8px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
Hi ${params.displayName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
Your AfriFX account <strong style="color:${TEXT_PRI};">@${params.username}</strong> is ready.
You can now trade stablecoins for African currencies with anyone on the platform.
</p>

<div style="background:${BG_2};border:1px solid ${BORDER_2};border-radius:10px;padding:16px;margin:20px 0;">
<p style="margin:0 0 12px;color:${TEXT_PRI};font-size:14px;font-weight:500;">Here is what you can do:</p>
<ul style="margin:0;padding:0 0 0 20px;color:${TEXT_SEC};font-size:13px;line-height:1.8;">
<li>Convert USDC ↔ NGN, GHS, KES, ZAR, EGP at live rates</li>
<li>Trade peer-to-peer with any wallet at agreed prices</li>
<li>Generate invoices with shareable payment links</li>
<li>Track all your trades and payments in one place</li>
</ul>
</div>

${btn2('Open dashboard', `${APP_URL_2}/convert`)}

<p style="margin:16px 0 0;color:${TEXT_SEC};font-size:12px;line-height:1.5;">
Every trade on AfriFX is secured by smart contract escrow on Arc. Your funds are never at risk of third-party mismanagement.
</p>`

  return { subject, html: base2(content, preview), previewText: preview }
}

// ─── 2. Admin dispute alert ─────────────────────────────────
export function adminDisputeAlertEmail(params: {
  adminName:      string
  raisedByName:   string
  raisedByRole:   'maker' | 'taker'
  disputeType:    'maker_silent' | 'maker_not_received'
  usdcAmount:     number
  localAmount:    number
  localCcy:       string
  disputeId:      string
}) {
  const subject = `⚠️ New dispute needs review — ${params.usdcAmount} USDC`
  const preview = `${params.raisedByName} raised a dispute. Claim it to become the judge.`

  const disputeReason = params.disputeType === 'maker_silent'
    ? 'Maker did not confirm receipt within the response window'
    : 'Maker claims payment was not received'

  const content = `
<h1 style="margin:0 0 12px;color:${WARNING_2};font-size:22px;font-weight:600;line-height:1.3;">
⚠️ New dispute opened
</h1>
<p style="margin:0 0 8px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
Hi ${params.adminName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
A new dispute needs admin review. Be the first to claim it and become the assigned judge.
</p>

${card2([
  { label: 'Raised by',     value: `${params.raisedByName} (${params.raisedByRole})` },
  { label: 'Reason',        value: disputeReason },
  { label: 'Amount at stake', value: `${params.usdcAmount} USDC · ${params.localAmount.toLocaleString()} ${params.localCcy}` },
])}

${btn2('Claim this dispute →', `${APP_URL_2}/admin/disputes?dispute=${params.disputeId}`)}

<p style="margin:16px 0 0;color:${TEXT_SEC};font-size:12px;line-height:1.5;">
Once you claim it, other admins will see it as taken. You will get a private chat with both parties and can request bank statements privately.
</p>`

  return { subject, html: base2(content, preview), previewText: preview }
}

// ─── 3. Dispute accepted confirmation ───────────────────────
export function disputeAcceptedEmail(params: {
  recipientName: string
  adminName:     string
  offerId:       string
}) {
  const subject = `Admin ${params.adminName} is handling your dispute`
  const preview = 'You can now chat with the assigned admin.'

  const content = `
<h1 style="margin:0 0 12px;color:${BRAND_2};font-size:22px;font-weight:600;line-height:1.3;">
An admin is on your case
</h1>
<p style="margin:0 0 8px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
Hi ${params.recipientName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
Good news — <strong style="color:${TEXT_PRI};">Admin ${params.adminName}</strong> has accepted your dispute and will be handling the review.
</p>

<div style="background:${BG_2};border:1px solid ${BORDER_2};border-radius:10px;padding:16px;margin:20px 0;">
<p style="margin:0 0 12px;color:${TEXT_PRI};font-size:14px;font-weight:500;">What happens next:</p>
<ol style="margin:0;padding:0 0 0 20px;color:${TEXT_SEC};font-size:13px;line-height:1.8;">
<li>You will get a private chat with the admin on your offer page</li>
<li>When requested, upload your bank statement (visible only to the admin)</li>
<li>The admin reviews the evidence and makes a judgement</li>
<li>The smart contract executes the resolution automatically</li>
</ol>
</div>

${btn2('Open dispute chat', `${APP_URL_2}/marketplace/${params.offerId}`)}

<p style="margin:16px 0 0;color:${TEXT_SEC};font-size:12px;line-height:1.5;">
Your USDC remains safely escrowed until the admin resolves the dispute.
</p>`

  return { subject, html: base2(content, preview), previewText: preview }
}

// ─── 4. Admin message nudge (hourly rate-limited) ───────────
export function adminMessageEmail(params: {
  recipientName: string
  adminName:     string
  offerId:       string
}) {
  const subject = `Admin ${params.adminName} sent a new message`
  const preview = 'Your assigned admin sent a message about your dispute.'

  const content = `
<h1 style="margin:0 0 12px;color:${TEXT_PRI};font-size:22px;font-weight:600;line-height:1.3;">
New message from your admin
</h1>
<p style="margin:0 0 8px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
Hi ${params.recipientName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
<strong style="color:${TEXT_PRI};">Admin ${params.adminName}</strong> sent you a message about your active dispute.
Please respond as soon as you can so the case can be resolved quickly.
</p>

${btn2('Read message', `${APP_URL_2}/marketplace/${params.offerId}`)}

<p style="margin:16px 0 0;color:${TEXT_SEC};font-size:12px;line-height:1.5;">
You will receive at most one email per hour about new admin messages, so you can focus without being spammed.
</p>`

  return { subject, html: base2(content, preview), previewText: preview }
}

// ─── 5. Invoice reminder (48h unpaid) ───────────────────────
export function invoiceReminderEmail(params: {
  creatorName:  string
  invoiceRef:   string
  amount:       number
  currency:     string
  invoiceId:    string
  createdAt:    number
}) {
  const subject = `Invoice ${params.invoiceRef} is still unpaid`
  const preview = `${params.amount.toLocaleString()} ${params.currency} pending — consider a reminder.`

  const daysAgo = Math.floor((Date.now() / 1000 - params.createdAt) / 86400)

  const content = `
<h1 style="margin:0 0 12px;color:${WARNING_2};font-size:22px;font-weight:600;line-height:1.3;">
Invoice still unpaid
</h1>
<p style="margin:0 0 8px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
Hi ${params.creatorName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
Your invoice <strong style="color:${TEXT_PRI};">${params.invoiceRef}</strong> was created ${daysAgo} days ago and has not been paid yet.
You might want to send a friendly reminder to your payer.
</p>

${card2([
  { label: 'Invoice',      value: params.invoiceRef },
  { label: 'Amount',       value: `${params.amount.toLocaleString()} ${params.currency}` },
  { label: 'Days pending', value: `${daysAgo}` },
])}

${btn2('View invoice', `${APP_URL_2}/invoices/${params.invoiceId}`)}

<p style="margin:16px 0 0;color:${TEXT_SEC};font-size:12px;line-height:1.5;">
You can copy the payment link from the invoice page and share it with your payer again. This reminder is sent once — future updates come from the platform when the invoice is paid.
</p>`

  return { subject, html: base2(content, preview), previewText: preview }
}

// ─── 6. Trade auto-cancelled ────────────────────────────────
export function tradeAutoCancelledEmail(params: {
  recipientName:   string
  recipientRole:   'maker' | 'taker'
  counterpartName: string
  usdcAmount:      number
  offerId:         string
}) {
  const isMaker = params.recipientRole === 'maker'
  const subject = 'Trade auto-cancelled — USDC returned'
  const preview = isMaker
    ? `Your offer expired. ${params.usdcAmount} USDC has been returned to your wallet.`
    : 'The offer you accepted expired because payment was not confirmed in time.'

  const content = `
<h1 style="margin:0 0 12px;color:${TEXT_PRI};font-size:22px;font-weight:600;line-height:1.3;">
Trade auto-cancelled
</h1>
<p style="margin:0 0 8px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
Hi ${params.recipientName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SEC};font-size:14px;line-height:1.6;">
${isMaker
  ? `Your trade with <strong style="color:${TEXT_PRI};">${params.counterpartName}</strong> was auto-cancelled because they did not confirm sending payment within the response window. Your ${params.usdcAmount} USDC has been safely returned to your wallet.`
  : `The trade with <strong style="color:${TEXT_PRI};">${params.counterpartName}</strong> was auto-cancelled because payment was not confirmed within the response window. If you did send payment, please contact support with your transfer receipt.`
}
</p>

${card2([
  { label: 'USDC amount',   value: `${params.usdcAmount} USDC` },
  { label: 'Counterparty',  value: params.counterpartName },
  { label: 'Status',        value: '⏱️ Auto-cancelled by system' },
])}

${btn2(isMaker ? 'Create a new offer' : 'Browse marketplace', `${APP_URL_2}/marketplace`)}

<p style="margin:16px 0 0;color:${TEXT_SEC};font-size:12px;line-height:1.5;">
Auto-cancellation happens when either party does not act within the timer window agreed at trade creation. This protects both sides from indefinite escrow.
</p>`

  return { subject, html: base2(content, preview), previewText: preview }
}
__EOF__
echo "✅  6 new templates added"

# ============================================================
# 3 — Extend notification service with 6 new functions
# ============================================================
cat >> afrifx-api/src/services/email/notifications.ts << '__EOF__'

// ─────────────────────────────────────────────────────────────
// Wave 2 notification functions
// ─────────────────────────────────────────────────────────────
import {
  welcomeEmail,
  adminDisputeAlertEmail,
  disputeAcceptedEmail,
  adminMessageEmail,
  invoiceReminderEmail,
  tradeAutoCancelledEmail,
} from './templates'

// Rate limit check (returns true if allowed to send)
async function checkRateLimit(key: string, minIntervalSeconds: number): Promise<boolean> {
  try {
    const rows = await db.run(sql`SELECT last_sent FROM email_rate_limits WHERE key = ${key} LIMIT 1`)
    const r = parseRows(rows)
    const now = Math.floor(Date.now() / 1000)

    if (r.length && (now - Number(r[0].last_sent ?? r[0][0])) < minIntervalSeconds) {
      return false
    }

    if (r.length) {
      await db.run(sql`UPDATE email_rate_limits SET last_sent = ${now} WHERE key = ${key}`)
    } else {
      await db.run(sql`INSERT INTO email_rate_limits (key, last_sent) VALUES (${key}, ${now})`)
    }
    return true
  } catch { return true }
}

// ─── 1. Welcome email ───────────────────────────────────────
export async function notifyWelcome(wallet: string) {
  const profile = await getProfile(wallet)
  if (!profile?.email) return

  const template = welcomeEmail({
    username:    profile.username ?? 'user',
    displayName: getDisplayName(profile),
  })

  const notifId = await queueAndSend({
    userWallet:     wallet,
    type:           'welcome',
    subject:        template.subject,
    payload:        {},
    recipientEmail: profile.email,
  })

  const result = await sendEmail({
    to: profile.email, subject: template.subject, html: template.html,
  })

  if (result.success) await markSent(notifId, result.id ?? null)
  else await markFailed(notifId, result.error ?? 'unknown')
}

// ─── 2. Admin dispute alert (to ALL admins with resolve_disputes) ─
export async function notifyAdminsOfNewDispute(params: {
  raisedByWallet: string
  raisedByRole:   'maker' | 'taker'
  disputeType:    'maker_silent' | 'maker_not_received'
  usdcAmount:     number
  localAmount:    number
  localCcy:       string
  disputeId:      string
}) {
  try {
    // Get all admins with resolve_disputes permission and an email
    const adminRows = await db.run(sql`
      SELECT id, username, email FROM admins
      WHERE email IS NOT NULL
        AND (role = 'super_admin' OR permissions LIKE '%resolve_disputes%')
    `)
    const admins = parseRows(adminRows)

    const raisedByProfile = await getProfile(params.raisedByWallet)
    const raisedByName    = getDisplayName(raisedByProfile)

    for (const admin of admins) {
      const email = admin.email ?? admin[2]
      const name  = admin.username ?? admin[1]
      if (!email) continue

      const template = adminDisputeAlertEmail({
        adminName:    name,
        raisedByName,
        raisedByRole: params.raisedByRole,
        disputeType:  params.disputeType,
        usdcAmount:   params.usdcAmount,
        localAmount:  params.localAmount,
        localCcy:     params.localCcy,
        disputeId:    params.disputeId,
      })

      await sendEmail({ to: email, subject: template.subject, html: template.html })
        .catch(err => console.error('[Notify] admin_dispute_alert:', err.message))
    }
  } catch (err: any) {
    console.error('[Notify] notifyAdminsOfNewDispute:', err.message)
  }
}

// ─── 3. Dispute accepted confirmation ───────────────────────
export async function notifyDisputeAccepted(params: {
  disputeId:  string
  offerId:    string
  adminName:  string
}) {
  try {
    // Get maker + taker wallets from the offer
    const offerRows = await db.run(sql`
      SELECT maker_address, taker_address FROM p2p_offers WHERE id = ${params.offerId} LIMIT 1
    `)
    const o = parseRows(offerRows)[0]
    if (!o) return

    const makerWallet = o.maker_address ?? o[0]
    const takerWallet = o.taker_address ?? o[1]

    for (const wallet of [makerWallet, takerWallet]) {
      if (!wallet) continue

      const profile = await getProfile(wallet)
      if (!profile?.email || !profile.notify_disputes) continue

      const template = disputeAcceptedEmail({
        recipientName: getDisplayName(profile),
        adminName:     params.adminName,
        offerId:       params.offerId,
      })

      const notifId = await queueAndSend({
        userWallet:     wallet,
        type:           'dispute_accepted',
        subject:        template.subject,
        payload:        params,
        recipientEmail: profile.email,
      })

      const result = await sendEmail({
        to: profile.email, subject: template.subject, html: template.html,
      })

      if (result.success) await markSent(notifId, result.id ?? null)
      else await markFailed(notifId, result.error ?? 'unknown')
    }
  } catch (err: any) {
    console.error('[Notify] notifyDisputeAccepted:', err.message)
  }
}

// ─── 4. Admin message (rate-limited to 1/hour per user) ─────
export async function notifyAdminMessage(params: {
  recipientWallet: string
  adminName:       string
  offerId:         string
  disputeId:       string
}) {
  const rateKey = `admin_msg:${params.disputeId}:${params.recipientWallet.toLowerCase()}`
  const allowed = await checkRateLimit(rateKey, 3600) // 1 hour
  if (!allowed) return

  const profile = await getProfile(params.recipientWallet)
  if (!profile?.email || !profile.notify_disputes) return

  const template = adminMessageEmail({
    recipientName: getDisplayName(profile),
    adminName:     params.adminName,
    offerId:       params.offerId,
  })

  const notifId = await queueAndSend({
    userWallet:     params.recipientWallet,
    type:           'admin_message',
    subject:        template.subject,
    payload:        params,
    recipientEmail: profile.email,
  })

  const result = await sendEmail({
    to: profile.email, subject: template.subject, html: template.html,
  })

  if (result.success) await markSent(notifId, result.id ?? null)
  else await markFailed(notifId, result.error ?? 'unknown')
}

// ─── 5. Invoice reminder (48h unpaid) ───────────────────────
export async function notifyInvoiceReminder(params: {
  creatorWallet: string
  invoiceId:     string
  invoiceRef:    string
  amount:        number
  currency:      string
  createdAt:     number
}) {
  const profile = await getProfile(params.creatorWallet)
  if (!profile?.email || !profile.notify_invoices) return

  const template = invoiceReminderEmail({
    creatorName: getDisplayName(profile),
    invoiceRef:  params.invoiceRef,
    amount:      params.amount,
    currency:    params.currency,
    invoiceId:   params.invoiceId,
    createdAt:   params.createdAt,
  })

  const notifId = await queueAndSend({
    userWallet:     params.creatorWallet,
    type:           'invoice_reminder',
    subject:        template.subject,
    payload:        params,
    recipientEmail: profile.email,
  })

  const result = await sendEmail({
    to: profile.email, subject: template.subject, html: template.html,
  })

  if (result.success) await markSent(notifId, result.id ?? null)
  else await markFailed(notifId, result.error ?? 'unknown')
}

// ─── 6. Trade auto-cancelled ────────────────────────────────
export async function notifyTradeAutoCancelled(params: {
  makerWallet: string
  takerWallet: string | null
  usdcAmount:  number
  offerId:     string
}) {
  const makerProfile = await getProfile(params.makerWallet)
  const takerProfile = params.takerWallet ? await getProfile(params.takerWallet) : null

  const notifyParty = async (
    profile: any, wallet: string,
    role: 'maker' | 'taker',
    counterpartProfile: any,
  ) => {
    if (!profile?.email || !profile.notify_trades) return

    const template = tradeAutoCancelledEmail({
      recipientName:   getDisplayName(profile),
      recipientRole:   role,
      counterpartName: counterpartProfile ? getDisplayName(counterpartProfile) : 'the other party',
      usdcAmount:      params.usdcAmount,
      offerId:         params.offerId,
    })

    const notifId = await queueAndSend({
      userWallet:     wallet, type: 'trade_auto_cancelled',
      subject:        template.subject, payload: params,
      recipientEmail: profile.email,
    })

    const result = await sendEmail({
      to: profile.email, subject: template.subject, html: template.html,
    })

    if (result.success) await markSent(notifId, result.id ?? null)
    else await markFailed(notifId, result.error ?? 'unknown')
  }

  await notifyParty(makerProfile, params.makerWallet, 'maker', takerProfile)
  if (params.takerWallet) {
    await notifyParty(takerProfile, params.takerWallet, 'taker', makerProfile)
  }
}
__EOF__
echo "✅  6 notification functions added"

# ============================================================
# 4 — Hook into routes/jobs
# ============================================================
echo ""
echo "  Wiring hooks..."

# --- Hook 1: Welcome email on profile email set (first time)
python3 - << 'PYEOF'
import os
path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/notifications.ts')
with open(path) as f:
    content = f.read()

if "notifyWelcome" not in content:
    # Add import
    content = content.replace(
        "import { db }     from '../db/client'",
        "import { db }     from '../db/client'\nimport { notifyWelcome } from '../services/email/notifications'"
    )

    # Hook into POST /notifications/email — send welcome if this is the first time adding email
    old = """    await db.run(sql`
      UPDATE profiles SET
        email = ${email ?? null},"""

    new = """    // Check if this is the first time adding an email
    const existingRows = await db.run(sql`SELECT email FROM profiles WHERE LOWER(wallet_address) = LOWER(${wallet}) LIMIT 1`)
    const existing = parseRows(existingRows)[0]
    const isFirstEmail = !existing?.email && email

    await db.run(sql`
      UPDATE profiles SET
        email = ${email ?? null},"""

    content = content.replace(old, new)

    # Send welcome after update
    old2 = "      WHERE LOWER(wallet_address) = LOWER(${wallet})\n    `)\n    res.json({ success: true })"
    new2 = """      WHERE LOWER(wallet_address) = LOWER(${wallet})
    `)

    // Send welcome email if this is their first email
    if (isFirstEmail) {
      notifyWelcome(wallet).catch(err => console.error('[Notify] welcome:', err.message))
    }

    res.json({ success: true })"""

    content = content.replace(old2, new2)

    with open(path, 'w') as f:
        f.write(content)
    print("✅  welcome email hooked on first email set")
else:
    print("⚠️  notifyWelcome already imported")
PYEOF

# --- Hook 2: Admin dispute alert when dispute is raised
python3 - << 'PYEOF'
import os
path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/disputes.ts')
with open(path) as f:
    content = f.read()

if "notifyAdminsOfNewDispute" not in content:
    content = content.replace(
        "import { notifyDisputeRaised } from '../services/email/notifications'",
        "import { notifyDisputeRaised, notifyAdminsOfNewDispute, notifyDisputeAccepted, notifyAdminMessage } from '../services/email/notifications'"
    )

    # Hook admin alert alongside dispute_raised
    old = "    notifyDisputeRaised({"
    new = """    // Alert all admins with resolve_disputes permission
    notifyAdminsOfNewDispute({
      raisedByWallet: raisedByLower,
      raisedByRole:   raisedByRole as 'maker' | 'taker',
      disputeType:    disputeType as 'maker_silent' | 'maker_not_received',
      usdcAmount:     Number(offer.usdc_amount ?? 0),
      localAmount:    Number(offer.local_amount ?? 0),
      localCcy:       offer.local_currency ?? '',
      disputeId:      id,
    }).catch((err: any) => console.error('[Notify] admin_alert:', err.message))

    notifyDisputeRaised({"""

    content = content.replace(old, new)

    with open(path, 'w') as f:
        f.write(content)
    print("✅  admin dispute alert hooked")
PYEOF

# --- Hook 3: Dispute accepted → notify both parties
python3 - << 'PYEOF'
import os
path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/disputes.ts')
with open(path) as f:
    content = f.read()

if "notifyDisputeAccepted({" not in content:
    # Find the accept route and add notification after successful insert
    old = "    res.json({ success: true, adminName })"
    new = """    // Fetch offer_id from dispute
    const dRows = await db.run(sql`SELECT offer_id FROM disputes WHERE id = ${req.params.id} LIMIT 1`)
    const dr = parseRows(dRows)[0]

    if (dr) {
      notifyDisputeAccepted({
        disputeId: req.params.id,
        offerId:   dr.offer_id ?? dr[0],
        adminName,
      }).catch((err: any) => console.error('[Notify] dispute_accepted:', err.message))
    }

    res.json({ success: true, adminName })"""

    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("✅  dispute accepted notification hooked")
PYEOF

# --- Hook 4: Admin message notification (in dispute message POST)
python3 - << 'PYEOF'
import os
path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/disputes.ts')
with open(path) as f:
    content = f.read()

if "notifyAdminMessage({" not in content:
    # Hook after dispute message insert when sender is admin
    old = """      INSERT INTO dispute_messages
        (id, dispute_id, sender_id, sender_type, sender_name,
         content, admin_only, created_at)
      VALUES
        (${id}, ${req.params.id}, ${senderId}, ${senderType},
         ${senderName ?? null}, ${content}, ${adminOnly ? 1 : 0}, ${now})
    `)
    res.status(201).json({ id })"""

    new = """      INSERT INTO dispute_messages
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

    res.status(201).json({ id })"""

    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("✅  admin message notification hooked")
PYEOF

# --- Hook 5: Trade auto-cancelled in p2pReleaseWatcher
python3 - << 'PYEOF'
import os
path = os.path.expanduser('~/AfriFX/afrifx-api/src/jobs/p2pReleaseWatcher.ts')
with open(path) as f:
    content = f.read()

if "notifyTradeAutoCancelled" not in content:
    content = content.replace(
        "import { notifyTradeCompleted } from '../services/email/notifications'",
        "import { notifyTradeCompleted, notifyTradeAutoCancelled } from '../services/email/notifications'"
    )

    # Hook after cancelOffer success
    old = """    console.log(`[P2PWatcher] ${label}: cancelled offer ${offerId.slice(0,18)}…`)"""

    new = """    console.log(`[P2PWatcher] ${label}: cancelled offer ${offerId.slice(0,18)}…`)

    // Notify both parties by email
    try {
      const oRows = await db.run(sql`SELECT maker_address, taker_address, usdc_amount FROM p2p_offers WHERE id = ${offerId} LIMIT 1`)
      const o = parseRows(oRows)[0]
      if (o) {
        notifyTradeAutoCancelled({
          makerWallet: o.maker_address ?? o[0] ?? '',
          takerWallet: o.taker_address ?? o[1] ?? null,
          usdcAmount:  Number(o.usdc_amount ?? o[2] ?? 0),
          offerId,
        }).catch((err: any) => console.error('[Notify] auto_cancelled:', err.message))
      }
    } catch {}"""

    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("✅  auto-cancelled notification hooked")
PYEOF

# --- Hook 6: Invoice reminder job — new background job every 6 hours
cat > afrifx-api/src/jobs/invoiceReminders.ts << '__EOF__'
import { db }  from '../db/client'
import { sql } from 'drizzle-orm'
import { notifyInvoiceReminder } from '../services/email/notifications'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export function startInvoiceReminders() {
  console.log('[InvoiceReminders] Started — checks every 6 hours')

  const check = async () => {
    const now      = Math.floor(Date.now() / 1000)
    const ago48h   = now - (48 * 3600)
    const ago96h   = now - (96 * 3600)

    try {
      // Find unpaid invoices created 48-96h ago that haven't been reminded yet
      const rows = await db.run(sql`
        SELECT id, memo_ref, creator_address, amount, currency, created_at
        FROM invoices
        WHERE status IN ('draft', 'sent')
          AND created_at BETWEEN ${ago96h} AND ${ago48h}
          AND reminder_sent_at IS NULL
        LIMIT 20
      `)

      const invoices = parseRows(rows)
      if (invoices.length === 0) return

      console.log(`[InvoiceReminders] Sending reminders for ${invoices.length} invoices`)

      for (const inv of invoices) {
        const invId = inv.id ?? inv[0]

        await notifyInvoiceReminder({
          creatorWallet: inv.creator_address ?? inv[2] ?? '',
          invoiceId:     invId,
          invoiceRef:    inv.memo_ref ?? inv[1] ?? '',
          amount:        Number(inv.amount ?? inv[3] ?? 0),
          currency:      inv.currency ?? inv[4] ?? '',
          createdAt:     Number(inv.created_at ?? inv[5] ?? 0),
        }).catch((err: any) => console.error('[InvoiceReminders] send failed:', err.message))

        // Mark as reminded
        await db.run(sql`UPDATE invoices SET reminder_sent_at = ${now} WHERE id = ${invId}`)
      }
    } catch (err: any) {
      console.error('[InvoiceReminders] error:', err.message)
    }
  }

  // Run once on startup after 30 seconds
  setTimeout(check, 30_000)
  // Then every 6 hours
  setInterval(check, 6 * 3600 * 1000)
}
__EOF__

# Wire the invoice reminders job into index.ts
python3 - << 'PYEOF'
import os
path = os.path.expanduser('~/AfriFX/afrifx-api/src/index.ts')
with open(path) as f:
    content = f.read()

if "startInvoiceReminders" not in content:
    content = content.replace(
        "import { startP2PReleaseWatcher }",
        "import { startInvoiceReminders }  from './jobs/invoiceReminders'\nimport { startP2PReleaseWatcher }"
    )
    # Call after other job starts
    content = content.replace(
        "startP2PReleaseWatcher()",
        "startP2PReleaseWatcher()\nstartInvoiceReminders()"
    )
    with open(path, 'w') as f:
        f.write(content)
    print("✅  invoice reminders job wired")
PYEOF

echo "✅  All 6 hooks wired"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 11 Wave 2 — Polish emails complete!"
echo ""
echo "  📧 6 new emails ready:"
echo "    1. Welcome — first time email is added to profile"
echo "    2. Admin alert — new dispute needs review"
echo "    3. Dispute accepted — parties told who took the case"
echo "    4. Admin message — 1/hour rate-limited nudge"
echo "    5. Invoice reminder — 48h unpaid follow-up"
echo "    6. Trade auto-cancelled — Job2 fires notification"
echo ""
echo "  📋 Reminders job runs every 6 hours"
echo "  ⚡  Rate limits stored in email_rate_limits table"
echo ""
echo "  Run: bash phase11-email-wave2.sh from ~/AfriFX"
echo "══════════════════════════════════════════════════════"
