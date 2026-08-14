// ============================================================
// Orchestrator tick loop the backstop behind webhooks (design §6), mirroring
// txSettler. Every N minutes it finds transfers stuck 'in_progress' with an
// in_flight leg and queries the provider's REAL status to move them forward,
// in case a webhook was missed. Ground-truth only, never optimistic.
// ============================================================

import cron from 'node-cron'
import { db } from '../../db/client'
import { sql } from 'drizzle-orm'
import { getProvider } from './registry'
import { getLegs, updateLeg, parseRows } from './repository'
import { advanceTransfer } from './engine'

const rowVal = (row: any, key: string, i: number) => Array.isArray(row) ? row[i] : row[key]

export function startTransferReconciler() {
  console.log('[TransferReconciler] ✅ Started, backstop reconciling in-flight transfers every 3 minutes')
  cron.schedule('*/3 * * * *', reconcile)
  setTimeout(reconcile, 15_000) // shortly after boot too
}

async function reconcile() {
  try {
    const cutoff = Math.floor(Date.now() / 1000) - 90 // give webhooks ~90s first
    const transfers = parseRows(await db.run(sql`
      SELECT id, provider FROM transfers
      WHERE status = 'in_progress' AND updated_at < ${cutoff}
      LIMIT 50`))
    if (!transfers.length) return

    for (const t of transfers) {
      const transferId = rowVal(t, 'id', 0)
      const providerKey = rowVal(t, 'provider', 1)
      const legs = await getLegs(transferId)

      // Only in_flight legs that finalize via provider (onramp/offramp/payout).
      const inflight = legs.filter((l: any) => {
        const s = rowVal(l, 'status', 4)
        const type = rowVal(l, 'leg_type', 2)
        return s === 'in_flight' && ['onramp', 'offramp', 'payout'].includes(type)
      })
      if (!inflight.length) { await advanceTransfer(transferId); continue }

      let provider
      try { provider = getProvider(providerKey) } catch { continue }

      for (const leg of inflight) {
        const legId  = rowVal(leg, 'id', 0)
        const idem   = rowVal(leg, 'idempotency_key', 5)
        const ref    = rowVal(leg, 'provider_ref', 6)
        try {
          const res = await provider.getStatus({ idempotencyKey: idem, providerRef: ref })
          if (res.status === 'done')   await updateLeg(legId, { status: 'done' })
          if (res.status === 'failed') await updateLeg(legId, { status: 'failed', error: 'reconciler: provider failed' })
        } catch { /* leave in_flight; try again next tick */ }
      }
      await advanceTransfer(transferId)
    }
  } catch (err: any) {
    console.error('[TransferReconciler] error:', err?.message)
  }
}
