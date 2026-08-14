#!/usr/bin/env tsx
/**
 * Versioned SQL migrations for Turso / libSQL.
 *
 * WHY THIS EXISTS
 * ---------------
 * Schema changes used to be loose .sql files in the repo root, pasted into
 * the Turso shell by hand. That has no record of what ran where, no ordering,
 * and no way to bring a fresh database up to date. It also can't be reviewed
 * as part of a normal diff.
 *
 * This runner applies numbered .sql files in order, exactly once, and records
 * each one in a `schema_migrations` table.
 *
 * USAGE
 * -----
 *   npm run migrate           apply every pending migration
 *   npm run migrate:status    show applied / pending, and flag edited files
 *   npm run migrate:mark 0001 record a migration as applied WITHOUT running it
 *
 * `migrate:mark` exists for the existing production database, which already
 * contains every baseline table. Mark the baselines applied there once, then
 * let everything after that run normally.
 *
 * CONVENTIONS
 * -----------
 *   - Files live in afrifx-api/migrations/ and are named NNNN_snake_case.sql
 *   - Migrations are append-only. Never edit one that has been applied;
 *     write a new one. (The checksum check will warn you if you do.)
 *   - Statements are split on `;` and run ONE AT A TIME, because libSQL stops
 *     at the first error in a multi-statement string, which would otherwise
 *     leave a migration half-applied with no record of it.
 *   - `ALTER TABLE ... ADD COLUMN` has no IF NOT EXISTS in SQLite, so a
 *     "duplicate column name" error is treated as already-applied and skipped
 *     rather than failing. Every other error aborts.
 */

import { createClient } from '@libsql/client'
import * as dotenv from 'dotenv'
import {
  loadMigrations, splitStatements, isAlreadyApplied, type Migration,
} from './migrate-lib'

dotenv.config()

const client = createClient({
  url:       process.env.TURSO_DATABASE_URL ?? 'file:local.db',
  authToken: process.env.TURSO_AUTH_TOKEN,
})

// ── helpers ────────────────────────────────────────────────

async function ensureMigrationsTable() {
  await client.execute(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version    TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      checksum   TEXT NOT NULL,
      applied_at INTEGER NOT NULL
    )
  `)
}

async function appliedMap(): Promise<Map<string, { checksum: string; applied_at: number }>> {
  const res = await client.execute('SELECT version, checksum, applied_at FROM schema_migrations')
  const map = new Map<string, { checksum: string; applied_at: number }>()
  for (const row of res.rows as any[]) {
    map.set(String(row.version), {
      checksum:   String(row.checksum),
      applied_at: Number(row.applied_at),
    })
  }
  return map
}

async function record(m: Migration) {
  await client.execute({
    sql: `INSERT INTO schema_migrations (version, name, checksum, applied_at)
          VALUES (?, ?, ?, ?)`,
    args: [m.version, m.name, m.checksum, Math.floor(Date.now() / 1000)],
  })
}

// ── commands ───────────────────────────────────────────────

async function up() {
  await ensureMigrationsTable()
  const applied    = await appliedMap()
  const migrations = loadMigrations()
  const pending    = migrations.filter(m => !applied.has(m.version))

  if (!pending.length) {
    console.log(`✓ Up to date (${applied.size} migration(s) applied)`)
    return
  }

  console.log(`→ ${pending.length} pending migration(s)\n`)

  for (const m of pending) {
    const statements = splitStatements(m.sql)
    console.log(`  ${m.file}  (${statements.length} statement(s))`)

    for (let i = 0; i < statements.length; i++) {
      try {
        await client.execute(statements[i])
      } catch (err: any) {
        if (isAlreadyApplied(err)) {
          console.log(`    · stmt ${i + 1}: already applied, skipped`)
          continue
        }
        console.error(`\n✗ ${m.file} failed at statement ${i + 1}:\n`)
        console.error(statements[i].slice(0, 400))
        console.error(`\n${err?.message ?? err}\n`)
        console.error(
          'Nothing was recorded for this migration. Fix the SQL (or the\n' +
          'database) and run again. Statements before this one already ran,\n' +
          'so make sure re-running is safe before you do.',
        )
        process.exit(1)
      }
    }

    await record(m)
    console.log(`    ✓ applied\n`)
  }

  console.log('✓ Done')
}

async function status() {
  await ensureMigrationsTable()
  const applied    = await appliedMap()
  const migrations = loadMigrations()

  console.log('')
  for (const m of migrations) {
    const a = applied.get(m.version)
    if (!a) {
      console.log(`  PENDING  ${m.file}`)
    } else if (a.checksum !== m.checksum) {
      console.log(`  EDITED!  ${m.file}  <- applied, but the file has changed since`)
    } else {
      const when = new Date(a.applied_at * 1000).toISOString().slice(0, 16).replace('T', ' ')
      console.log(`  applied  ${m.file}  ${when}`)
    }
  }

  // Migrations recorded in the DB with no matching file: usually means someone
  // deleted or renamed a migration that had already run somewhere.
  const known = new Set(migrations.map(m => m.version))
  for (const [version] of applied) {
    if (!known.has(version)) {
      console.log(`  ORPHAN   ${version}  <- in database, no file in migrations/`)
    }
  }
  console.log('')
}

async function mark(version: string) {
  await ensureMigrationsTable()
  const m = loadMigrations().find(x => x.version === version)
  if (!m) {
    console.error(`✗ No migration with version "${version}"`)
    process.exit(1)
  }
  const applied = await appliedMap()
  if (applied.has(version)) {
    console.log(`· ${m.file} is already recorded as applied`)
    return
  }
  await record(m)
  console.log(`✓ Recorded ${m.file} as applied WITHOUT running it`)
}

// ── entry ──────────────────────────────────────────────────

const [cmd, arg] = process.argv.slice(2)

const run =
  cmd === 'status' ? status()
  : cmd === 'mark' ? (
      arg
        ? mark(arg)
        : (console.error('✗ Usage: npm run migrate:mark <version>   e.g. 0001'), process.exit(1))
    )
  : up()

Promise.resolve(run)
  .then(() => process.exit(0))
  .catch(err => {
    console.error('✗ Migration runner failed:', err?.message ?? err)
    process.exit(1)
  })
