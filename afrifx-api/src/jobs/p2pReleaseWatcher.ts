import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { releasePlatform, cancelPlatform } from '../services/platformWallet'

export function startP2PReleaseWatcher() {
  if (!process.env.PLATFORM_WALLET_PRIVATE_KEY) {
    console.warn('[P2PWatcher] PLATFORM_WALLET_PRIVATE_KEY not set — auto-release disabled')
    return
  }
  console.log('[P2PWatcher] ✅ Started — polling every 15s')

  cron.schedule('*/15 * * * * *', async () => {
    await job1_releaseConfirmed()
    await job2_cancelTimedOutTakers()
    await job3_flagTimedOutMakers()
    await job4_autoSettleDisputes()
  })

  setTimeout(async () => {
    await job1_releaseConfirmed()
    await job2_cancelTimedOutTakers()
    await job3_flagTimedOutMakers()
    await job4_autoSettleDisputes()
  }, 3000)
}

// ── Job 1: Both confirmed → release USDC + delete chat ───
async function job1_releaseConfirmed() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id, dispute_raised FROM p2p_offers
          WHERE status          = 'accepted'
            AND maker_confirmed = 1
            AND taker_confirmed = 1`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId       = (row.id             ?? row[0]) as `0x${string}`
      const disputeRaised = Number(row.dispute_raised ?? row[1] ?? 0)
      try {
        const lateNote = disputeRaised ? ' (maker confirmed late — dispute on record)' : ''
        console.log(`[P2PWatcher] Job1: releasing ${offerId.slice(0,14)}…${lateNote}`)

        const hash = await releasePlatform(offerId)

        // Mark offer as released
        await db.run(
          sql`UPDATE p2p_offers SET
                status          = 'released',
                release_tx_hash = ${hash},
                updated_at      = ${now}
              WHERE id = ${offerId}`
        )

        // ── Delete chat messages — trade is complete ──────
        const deleted = await db.run(
          sql`DELETE FROM messages WHERE offer_id = ${offerId}`
        )
        console.log(`[P2PWatcher] 🗑  Chat deleted for completed offer ${offerId.slice(0,14)}…`)

        // Resolve late-confirm disputes
        if (disputeRaised) {
          await db.run(
            sql`UPDATE disputes SET
                  status     = 'resolved_late_confirm',
                  settled_at = ${now}
                WHERE offer_id = ${offerId} AND status = 'open'`
          ).catch(() => {})
        }

        console.log(`[P2PWatcher] ✅ Released ${offerId.slice(0,14)}… tx: ${hash.slice(0,14)}…`)
      } catch (err: any) {
        console.error(`[P2PWatcher] Job1 release failed:`, err.message)
      }
    }
  } catch (err: any) { console.error('[P2PWatcher] Job1 error:', err.message) }
}

// ── Job 2: Taker didn't confirm in time → cancel ─────────
async function job2_cancelTimedOutTakers() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id FROM p2p_offers
          WHERE status          = 'accepted'
            AND taker_confirmed = 0
            AND taker_deadline  IS NOT NULL
            AND taker_deadline  < ${now}`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      try {
        await cancelPlatform(offerId, 'Taker did not send within agreed window')
        await db.run(
          sql`UPDATE p2p_offers SET
                status         = 'cancelled',
                taker_address  = NULL,
                taker_deadline = NULL,
                updated_at     = ${now}
              WHERE id = ${offerId}`
        )
        // Also delete chat on taker timeout cancel
        await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`)
        console.log(`[P2PWatcher] ⏰ Taker timed out — offer ${offerId.slice(0,14)} cancelled + chat deleted`)
      } catch (err: any) {
        console.error(`[P2PWatcher] Job2 failed:`, err.message)
      }
    }
  } catch (err: any) { console.error('[P2PWatcher] Job2 error:', err.message) }
}

// ── Job 3: Maker didn't confirm in time → flag dispute ───
async function job3_flagTimedOutMakers() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id FROM p2p_offers
          WHERE status          = 'accepted'
            AND taker_confirmed = 1
            AND maker_confirmed = 0
            AND dispute_raised  = 0
            AND maker_deadline  IS NOT NULL
            AND maker_deadline  < ${now}`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      await db.run(
        sql`UPDATE p2p_offers SET dispute_raised = 1, updated_at = ${now} WHERE id = ${offerId}`
      ).catch(() => {})
      console.log(`[P2PWatcher] ⚠️  Maker timed out — dispute flagged ${offerId.slice(0,14)}`)
    }
  } catch (err: any) { console.error('[P2PWatcher] Job3 error:', err.message) }
}

// ── Job 4: Dispute 24h → auto-release to taker + delete chat
async function job4_autoSettleDisputes() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT d.id as dispute_id, d.offer_id
          FROM disputes d
          JOIN p2p_offers o ON o.id = d.offer_id
          WHERE d.status         = 'open'
            AND d.auto_settle_at < ${now}
            AND o.status         = 'accepted'
            AND o.maker_confirmed = 0`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId   = (row.offer_id   ?? row[1]) as `0x${string}`
      const disputeId =  row.dispute_id ?? row[0]
      try {
        const hash = await releasePlatform(offerId)
        await db.run(
          sql`UPDATE p2p_offers SET
                status = 'released', release_tx_hash = ${hash}, updated_at = ${now}
              WHERE id = ${offerId}`
        )
        await db.run(
          sql`UPDATE disputes SET status = 'auto_settled', settled_at = ${now}
              WHERE id = ${disputeId}`
        )
        // Delete chat after auto-settlement
        await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`)
        console.log(`[P2PWatcher] ⚖️  Auto-settled + chat deleted → ${offerId.slice(0,14)}`)
      } catch (err: any) {
        console.error(`[P2PWatcher] Job4 failed:`, err.message)
      }
    }
  } catch (err: any) { console.error('[P2PWatcher] Job4 error:', err.message) }
}

function parseRows(result: any): any[] {
  if (!result) return []
  if (Array.isArray((result as any).rows)) return (result as any).rows
  if (Array.isArray(result)) return result
  return []
}
