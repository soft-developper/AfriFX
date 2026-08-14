/**
 * Migrations, end to end against a real SQLite database.
 *
 * This is the test that matters most in this file set. Before the migration
 * work, a fresh database could not be built from this repository at all: the
 * core, admin, and app tables had never been written down as SQL. It failed
 * silently because nobody ever created an empty database.
 *
 * These tests create one every run, so that can't regress.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { createClient, type Client } from '@libsql/client'
import { readFileSync, rmSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { loadMigrations, splitStatements, isAlreadyApplied } from '../src/db/migrate-lib'

const DB_FILE = join(process.cwd(), 'tests', '.tmp-migrations.db')

/** Apply every migration to `client`, returning how many statements ran. */
async function applyAll(client: Client): Promise<number> {
  let ran = 0
  for (const m of loadMigrations()) {
    for (const stmt of splitStatements(m.sql)) {
      try {
        await client.execute(stmt)
        ran++
      } catch (err) {
        if (isAlreadyApplied(err)) continue
        throw new Error(`${m.file}: ${(err as any)?.message}\n\n${stmt.slice(0, 300)}`)
      }
    }
  }
  return ran
}

async function tableNames(client: Client): Promise<Set<string>> {
  const res = await client.execute(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
  )
  return new Set(res.rows.map(r => String(r.name)))
}

/**
 * Every table the application actually queries, scraped from the route and
 * service code. If someone adds a table to a query without adding a migration,
 * this list is how it gets caught.
 */
const REQUIRED_TABLES = [
  // core
  'transactions', 'p2p_offers', 'disputes', 'fx_rates', 'users',
  // admin
  'admins', 'admin_sessions', 'admin_audit_log', 'admin_login_log',
  'admin_password_resets', 'admin_invitations', 'admin_duty_sessions',
  'admin_broadcasts',
  // app
  'profiles', 'messages', 'notifications', 'invoices', 'payments',
  'treasury_rules', 'email_rate_limits',
  'dispute_assignments', 'dispute_messages', 'dispute_ai_summaries',
  'contact_messages', 'site_content',
  // features
  'maintenance_state', 'bridge_transfers',
  'transfers', 'transfer_legs',
  'payroll_batches', 'payroll_recipients',
]

describe('migrations (integration)', () => {
  let client: Client

  beforeAll(async () => {
    if (existsSync(DB_FILE)) rmSync(DB_FILE)
    client = createClient({ url: `file:${DB_FILE}` })
  })

  afterAll(() => {
    client?.close()
    for (const f of [DB_FILE, `${DB_FILE}-wal`, `${DB_FILE}-shm`]) {
      if (existsSync(f)) rmSync(f)
    }
  })

  it('builds a complete database from empty', async () => {
    const ran = await applyAll(client)
    expect(ran).toBeGreaterThan(0)
  })

  it('creates every table the application queries', async () => {
    const have    = await tableNames(client)
    const missing = REQUIRED_TABLES.filter(t => !have.has(t))
    expect(missing, `missing tables: ${missing.join(', ')}`).toEqual([])
  })

  it('is idempotent: applying twice changes nothing and throws nothing', async () => {
    const before = await tableNames(client)
    await applyAll(client)          // must not throw
    const after  = await tableNames(client)
    expect([...after].sort()).toEqual([...before].sort())
  })

  it('created the payroll dest_chain column with an arc default', async () => {
    // Guards the multichain payroll change: the column has to exist and
    // default to 'arc' so pre-existing batches keep their old behaviour.
    const res  = await client.execute('PRAGMA table_info(payroll_batches)')
    const col  = res.rows.find(r => String(r.name) === 'dest_chain')
    expect(col, 'payroll_batches.dest_chain is missing').toBeDefined()
    expect(String(col!.dflt_value)).toContain('arc')
  })

  it('key lookup columns are indexed', async () => {
    // Not exhaustive; these are the ones on hot paths.
    const res = await client.execute(
      "SELECT name FROM sqlite_master WHERE type='index'",
    )
    const idx = new Set(res.rows.map(r => String(r.name)))
    for (const want of [
      'idx_admin_sessions_token',
      'idx_disputes_offer',
      'idx_messages_offer',
      'idx_payroll_recipients_batch',
    ]) {
      expect(idx.has(want), `missing index ${want}`).toBe(true)
    }
  })

  it('accepts a real insert into a reconstructed table', async () => {
    // The baselines were reconstructed from INSERT statements in the routes,
    // so prove the columns actually line up with what the code writes.
    const now = Math.floor(Date.now() / 1000)
    await client.execute({
      sql: `INSERT INTO payroll_batches
            (id, wallet_address, name, description, total_amount,
             currency, recipient_count, created_at, dest_chain)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      args: ['b1', '0xabc', 'August payroll', null, 100.5, 'USDC', 2, now, 'base'],
    })
    await client.execute({
      sql: `INSERT INTO payroll_recipients
            (id, batch_id, name, wallet_address, amount, currency, memo_ref, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      args: ['r1', 'b1', 'Ada', '0xdef', 50.25, 'USDC', 'ref-1', now],
    })

    const res = await client.execute({
      sql: 'SELECT dest_chain, status FROM payroll_batches WHERE id = ?',
      args: ['b1'],
    })
    expect(String(res.rows[0].dest_chain)).toBe('base')
    expect(String(res.rows[0].status)).toBe('draft')
  })
})
