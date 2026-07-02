import { db }     from '../../db/client'
import { sql }    from 'drizzle-orm'
import { randomUUID } from 'crypto'
import { sendEmail } from './client'
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

// ─────────────────────────────────────────────────────────────
// Wave 2 notification functions
// ─────────────────────────────────────────────────────────────


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
