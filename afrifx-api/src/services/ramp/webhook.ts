// ============================================================
// Webhook handling a provider webhook (normalized via provider.parseWebhook)
// flips the matching leg to done/failed, then advances the transfer. This is
// the PRIMARY confirmation signal (design §5/§6); the tick loop is the backstop.
// ============================================================

import { getProvider } from './registry'
import { findLegByIdempotencyKey, updateLeg, getLegs, parseRows } from './repository'
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

  // Find the leg. We set `reference` on every provider call, but some providers
  // (Flutterwave) impose a STRICT reference format, so what comes back may be a
  // TRANSFORMED version of our idempotency key rather than the key itself.
  // Try the raw key first, then fall back to matching on the derived reference.
  const key = norm.externalReference
  if (!key) return { ok: false }

  let leg = await findLegByIdempotencyKey(key)

  if (!leg) {
    leg = await findLegByProviderReference(providerKey, key)
  }
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

// When the provider echoes back a TRANSFORMED reference (because our
// idempotency key doesn't fit their format), find the leg by re-deriving the
// reference for each in-flight leg and comparing. Scoped to in-flight legs, so
// this stays cheap.
async function findLegByProviderReference(
  providerKey: string, reference: string,
): Promise<any | null> {
  if (providerKey !== 'flutterwave') return null
  try {
    const { toFlwReference } = await import('./providers/flutterwave')
    const rows = parseRows(await db.run(sql`
      SELECT * FROM transfer_legs
      WHERE status IN ('in_flight', 'pending')
      ORDER BY created_at DESC LIMIT 200`))
    for (const r of rows) {
      const key = rowVal(r, 'idempotency_key', 5)
      if (key && toFlwReference(String(key)) === reference) return r
    }
  } catch { /* fall through */ }
  return null
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
