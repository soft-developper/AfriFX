// ============================================================
// P2P Release Watcher — 4 jobs:
// Job1: release when both confirmed (every 15s)
// Job2: auto-cancel when taker timer expires + taker NOT confirmed (every 60s)
// Job3: auto-release to taker after 24h when maker goes silent (every 5min)
// Job4: clean up released/cancelled trade chats (every 5min)
// ============================================================
import { db }               from '../db/client'
import { sql }              from 'drizzle-orm'
import { releasePlatform, cancelPlatform } from '../services/platformWallet'
import { notifyTradeCompleted, notifyTradeAutoCancelled } from '../services/email/notifications'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

async function releaseOffer(offerId: string, label: string) {
  console.log(`[P2PWatcher] ${label}: releasing ${offerId.slice(0,18)}…`)
  try {
    const hash = await releasePlatform(offerId as `0x${string}`)
    const now  = Math.floor(Date.now() / 1000)
    await db.run(sql`
      UPDATE p2p_offers SET
        status          = 'released',
        release_tx_hash = ${hash},
        updated_at      = ${now}
      WHERE id = ${offerId}
    `)
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`)
    console.log(`[P2PWatcher] ${label} released ✅ tx: ${hash}`)

    // Fetch offer details for email notification
    try {
      const offerRows = await db.run(sql`SELECT * FROM p2p_offers WHERE id = ${offerId} LIMIT 1`)
      const r = parseRows(offerRows)
      const o = r[0]
      if (o) {
        notifyTradeCompleted({
          makerWallet: o.maker_address ?? o[1] ?? '',
          takerWallet: o.taker_address ?? o[2] ?? '',
          usdcAmount:  Number(o.usdc_amount  ?? o[3]  ?? 0),
          localAmount: Number(o.local_amount  ?? o[5]  ?? 0),
          localCcy:    o.local_currency ?? o[4] ?? '',
          offerId,
          txHash:      hash,
        }).catch((err: any) => console.error('[Notify] trade_completed failed:', err.message))
      }
    } catch {}

    return true
  } catch (err: any) {
    console.error(`[P2PWatcher] ${label} release failed:`, err.message)
    return false
  }
}

async function cancelOffer(offerId: string, label: string) {
  console.log(`[P2PWatcher] ${label}: cancelling ${offerId.slice(0,18)}…`)
  try {
    const hash = await cancelPlatform(offerId as `0x${string}`, 'Taker timer expired — auto cancelled')
    const now  = Math.floor(Date.now() / 1000)
    await db.run(sql`
      UPDATE p2p_offers SET
        status     = 'cancelled',
        updated_at = ${now}
      WHERE id = ${offerId}
    `)
    console.log(`[P2PWatcher] ${label} cancelled ✅ tx: ${hash}`)

    // Notify both parties by email
    try {
      const oRows = await db.run(sql`
        SELECT maker_address, taker_address, usdc_amount
        FROM p2p_offers WHERE id = ${offerId} LIMIT 1
      `)
      const o = parseRows(oRows)[0]
      if (o) {
        notifyTradeAutoCancelled({
          makerWallet: o.maker_address ?? o[0] ?? '',
          takerWallet: o.taker_address ?? o[1] ?? null,
          usdcAmount:  Number(o.usdc_amount ?? o[2] ?? 0),
          offerId,
        }).catch((err: any) => console.error('[Notify] auto_cancelled:', err.message))
      }
    } catch {}

    return true
  } catch (err: any) {
    console.error(`[P2PWatcher] ${label} cancel failed:`, err.message)
    return false
  }
}

export function startP2PReleaseWatcher() {
  if (!process.env.PLATFORM_WALLET_PRIVATE_KEY) {
    console.warn('[P2PWatcher] PLATFORM_WALLET_PRIVATE_KEY not set — auto-release disabled')
    return
  }

  // ── Job1: Release when both confirmed (every 15s) ──────────
  setInterval(async () => {
    try {
      const rows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status          = 'accepted'
          AND maker_confirmed = 1
          AND taker_confirmed = 1
        LIMIT 5
      `)
      for (const r of parseRows(rows)) {
        await releaseOffer(r.id ?? r[0], 'Job1')
      }
    } catch (err: any) { console.error('[P2PWatcher] Job1 error:', err.message) }
  }, 15_000)

  // ── Job2: Auto-cancel when taker timer expires (every 60s) ─
  setInterval(async () => {
    const now = Math.floor(Date.now() / 1000)
    try {
      const rows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status          = 'accepted'
          AND taker_confirmed = 0
          AND taker_deadline  IS NOT NULL
          AND taker_deadline  < ${now}
        LIMIT 5
      `)
      for (const r of parseRows(rows)) {
        await cancelOffer(r.id ?? r[0], 'Job2')
      }
    } catch (err: any) { console.error('[P2PWatcher] Job2 error:', err.message) }
  }, 60_000)

  // ── Job3: Auto-release after 24h maker silence (every 5min) ─
  setInterval(async () => {
    const now    = Math.floor(Date.now() / 1000)
    const ago24h = now - 86400
    try {
      // Case B: no dispute raised but 24h+ since maker_deadline passed
      const silentRows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status          = 'accepted'
          AND taker_confirmed = 1
          AND maker_confirmed = 0
          AND dispute_raised  = 0
          AND maker_deadline  IS NOT NULL
          AND maker_deadline  < ${ago24h}
        LIMIT 5
      `)
      for (const r of parseRows(silentRows)) {
        const offerId = r.id ?? r[0]
        console.log(`[P2PWatcher] Job3B: 24h no action, auto-releasing: ${offerId.slice(0,18)}…`)
        await db.run(sql`
          UPDATE p2p_offers SET maker_confirmed = 1, updated_at = ${now}
          WHERE id = ${offerId}
        `)
      }
    } catch (err: any) { console.error('[P2PWatcher] Job3 error:', err.message) }
  }, 5 * 60_000)

  // ── Job4: Clean up released/cancelled chats (every 5min) ───
  setInterval(async () => {
    try {
      const rows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status IN ('released', 'cancelled')
        LIMIT 20
      `)
      for (const r of parseRows(rows)) {
        await db.run(sql`DELETE FROM messages WHERE offer_id = ${r.id ?? r[0]}`)
      }
    } catch (err: any) { console.error('[P2PWatcher] Job4 error:', err.message) }
  }, 5 * 60_000)

  console.log('[P2PWatcher] started — Job1:15s | Job2:60s | Job3:5min | Job4:5min')
}
