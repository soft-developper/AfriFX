// AfriFX email templates branded, mobile-responsive
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
            <p style="margin:0 0 8px;">AfriFX, Stablecoin-powered cross-border payments on Arc</p>
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
  const subject = '✅ Trade completed, funds released'
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
  const previewText = `Action required, review the dispute and respond.`

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
      3. Upload your bank statement when requested, it stays admin-only<br>
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
  Good news, your invoice <strong style="color:${TEXT_PRIMARY};">${params.invoiceRef}</strong> just got paid in USDC.
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
<p style="margin:0 0 8px;">AfriFX, Stablecoin-powered cross-border payments on Arc</p>
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
  const subject = `⚠️ New dispute needs review, ${params.usdcAmount} USDC`
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
Good news, <strong style="color:${TEXT_PRI};">Admin ${params.adminName}</strong> has accepted your dispute and will be handling the review.
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
  const preview = `${params.amount.toLocaleString()} ${params.currency} pending, consider a reminder.`

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
You can copy the payment link from the invoice page and share it with your payer again. This reminder is sent once, future updates come from the platform when the invoice is paid.
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
  const subject = 'Trade auto-cancelled, USDC returned'
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
<p style="margin:0 0 8px;">AfriFX, Stablecoin-powered cross-border payments on Arc</p>
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
<p style="margin:0 0 4px;color:${TS3};font-size:13px;">${params.periodStart}, ${params.periodEnd}</p>
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
