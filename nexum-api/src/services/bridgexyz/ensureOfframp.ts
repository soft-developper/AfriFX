// ============================================================
// Boot-time self-heal for the off-ramp schema + corridor seed.
//
// WHY THIS EXISTS: migration 0024's corridor INSERT did not execute on the
// production Turso DB even though the migration was recorded as applied — the
// same "recorded-but-not-run" gap seen with the transactions.from_chain column
// (0022/0023). Rather than trust the migration runner, we ensure the off-ramp
// tables and the six corridor rows exist every time the API boots.
//
// Safe by construction: CREATE TABLE IF NOT EXISTS + INSERT ... ON CONFLICT
// (direction,currency) DO NOTHING. If 0024 already applied cleanly, this is a
// no-op. If it didn't, this repairs it. Idempotent on every deploy.
//
// Mirrors the on-ramp corridor set but as the DESTINATION side. usd/eur/mxn
// enabled (rails with a defined external-account shape); gbp/brl/cop seeded
// disabled until their forms ship.
// ============================================================

import { db } from '../../db/client'
import { sql } from 'drizzle-orm'

export async function ensureOfframpSchema(): Promise<void> {
  try {
    // 1) Tables (no-op if 0024 already created them).
    await db.run(sql`
      CREATE TABLE IF NOT EXISTS ramp_external_accounts (
        id                    TEXT PRIMARY KEY,
        account_id            TEXT NOT NULL,
        provider              TEXT NOT NULL DEFAULT 'bridgexyz',
        currency              TEXT NOT NULL,
        bridge_customer_id    TEXT NOT NULL,
        external_account_id   TEXT NOT NULL,
        bank_name             TEXT,
        last_4                TEXT,
        account_type          TEXT,
        created_at            INTEGER NOT NULL,
        updated_at            INTEGER NOT NULL,
        UNIQUE (account_id, currency)
      )`)
    await db.run(sql`CREATE INDEX IF NOT EXISTS idx_ramp_ext_acct_account ON ramp_external_accounts (account_id)`)
    await db.run(sql`CREATE INDEX IF NOT EXISTS idx_ramp_ext_acct_bridge_id ON ramp_external_accounts (external_account_id)`)

    await db.run(sql`
      CREATE TABLE IF NOT EXISTS ramp_liquidation_addresses (
        id                       TEXT PRIMARY KEY,
        account_id               TEXT NOT NULL,
        provider                 TEXT NOT NULL DEFAULT 'bridgexyz',
        currency                 TEXT NOT NULL,
        bridge_customer_id       TEXT NOT NULL,
        liquidation_address_id   TEXT NOT NULL,
        external_account_id      TEXT NOT NULL,
        address                  TEXT NOT NULL,
        source_chain             TEXT NOT NULL DEFAULT 'base',
        source_currency          TEXT NOT NULL DEFAULT 'usdc',
        destination_payment_rail TEXT NOT NULL,
        destination_currency     TEXT NOT NULL,
        status                   TEXT NOT NULL DEFAULT 'active',
        created_at               INTEGER NOT NULL,
        updated_at               INTEGER NOT NULL,
        UNIQUE (account_id, currency)
      )`)
    await db.run(sql`CREATE INDEX IF NOT EXISTS idx_ramp_liq_addr_account ON ramp_liquidation_addresses (account_id)`)
    await db.run(sql`CREATE INDEX IF NOT EXISTS idx_ramp_liq_addr_bridge_id ON ramp_liquidation_addresses (liquidation_address_id)`)
    await db.run(sql`CREATE INDEX IF NOT EXISTS idx_ramp_liq_addr_address ON ramp_liquidation_addresses (address)`)

    // 2) Corridor seed (the piece 0024 failed to run). ON CONFLICT keeps it
    //    idempotent and won't disturb any rows an operator later edits.
    await db.run(sql`
      INSERT INTO ramp_corridors
        (id, direction, currency, label, min_amount, enabled, sort_order, created_at, updated_at)
      VALUES
        ('cor_offramp_usd', 'offramp', 'usd', 'US Dollar (ACH)',        1, 1, 10, strftime('%s','now'), strftime('%s','now')),
        ('cor_offramp_eur', 'offramp', 'eur', 'Euro (SEPA)',            1, 1, 20, strftime('%s','now'), strftime('%s','now')),
        ('cor_offramp_mxn', 'offramp', 'mxn', 'Mexican Peso (SPEI)',    1, 1, 40, strftime('%s','now'), strftime('%s','now')),
        ('cor_offramp_gbp', 'offramp', 'gbp', 'British Pound (FPS)',    1, 0, 30, strftime('%s','now'), strftime('%s','now')),
        ('cor_offramp_brl', 'offramp', 'brl', 'Brazilian Real (Pix)',   1, 0, 50, strftime('%s','now'), strftime('%s','now')),
        ('cor_offramp_cop', 'offramp', 'cop', 'Colombian Peso (Bre-B)', 1, 0, 60, strftime('%s','now'), strftime('%s','now'))
      ON CONFLICT (direction, currency) DO NOTHING`)

    const rows: any = await db.run(sql`SELECT COUNT(*) AS c FROM ramp_corridors WHERE direction = 'offramp'`)
    const count = rows?.rows?.[0]?.c ?? rows?.[0]?.c ?? '?'
    console.log(`[Ramp] \u2705 off-ramp schema ensured (${count} off-ramp corridors present)`)
  } catch (err: any) {
    // Never let a seed failure crash boot — log and continue.
    console.error('[Ramp] \u26a0 ensureOfframpSchema failed:', err?.message ?? err)
  }
}
