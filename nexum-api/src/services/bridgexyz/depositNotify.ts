// ============================================================
// Deposit email notifications (Phase 4 #3).
//
// Called from the Bridge webhook handler after a verified event is mirrored.
// Fires a branded email on terminal deposit states:
//   • payment_processed              → "deposit landed" (USDC delivered)
//   • refund / refund_in_flight      → "deposit returned"
//   • refund_failed                  → "return failed" (needs support)
//
// Every send is guarded by claimDepositNotification() so a webhook redelivery
// (or the same event seen twice) can only email once per (deposit, kind). The
// whole thing is best-effort: any failure is logged and swallowed so it can
// never break webhook processing (which must still 200).
// ============================================================

import { sendEmail } from '../email/client'
import { depositLandedEmail, depositReturnedEmail } from '../email/templates'
import {
  getAccountContact, getVirtualAccountRowById, claimDepositNotification,
} from './repository'
import type { ActivityDetail } from './webhooks'

// Which email (if any) a given event type maps to.
type Kind = 'landed' | 'returned' | 'returned_failed'
function kindForEvent(eventType: string | null): Kind | null {
  switch (eventType) {
    case 'payment_processed': return 'landed'
    case 'refund':
    case 'refund_in_flight':  return 'returned'
    case 'refund_failed':     return 'returned_failed'
    default:                  return null
  }
}

export async function maybeSendDepositEmail(detail: ActivityDetail): Promise<void> {
  try {
    const kind = kindForEvent(detail.eventType)
    if (!kind) return // not a terminal state we notify on
    if (!detail.virtualAccountId) return

    // Claim first — cheap guard, avoids doing lookups for a dupe.
    const won = await claimDepositNotification({
      virtualAccountId: detail.virtualAccountId,
      depositId:        detail.depositId,
      kind,
    })
    if (!won) return

    const vaRow = await getVirtualAccountRowById(detail.virtualAccountId)
    if (!vaRow) { console.warn('[DepositNotify] no VA row for', detail.virtualAccountId); return }
    const contact = await getAccountContact(vaRow.account_id)
    if (!contact?.email) { console.warn('[DepositNotify] no email for account', vaRow.account_id); return }

    const displayName = contact.display_name ?? 'there'
    const currency    = detail.currency ?? vaRow.currency ?? undefined

    let tmpl: { subject: string; html: string }
    if (kind === 'landed') {
      tmpl = depositLandedEmail({
        displayName,
        amountUsdc: detail.amount ?? '—',
        sentCcy:    currency,
        txHash:     detail.destinationTxHash ?? undefined,
      })
    } else {
      tmpl = depositReturnedEmail({
        displayName,
        sentCcy: currency,
        failed:  kind === 'returned_failed',
      })
    }

    const res = await sendEmail({ to: contact.email, subject: tmpl.subject, html: tmpl.html })
    if (!res.success) console.error('[DepositNotify] send failed:', res.error)
  } catch (err: any) {
    // Never let a notification error affect webhook processing.
    console.error('[DepositNotify] error:', err?.message)
  }
}
