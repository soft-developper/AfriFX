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
