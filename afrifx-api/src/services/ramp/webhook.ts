// ============================================================
// Webhook handling — a provider webhook (normalized via provider.parseWebhook)
// flips the matching leg to done/failed, then advances the transfer. This is
// the PRIMARY confirmation signal (design §5/§6); the tick loop is the backstop.
// ============================================================

import { getProvider } from './registry'
import { findLegByIdempotencyKey, updateLeg, getLegs } from './repository'
import { advanceTransfer } from './engine'
import { db } from '../../db/client'
import { sql } from 'drizzle-orm'

const rowVal = (row: any, key: string, i: number) => Array.isArray(row) ? row[i] : row[key]

// Process a raw provider webhook. Returns the transferId it touched, if any.
export async function handleProviderWebhook(
  providerKey: string, body: unknown, headers: Record<string, string>,
): Promise<{ ok: boolean; transferId?: string }> {
  const provider = getProvider(providerKey)

  // TODO: verify webhook signature per provider (e.g. HoneyCoin webhook secret)
  // BEFORE trusting the body. Reject if invalid.

  const norm = provider.parseWebhook(body, headers)

  // Find the leg by our idempotency key (which we set == externalReference).
  const key = norm.externalReference
  if (!key) return { ok: false }

  const leg = await findLegByIdempotencyKey(key)
  if (!leg) return { ok: false }

  const legId      = rowVal(leg, 'id', 0)
  const transferId = rowVal(leg, 'transfer_id', 1)
  const current    = rowVal(leg, 'status', 4)

  // Idempotent: ignore if already finalized.
  if (current === 'done' || current === 'failed') return { ok: true, transferId }

  if (norm.status === 'done') {
    await updateLeg(legId, { status: 'done' })
    // If this was the offramp, its paired payout leg also completes here
    // (HoneyCoin auto-pays after offramp deposit confirms).
    await maybeCompletePairedPayout(transferId)
  } else if (norm.status === 'failed') {
    await updateLeg(legId, { status: 'failed', error: 'provider reported failure' })
  }

  await advanceTransfer(transferId)
  return { ok: true, transferId }
}

// When the offramp completes, HoneyCoin auto-initiates the payout and its
// completion is the same/next webhook. To keep the machine moving, mark a
// still-pending payout leg done once offramp is done.
async function maybeCompletePairedPayout(transferId: string) {
  const legs = await getLegs(transferId)
  const offramp = legs.find((l: any) => rowVal(l, 'leg_type', 2) === 'offramp')
  const payout  = legs.find((l: any) => rowVal(l, 'leg_type', 2) === 'payout')
  if (!offramp || !payout) return
  const offDone   = rowVal(offramp, 'status', 4) === 'done'
  const payStatus = rowVal(payout, 'status', 4)
  if (offDone && payStatus !== 'done' && payStatus !== 'failed') {
    await updateLeg(rowVal(payout, 'id', 0), { status: 'done' })
  }
}
