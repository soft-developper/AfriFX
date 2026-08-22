// ============================================================
// Boot-time self-heal for the transactions.from_chain column.
//
// WHY: migrations 0022 AND 0023 were both recorded as applied on the prod
// Turso DB, but the ALTER TABLE never actually ran — the from_chain column is
// absent (confirmed: GET /transactions returns 11 rows, none carrying a
// from_chain key; SELECT * would expose it if the column existed). This is the
// same "recorded-but-not-run" Turso gap seen with the off-ramp corridor seed.
//
// Consequence of the missing column: POST /transactions falls back to its
// no-from_chain INSERT branch, so every send is stored with no chain. History
// then can't pick the right block explorer (defaults to Arc) and the settle
// path can't resolve the chain, leaving cross-chain sends stuck "pending".
//
// FIX: add the column at boot via ALTER TABLE, guarded so it's a no-op when the
// column already exists. Independent of the migration runner. Idempotent.
// ============================================================

import { db } from '../db/client'
import { sql } from 'drizzle-orm'

/** Does transactions.from_chain exist right now? */
async function columnExists(): Promise<boolean> {
  try {
    const info: any = await db.run(sql`PRAGMA table_info(transactions)`)
    const rows: any[] = info?.rows ?? info ?? []
    return rows.some((c: any) => (c.name ?? c[1]) === 'from_chain')
  } catch {
    return false
  }
}

/**
 * Ensure transactions.from_chain exists. Called once at boot, before the server
 * accepts requests. Safe to run every boot: if the column is already there it
 * does nothing; if a concurrent add wins the race, the "duplicate column"
 * error is swallowed.
 */
export async function ensureTransactionsSchema(): Promise<void> {
  try {
    if (await columnExists()) {
      console.log('[Tx] from_chain column present')
      return
    }
    try {
      await db.run(sql`ALTER TABLE transactions ADD COLUMN from_chain TEXT`)
      console.log('[Tx] \u2705 added transactions.from_chain (self-heal; migrations 0022/0023 did not run on prod)')
    } catch (e: any) {
      // Another instance may have added it between our check and here.
      if (/duplicate column/i.test(String(e?.message ?? ''))) {
        console.log('[Tx] from_chain already present (concurrent add)')
      } else {
        throw e
      }
    }
  } catch (err: any) {
    // Never crash boot over this — the insert path degrades gracefully anyway.
    console.error('[Tx] \u26a0 ensureTransactionsSchema failed:', err?.message ?? err)
  }
}
