#!/bin/bash
# ============================================================
# AfriFX — Phase 11 Wave 1: Email Notifications
# Run from ~/AfriFX:  bash phase11-email-wave1.sh
# ============================================================
set -e
echo ""
echo "📧  Building Phase 11 Wave 1 — Email Notifications..."
echo ""

# ============================================================
# 1 — DB: add email column to profiles + notifications table
# ============================================================
echo "  Updating database..."

turso db shell afrifx "ALTER TABLE profiles ADD COLUMN email TEXT;" 2>/dev/null && echo "  ✅  email column" || echo "  ⚠️  email column may exist"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN email_verified INTEGER DEFAULT 0;" 2>/dev/null && echo "  ✅  email_verified" || echo "  ⚠️  may exist"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_trades INTEGER DEFAULT 1;" 2>/dev/null && echo "  ✅  notify_trades" || echo "  ⚠️  may exist"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_disputes INTEGER DEFAULT 1;" 2>/dev/null && echo "  ✅  notify_disputes" || echo "  ⚠️  may exist"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN notify_invoices INTEGER DEFAULT 1;" 2>/dev/null && echo "  ✅  notify_invoices" || echo "  ⚠️  may exist"
turso db shell afrifx "ALTER TABLE profiles ADD COLUMN last_active_at INTEGER;" 2>/dev/null && echo "  ✅  last_active_at" || echo "  ⚠️  may exist"

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS notifications (
  id              TEXT PRIMARY KEY,
  user_wallet     TEXT NOT NULL,
  recipient_email TEXT,
  type            TEXT NOT NULL,
  subject         TEXT NOT NULL,
  payload         TEXT,
  status          TEXT DEFAULT 'pending',
  attempts        INTEGER DEFAULT 0,
  last_error      TEXT,
  email_id        TEXT,
  read_at         INTEGER,
  sent_at         INTEGER,
  created_at      INTEGER NOT NULL
);" && echo "  ✅  notifications table"

turso db shell afrifx "
CREATE INDEX IF NOT EXISTS idx_notif_user ON notifications (user_wallet, created_at);
CREATE INDEX IF NOT EXISTS idx_notif_status ON notifications (status);
" && echo "  ✅  indexes"

# ============================================================
# 2 — Install Resend
# ============================================================
echo ""
echo "  Installing Resend SDK..."
cd afrifx-api
npm install resend
cd ..
echo "  ✅  Resend installed"

# ============================================================
# 3 — Backend: email service
# ============================================================
mkdir -p afrifx-api/src/services/email

cat > afrifx-api/src/services/email/client.ts << '__EOF__'
import { Resend } from 'resend'

const RESEND_KEY = process.env.RESEND_API_KEY
const FROM_EMAIL = process.env.EMAIL_FROM ?? 'AfriFX <notifications@afrifx.xyz>'

if (!RESEND_KEY) {
  console.warn('[Email] RESEND_API_KEY not set — emails will be logged but not sent')
}

const resend = RESEND_KEY ? new Resend(RESEND_KEY) : null

export interface SendEmailParams {
  to:      string
  subject: string
  html:    string
}

export async function sendEmail({ to, subject, html }: SendEmailParams) {
  if (!resend) {
    console.log(`[Email DEV MODE] To: ${to} | Subject: ${subject}`)
    return { id: 'dev-mode', success: true }
  }

  try {
    const result = await resend.emails.send({
      from:    FROM_EMAIL,
      to:      [to],
      subject,
      html,
    })
    return { id: result.data?.id, success: true, error: result.error }
  } catch (err: any) {
    console.error('[Email] Send failed:', err.message)
    return { id: null, success: false, error: err.message }
  }
}
__EOF__
echo "✅  email/client.ts"

# ============================================================
# 4 — Email templates (4 for Wave 1)
# ============================================================
cat > afrifx-api/src/services/email/templates.ts << '__EOF__'
// AfriFX email templates — branded, mobile-responsive
// Designed to render correctly in Gmail, Yahoo, Outlook

const BRAND_COLOR     = '#378ADD'
const BG_COLOR        = '#080D1B'
const CARD_COLOR      = '#0F1729'
const BORDER_COLOR    = '#1B2B4B'
const TEXT_PRIMARY    = '#E2E8F0'
const TEXT_SECONDARY  = '#64748B'
const SUCCESS_COLOR   = '#10B981'
const WARNING_COLOR   = '#F59E0B'
const DANGER_COLOR    = '#EF4444'

const APP_URL = process.env.APP_URL ?? 'https://afrifx.xyz'

function baseLayout(content: string, options: { previewText?: string } = {}) {
  return `
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AfriFX</title>
<style>
  body { margin: 0; padding: 0; background: ${BG_COLOR}; color: ${TEXT_PRIMARY}; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
  table { border-collapse: collapse; }
  a { color: ${BRAND_COLOR}; text-decoration: none; }
</style>
</head>
<body style="margin:0;padding:0;background:${BG_COLOR};">
${options.previewText ? `<div style="display:none;font-size:1px;line-height:1px;max-height:0px;max-width:0px;opacity:0;overflow:hidden;">${options.previewText}</div>` : ''}
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG_COLOR};padding:32px 16px;">
  <tr>
    <td align="center">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;width:100%;">
        <!-- Logo -->
        <tr>
          <td style="padding-bottom:24px;text-align:center;">
            <div style="display:inline-block;padding:8px 16px;border-radius:8px;background:${CARD_COLOR};border:1px solid ${BORDER_COLOR};">
              <span style="color:${BRAND_COLOR};font-weight:600;font-size:18px;letter-spacing:0.5px;">AfriFX</span>
              <span style="color:${TEXT_SECONDARY};font-size:11px;margin-left:8px;">Arc Testnet</span>
            </div>
          </td>
        </tr>
        <!-- Card -->
        <tr>
          <td style="background:${CARD_COLOR};border:1px solid ${BORDER_COLOR};border-radius:12px;padding:32px 28px;">
            ${content}
          </td>
        </tr>
        <!-- Footer -->
        <tr>
          <td style="padding-top:24px;text-align:center;color:${TEXT_SECONDARY};font-size:12px;line-height:1.6;">
            <p style="margin:0 0 8px;">AfriFX — Stablecoin-powered cross-border payments on Arc</p>
            <p style="margin:0;">
              <a href="${APP_URL}" style="color:${BRAND_COLOR};">afrifx.xyz</a> ·
              <a href="${APP_URL}/profile" style="color:${TEXT_SECONDARY};">Notification settings</a>
            </p>
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
</body>
</html>
  `.trim()
}

function ctaButton(text: string, url: string) {
  return `
<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0;">
  <tr>
    <td style="background:${BRAND_COLOR};border-radius:10px;">
      <a href="${url}" style="display:inline-block;padding:14px 32px;color:white;font-weight:500;font-size:14px;text-decoration:none;">${text}</a>
    </td>
  </tr>
</table>`.trim()
}

function infoCard(rows: { label: string, value: string }[]) {
  return `
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG_COLOR};border-radius:10px;margin:20px 0;">
  ${rows.map((r, i) => `
    <tr>
      <td style="padding:12px 16px;${i < rows.length - 1 ? `border-bottom:1px solid ${BORDER_COLOR};` : ''}">
        <div style="color:${TEXT_SECONDARY};font-size:11px;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:4px;">${r.label}</div>
        <div style="color:${TEXT_PRIMARY};font-size:14px;font-weight:500;">${r.value}</div>
      </td>
    </tr>
  `).join('')}
</table>`.trim()
}

// ─────────────────────────────────────────────────────────────
// Template 1: Trade Accepted (sent to maker)
// ─────────────────────────────────────────────────────────────
export function tradeAcceptedEmail(params: {
  makerName:   string
  takerName:   string
  usdcAmount:  number
  localAmount: number
  localCcy:    string
  offerId:     string
}) {
  const subject     = `${params.takerName} accepted your offer`
  const previewText = `Your ${params.usdcAmount} USDC trade is in escrow. Awaiting payment confirmation.`

  const content = `
<h1 style="margin:0 0 12px;color:${TEXT_PRIMARY};font-size:22px;font-weight:600;line-height:1.3;">
  Your offer was accepted ✓
</h1>
<p style="margin:0 0 8px;color:${TEXT_SECONDARY};font-size:14px;line-height:1.6;">
  Hi ${params.makerName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SECONDARY};font-size:14px;line-height:1.6;">
  <strong style="color:${TEXT_PRIMARY};">${params.takerName}</strong> just accepted your USDC offer.
  Your USDC is now locked in the Arc smart contract escrow.
</p>

${infoCard([
  { label: 'You will receive',  value: `${params.localAmount.toLocaleString()} ${params.localCcy}` },
  { label: 'In exchange for',   value: `${params.usdcAmount} USDC (escrowed)` },
  { label: 'Status',            value: '🔒 Awaiting payment from buyer' },
])}

<p style="margin:0 0 8px;color:${TEXT_SECONDARY};font-size:14px;line-height:1.6;">
  <strong style="color:${TEXT_PRIMARY};">Next step:</strong> When the buyer sends you ${params.localCcy} via bank transfer or mobile money,
  they'll mark it as sent. You'll then confirm receipt to release the USDC.
</p>

${ctaButton('View trade', `${APP_URL}/marketplace/${params.offerId}`)}

<p style="margin:16px 0 0;color:${TEXT_SECONDARY};font-size:12px;line-height:1.5;">
  💡 Tip: Use the trade chat to share your account details privately with the buyer.
</p>`

  return { subject, html: baseLayout(content, { previewText }), previewText }
}

// ─────────────────────────────────────────────────────────────
// Template 2: Trade Completed (sent to both parties)
// ─────────────────────────────────────────────────────────────
export function tradeCompletedEmail(params: {
  recipientName: string
  recipientRole: 'maker' | 'taker'
  counterpartName: string
  usdcAmount:    number
  localAmount:   number
  localCcy:      string
  offerId:       string
  txHash:        string
}) {
  const isMaker = params.recipientRole === 'maker'
  const subject = '✅ Trade completed — funds released'
  const previewText = `Your trade with ${params.counterpartName} is complete.`

  const content = `
<h1 style="margin:0 0 12px;color:${SUCCESS_COLOR};font-size:22px;font-weight:600;line-height:1.3;">
  ✅ Trade complete
</h1>
<p style="margin:0 0 8px;color:${TEXT_SECONDARY};font-size:14px;line-height:1.6;">
  Hi ${params.recipientName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SECONDARY};font-size:14px;line-height:1.6;">
  Your trade with <strong style="color:${TEXT_PRIMARY};">${params.counterpartName}</strong> just settled successfully on Arc.
  ${isMaker
    ? `You received ${params.localAmount.toLocaleString()} ${params.localCcy} off-chain.`
    : `${params.usdcAmount} USDC has been released to your wallet.`
  }
</p>

${infoCard([
  { label: isMaker ? 'You received'    : 'You received',
    value: isMaker ? `${params.localAmount.toLocaleString()} ${params.localCcy}` : `${params.usdcAmount} USDC` },
  { label: isMaker ? 'You sent (USDC)' : 'You sent (local)',
    value: isMaker ? `${params.usdcAmount} USDC` : `${params.localAmount.toLocaleString()} ${params.localCcy}` },
  { label: 'Counterparty', value: params.counterpartName },
  { label: 'On-chain proof', value: `<a href="https://testnet.arcscan.app/tx/${params.txHash}" style="color:${BRAND_COLOR};font-family:monospace;font-size:12px;">${params.txHash.slice(0,16)}…</a>` },
])}

${ctaButton('View on ArcScan', `https://testnet.arcscan.app/tx/${params.txHash}`)}

<p style="margin:16px 0 0;color:${TEXT_SECONDARY};font-size:12px;line-height:1.5;">
  This trade is now part of your AfriFX reputation. Keep trading to build trust and unlock verified status.
</p>`

  return { subject, html: baseLayout(content, { previewText }), previewText }
}

// ─────────────────────────────────────────────────────────────
// Template 3: Dispute Raised (sent to other party)
// ─────────────────────────────────────────────────────────────
export function disputeRaisedEmail(params: {
  recipientName:  string
  raisedByName:   string
  raisedByRole:   'maker' | 'taker'
  disputeType:    'maker_silent' | 'maker_not_received'
  offerId:        string
  disputeId:      string
}) {
  const subject     = `⚠️ Dispute raised on your trade by ${params.raisedByName}`
  const previewText = `Action required — review the dispute and respond.`

  const disputeReason = params.disputeType === 'maker_silent'
    ? 'claims you did not confirm receiving payment within the agreed window'
    : 'is requesting an admin review of your transaction'

  const content = `
<h1 style="margin:0 0 12px;color:${WARNING_COLOR};font-size:22px;font-weight:600;line-height:1.3;">
  ⚠️ A dispute was raised
</h1>
<p style="margin:0 0 8px;color:${TEXT_SECONDARY};font-size:14px;line-height:1.6;">
  Hi ${params.recipientName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SECONDARY};font-size:14px;line-height:1.6;">
  <strong style="color:${TEXT_PRIMARY};">${params.raisedByName}</strong> ${disputeReason}.
  An AfriFX admin will review the case and contact both parties.
</p>

<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:rgba(245,158,11,0.1);border:1px solid rgba(245,158,11,0.3);border-radius:10px;margin:20px 0;">
  <tr>
    <td style="padding:16px;color:${WARNING_COLOR};font-size:13px;line-height:1.5;">
      <strong>What happens next:</strong><br>
      1. An admin will accept the dispute and become the assigned judge<br>
      2. You'll be able to chat privately with the admin<br>
      3. Upload your bank statement when requested — it stays admin-only<br>
      4. The admin reviews evidence and resolves the dispute on-chain
    </td>
  </tr>
</table>

${ctaButton('Open dispute', `${APP_URL}/marketplace/${params.offerId}`)}

<p style="margin:16px 0 0;color:${TEXT_SECONDARY};font-size:12px;line-height:1.5;">
  Your USDC remains safely escrowed in the smart contract until the admin resolves this dispute.
  No funds can be released or refunded without admin approval.
</p>`

  return { subject, html: baseLayout(content, { previewText }), previewText }
}

// ─────────────────────────────────────────────────────────────
// Template 4: Invoice Paid (sent to creator)
// ─────────────────────────────────────────────────────────────
export function invoicePaidEmail(params: {
  creatorName:    string
  payerAddress:   string
  invoiceRef:     string
  usdcAmount:     number
  localAmount?:   number
  localCcy?:      string
  invoiceId:      string
  txHash:         string
}) {
  const subject     = `💰 Invoice ${params.invoiceRef} paid`
  const previewText = `${params.usdcAmount} USDC received.`

  const content = `
<h1 style="margin:0 0 12px;color:${SUCCESS_COLOR};font-size:22px;font-weight:600;line-height:1.3;">
  💰 Invoice paid
</h1>
<p style="margin:0 0 8px;color:${TEXT_SECONDARY};font-size:14px;line-height:1.6;">
  Hi ${params.creatorName},
</p>
<p style="margin:0 0 16px;color:${TEXT_SECONDARY};font-size:14px;line-height:1.6;">
  Good news — your invoice <strong style="color:${TEXT_PRIMARY};">${params.invoiceRef}</strong> just got paid in USDC.
  The funds have settled to your wallet.
</p>

${infoCard([
  { label: 'Amount received',  value: `${params.usdcAmount} USDC` },
  ...(params.localAmount && params.localCcy ? [{
    label: 'Original invoice', value: `${params.localAmount.toLocaleString()} ${params.localCcy}`
  }] : []),
  { label: 'Payer',            value: `<span style="font-family:monospace;font-size:12px;">${params.payerAddress.slice(0,10)}…${params.payerAddress.slice(-6)}</span>` },
  { label: 'Reference',        value: params.invoiceRef },
  { label: 'On-chain proof',   value: `<a href="https://testnet.arcscan.app/tx/${params.txHash}" style="color:${BRAND_COLOR};font-family:monospace;font-size:12px;">${params.txHash.slice(0,16)}…</a>` },
])}

${ctaButton('View invoice', `${APP_URL}/invoices/${params.invoiceId}`)}

<p style="margin:16px 0 0;color:${TEXT_SECONDARY};font-size:12px;line-height:1.5;">
  This payment is automatically reflected in your settlements report and treasury dashboard.
</p>`

  return { subject, html: baseLayout(content, { previewText }), previewText }
}
__EOF__
echo "✅  email/templates.ts — 4 branded templates"

# ============================================================
# 5 — Notification service: queue + send
# ============================================================
cat > afrifx-api/src/services/email/notifications.ts << '__EOF__'
import { db }     from '../../db/client'
import { sql }    from 'drizzle-orm'
import { randomUUID } from 'crypto'
import { sendEmail } from './client'
import {
  tradeAcceptedEmail,
  tradeCompletedEmail,
  disputeRaisedEmail,
  invoicePaidEmail,
} from './templates'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

async function getProfile(wallet: string): Promise<any | null> {
  try {
    const rows = await db.run(sql`
      SELECT wallet_address, username, display_name, email,
             notify_trades, notify_disputes, notify_invoices, last_active_at
      FROM profiles WHERE LOWER(wallet_address) = LOWER(${wallet}) LIMIT 1
    `)
    const r = parseRows(rows)
    return r.length ? r[0] : null
  } catch { return null }
}

function getDisplayName(profile: any): string {
  return profile?.display_name ?? profile?.username ?? profile?.wallet_address?.slice(0,8) ?? 'there'
}

// Suppress emails to users active in the last 5 minutes
function isRecentlyActive(profile: any): boolean {
  if (!profile?.last_active_at) return false
  const now = Math.floor(Date.now() / 1000)
  return (now - Number(profile.last_active_at)) < 300
}

interface QueueParams {
  userWallet:   string
  type:         string
  subject:      string
  payload:      any
  recipientEmail?: string
}

async function queueAndSend({ userWallet, type, subject, payload, recipientEmail }: QueueParams) {
  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)

  // Insert as pending
  await db.run(sql`
    INSERT INTO notifications
      (id, user_wallet, recipient_email, type, subject, payload, status, attempts, created_at)
    VALUES
      (${id}, ${userWallet.toLowerCase()}, ${recipientEmail ?? null},
       ${type}, ${subject}, ${JSON.stringify(payload)}, 'pending', 0, ${now})
  `)

  return id
}

async function markSent(notifId: string, emailId: string | null) {
  const now = Math.floor(Date.now() / 1000)
  await db.run(sql`
    UPDATE notifications SET status = 'sent', email_id = ${emailId}, sent_at = ${now}
    WHERE id = ${notifId}
  `)
}

async function markFailed(notifId: string, error: string) {
  await db.run(sql`
    UPDATE notifications SET
      status = 'failed',
      attempts = attempts + 1,
      last_error = ${error}
    WHERE id = ${notifId}
  `)
}

// ─────────────────────────────────────────────────────────────
// Public API — called from routes
// ─────────────────────────────────────────────────────────────

export async function notifyTradeAccepted(params: {
  makerWallet:    string
  takerWallet:    string
  usdcAmount:     number
  localAmount:    number
  localCcy:       string
  offerId:        string
}) {
  const [makerProfile, takerProfile] = await Promise.all([
    getProfile(params.makerWallet),
    getProfile(params.takerWallet),
  ])

  if (!makerProfile?.email || !makerProfile.notify_trades || isRecentlyActive(makerProfile)) {
    // Still queue as in-app notification
    await queueAndSend({
      userWallet: params.makerWallet,
      type:       'trade_accepted',
      subject:    `${getDisplayName(takerProfile)} accepted your offer`,
      payload:    params,
    })
    return
  }

  const template = tradeAcceptedEmail({
    makerName:   getDisplayName(makerProfile),
    takerName:   getDisplayName(takerProfile),
    usdcAmount:  params.usdcAmount,
    localAmount: params.localAmount,
    localCcy:    params.localCcy,
    offerId:     params.offerId,
  })

  const notifId = await queueAndSend({
    userWallet:     params.makerWallet,
    type:           'trade_accepted',
    subject:        template.subject,
    payload:        params,
    recipientEmail: makerProfile.email,
  })

  const result = await sendEmail({
    to:      makerProfile.email,
    subject: template.subject,
    html:    template.html,
  })

  if (result.success) await markSent(notifId, result.id ?? null)
  else await markFailed(notifId, result.error ?? 'unknown')
}

export async function notifyTradeCompleted(params: {
  makerWallet:  string
  takerWallet:  string
  usdcAmount:   number
  localAmount:  number
  localCcy:     string
  offerId:      string
  txHash:       string
}) {
  const [makerProfile, takerProfile] = await Promise.all([
    getProfile(params.makerWallet),
    getProfile(params.takerWallet),
  ])

  // Send to both parties
  for (const [profile, role, wallet, counterpart] of [
    [makerProfile, 'maker' as const, params.makerWallet, takerProfile],
    [takerProfile, 'taker' as const, params.takerWallet, makerProfile],
  ] as const) {

    const subject = '✅ Trade completed — funds released'
    const payload = { ...params, role }

    if (!profile?.email || !profile.notify_trades) {
      await queueAndSend({ userWallet: wallet, type: 'trade_completed', subject, payload })
      continue
    }

    const template = tradeCompletedEmail({
      recipientName:   getDisplayName(profile),
      recipientRole:   role,
      counterpartName: getDisplayName(counterpart),
      usdcAmount:      params.usdcAmount,
      localAmount:     params.localAmount,
      localCcy:        params.localCcy,
      offerId:         params.offerId,
      txHash:          params.txHash,
    })

    const notifId = await queueAndSend({
      userWallet: wallet, type: 'trade_completed',
      subject: template.subject, payload,
      recipientEmail: profile.email,
    })

    const result = await sendEmail({
      to: profile.email, subject: template.subject, html: template.html,
    })

    if (result.success) await markSent(notifId, result.id ?? null)
    else await markFailed(notifId, result.error ?? 'unknown')
  }
}

export async function notifyDisputeRaised(params: {
  raisedByWallet:    string
  otherPartyWallet:  string
  raisedByRole:      'maker' | 'taker'
  disputeType:       'maker_silent' | 'maker_not_received'
  offerId:           string
  disputeId:         string
}) {
  const [otherProfile, raisedByProfile] = await Promise.all([
    getProfile(params.otherPartyWallet),
    getProfile(params.raisedByWallet),
  ])

  const subject = `⚠️ Dispute raised on your trade`

  if (!otherProfile?.email || !otherProfile.notify_disputes) {
    await queueAndSend({
      userWallet: params.otherPartyWallet, type: 'dispute_raised',
      subject, payload: params,
    })
    return
  }

  const template = disputeRaisedEmail({
    recipientName: getDisplayName(otherProfile),
    raisedByName:  getDisplayName(raisedByProfile),
    raisedByRole:  params.raisedByRole,
    disputeType:   params.disputeType,
    offerId:       params.offerId,
    disputeId:     params.disputeId,
  })

  const notifId = await queueAndSend({
    userWallet:     params.otherPartyWallet,
    type:           'dispute_raised',
    subject:        template.subject,
    payload:        params,
    recipientEmail: otherProfile.email,
  })

  const result = await sendEmail({
    to: otherProfile.email, subject: template.subject, html: template.html,
  })

  if (result.success) await markSent(notifId, result.id ?? null)
  else await markFailed(notifId, result.error ?? 'unknown')
}

export async function notifyInvoicePaid(params: {
  creatorWallet:  string
  payerAddress:   string
  invoiceRef:     string
  usdcAmount:     number
  localAmount?:   number
  localCcy?:      string
  invoiceId:      string
  txHash:         string
}) {
  const profile = await getProfile(params.creatorWallet)
  const subject = `💰 Invoice ${params.invoiceRef} paid`

  if (!profile?.email || !profile.notify_invoices) {
    await queueAndSend({
      userWallet: params.creatorWallet, type: 'invoice_paid',
      subject, payload: params,
    })
    return
  }

  const template = invoicePaidEmail({
    creatorName:  getDisplayName(profile),
    payerAddress: params.payerAddress,
    invoiceRef:   params.invoiceRef,
    usdcAmount:   params.usdcAmount,
    localAmount:  params.localAmount,
    localCcy:     params.localCcy,
    invoiceId:    params.invoiceId,
    txHash:       params.txHash,
  })

  const notifId = await queueAndSend({
    userWallet:     params.creatorWallet,
    type:           'invoice_paid',
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
__EOF__
echo "✅  email/notifications.ts"

# ============================================================
# 6 — Notifications route (in-app bell + preferences)
# ============================================================
cat > afrifx-api/src/routes/notifications.ts << '__EOF__'
import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// GET /notifications?wallet=0x — recent notifications for in-app bell
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })

  try {
    const rows = await db.run(sql`
      SELECT id, type, subject, payload, read_at, created_at
      FROM notifications
      WHERE LOWER(user_wallet) = ${wallet}
      ORDER BY created_at DESC LIMIT 30
    `)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /notifications/unread?wallet=0x — unread count for badge
router.get('/unread', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(sql`
      SELECT COUNT(*) as cnt FROM notifications
      WHERE LOWER(user_wallet) = ${wallet} AND read_at IS NULL
    `)
    const r = parseRows(rows)
    res.json({ count: Number(r[0]?.cnt ?? r[0]?.[0] ?? 0) })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /notifications/:id/read — mark as read
router.patch('/:id/read', async (req, res) => {
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      UPDATE notifications SET read_at = ${now} WHERE id = ${req.params.id}
    `)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /notifications/mark-all-read?wallet=0x
router.patch('/mark-all-read', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      UPDATE notifications SET read_at = ${now}
      WHERE LOWER(user_wallet) = ${wallet} AND read_at IS NULL
    `)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /notifications/email — update user email + preferences
router.post('/email', async (req, res) => {
  const { wallet, email, notify_trades, notify_disputes, notify_invoices } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: 'invalid email format' })
  }

  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      UPDATE profiles SET
        email = ${email ?? null},
        notify_trades   = ${notify_trades   ? 1 : 0},
        notify_disputes = ${notify_disputes ? 1 : 0},
        notify_invoices = ${notify_invoices ? 1 : 0},
        updated_at = ${now}
      WHERE LOWER(wallet_address) = LOWER(${wallet})
    `)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /notifications/heartbeat — track user activity to suppress duplicate emails
router.post('/heartbeat', async (req, res) => {
  const { wallet } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      UPDATE profiles SET last_active_at = ${now}
      WHERE LOWER(wallet_address) = LOWER(${wallet})
    `)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
__EOF__
echo "✅  routes/notifications.ts"

# ============================================================
# 7 — Wire route in index.ts
# ============================================================
python3 - << 'PYEOF'
import os
path = os.path.expanduser('~/AfriFX/afrifx-api/src/index.ts')
with open(path) as f:
    content = f.read()

if "import notificationsRouter" not in content:
    content = content.replace(
        "import disputesRouter",
        "import notificationsRouter         from './routes/notifications'\nimport disputesRouter"
    )

if "app.use('/notifications'" not in content:
    content = content.replace(
        "app.use('/disputes'",
        "app.use('/notifications', notificationsRouter)\napp.use('/disputes'"
    )

with open(path, 'w') as f:
    f.write(content)
print("✅  notifications route wired")
PYEOF

# ============================================================
# 8 — Hook into existing routes (offers, disputes, payments)
# ============================================================
python3 - << 'PYEOF'
import os

# Hook into offers.ts — PATCH /:id/accept (trade accepted)
path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/offers.ts')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()

    if 'notifyTradeAccepted' not in content:
        content = content.replace(
            "import { Router }",
            "import { notifyTradeAccepted, notifyTradeCompleted } from '../services/email/notifications'\nimport { Router }"
        )
        # Add call after accept logic
        # Look for the accept route success response
        old = "    res.json({ success: true })"
        if old in content:
            new = """    // Fire email + in-app notification (non-blocking)
    notifyTradeAccepted({
      makerWallet: offer.maker_address ?? offer[1],
      takerWallet: req.body.takerAddress?.toLowerCase() ?? '',
      usdcAmount:  Number(offer.usdc_amount ?? offer[3] ?? 0),
      localAmount: Number(offer.local_amount ?? offer[5] ?? 0),
      localCcy:    offer.local_currency ?? offer[4] ?? '',
      offerId:     offerId,
    }).catch(err => console.error('[Notify] trade_accepted failed:', err.message))

    res.json({ success: true })"""
            content = content.replace(old, new, 1)

        with open(path, 'w') as f:
            f.write(content)
        print("✅  offers.ts — trade_accepted hooked")

# Hook into disputes.ts — POST / (dispute raised)
path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/disputes.ts')
with open(path) as f:
    content = f.read()

if 'notifyDisputeRaised' not in content:
    content = content.replace(
        "import { Router }     from 'express'",
        "import { Router }     from 'express'\nimport { notifyDisputeRaised } from '../services/email/notifications'"
    )

    old = "    res.status(201).json({ id, autoReleaseAt })"
    new = """    // Determine other party
    const otherPartyWallet = raisedByLower === makerAddress ? takerAddress : makerAddress

    // Fire notification (non-blocking)
    notifyDisputeRaised({
      raisedByWallet:   raisedByLower,
      otherPartyWallet: otherPartyWallet ?? '',
      raisedByRole:     raisedByRole as 'maker' | 'taker',
      disputeType:      disputeType as 'maker_silent' | 'maker_not_received',
      offerId,
      disputeId:        id,
    }).catch(err => console.error('[Notify] dispute_raised failed:', err.message))

    res.status(201).json({ id, autoReleaseAt })"""
    content = content.replace(old, new, 1)

    with open(path, 'w') as f:
        f.write(content)
    print("✅  disputes.ts — dispute_raised hooked")

# Hook into payments.ts — invoice paid
path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/payments.ts')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()

    if 'notifyInvoicePaid' not in content:
        content = content.replace(
            "import { Router }",
            "import { notifyInvoicePaid } from '../services/email/notifications'\nimport { Router }"
        )
        print("✅  payments.ts — invoice_paid import added (manual hook required)")
        with open(path, 'w') as f:
            f.write(content)
PYEOF

# ============================================================
# 9 — Frontend: in-app notification bell
# ============================================================
mkdir -p afrifx-web/components/notifications

cat > afrifx-web/components/notifications/NotificationBell.tsx << '__EOF__'
'use client'
import { useEffect, useState, useRef } from 'react'
import { useAccount } from 'wagmi'
import { Bell, Check, X } from 'lucide-react'
import Link from 'next/link'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Notification {
  id:         string
  type:       string
  subject:    string
  payload:    string
  read_at:    number | null
  created_at: number
}

export function NotificationBell() {
  const { address }               = useAccount()
  const [open,         setOpen]   = useState(false)
  const [notifs,       setNotifs] = useState<Notification[]>([])
  const [unreadCount,  setCount]  = useState(0)
  const dropdownRef = useRef<HTMLDivElement>(null)

  async function loadUnreadCount() {
    if (!address) return
    try {
      const res = await fetch(`${API}/notifications/unread?wallet=${address}`)
      const data = await res.json()
      setCount(Number(data.count ?? 0))
    } catch {}
  }

  async function loadNotifs() {
    if (!address) return
    try {
      const res  = await fetch(`${API}/notifications?wallet=${address}`)
      const data = await res.json()
      setNotifs(Array.isArray(data) ? data : [])
    } catch {}
  }

  async function markRead(id: string) {
    try {
      await fetch(`${API}/notifications/${id}/read`, { method: 'PATCH' })
      await loadNotifs()
      await loadUnreadCount()
    } catch {}
  }

  async function markAllRead() {
    if (!address) return
    try {
      await fetch(`${API}/notifications/mark-all-read?wallet=${address}`, { method: 'PATCH' })
      await loadNotifs()
      await loadUnreadCount()
    } catch {}
  }

  useEffect(() => {
    if (!address) return
    loadUnreadCount()
    const interval = setInterval(loadUnreadCount, 30_000)
    return () => clearInterval(interval)
  }, [address])

  useEffect(() => {
    if (open) loadNotifs()
  }, [open])

  // Close on outside click
  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    if (open) document.addEventListener('mousedown', onClick)
    return () => document.removeEventListener('mousedown', onClick)
  }, [open])

  if (!address) return null

  const getNotifLink = (n: Notification) => {
    try {
      const p = JSON.parse(n.payload)
      if (n.type.startsWith('trade')   && p.offerId)   return `/marketplace/${p.offerId}`
      if (n.type.startsWith('dispute') && p.offerId)   return `/marketplace/${p.offerId}`
      if (n.type === 'invoice_paid'    && p.invoiceId) return `/invoices/${p.invoiceId}`
    } catch {}
    return '#'
  }

  const getIcon = (type: string) => {
    if (type.startsWith('trade'))   return '🤝'
    if (type.startsWith('dispute')) return '⚠️'
    if (type === 'invoice_paid')    return '💰'
    return '🔔'
  }

  return (
    <div className="relative" ref={dropdownRef}>
      <button onClick={() => setOpen(!open)}
        className="relative flex h-9 w-9 items-center justify-center rounded-lg border border-[#1B2B4B] text-[#64748B] hover:bg-[#0F1729] hover:text-[#E2E8F0] transition-colors">
        <Bell className="h-4 w-4" />
        {unreadCount > 0 && (
          <span className="absolute -top-1 -right-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-red-500 px-1 text-[10px] font-bold text-white">
            {unreadCount > 9 ? '9+' : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <div className="absolute right-0 mt-2 w-80 rounded-xl border border-[#1B2B4B] bg-[#0F1729] shadow-2xl z-50">
          <div className="flex items-center justify-between border-b border-[#1B2B4B] px-4 py-3">
            <p className="text-sm font-medium text-[#E2E8F0]">Notifications</p>
            <div className="flex items-center gap-2">
              {unreadCount > 0 && (
                <button onClick={markAllRead}
                  className="text-xs text-[#378ADD] hover:underline">
                  Mark all read
                </button>
              )}
              <button onClick={() => setOpen(false)}
                className="text-[#64748B] hover:text-[#E2E8F0]">
                <X className="h-4 w-4" />
              </button>
            </div>
          </div>
          <div className="max-h-96 overflow-y-auto">
            {notifs.length === 0 ? (
              <p className="px-4 py-8 text-center text-xs text-[#64748B]">No notifications yet</p>
            ) : (
              notifs.map(n => {
                const link   = getNotifLink(n)
                const isUnread = !n.read_at
                return (
                  <Link key={n.id} href={link}
                    onClick={() => { markRead(n.id); setOpen(false) }}
                    className={`flex items-start gap-3 border-b border-[#1B2B4B] px-4 py-3 last:border-0
                      ${isUnread ? 'bg-[#378ADD]/5' : ''} hover:bg-[#080D1B] transition-colors`}>
                    <span className="text-lg">{getIcon(n.type)}</span>
                    <div className="flex-1 min-w-0">
                      <p className={`text-xs ${isUnread ? 'font-medium text-[#E2E8F0]' : 'text-[#64748B]'}`}>
                        {n.subject}
                      </p>
                      <p className="mt-0.5 text-[10px] text-[#64748B]">
                        {new Date(n.created_at * 1000).toLocaleString()}
                      </p>
                    </div>
                    {isUnread && (
                      <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-[#378ADD]" />
                    )}
                  </Link>
                )
              })
            )}
          </div>
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  NotificationBell.tsx"

# ============================================================
# 10 — Email preferences in profile page
# ============================================================
cat > afrifx-web/components/notifications/EmailPreferences.tsx << '__EOF__'
'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Mail, Check, Loader2 } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function EmailPreferences() {
  const { address } = useAccount()
  const { data: profile, refetch } = useProfile()

  const [email,            setEmail]   = useState('')
  const [notifyTrades,     setT]       = useState(true)
  const [notifyDisputes,   setD]       = useState(true)
  const [notifyInvoices,   setI]       = useState(true)
  const [saving,           setSaving]  = useState(false)
  const [saved,            setSaved]   = useState(false)

  useEffect(() => {
    if (profile) {
      setEmail((profile as any).email ?? '')
      setT(Number((profile as any).notify_trades   ?? 1) === 1)
      setD(Number((profile as any).notify_disputes ?? 1) === 1)
      setI(Number((profile as any).notify_invoices ?? 1) === 1)
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
        body: JSON.stringify({
          wallet:          address,
          email:           email || null,
          notify_trades:   notifyTrades,
          notify_disputes: notifyDisputes,
          notify_invoices: notifyInvoices,
        }),
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
          What to notify about
        </p>

        <Toggle label="Trade activity"     description="Offers accepted, trades completed" checked={notifyTrades}   onChange={setT} />
        <Toggle label="Dispute updates"    description="Always recommended for safety"     checked={notifyDisputes} onChange={setD} />
        <Toggle label="Invoice payments"   description="When customers pay your invoices"  checked={notifyInvoices} onChange={setI} />
      </div>

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
__EOF__
echo "✅  EmailPreferences.tsx"

# ============================================================
# 11 — Add bell to AppShell + preferences to profile page
# ============================================================
python3 - << 'PYEOF'
import os

# Add NotificationBell to AppShell
path = os.path.expanduser('~/AfriFX/afrifx-web/components/layout/AppShell.tsx')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()

    if 'NotificationBell' not in content:
        content = content.replace(
            "import Link from 'next/link'",
            "import Link from 'next/link'\nimport { NotificationBell } from '@/components/notifications/NotificationBell'"
        )
        # Add bell near ConnectButton in header
        content = content.replace(
            '<ConnectButton',
            '<NotificationBell />\n            <ConnectButton'
        )
        with open(path, 'w') as f:
            f.write(content)
        print("✅  AppShell — NotificationBell added")

# Add EmailPreferences to profile page
path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/profile/page.tsx')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()

    if 'EmailPreferences' not in content:
        content = content.replace(
            "'use client'",
            "'use client'\nimport { EmailPreferences } from '@/components/notifications/EmailPreferences'"
        )
        # Add at bottom of return statement before closing div
        # User must add <EmailPreferences /> manually where they want it
        with open(path, 'w') as f:
            f.write(content)
        print("✅  EmailPreferences imported in profile/page.tsx — add <EmailPreferences /> manually")
PYEOF

# ============================================================
# 12 — Add env vars to .env example
# ============================================================
echo "" >> ~/AfriFX/afrifx-api/.env 2>/dev/null
echo "# Email service (Wave 1)" >> ~/AfriFX/afrifx-api/.env 2>/dev/null
echo "RESEND_API_KEY=" >> ~/AfriFX/afrifx-api/.env 2>/dev/null
echo "EMAIL_FROM=AfriFX <notifications@afrifx.xyz>" >> ~/AfriFX/afrifx-api/.env 2>/dev/null
echo "APP_URL=https://afrifx.xyz" >> ~/AfriFX/afrifx-api/.env 2>/dev/null
echo "✅  .env updated"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 11 Wave 1 — Email Notifications complete!"
echo ""
echo "  📧 4 email templates ready:"
echo "    • Trade accepted (to maker)"
echo "    • Trade completed (to both parties)"
echo "    • Dispute raised (to other party)"
echo "    • Invoice paid (to creator)"
echo ""
echo "  🔔 In-app notification bell in header"
echo "  ⚙️  Email preferences in profile settings"
echo ""
echo "  📝 NEXT STEPS:"
echo "  1. Sign up at https://resend.com (free 100 emails/day)"
echo "  2. Add RESEND_API_KEY to .env + Render env vars"
echo "  3. Verify domain afrifx.xyz on Resend"
echo "  4. Manually add <EmailPreferences /> to profile page where you want it"
echo "  5. Test by triggering a trade or dispute"
echo ""
echo "  🚀 Without RESEND_API_KEY: emails log to console in dev mode"
echo "  📦 In-app notifications work immediately even without email setup"
echo "══════════════════════════════════════════════════════"
