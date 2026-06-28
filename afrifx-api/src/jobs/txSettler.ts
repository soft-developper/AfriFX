// Marks pending transactions as settled if they have an arc_tx_hash
// and are older than 2 minutes (Arc confirms in seconds)
// This catches cases where:
//   - Direct transfer used (no Memo event)
//   - Frontend closed before confirmation callback
//   - Event listener missed the event

import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'

export function startTxSettler() {
  console.log('[TxSettler] ✅ Started — settling pending txs every 2 minutes')

  // Run every 2 minutes
  cron.schedule('*/2 * * * *', settle)

  // Run 10s after boot to catch any from last session
  setTimeout(settle, 10_000)
}

async function settle() {
  const now      = Math.floor(Date.now() / 1000)
  const cutoff   = now - 120 // older than 2 minutes

  try {
    const result = await db.run(
      sql`UPDATE transactions
          SET status     = 'settled',
              settled_at = ${now}
          WHERE status      = 'pending'
            AND arc_tx_hash IS NOT NULL
            AND created_at  < ${cutoff}`
    )

    // Log how many were settled (if any)
    const changes = (result as any).rowsAffected ?? (result as any).changes ?? 0
    if (changes > 0) {
      console.log(`[TxSettler] ✅ Settled ${changes} pending transaction(s)`)
    }
  } catch (err: any) {
    console.error('[TxSettler] Error:', err.message)
  }
}
