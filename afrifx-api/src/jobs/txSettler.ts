// Reconciles pending transactions against the chain.
//
// Previously this marked ANY pending tx with a hash as 'settled' after
// 2 minutes, without checking the chain so a tx that reverted on-chain
// was still shown as successful. It now fetches each pending tx's receipt
// and sets 'settled' only when the receipt status is 'success', otherwise
// 'failed'. This catches cases where:
//   - Direct transfer used (no Memo event)
//   - Frontend closed before its confirmation callback ran
//   - Event listener missed the event

import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { createPublicClient, http } from 'viem'

const ARC_RPC = process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'

const arcClient = createPublicClient({
  transport: http(ARC_RPC),
  chain: {
    id: 5042002, name: 'Arc Testnet',
    nativeCurrency: { name: 'ARC', symbol: 'ARC', decimals: 18 },
    rpcUrls: { default: { http: [ARC_RPC] } },
  } as any,
})

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export function startTxSettler() {
  console.log('[TxSettler] ✅ Started, reconciling pending txs against the chain every 2 minutes')
  cron.schedule('*/2 * * * *', settle)
  setTimeout(settle, 10_000) // also run shortly after boot
}

async function settle() {
  const now    = Math.floor(Date.now() / 1000)
  const cutoff = now - 120 // give the chain ~2 min to confirm before we check

  try {
    const rows = parseRows(await db.run(
      sql`SELECT id, arc_tx_hash FROM transactions
          WHERE status = 'pending'
            AND arc_tx_hash IS NOT NULL
            AND created_at < ${cutoff}
          LIMIT 100`
    ))
    if (!rows.length) return

    let settled = 0, failed = 0, stillPending = 0

    for (const row of rows) {
      const id   = Array.isArray(row) ? row[0] : row.id
      const hash = Array.isArray(row) ? row[1] : row.arc_tx_hash
      if (!hash) continue

      let status: 'settled' | 'failed' | null = null
      try {
        const receipt = await arcClient.getTransactionReceipt({ hash: hash as `0x${string}` })
        status = receipt.status === 'success' ? 'settled' : 'failed'
      } catch {
        // Receipt not found yet (still propagating) leave pending; a later
        // run will pick it up. Don't guess a status.
        stillPending++
        continue
      }

      await db.run(
        sql`UPDATE transactions
            SET status = ${status}, settled_at = ${now}
            WHERE id = ${id}`
      )
      if (status === 'settled') settled++; else failed++
    }

    if (settled || failed) {
      console.log(`[TxSettler] Reconciled, settled: ${settled}, failed: ${failed}, still pending: ${stillPending}`)
    }
  } catch (err: any) {
    console.error('[TxSettler] Error:', err.message)
  }
}
