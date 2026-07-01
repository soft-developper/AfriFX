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
