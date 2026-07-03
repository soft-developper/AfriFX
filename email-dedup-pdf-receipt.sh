#!/bin/bash
# ============================================================
# AfriFX -- Email fixes: de-duplicate trade emails + PDF receipts
#
# TWO fixes, both backend-only:
#
# 1) DUPLICATE / NAMELESS ACCEPT EMAILS
#    PATCH /offers/:id fired the "trade accepted" email on EVERY call,
#    so the taker-confirm and maker-confirm steps (which hit the same
#    endpoint without a takerAddress) re-sent it -- producing extra
#    emails, some with a blank taker name. It now sends that email ONLY
#    on the real accept transition (status -> 'accepted' WITH a taker),
#    so the maker gets exactly ONE email, naming the taker.
#
# 2) RECEIPT AS A PDF ATTACHMENT (not a separate email)
#    Trade completion and invoice payment used to send a SEPARATE
#    "receipt" email. The receipt is now generated as a PDF and attached
#    to the completion / invoice-paid email, and the separate receipt
#    email is removed. New: src/services/email/receipt-pdf.ts (pdfkit).
#    sendEmail() gained attachment support.
#
# Adds a dependency: pdfkit (+ @types/pdfkit). The script installs it.
#
# Run from ~/AfriFX:  bash email-dedup-pdf-receipt.sh
# ============================================================
set -e
echo ""
echo "Applying email de-dup + PDF receipt fixes..."
echo ""

# Install the PDF library (regenerates package-lock.json)
echo "Installing pdfkit..."
( cd afrifx-api && npm install pdfkit && npm install --save-dev @types/pdfkit )
echo ""

mkdir -p "afrifx-api/src/services/email"
cat > "afrifx-api/src/services/email/receipt-pdf.ts" << 'AFX_EOF'
import PDFDocument from 'pdfkit'

export interface ReceiptData {
  title:           string          // e.g. 'Trade Receipt' | 'Payment Receipt'
  recipientName:   string
  recipientRole:   string          // 'Buyer' | 'Seller' | 'Sender' | 'Receiver'
  counterpartName: string
  usdcAmount:      number
  localAmount?:    number
  localCcy?:       string
  reference:       string
  txHash:          string
  timestamp:       number          // unix seconds
  type:            'trade' | 'invoice'
}

// Brand colors (kept literal — PDF is theme-independent)
const GOLD  = '#8A5E13'
const INK   = '#2B2416'
const MUTED = '#6B5F49'
const LINE  = '#E4D9C4'

// Render the receipt to a PDF and return it as a Buffer.
export function generateReceiptPdf(data: ReceiptData): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    try {
      const doc = new PDFDocument({ size: 'A4', margin: 50 })
      const chunks: Buffer[] = []
      doc.on('data', (c: Buffer) => chunks.push(c))
      doc.on('end', () => resolve(Buffer.concat(chunks)))
      doc.on('error', reject)

      // ── Header ──────────────────────────────────────────────
      doc.fillColor(GOLD).fontSize(22).font('Helvetica-Bold').text('AfriFX', 50, 50)
      doc.fillColor(MUTED).fontSize(9).font('Helvetica')
        .text('Stablecoin FX & cross-border payments on Arc', 50, 76)

      doc.fillColor(INK).fontSize(16).font('Helvetica-Bold')
        .text(data.title, 50, 110)
      doc.fillColor(MUTED).fontSize(9).font('Helvetica')
        .text(`Issued ${new Date(data.timestamp * 1000).toUTCString()}`, 50, 132)

      // Divider
      doc.moveTo(50, 155).lineTo(545, 155).strokeColor(LINE).lineWidth(1).stroke()

      // ── Body rows ───────────────────────────────────────────
      let y = 175
      const row = (label: string, value: string) => {
        doc.fillColor(MUTED).fontSize(10).font('Helvetica').text(label, 50, y)
        doc.fillColor(INK).fontSize(10).font('Helvetica-Bold')
          .text(value, 220, y, { width: 325, align: 'right' })
        y += 26
      }

      row('Receipt for', `${data.recipientName} (${data.recipientRole})`)
      row('Counterparty', data.counterpartName)
      row('USDC amount', `${data.usdcAmount.toLocaleString(undefined, { maximumFractionDigits: 6 })} USDC`)
      if (data.localAmount && data.localCcy) {
        row('Local amount', `${data.localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })} ${data.localCcy}`)
      }
      row('Reference', data.reference)

      // Tx hash wraps, so give it its own block
      doc.fillColor(MUTED).fontSize(10).font('Helvetica').text('Transaction', 50, y)
      doc.fillColor(GOLD).fontSize(8).font('Courier')
        .text(data.txHash, 220, y, { width: 325, align: 'right' })
      y += 34

      // Divider
      doc.moveTo(50, y).lineTo(545, y).strokeColor(LINE).lineWidth(1).stroke()
      y += 20

      // ── Footer ──────────────────────────────────────────────
      doc.fillColor(MUTED).fontSize(8).font('Helvetica').text(
        'This receipt was generated automatically by AfriFX. The transaction is recorded on the Arc blockchain and can be verified at testnet.arcscan.app using the transaction hash above.',
        50, y, { width: 495, align: 'left' },
      )
      doc.fillColor(MUTED).fontSize(8)
        .text('© ' + new Date().getFullYear() + ' AfriFX', 50, y + 40, { align: 'center', width: 495 })

      doc.end()
    } catch (err) {
      reject(err)
    }
  })
}
AFX_EOF
echo "  afrifx-api/src/services/email/receipt-pdf.ts"

mkdir -p "afrifx-api/src/services/email"
cat > "afrifx-api/src/services/email/client.ts" << 'AFX_EOF'
import { Resend } from 'resend'

const RESEND_KEY = process.env.RESEND_API_KEY
const FROM_EMAIL = process.env.EMAIL_FROM ?? 'AfriFX <notifications@afrifx.xyz>'

if (!RESEND_KEY) {
  console.warn('[Email] RESEND_API_KEY not set — emails will be logged but not sent')
}

const resend = RESEND_KEY ? new Resend(RESEND_KEY) : null

export interface EmailAttachment {
  filename: string
  content:  Buffer | string   // Buffer or base64 string
}

export interface SendEmailParams {
  to:           string
  subject:      string
  html:         string
  attachments?: EmailAttachment[]
}

export async function sendEmail({ to, subject, html, attachments }: SendEmailParams) {
  if (!resend) {
    console.log(`[Email DEV MODE] To: ${to} | Subject: ${subject}${attachments?.length ? ` | ${attachments.length} attachment(s)` : ''}`)
    return { id: 'dev-mode', success: true }
  }

  try {
    const result = await resend.emails.send({
      from:    FROM_EMAIL,
      to:      [to],
      subject,
      html,
      ...(attachments?.length
        ? { attachments: attachments.map(a => ({ filename: a.filename, content: a.content })) }
        : {}),
    })
    return { id: result.data?.id, success: true, error: result.error }
  } catch (err: any) {
    console.error('[Email] Send failed:', err.message)
    return { id: null, success: false, error: err.message }
  }
}
AFX_EOF
echo "  afrifx-api/src/services/email/client.ts"

mkdir -p "afrifx-api/src/services/email"
cat > "afrifx-api/src/services/email/notifications.ts" << 'AFX_EOF'
import { db }     from '../../db/client'
import { sql }    from 'drizzle-orm'
import { randomUUID } from 'crypto'
import { sendEmail } from './client'
import { generateReceiptPdf } from './receipt-pdf'
import {
  tradeAcceptedEmail,
  tradeCompletedEmail,
  disputeRaisedEmail,
  invoicePaidEmail,
  welcomeEmail,
  adminDisputeAlertEmail,
  disputeAcceptedEmail,
  adminMessageEmail,
  invoiceReminderEmail,
  tradeAutoCancelledEmail,
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

    // Generate a PDF receipt and attach it to the completion email so the
    // user gets a single email with the receipt, rather than two separate ones.
    let attachments: { filename: string; content: Buffer }[] | undefined
    try {
      const pdf = await generateReceiptPdf({
        title:           'Trade Receipt',
        recipientName:   getDisplayName(profile),
        recipientRole:   role === 'maker' ? 'Seller' : 'Buyer',
        counterpartName: getDisplayName(counterpart),
        usdcAmount:      params.usdcAmount,
        localAmount:     params.localAmount,
        localCcy:        params.localCcy,
        reference:       params.offerId.slice(0, 16),
        txHash:          params.txHash,
        timestamp:       Math.floor(Date.now() / 1000),
        type:            'trade',
      })
      attachments = [{ filename: `afrifx-trade-receipt-${params.offerId.slice(0, 8)}.pdf`, content: pdf }]
    } catch (err: any) {
      console.error('[Notify] receipt PDF generation failed:', err.message)
    }

    const result = await sendEmail({
      to: profile.email, subject: template.subject, html: template.html,
      attachments,
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

  // Attach the receipt as a PDF (replaces the separate receipt email).
  let attachments: { filename: string; content: Buffer }[] | undefined
  try {
    const payerProfile = await getProfile(params.payerAddress)
    const pdf = await generateReceiptPdf({
      title:           'Payment Receipt',
      recipientName:   getDisplayName(profile),
      recipientRole:   'Receiver',
      counterpartName: getDisplayName(payerProfile),
      usdcAmount:      params.usdcAmount,
      localAmount:     params.localAmount,
      localCcy:        params.localCcy,
      reference:       params.invoiceRef,
      txHash:          params.txHash,
      timestamp:       Math.floor(Date.now() / 1000),
      type:            'invoice',
    })
    attachments = [{ filename: `afrifx-invoice-receipt-${params.invoiceRef}.pdf`, content: pdf }]
  } catch (err: any) {
    console.error('[Notify] invoice receipt PDF failed:', err.message)
  }

  const result = await sendEmail({
    to: profile.email, subject: template.subject, html: template.html,
    attachments,
  })

  if (result.success) await markSent(notifId, result.id ?? null)
  else await markFailed(notifId, result.error ?? 'unknown')

  // Also send the PAYER a PDF receipt (previously a separate text email).
  try {
    const payerProfile = await getProfile(params.payerAddress)
    if (payerProfile?.email && Number(payerProfile.notify_receipts ?? 1) !== 0) {
      const payerPdf = await generateReceiptPdf({
        title:           'Payment Receipt',
        recipientName:   getDisplayName(payerProfile),
        recipientRole:   'Sender',
        counterpartName: getDisplayName(profile),
        usdcAmount:      params.usdcAmount,
        localAmount:     params.localAmount,
        localCcy:        params.localCcy,
        reference:       params.invoiceRef,
        txHash:          params.txHash,
        timestamp:       Math.floor(Date.now() / 1000),
        type:            'invoice',
      })
      await sendEmail({
        to:      payerProfile.email,
        subject: `Receipt — invoice ${params.invoiceRef} paid`,
        html:    `<div style="font-family:sans-serif;line-height:1.5">
          <p>Hi ${getDisplayName(payerProfile)},</p>
          <p>Thanks for your payment of ${params.usdcAmount} USDC for invoice
          <strong>${params.invoiceRef}</strong>. Your receipt is attached as a PDF.</p>
          <p style="color:#6B5F49;font-size:13px">AfriFX · Stablecoin FX on Arc</p>
        </div>`,
        attachments: [{ filename: `afrifx-invoice-receipt-${params.invoiceRef}.pdf`, content: payerPdf }],
      })
    }
  } catch (err: any) {
    console.error('[Notify] payer receipt PDF failed:', err.message)
  }
}
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
AFX_EOF
echo "  afrifx-api/src/services/email/notifications.ts"

mkdir -p "afrifx-api/src/jobs"
cat > "afrifx-api/src/jobs/p2pReleaseWatcher.ts" << 'AFX_EOF'
// ============================================================
// P2P Release Watcher — 4 jobs:
// Job1: release when both confirmed (every 15s)
// Job2: auto-cancel when taker timer expires + taker NOT confirmed (every 60s)
// Job3: auto-release to taker after 24h when maker goes silent (every 5min)
// Job4: clean up released/cancelled trade chats (every 5min)
// ============================================================
import { db }               from '../db/client'
import { sql }              from 'drizzle-orm'
import { releasePlatform, cancelPlatform } from '../services/platformWallet'
import { notifyTradeCompleted, notifyTradeAutoCancelled } from '../services/email/notifications'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

async function releaseOffer(offerId: string, label: string) {
  console.log(`[P2PWatcher] ${label}: releasing ${offerId.slice(0,18)}…`)
  try {
    const hash = await releasePlatform(offerId as `0x${string}`)
    const now  = Math.floor(Date.now() / 1000)
    await db.run(sql`
      UPDATE p2p_offers SET
        status          = 'released',
        release_tx_hash = ${hash},
        updated_at      = ${now}
      WHERE id = ${offerId}
    `)
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`)
    console.log(`[P2PWatcher] ${label} released ✅ tx: ${hash}`)

    // Fetch offer details for email notification
    try {
      const offerRows = await db.run(sql`SELECT * FROM p2p_offers WHERE id = ${offerId} LIMIT 1`)
      const r = parseRows(offerRows)
      const o = r[0]
      if (o) {
        notifyTradeCompleted({
          makerWallet: o.maker_address ?? o[1] ?? '',
          takerWallet: o.taker_address ?? o[2] ?? '',
          usdcAmount:  Number(o.usdc_amount  ?? o[3]  ?? 0),
          localAmount: Number(o.local_amount  ?? o[5]  ?? 0),
          localCcy:    o.local_currency ?? o[4] ?? '',
          offerId,
          txHash:      hash,
        }).catch((err: any) => console.error('[Notify] trade_completed failed:', err.message))

        // The receipt is now attached as a PDF to the completion email above,
        // so we no longer send a separate receipt email per party.
      }
    } catch {}

    return true
  } catch (err: any) {
    console.error(`[P2PWatcher] ${label} release failed:`, err.message)
    return false
  }
}

async function cancelOffer(offerId: string, label: string) {
  console.log(`[P2PWatcher] ${label}: cancelling ${offerId.slice(0,18)}…`)
  try {
    const hash = await cancelPlatform(offerId as `0x${string}`, 'Taker timer expired — auto cancelled')
    const now  = Math.floor(Date.now() / 1000)
    await db.run(sql`
      UPDATE p2p_offers SET
        status     = 'cancelled',
        updated_at = ${now}
      WHERE id = ${offerId}
    `)
    console.log(`[P2PWatcher] ${label} cancelled ✅ tx: ${hash}`)

    // Notify both parties by email
    try {
      const oRows = await db.run(sql`
        SELECT maker_address, taker_address, usdc_amount
        FROM p2p_offers WHERE id = ${offerId} LIMIT 1
      `)
      const o = parseRows(oRows)[0]
      if (o) {
        notifyTradeAutoCancelled({
          makerWallet: o.maker_address ?? o[0] ?? '',
          takerWallet: o.taker_address ?? o[1] ?? null,
          usdcAmount:  Number(o.usdc_amount ?? o[2] ?? 0),
          offerId,
        }).catch((err: any) => console.error('[Notify] auto_cancelled:', err.message))
      }
    } catch {}

    return true
  } catch (err: any) {
    console.error(`[P2PWatcher] ${label} cancel failed:`, err.message)
    return false
  }
}

export function startP2PReleaseWatcher() {
  if (!process.env.PLATFORM_WALLET_PRIVATE_KEY) {
    console.warn('[P2PWatcher] PLATFORM_WALLET_PRIVATE_KEY not set — auto-release disabled')
    return
  }

  // ── Job1: Release when both confirmed (every 15s) ──────────
  setInterval(async () => {
    try {
      const rows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status          = 'accepted'
          AND maker_confirmed = 1
          AND taker_confirmed = 1
        LIMIT 5
      `)
      for (const r of parseRows(rows)) {
        await releaseOffer(r.id ?? r[0], 'Job1')
      }
    } catch (err: any) { console.error('[P2PWatcher] Job1 error:', err.message) }
  }, 15_000)

  // ── Job2: Auto-cancel when taker timer expires (every 60s) ─
  setInterval(async () => {
    const now = Math.floor(Date.now() / 1000)
    try {
      const rows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status          = 'accepted'
          AND taker_confirmed = 0
          AND taker_deadline  IS NOT NULL
          AND taker_deadline  < ${now}
        LIMIT 5
      `)
      for (const r of parseRows(rows)) {
        await cancelOffer(r.id ?? r[0], 'Job2')
      }
    } catch (err: any) { console.error('[P2PWatcher] Job2 error:', err.message) }
  }, 60_000)

  // ── Job3: Auto-release after 24h maker silence (every 5min) ─
  setInterval(async () => {
    const now    = Math.floor(Date.now() / 1000)
    const ago24h = now - 86400
    try {
      // Case B: no dispute raised but 24h+ since maker_deadline passed
      const silentRows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status          = 'accepted'
          AND taker_confirmed = 1
          AND maker_confirmed = 0
          AND dispute_raised  = 0
          AND maker_deadline  IS NOT NULL
          AND maker_deadline  < ${ago24h}
        LIMIT 5
      `)
      for (const r of parseRows(silentRows)) {
        const offerId = r.id ?? r[0]
        console.log(`[P2PWatcher] Job3B: 24h no action, auto-releasing: ${offerId.slice(0,18)}…`)
        await db.run(sql`
          UPDATE p2p_offers SET maker_confirmed = 1, updated_at = ${now}
          WHERE id = ${offerId}
        `)
      }
    } catch (err: any) { console.error('[P2PWatcher] Job3 error:', err.message) }
  }, 5 * 60_000)

  // ── Job4: Clean up released/cancelled chats (every 5min) ───
  setInterval(async () => {
    try {
      const rows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status IN ('released', 'cancelled')
        LIMIT 20
      `)
      for (const r of parseRows(rows)) {
        await db.run(sql`DELETE FROM messages WHERE offer_id = ${r.id ?? r[0]}`)
      }
    } catch (err: any) { console.error('[P2PWatcher] Job4 error:', err.message) }
  }, 5 * 60_000)

  console.log('[P2PWatcher] started — Job1:15s | Job2:60s | Job3:5min | Job4:5min')
}
AFX_EOF
echo "  afrifx-api/src/jobs/p2pReleaseWatcher.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/offers.ts" << 'AFX_EOF'
import { notifyTradeAccepted, notifyTradeCompleted } from '../services/email/notifications'
import { Router } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

// GET /offers — only OPEN offers visible to everyone
router.get('/', async (req, res) => {
  const currency = req.query.currency as string | undefined
  const type     = req.query.type     as string | undefined
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE status = 'open'
          ${currency ? sql`AND local_currency = ${currency}` : sql``}
          ${type     ? sql`AND order_type = ${type}`         : sql``}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/my?wallet=0x… — maker + taker see ALL their offers
router.get('/my', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE LOWER(maker_address) = ${wallet}
             OR LOWER(taker_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id — returns offer but frontend enforces access control
router.get('/:id', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!offers.length) return res.status(404).json({ error: 'Not found' })
    res.json(offers[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers — create new offer
router.post('/', async (req, res) => {
  const {
    id, makerAddress, usdcAmount, localCurrency, localAmount,
    rateOffered, orderType, limitRate, makerTimerSeconds, arcTxHash,
  } = req.body
  const now      = Math.floor(Date.now() / 1000)
  const PERPETUAL = 9999999999
  try {
    await db.run(
      sql`INSERT OR IGNORE INTO p2p_offers
          (id, maker_address, usdc_amount, local_currency, local_amount,
           rate_offered, order_type, limit_rate, maker_timer_seconds,
           arc_tx_hash, expires_at, created_at, updated_at)
          VALUES
          (${id}, ${makerAddress.toLowerCase()}, ${usdcAmount},
           ${localCurrency}, ${localAmount}, ${rateOffered},
           ${orderType ?? 'market'}, ${limitRate ?? null},
           ${makerTimerSeconds ?? 1800}, ${arcTxHash ?? null},
           ${PERPETUAL}, ${now}, ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) {
    console.error('[Offers] Insert error:', err.message)
    res.status(500).json({ error: err.message })
  }
})

// PATCH /offers/:id
router.patch('/:id', async (req, res) => {
  const {
    status, takerAddress, makerConfirmed, takerConfirmed,
    releaseTxHash, takerDeadline, makerDeadline,
    disputeRaised, disputeId,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE p2p_offers SET
            status          = COALESCE(${status         ?? null}, status),
            taker_address   = COALESCE(${takerAddress   ? takerAddress.toLowerCase() : null}, taker_address),
            maker_confirmed = COALESCE(${makerConfirmed ?? null}, maker_confirmed),
            taker_confirmed = COALESCE(${takerConfirmed ?? null}, taker_confirmed),
            release_tx_hash = COALESCE(${releaseTxHash  ?? null}, release_tx_hash),
            taker_deadline  = COALESCE(${takerDeadline  ?? null}, taker_deadline),
            maker_deadline  = COALESCE(${makerDeadline  ?? null}, maker_deadline),
            dispute_raised  = COALESCE(${disputeRaised  ?? null}, dispute_raised),
            dispute_id      = COALESCE(${disputeId      ?? null}, dispute_id),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )
    // Fetch offer data for email notification
    const _offerRows = await db.run(sql`SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1`)
    const _offerData = Array.isArray((_offerRows as any).rows) ? (_offerRows as any).rows[0] : (_offerRows as any)[0]
    // Fire the "trade accepted" email ONLY on the actual accept transition —
    // i.e. when the taker accepts (status -> 'accepted' with a takerAddress).
    // Other PATCHes (takerConfirmed / makerConfirmed / release, etc.) hit this
    // same endpoint and must NOT re-trigger the email (that caused duplicate
    // notifications, including ones with a blank taker name).
    const isAcceptTransition =
      status === 'accepted' && !!takerAddress

    if (_offerData && isAcceptTransition) {
      notifyTradeAccepted({
        makerWallet: _offerData.maker_address ?? _offerData[1] ?? '',
        takerWallet: (takerAddress ?? '').toLowerCase(),
        usdcAmount:  Number(_offerData.usdc_amount  ?? _offerData[3]  ?? 0),
        localAmount: Number(_offerData.local_amount ?? _offerData[5]  ?? 0),
        localCcy:    _offerData.local_currency ?? _offerData[4] ?? '',
        offerId:     req.params.id,
      }).catch((err: any) => console.error('[Notify] trade_accepted:', err.message))
    }
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers/:id/dispute
router.post('/:id/dispute', async (req, res) => {
  const { raisedBy, reason } = req.body
  const offerId      = req.params.id
  const now          = Math.floor(Date.now() / 1000)
  const disputeId    = randomUUID()
  const autoSettleAt = now + 86400
  try {
    await db.run(
      sql`INSERT INTO disputes (id, offer_id, raised_by, reason, auto_settle_at, created_at)
          VALUES (${disputeId}, ${offerId}, ${raisedBy.toLowerCase()},
                  ${reason ?? null}, ${autoSettleAt}, ${now})`
    )
    await db.run(
      sql`UPDATE p2p_offers
          SET dispute_raised = 1, dispute_id = ${disputeId}, updated_at = ${now}
          WHERE id = ${offerId}`
    )
    const offerRows = await db.run(sql`SELECT maker_address FROM p2p_offers WHERE id = ${offerId}`)
    const rows = Array.isArray((offerRows as any).rows) ? (offerRows as any).rows : []
    if (rows.length) {
      const maker = rows[0].maker_address ?? rows[0][0]
      await db.run(
        sql`UPDATE users SET dispute_warnings = dispute_warnings + 1
            WHERE LOWER(wallet_address) = ${maker.toLowerCase()}`
      ).catch(() => {})
    }
    res.status(201).json({ disputeId, autoSettleAt })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id/dispute
router.get('/:id/dispute', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM disputes WHERE offer_id = ${req.params.id}
          ORDER BY created_at DESC LIMIT 1`
    )
    const disputes = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!disputes.length) return res.status(404).json({ error: 'No dispute' })
    res.json(disputes[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})


// PATCH /offers/:id/accept — called by taker after tx confirms
// Forces DB update so detail page loads correctly
router.patch('/:id/accept', async (req, res) => {
  const { takerAddress, timerSeconds = 1800 } = req.body
  if (!takerAddress) return res.status(400).json({ error: 'takerAddress required' })

  const now          = Math.floor(Date.now() / 1000)
  const takerDeadline = now + Number(timerSeconds)

  try {
    await db.run(
      sql`UPDATE p2p_offers SET
            status         = 'accepted',
            taker_address  = ${takerAddress.toLowerCase()},
            taker_deadline = ${takerDeadline},
            updated_at     = ${now}
          WHERE id = ${req.params.id}
            AND status = 'open'`
    )
    res.json({ success: true, takerDeadline })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

export default router
AFX_EOF
echo "  afrifx-api/src/routes/offers.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/invoices.ts" << 'AFX_EOF'
import { notifyInvoicePaid, notifyPaymentReceipt } from '../services/email/notifications'
import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

function normInvoice(r: any) {
  if (Array.isArray(r)) return {
    id: r[0], creator_address: r[1], payer_address: r[2],
    amount: Number(r[3]), currency: r[4], description: r[5],
    notes: r[6], due_date: r[7] ? Number(r[7]) : null,
    memo_ref: r[8], status: r[9], payment_tx_hash: r[10],
    paid_at: r[11] ? Number(r[11]) : null,
    created_at: Number(r[12]), updated_at: Number(r[13]),
  }
  return { ...r, amount: Number(r.amount) }
}

function genRef(prefix: string): string {
  const date = new Date().toISOString().slice(0,10).replace(/-/g,'')
  const rand = Math.random().toString(36).slice(2,6).toUpperCase()
  return `${prefix}-${date}-${rand}`
}

// GET /invoices?wallet=0x — invoices created by or addressed to wallet
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM invoices
          WHERE LOWER(creator_address) = ${wallet}
             OR LOWER(payer_address)   = ${wallet}
          ORDER BY created_at DESC LIMIT 100`
    )
    res.json(parseRows(rows).map(normInvoice))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /invoices/ref/:ref — by memo ref (for payment page)
router.get('/ref/:ref', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM invoices WHERE memo_ref = ${req.params.ref} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Invoice not found' })
    res.json(normInvoice(r[0]))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /invoices/:id
router.get('/:id', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM invoices WHERE id = ${req.params.id} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Invoice not found' })
    res.json(normInvoice(r[0]))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /invoices — create invoice
router.post('/', async (req, res) => {
  const { walletAddress, amount, currency = 'USDC', description, notes, dueDate, payerAddress } = req.body
  if (!walletAddress || !amount) return res.status(400).json({ error: 'walletAddress and amount required' })

  const id      = randomUUID()
  const memoRef = genRef('INV')
  const now     = Math.floor(Date.now() / 1000)

  try {
    await db.run(
      sql`INSERT INTO invoices
          (id, creator_address, payer_address, amount, currency,
           description, notes, due_date, memo_ref, status, created_at, updated_at)
          VALUES
          (${id}, ${walletAddress.toLowerCase()},
           ${payerAddress?.toLowerCase() ?? null},
           ${Number(amount)}, ${currency},
           ${description ?? null}, ${notes ?? null},
           ${dueDate ?? null}, ${memoRef}, 'draft', ${now}, ${now})`
    )
    res.status(201).json({ id, memoRef })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /invoices/:id/status — update status (send, pay, cancel)
router.patch('/:id/status', async (req, res) => {
  const { status, paymentTxHash, paidAt } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE invoices SET
            status          = ${status},
            payment_tx_hash = COALESCE(${paymentTxHash ?? null}, payment_tx_hash),
            paid_at         = COALESCE(${paidAt ?? null}, paid_at),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /invoices/ref/:ref/pay — mark paid or failed by memo ref
// Called by frontend after on-chain confirmation with receipt.status
router.patch('/ref/:ref/pay', async (req, res) => {
  const { txHash, payerAddress, status: txStatus, usdcAmount } = req.body
  const now = Math.floor(Date.now() / 1000)

  // Only mark as 'paid' if tx actually succeeded on-chain
  // txStatus = 'failed' means receipt.status === 'reverted'
  const invoiceStatus = txStatus === 'failed' ? 'sent' : 'paid' // keep as 'sent' if failed
  const paidAt        = txStatus === 'failed' ? null : now

  try {
    await db.run(
      sql`UPDATE invoices SET
            status          = ${invoiceStatus},
            payment_tx_hash = COALESCE(${txHash ?? null}, payment_tx_hash),
            payer_address   = COALESCE(${payerAddress?.toLowerCase() ?? null}, payer_address),
            usdc_amount     = COALESCE(${usdcAmount ?? null}, usdc_amount),
            paid_at         = COALESCE(${paidAt}, paid_at),
            updated_at      = ${now}
          WHERE memo_ref = ${req.params.ref}`
    )
    // Email notification on successful payment
    if (invoiceStatus === 'paid') {
      try {
        const _invRows = await db.run(sql`SELECT id, creator_address, memo_ref, currency, amount, usdc_amount FROM invoices WHERE memo_ref = ${req.params.ref} LIMIT 1`)
        const _inv = parseRows(_invRows)[0]
        console.log('[Notify] invoice data:', JSON.stringify(_inv))
        if (_inv) {
          notifyInvoicePaid({
            creatorWallet: _inv.creator_address ?? '',
            payerAddress:  payerAddress ?? '',
            invoiceRef:    _inv.memo_ref ?? req.params.ref,
            usdcAmount:    Number(_inv.usdc_amount ?? 0),
            localAmount:   _inv.amount ? Number(_inv.amount) : undefined,
            localCcy:      _inv.currency ?? undefined,
            invoiceId:     _inv.id ?? '',
            txHash:        txHash ?? '',
          }).catch((e: any) => console.error('[Notify] invoice_paid:', e.message))

          // The payer's receipt is now sent as a PDF attachment by
          // notifyInvoicePaid (to both creator and payer), so we no longer
          // send a separate text receipt email here.
        }
      } catch (err: any) { console.error('[Notify] invoice hook error:', err.message) }
    } else {
      console.log('[Notify] invoiceStatus not paid:', invoiceStatus)
    }
    res.json({ success: true, invoiceStatus })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// DELETE /invoices/:id — cancel/delete draft
router.delete('/:id', async (req, res) => {
  try {
    await db.run(
      sql`UPDATE invoices SET status = 'cancelled', updated_at = ${Math.floor(Date.now()/1000)}
          WHERE id = ${req.params.id} AND status IN ('draft','sent')`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
AFX_EOF
echo "  afrifx-api/src/routes/invoices.ts"

echo ""
echo "Done. Now:"
echo "  cd afrifx-api && npx tsc --noEmit    # verify backend"
echo "  git add -A && git commit -m 'Emails: de-dup accept notification + PDF receipt attachments'"
echo "  git push"
echo ""
echo "  Redeploy the API (Render). Then test: accept an offer -> maker gets"
echo "  ONE email naming the taker. Complete a trade -> each party gets one"
echo "  completion email with a PDF receipt attached (no separate receipt email)."
