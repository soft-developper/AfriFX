#!/usr/bin/env bash
# ============================================================
# phase0-migrations-and-tests.sh
#
# PHASE 0.3 + 0.4 - Database migrations, and the first tests.
#
# SUPERSEDES phase0-migrations.sh. Run this one instead; if you
# already ran that script, running this is safe and fixes a real
# problem in it (see FIX below).
#
# ── 0.3 MIGRATIONS ─────────────────────────────────────────
# Schema changes were loose *-schema.sql files pasted into the Turso
# shell by hand. No ordering, no record of what ran where.
#
# Worse, three groups of tables were never written down as SQL:
#   core   (transactions, p2p_offers, disputes, fx_rates, users)
#          - created by `drizzle-kit push` from src/db/schema.ts
#   admin  (admins, sessions, audit log, invitations, ...)
#   app    (profiles, messages, invoices, payments, notifications, ...)
# A fresh database could NOT be built from this repo. All three are
# reconstructed here from the route code: 13 migrations, 33 tables.
#
# Also disables `npm run db:push`. src/db/schema.ts describes 5 of
# ~29 real tables, so a push would offer to DROP the other 24.
#
#   npm run migrate           apply pending
#   npm run migrate:status    applied / pending / edited-since-applied
#   npm run migrate:mark NNNN record as applied WITHOUT running
#
# FIX vs the earlier script: migrate.ts used `import.meta`, which is
# illegal under this package's tsconfig (module=CommonJS) and fails
# `npx tsc --noEmit` in CI. Path resolution no longer uses it.
#
# ── 0.4 TESTS ──────────────────────────────────────────────
# First test suite (vitest), 40 tests:
#   tests/duty.test.ts        the duty-window logic behind the dispute
#                             gate - boundaries, midnight, UTC anchoring
#   tests/migrate-lib.test.ts statement splitting (quotes, comments) and
#                             migration file naming/numbering integrity
#   tests/migrations.test.ts  integration: builds a database from empty,
#                             asserts every table the code queries exists,
#                             is idempotent, and accepts real inserts
#
# The integration test is the one that would have caught the missing
# baselines automatically.
#
# Verified by mutation: dropping a baseline migration, making the duty
# window end inclusive, replacing the splitter with split(';'), and
# changing the payroll dest_chain default all make the suite fail.
#
# `npm test` is wired into the API CI job, before the build.
#
# AFTER RUNNING: cd afrifx-api && npm install   (adds vitest)
# Safe to re-run: writes whole files.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-api/package.json")"
cat > 'afrifx-api/package.json' <<'AFX_G00_EOF'
{
  "name": "afrifx-api",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "tsx src/index.ts",
    "build": "tsc",
    "test": "vitest run",
    "test:watch": "vitest",
    "start": "node dist/index.js",
    "db:push": "echo 'db:push is DISABLED. src/db/schema.ts describes only 5 of ~29 real tables, so drizzle-kit push would offer to DROP the other 24. Use: npm run migrate' && exit 1",
    "migrate": "tsx src/db/migrate.ts",
    "migrate:status": "tsx src/db/migrate.ts status",
    "migrate:mark": "tsx src/db/migrate.ts mark"
  },
  "dependencies": {
    "@anthropic-ai/sdk": "^0.112.4",
    "@libsql/client": "^0.10.0",
    "bcryptjs": "^3.0.3",
    "cloudinary": "^2.10.0",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "drizzle-orm": "^0.33.0",
    "express": "^4.19.2",
    "express-rate-limit": "^8.5.2",
    "helmet": "^8.3.0",
    "jsonwebtoken": "^9.0.3",
    "multer": "^2.2.0",
    "node-cron": "^3.0.3",
    "otpauth": "^9.5.1",
    "pdfkit": "^0.19.1",
    "qrcode": "^1.5.4",
    "resend": "^6.16.0",
    "viem": "^2.17.7"
  },
  "devDependencies": {
    "@types/bcryptjs": "^2.4.6",
    "@types/cors": "^2.8.17",
    "@types/express": "^4.17.21",
    "@types/express-rate-limit": "^5.1.3",
    "@types/jsonwebtoken": "^9.0.10",
    "@types/multer": "^2.1.0",
    "@types/node": "^20",
    "@types/node-cron": "^3.0.11",
    "@types/pdfkit": "^0.17.6",
    "@types/qrcode": "^1.5.6",
    "drizzle-kit": "^0.24.0",
    "tsx": "^4.19.1",
    "typescript": "^5",
    "vitest": "^2.1.9"
  }
}
AFX_G00_EOF
echo "  ✓ afrifx-api/package.json"

mkdir -p "$(dirname "afrifx-api/.gitignore")"
cat > 'afrifx-api/.gitignore' <<'AFX_G01_EOF'
node_modules/
dist/
.env
.env.*
!.env.example
*.log
*.tsbuildinfo

# Local scratch databases: the migration runner defaults to file:local.db,
# and the integration tests write a temp db under tests/.
local.db
*.db
*.db-wal
*.db-shm
tests/.tmp-*
AFX_G01_EOF
echo "  ✓ afrifx-api/.gitignore"

mkdir -p "$(dirname "afrifx-api/vitest.config.ts")"
cat > 'afrifx-api/vitest.config.ts' <<'AFX_G02_EOF'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Money-moving code: run tests serially so integration tests that touch a
    // scratch SQLite file can't race each other.
    fileParallelism: false,
    include: ['tests/**/*.test.ts'],
    environment: 'node',
  },
})
AFX_G02_EOF
echo "  ✓ afrifx-api/vitest.config.ts"

mkdir -p "$(dirname "afrifx-api/src/db/migrate-lib.ts")"
cat > 'afrifx-api/src/db/migrate-lib.ts' <<'AFX_G03_EOF'
/**
 * Pure helpers for the migration runner.
 *
 * Split out from migrate.ts so they can be unit tested without the runner's
 * side effects (it connects to a database and executes a command on import).
 */

import { readdirSync, readFileSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { join } from 'node:path'

/**
 * Locate the migrations directory.
 *
 * Deliberately avoids `import.meta` (tsconfig sets module=CommonJS, which
 * rejects it) and `__dirname` (undefined when vitest loads this as ESM).
 * Both `npm run migrate` and `npm test` run with the working directory set to
 * afrifx-api, so resolve from cwd, with a fallback for running from the repo
 * root.
 */
function findMigrationsDir(): string {
  const candidates = [
    join(process.cwd(), 'migrations'),
    join(process.cwd(), 'afrifx-api', 'migrations'),
  ]
  for (const c of candidates) if (existsSync(c)) return c
  throw new Error(
    `Could not find a migrations directory. Looked in:\n  ${candidates.join('\n  ')}\n` +
    `Run this from afrifx-api (or the repo root).`,
  )
}

export const MIGRATIONS_DIR = findMigrationsDir()

export interface Migration {
  version:  string   // '0001'
  name:     string   // 'core'
  file:     string   // '0001_core.sql'
  sql:      string
  checksum: string
}

export function checksum(sql: string): string {
  return createHash('sha256').update(sql).digest('hex').slice(0, 16)
}

export function loadMigrations(dir: string = MIGRATIONS_DIR): Migration[] {
  const files = readdirSync(dir)
    .filter(f => f.endsWith('.sql'))
    .sort()

  return files.map(file => {
    const m = /^(\d{4})_(.+)\.sql$/.exec(file)
    if (!m) {
      throw new Error(
        `Migration "${file}" is misnamed. Expected NNNN_snake_case.sql`,
      )
    }
    const sql = readFileSync(join(dir, file), 'utf8')
    return { version: m[1], name: m[2], file, sql, checksum: checksum(sql) }
  })
}

/**
 * Split a migration into individual statements.
 *
 * Naive `sql.split(';')` breaks on semicolons inside string literals and
 * comments, so we scan character by character and only treat `;` as a
 * terminator when we're not inside a quote or a comment.
 */
export function splitStatements(sql: string): string[] {
  const out: string[] = []
  let buf = ''
  let inSingle = false, inDouble = false
  let inLineComment = false, inBlockComment = false

  for (let i = 0; i < sql.length; i++) {
    const c = sql[i]
    const next = sql[i + 1]

    if (inLineComment) {
      if (c === '\n') inLineComment = false
      buf += c
      continue
    }
    if (inBlockComment) {
      if (c === '*' && next === '/') { inBlockComment = false; buf += c + next; i++; continue }
      buf += c
      continue
    }
    if (!inSingle && !inDouble) {
      if (c === '-' && next === '-') { inLineComment = true;  buf += c + next; i++; continue }
      if (c === '/' && next === '*') { inBlockComment = true; buf += c + next; i++; continue }
    }

    if (c === "'" && !inDouble) {
      // '' is an escaped quote inside a string, not a terminator
      if (inSingle && next === "'") { buf += c + next; i++; continue }
      inSingle = !inSingle
      buf += c
      continue
    }
    if (c === '"' && !inSingle) { inDouble = !inDouble; buf += c; continue }

    if (c === ';' && !inSingle && !inDouble) {
      if (buf.trim()) out.push(buf.trim())
      buf = ''
      continue
    }
    buf += c
  }

  if (buf.trim()) out.push(buf.trim())

  // Drop fragments that are only comments/whitespace, they aren't executable
  return out.filter(s => {
    const stripped = s
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/--[^\n]*/g, '')
      .trim()
    return stripped.length > 0
  })
}

/** SQLite cannot express "ADD COLUMN IF NOT EXISTS", so re-adding is a no-op. */
export function isAlreadyApplied(err: any): boolean {
  const msg = String(err?.message ?? err).toLowerCase()
  return msg.includes('duplicate column name')
      || msg.includes('already exists')
}
AFX_G03_EOF
echo "  ✓ afrifx-api/src/db/migrate-lib.ts"

mkdir -p "$(dirname "afrifx-api/src/db/migrate.ts")"
cat > 'afrifx-api/src/db/migrate.ts' <<'AFX_G04_EOF'
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
AFX_G04_EOF
echo "  ✓ afrifx-api/src/db/migrate.ts"

mkdir -p "$(dirname "afrifx-api/migrations/README.md")"
cat > 'afrifx-api/migrations/README.md' <<'AFX_G05_EOF'
# Database migrations

Every schema change goes in this folder. Nothing gets pasted into the Turso
shell by hand any more.

## Commands

```bash
npm run migrate            # apply all pending migrations
npm run migrate:status     # what's applied, what's pending, what's been edited
npm run migrate:mark 0001  # record as applied WITHOUT running (see below)
```

## First run against the existing production database

Production already contains every table in `0001`–`0013`. Those migrations are
written to be safe to re-run (`IF NOT EXISTS`, and the runner skips
"duplicate column" errors), so you can simply run:

```bash
npm run migrate
```

If you'd rather not touch production schema at all, mark the baselines instead:

```bash
for v in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011 0012 0013; do
  npm run migrate:mark $v
done
```

Either way, from `0014` onward everything applies normally.

## What the baselines are

`0001`–`0003` did not exist as SQL anywhere before. The core tables came from
`drizzle-kit push`, and the admin and app tables were created by hand in the
Turso shell, which meant **a fresh database could not be built from this
repository at all**. They were reconstructed from the `INSERT` statements and
row normalizers in the route code.

`0004`–`0013` are the former loose `*-schema.sql` files from `afrifx-api/`,
moved here unchanged and given an order.

## Writing a migration

1. Create `NNNN_snake_case.sql` with the next free number.
2. Write plain SQL. Multiple statements are fine — the runner splits on `;`
   and executes them one at a time, because libSQL aborts a multi-statement
   string at the first error and would leave you half-migrated.
3. Prefer `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`.
4. `ALTER TABLE ... ADD COLUMN` has no `IF NOT EXISTS` in SQLite. Write it
   plainly — the runner treats "duplicate column name" as already-applied.
5. Run `npm run migrate` locally, then commit the file.

## Rules

- **Append-only.** Never edit a migration that has already run. Write a new
  one. `migrate:status` flags edited files as `EDITED!` by checksum.
- **One concern per migration.** Easier to review, easier to reason about when
  something fails halfway.
- **No `drizzle-kit push`.** `src/db/schema.ts` describes only 5 of roughly 29
  real tables, so a push would offer to drop the other 24. The `db:push`
  script is deliberately disabled.

## Note on `src/db/schema.ts`

The drizzle schema is badly out of date and is **not** the source of truth for
this database — these migration files are. The schema file is only used for
typing on the handful of tables it does define. Don't run schema-sync tools
against it.
AFX_G05_EOF
echo "  ✓ afrifx-api/migrations/README.md"

mkdir -p "$(dirname "afrifx-api/migrations/0001_core.sql")"
cat > 'afrifx-api/migrations/0001_core.sql' <<'AFX_G06_EOF'
-- ============================================================
-- Core tables.
--
-- These five tables were created by `drizzle-kit push` from
-- src/db/schema.ts and were never written down as SQL, so a fresh
-- database could not be built from this repository at all. Every
-- later migration assumes they exist (0003 alters p2p_offers, the
-- disputes flow reads `disputes`, and so on).
--
-- Transcribed from src/db/schema.ts. Production already has these,
-- so running this there is a no-op.
-- ============================================================

CREATE TABLE IF NOT EXISTS transactions (
  id            TEXT PRIMARY KEY,
  wallet_address TEXT NOT NULL,
  from_currency TEXT NOT NULL,
  to_currency   TEXT NOT NULL,
  from_amount   REAL NOT NULL,
  to_amount     REAL NOT NULL,
  spread_fee    REAL NOT NULL,
  network_fee   REAL NOT NULL DEFAULT 0.001,
  arc_tx_hash   TEXT,
  memo_id       TEXT,
  reference     TEXT,
  corridor_id   TEXT,
  corridor_step INTEGER,
  status        TEXT NOT NULL DEFAULT 'pending',
  settled_at    INTEGER,
  created_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_transactions_wallet
  ON transactions (wallet_address);

CREATE TABLE IF NOT EXISTS p2p_offers (
  id                  TEXT PRIMARY KEY,
  maker_address       TEXT NOT NULL,
  taker_address       TEXT,
  usdc_amount         REAL NOT NULL,
  local_currency      TEXT NOT NULL,
  local_amount        REAL NOT NULL,
  rate_offered        REAL NOT NULL,
  order_type          TEXT NOT NULL DEFAULT 'market',
  limit_rate          REAL,
  maker_timer_seconds INTEGER NOT NULL DEFAULT 1800,
  status              TEXT NOT NULL DEFAULT 'open',
  maker_confirmed     INTEGER NOT NULL DEFAULT 0,
  taker_confirmed     INTEGER NOT NULL DEFAULT 0,
  taker_deadline      INTEGER,
  maker_deadline      INTEGER,
  dispute_raised      INTEGER NOT NULL DEFAULT 0,
  dispute_id          TEXT,
  arc_tx_hash         TEXT,
  release_tx_hash     TEXT,
  created_at          INTEGER NOT NULL,
  updated_at          INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_p2p_offers_status
  ON p2p_offers (status);
CREATE INDEX IF NOT EXISTS idx_p2p_offers_maker
  ON p2p_offers (maker_address);

CREATE TABLE IF NOT EXISTS disputes (
  id             TEXT PRIMARY KEY,
  offer_id       TEXT NOT NULL,
  raised_by      TEXT NOT NULL,
  reason         TEXT,
  status         TEXT NOT NULL DEFAULT 'open',
  auto_settle_at INTEGER NOT NULL,
  settled_at     INTEGER,
  created_at     INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_disputes_offer
  ON disputes (offer_id);
CREATE INDEX IF NOT EXISTS idx_disputes_status
  ON disputes (status);

CREATE TABLE IF NOT EXISTS fx_rates (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  pair       TEXT NOT NULL,
  rate       REAL NOT NULL,
  change_24h REAL NOT NULL DEFAULT 0,
  source     TEXT NOT NULL,
  fetched_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_fx_rates_pair
  ON fx_rates (pair);

CREATE TABLE IF NOT EXISTS users (
  wallet_address   TEXT PRIMARY KEY,
  volume_30d       REAL NOT NULL DEFAULT 0,
  tx_count         INTEGER NOT NULL DEFAULT 0,
  dispute_warnings INTEGER NOT NULL DEFAULT 0,
  created_at       INTEGER NOT NULL
);
AFX_G06_EOF
echo "  ✓ afrifx-api/migrations/0001_core.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0002_admin_core.sql")"
cat > 'afrifx-api/migrations/0002_admin_core.sql' <<'AFX_G07_EOF'
-- ============================================================
-- Admin authentication and audit tables.
--
-- Like the core tables in 0000, these were created ad hoc and never
-- written down, so a fresh database had no `admins` table and every
-- admin feature failed. Migration 0005 (duty sessions) alters
-- `admins`, so this has to come first.
--
-- Reconstructed from the INSERT statements and row normalizers in:
--   src/lib/adminAuth.ts, src/lib/seedAdmin.ts,
--   src/routes/adminAuth.ts, src/routes/adminManage.ts
--
-- Production already has these, so this is a no-op there.
--
-- Note: `permissions` holds either a JSON array of permission strings
-- or the literal 'all' for the super admin - see parsePermissions().
-- ============================================================

CREATE TABLE IF NOT EXISTS admins (
  id              TEXT PRIMARY KEY,
  username        TEXT NOT NULL UNIQUE,
  email           TEXT NOT NULL UNIQUE,
  password_hash   TEXT NOT NULL,
  wallet_address  TEXT,
  role            TEXT NOT NULL DEFAULT 'sub_admin',
  permissions     TEXT,
  status          TEXT NOT NULL DEFAULT 'active',
  suspended_until INTEGER,
  created_by      TEXT,
  last_login      INTEGER,
  setup_completed INTEGER NOT NULL DEFAULT 0,
  is_active       INTEGER NOT NULL DEFAULT 1,
  login_attempts  INTEGER NOT NULL DEFAULT 0,
  locked_until    INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_sessions (
  id             TEXT PRIMARY KEY,
  admin_id       TEXT NOT NULL,
  token          TEXT NOT NULL UNIQUE,
  ip_address     TEXT,
  user_agent     TEXT,
  created_at     INTEGER NOT NULL,
  expires_at     INTEGER NOT NULL,
  last_active_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_admin_sessions_token
  ON admin_sessions (token);
CREATE INDEX IF NOT EXISTS idx_admin_sessions_admin
  ON admin_sessions (admin_id);

CREATE TABLE IF NOT EXISTS admin_audit_log (
  id          TEXT PRIMARY KEY,
  admin_id    TEXT,
  admin_name  TEXT,
  action      TEXT NOT NULL,
  target_type TEXT,
  target_id   TEXT,
  details     TEXT,
  ip_address  TEXT,
  created_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_admin
  ON admin_audit_log (admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_audit_created
  ON admin_audit_log (created_at);

CREATE TABLE IF NOT EXISTS admin_login_log (
  id         TEXT PRIMARY KEY,
  admin_id   TEXT,
  email      TEXT,
  success    INTEGER NOT NULL DEFAULT 0,
  ip_address TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_password_resets (
  id         TEXT PRIMARY KEY,
  admin_id   TEXT NOT NULL,
  token      TEXT NOT NULL UNIQUE,
  used_at    INTEGER,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_invitations (
  id          TEXT PRIMARY KEY,
  email       TEXT NOT NULL,
  invited_by  TEXT,
  permissions TEXT,
  token       TEXT NOT NULL UNIQUE,
  accepted_at INTEGER,
  expires_at  INTEGER NOT NULL,
  created_at  INTEGER NOT NULL
);
AFX_G07_EOF
echo "  ✓ afrifx-api/migrations/0002_admin_core.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0003_app_core.sql")"
cat > 'afrifx-api/migrations/0003_app_core.sql' <<'AFX_G08_EOF'
-- ============================================================
-- Remaining application tables.
--
-- The last group of tables created ad hoc and never written down.
-- Later migrations depend on these existing: 0009 (broadcasts) adds
-- columns to `profiles`, so this must run before it.
--
-- Reconstructed from the INSERT statements in:
--   src/routes/profile.ts, src/routes/messages.ts, src/routes/invoices.ts,
--   src/routes/payments.ts, src/routes/treasury.ts, src/routes/disputes.ts,
--   src/services/notify.ts
--
-- Production already has these, so this is a no-op there.
-- ============================================================

-- User profiles (username, socials, notification prefs).
CREATE TABLE IF NOT EXISTS profiles (
  wallet_address   TEXT PRIMARY KEY,
  username         TEXT UNIQUE,
  display_name     TEXT,
  bio              TEXT,
  email            TEXT,
  twitter_handle   TEXT,
  telegram_handle  TEXT,
  avatar_color     TEXT,
  show_socials     INTEGER NOT NULL DEFAULT 1,
  suspended        INTEGER NOT NULL DEFAULT 0,
  last_active_at   INTEGER,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_profiles_username
  ON profiles (username);

-- P2P trade chat.
CREATE TABLE IF NOT EXISTS messages (
  id           TEXT PRIMARY KEY,
  offer_id     TEXT NOT NULL,
  sender       TEXT NOT NULL,
  content      TEXT,
  media_url    TEXT,
  media_type   TEXT,
  msg_type     TEXT NOT NULL DEFAULT 'text',
  quick_action TEXT,
  read_at      INTEGER,
  created_at   INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_messages_offer
  ON messages (offer_id);

-- Dispute handling: which admin took it, and the dispute thread.
CREATE TABLE IF NOT EXISTS dispute_assignments (
  id          TEXT PRIMARY KEY,
  dispute_id  TEXT NOT NULL,
  admin_id    TEXT NOT NULL,
  admin_name  TEXT,
  accepted_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dispute_assignments_dispute
  ON dispute_assignments (dispute_id);

CREATE TABLE IF NOT EXISTS dispute_messages (
  id          TEXT PRIMARY KEY,
  dispute_id  TEXT NOT NULL,
  sender_id   TEXT,
  sender_type TEXT,
  sender_name TEXT,
  content     TEXT,
  media_url   TEXT,
  media_type  TEXT,
  admin_only  INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dispute_messages_dispute
  ON dispute_messages (dispute_id);

-- Outbound email/notification queue.
CREATE TABLE IF NOT EXISTS notifications (
  id              TEXT PRIMARY KEY,
  user_wallet     TEXT,
  recipient_email TEXT,
  type            TEXT NOT NULL,
  subject         TEXT,
  payload         TEXT,
  status          TEXT NOT NULL DEFAULT 'pending',
  attempts        INTEGER NOT NULL DEFAULT 0,
  sent_at         INTEGER,
  created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_notifications_status
  ON notifications (status);

-- Throttle for transactional email, keyed by "type:recipient".
CREATE TABLE IF NOT EXISTS email_rate_limits (
  key       TEXT PRIMARY KEY,
  last_sent INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS invoices (
  id               TEXT PRIMARY KEY,
  creator_address  TEXT NOT NULL,
  payer_address    TEXT,
  amount           REAL NOT NULL,
  currency         TEXT NOT NULL DEFAULT 'USDC',
  description      TEXT,
  notes            TEXT,
  due_date         INTEGER,
  memo_ref         TEXT,
  status           TEXT NOT NULL DEFAULT 'pending',
  reminder_sent_at INTEGER,
  paid_at          INTEGER,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_invoices_creator
  ON invoices (creator_address);
CREATE INDEX IF NOT EXISTS idx_invoices_payer
  ON invoices (payer_address);

CREATE TABLE IF NOT EXISTS payments (
  id                TEXT PRIMARY KEY,
  sender_address    TEXT NOT NULL,
  recipient_address TEXT NOT NULL,
  amount            REAL NOT NULL,
  currency          TEXT NOT NULL DEFAULT 'USDC',
  local_currency    TEXT,
  local_amount      REAL,
  description       TEXT,
  invoice_ref       TEXT,
  invoice_id        TEXT,
  memo_ref          TEXT,
  status            TEXT NOT NULL DEFAULT 'pending',
  arc_tx_hash       TEXT,
  created_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_payments_sender
  ON payments (sender_address);
CREATE INDEX IF NOT EXISTS idx_payments_recipient
  ON payments (recipient_address);

-- Treasury automation rules (parked until the mainnet contract lands).
CREATE TABLE IF NOT EXISTS treasury_rules (
  id                TEXT PRIMARY KEY,
  wallet_address    TEXT NOT NULL,
  name              TEXT NOT NULL,
  trigger_threshold REAL,
  action_percent    REAL,
  action_amount     REAL,
  target_currency   TEXT,
  enabled           INTEGER NOT NULL DEFAULT 1,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_treasury_rules_wallet
  ON treasury_rules (wallet_address);
AFX_G08_EOF
echo "  ✓ afrifx-api/migrations/0003_app_core.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0004_phase_d.sql")"
cat > 'afrifx-api/migrations/0004_phase_d.sql' <<'AFX_G09_EOF'
-- ============================================================
-- AfriFX Phase D site content tables
-- Run ONCE against your Turso DB:
--   turso db shell <your-db-name> < phaseD-schema.sql
-- (or paste the statements into: turso db shell <your-db-name>)
-- ============================================================

-- Single-row-per-key store for editable page content.
-- key = 'about'   -> value holds a JSON array of { heading, body } sections
-- key = 'contact' -> value holds a JSON object of contact fields
CREATE TABLE IF NOT EXISTS site_content (
  key         TEXT PRIMARY KEY,          -- 'about' | 'contact'
  value       TEXT NOT NULL,             -- JSON payload
  updated_by  TEXT,                      -- admin id who last edited
  updated_at  INTEGER NOT NULL           -- unix seconds
);

-- Messages submitted through the public Contact form.
-- Stored as a record AND emailed to the platform inbox via Resend.
CREATE TABLE IF NOT EXISTS contact_messages (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  email       TEXT NOT NULL,
  subject     TEXT,
  message     TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'new',  -- new | read | archived
  created_at  INTEGER NOT NULL
);

-- Seed sensible defaults so the public pages are never blank before
-- the admin edits them. INSERT OR IGNORE keeps existing rows untouched.
INSERT OR IGNORE INTO site_content (key, value, updated_at) VALUES
  ('about',
   '[{"heading":"About AfriFX","body":"AfriFX is a decentralized foreign-exchange and cross-border payments platform built on the Arc blockchain, making it fast and affordable to move value across Africa using stablecoins."},{"heading":"Our mission","body":"To give everyone access to instant, low-cost currency exchange and cross-border payments without the delays and fees of traditional banking."},{"heading":"How it works","body":"Convert between USDC and local currencies directly, or trade peer-to-peer on our marketplace. Every transaction settles on Arc in under a second, with fees paid in USDC."}]',
   strftime('%s','now')),
  ('contact',
   '{"email":"support@afrifx.xyz","phone":"","address":"","supportHours":"Monday to Friday, 9am – 5pm WAT","twitter":"https://x.com/afrifx","telegram":"","discord":""}',
   strftime('%s','now'));
AFX_G09_EOF
echo "  ✓ afrifx-api/migrations/0004_phase_d.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0005_contact_messages.sql")"
cat > 'afrifx-api/migrations/0005_contact_messages.sql' <<'AFX_G10_EOF'
-- Ensures the contact_messages table exists (safe if Phase D already made it).
-- Run once if you're unsure whether Phase D's schema was applied:
--   turso db shell <your-db-name> < afrifx-api/messages-schema.sql
CREATE TABLE IF NOT EXISTS contact_messages (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  email       TEXT NOT NULL,
  subject     TEXT,
  message     TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'new',  -- new | read | archived
  created_at  INTEGER NOT NULL
);
AFX_G10_EOF
echo "  ✓ afrifx-api/migrations/0005_contact_messages.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0006_p2p_bank_details.sql")"
cat > 'afrifx-api/migrations/0006_p2p_bank_details.sql' <<'AFX_G11_EOF'
-- Adds the maker's payout details to each P2P offer, so a taker who accepts
-- knows exactly where to send the local-currency payment.
-- Safe to run more than once: each ADD COLUMN is guarded.
-- Run:  turso db shell <your-db-name> < afrifx-api/p2p-bank-details-schema.sql
--
-- SQLite/libSQL has no "ADD COLUMN IF NOT EXISTS", so if a column already
-- exists the statement errors harmlessly run them individually if needed.

ALTER TABLE p2p_offers ADD COLUMN payment_method   TEXT DEFAULT 'bank';   -- 'bank' | 'mobile_money'
ALTER TABLE p2p_offers ADD COLUMN account_name     TEXT;                  -- account holder / recipient name
ALTER TABLE p2p_offers ADD COLUMN account_number   TEXT;                  -- bank account no. OR mobile-money phone
ALTER TABLE p2p_offers ADD COLUMN bank_name        TEXT;                  -- bank name OR mobile-money provider
ALTER TABLE p2p_offers ADD COLUMN payment_note     TEXT;                  -- optional instructions / reference
AFX_G11_EOF
echo "  ✓ afrifx-api/migrations/0006_p2p_bank_details.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0007_bridge.sql")"
cat > 'afrifx-api/migrations/0007_bridge.sql' <<'AFX_G12_EOF'
-- ============================================================
-- CCTP bridge transfers.
--
-- WHY THIS TABLE EXISTS AT ALL:
-- CCTP is burn-and-mint. Circle's own docs are blunt about the consequence:
-- "Once USDC is burned, complete the mint on destination or lose funds."
-- There is no rollback. If the browser closes, the user's laptop dies, or our
-- API restarts between the burn and the mint, the money is NOT gone but it IS
-- stranded until someone finishes the mint.
--
-- So every bridge is recorded BEFORE the burn is signed, and each stage is
-- persisted as it completes. That gives us:
--   * a resume path        (user returns, we know exactly where they were)
--   * a reconciler target  (a cron can finish stuck mints)
--   * an audit trail       (what happened, when, on which chain)
--
-- THE TWO FIELDS THAT MAKE RECOVERY POSSIBLE are message_bytes and
-- message_hash. Once we have those from the burn receipt, the mint can be
-- completed by ANYONE at ANY TIME (attestations don't expire) -- so as long as
-- they're saved, funds are recoverable even if everything else fails.
--
-- RUN EACH STATEMENT INDIVIDUALLY in the turso shell (it stops on first error).
-- ============================================================

CREATE TABLE IF NOT EXISTS bridge_transfers (
  id              TEXT PRIMARY KEY,        -- 'br-<uuid>'
  wallet_address  TEXT NOT NULL,           -- who owns this bridge (the signer)

  -- Route
  from_chain      TEXT NOT NULL,           -- our chain key, e.g. 'arc'
  to_chain        TEXT NOT NULL,           -- e.g. 'base'
  from_domain     INTEGER NOT NULL,        -- CCTP domain (NOT the EVM chain id)
  to_domain       INTEGER NOT NULL,
  amount          REAL NOT NULL,           -- USDC, human units
  recipient       TEXT NOT NULL,           -- destination address (usually same wallet)

  -- Stage: created -> approving -> burning -> attesting -> minting -> completed
  --        (or 'failed' at any point; 'stranded' if burned but mint unresolved)
  status          TEXT NOT NULL DEFAULT 'created',

  -- Evidence at each step. These are what make recovery possible.
  approve_tx      TEXT,                    -- ERC-20 approve (not needed on all chains)
  burn_tx         TEXT,                    -- depositForBurn tx hash on source
  message_bytes   TEXT,                    -- the CCTP message emitted by the burn
  message_hash    TEXT,                    -- keccak256(message) -- the attestation key
  attestation     TEXT,                    -- Circle's signature over the message
  mint_tx         TEXT,                    -- receiveMessage tx hash on destination

  error           TEXT,                    -- last error, for support/debugging
  attempts        INTEGER NOT NULL DEFAULT 0,

  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_bridge_wallet ON bridge_transfers (wallet_address, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_bridge_status ON bridge_transfers (status, updated_at);
AFX_G12_EOF
echo "  ✓ afrifx-api/migrations/0007_bridge.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0008_duty_sessions.sql")"
cat > 'afrifx-api/migrations/0008_duty_sessions.sql' <<'AFX_G13_EOF'
-- ============================================================
-- Dispute duty sessions sub-admin working hours + duty tracking
--
-- 1) Working hours live ON the admin record (set by the general admin when
--    inviting them). Max 6 hours, recurring daily, with optional specific dates.
-- 2) admin_duty_sessions records each actual shift: when they clicked
--    "resume duty", when it ended, and what they did this is the session log
--    the general admin reviews.
--
-- SQLite/libSQL has no "ADD COLUMN IF NOT EXISTS": if a column already exists
-- that line errors harmlessly, the rest still apply. Run individually if needed.
-- Run:  turso db shell <your-db-name> < afrifx-api/duty-sessions-schema.sql
-- ============================================================

-- Working hours on the admin record.
-- duty_start_min / duty_end_min: minutes from midnight UTC (e.g. 540 = 09:00 UTC).
-- Max span enforced in app code (6h = 360 min).
ALTER TABLE admins ADD COLUMN duty_start_min   INTEGER;         -- 0..1439, UTC
ALTER TABLE admins ADD COLUMN duty_end_min     INTEGER;         -- 0..1439, UTC
ALTER TABLE admins ADD COLUMN duty_days        TEXT;            -- CSV of 0..6 (Sun..Sat), e.g. '1,2,3,4,5'
ALTER TABLE admins ADD COLUMN duty_dates       TEXT;            -- optional CSV of 'YYYY-MM-DD' specific dates
ALTER TABLE admins ADD COLUMN duty_notified_at INTEGER;         -- last time we sent the 3-min heads-up

CREATE TABLE IF NOT EXISTS admin_duty_sessions (
  id                TEXT PRIMARY KEY,
  admin_id          TEXT NOT NULL,
  admin_name        TEXT NOT NULL,

  -- The scheduled window this session belongs to (unix seconds)
  window_start      INTEGER NOT NULL,
  window_end        INTEGER NOT NULL,

  -- Actual duty
  resumed_at        INTEGER,                -- when they clicked "resume duty"
  ended_at          INTEGER,                -- when the window elapsed / they clocked off
  status            TEXT NOT NULL DEFAULT 'scheduled',
                    -- scheduled | on_duty | ended | missed

  -- Session log (what they did) filled when the session ends
  disputes_accepted INTEGER DEFAULT 0,
  disputes_resolved INTEGER DEFAULT 0,
  actions_count     INTEGER DEFAULT 0,
  log_sent          INTEGER DEFAULT 0,      -- 1 once summarised to the admin dashboard

  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_duty_admin   ON admin_duty_sessions (admin_id);
CREATE INDEX IF NOT EXISTS idx_duty_status  ON admin_duty_sessions (status);
CREATE INDEX IF NOT EXISTS idx_duty_window  ON admin_duty_sessions (window_start, window_end);

-- Working hours are chosen by the general admin at INVITE time, so they must
-- ride along on the invitation and be copied onto the admin record when the
-- sub-admin accepts and sets their password.
ALTER TABLE admin_invitations ADD COLUMN duty_start_min INTEGER;
ALTER TABLE admin_invitations ADD COLUMN duty_end_min   INTEGER;
ALTER TABLE admin_invitations ADD COLUMN duty_days      TEXT;
ALTER TABLE admin_invitations ADD COLUMN duty_dates     TEXT;
AFX_G13_EOF
echo "  ✓ afrifx-api/migrations/0008_duty_sessions.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0009_broadcasts.sql")"
cat > 'afrifx-api/migrations/0009_broadcasts.sql' <<'AFX_G14_EOF'
-- ============================================================
-- Admin broadcasts mass / targeted email from the general admin
--
-- Two things:
--   1) A broadcast opt-out on profiles. Users opted into TRANSACTIONAL alerts
--      (trades / disputes / invoices) a general broadcast is a different
--      category, so they get an explicit opt-out which we always honour.
--      Defaults to 1 (opted in) so existing users still receive announcements,
--      but every broadcast email carries an unsubscribe link.
--   2) A record of every broadcast sent, for the audit trail + delivery stats.
--
-- SQLite/libSQL has no "ADD COLUMN IF NOT EXISTS": if a column already exists
-- that statement errors harmlessly. Run the ALTERs individually if needed.
-- Run:  turso db shell <your-db-name> < afrifx-api/broadcasts-schema.sql
-- ============================================================

-- 1) Broadcast opt-out (users). 1 = will receive broadcasts, 0 = opted out.
ALTER TABLE profiles ADD COLUMN notify_broadcasts INTEGER DEFAULT 1;

-- An unguessable token so a user can unsubscribe from an email link without
-- being logged in. Generated lazily on first broadcast.
ALTER TABLE profiles ADD COLUMN unsubscribe_token TEXT;

-- 2) Broadcast history
CREATE TABLE IF NOT EXISTS admin_broadcasts (
  id              TEXT PRIMARY KEY,
  sent_by_id      TEXT NOT NULL,          -- admin id
  sent_by_name    TEXT NOT NULL,          -- shown in the email header

  audience        TEXT NOT NULL,          -- 'sub_admins' | 'all_users' | 'selected' | 'filtered'
  audience_detail TEXT,                   -- JSON: filter used, or list of recipients

  subject         TEXT NOT NULL,
  body            TEXT NOT NULL,          -- the admin's message (plain text / light markup)

  recipients      INTEGER DEFAULT 0,      -- how many we attempted
  delivered       INTEGER DEFAULT 0,
  failed          INTEGER DEFAULT 0,
  skipped_optout  INTEGER DEFAULT 0,      -- honoured opt-outs (users, not sub-admins)

  status          TEXT NOT NULL DEFAULT 'sending',  -- sending | sent | failed
  error           TEXT,

  created_at      INTEGER NOT NULL,
  completed_at    INTEGER
);

CREATE INDEX IF NOT EXISTS idx_broadcasts_sender ON admin_broadcasts (sent_by_id);
CREATE INDEX IF NOT EXISTS idx_broadcasts_time   ON admin_broadcasts (created_at);
AFX_G14_EOF
echo "  ✓ afrifx-api/migrations/0009_broadcasts.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0010_maintenance.sql")"
cat > 'afrifx-api/migrations/0010_maintenance.sql' <<'AFX_G15_EOF'
-- ============================================================
-- Maintenance mode take the platform, or one section of it, offline
-- from the admin dashboard. No code change, no redeploy.
--
-- Run EACH statement individually (a "table already exists" or "duplicate
-- column" error is harmless just move to the next):
--
--   turso db shell <db> "CREATE TABLE IF NOT EXISTS maintenance_state (...);"
--
-- (The whole file also works on a first, clean run.)
-- ============================================================

CREATE TABLE IF NOT EXISTS maintenance_state (
  section      TEXT PRIMARY KEY,     -- 'platform' | 'convert' | 'marketplace' | …
  enabled      INTEGER NOT NULL DEFAULT 0,
  message      TEXT,                 -- shown to users; falls back to a default
  eta          TEXT,                 -- optional, e.g. "back by 04:00 UTC"
  enabled_by   TEXT,                 -- admin username
  enabled_at   INTEGER,
  updated_at   INTEGER NOT NULL
);
AFX_G15_EOF
echo "  ✓ afrifx-api/migrations/0010_maintenance.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0011_orchestrator.sql")"
cat > 'afrifx-api/migrations/0011_orchestrator.sql' <<'AFX_G16_EOF'
-- ============================================================
-- Payout orchestrator schema cross-border transfers
--
-- Two tables:
--   transfers      one row per end-to-end transfer (user-facing summary)
--   transfer_legs  one row per leg (the audit trail the orchestrator walks)
--
-- Provider-agnostic: no HoneyCoin/Yellow Card specifics live here.
-- Safe to run more than once (IF NOT EXISTS).
-- Run:  turso db shell <your-db-name> < afrifx-api/orchestrator-schema.sql
-- ============================================================

CREATE TABLE IF NOT EXISTS transfers (
  id                TEXT PRIMARY KEY,           -- 'tr-<uuid>'
  sender_address    TEXT NOT NULL,              -- AfriFX wallet initiating
  sender_mode       TEXT NOT NULL,              -- 'fiat_in' | 'usdc_in'

  -- What the sender is sending
  source_currency   TEXT NOT NULL,              -- 'NGN' (fiat_in) or 'USDC' (usdc_in)
  source_amount     REAL NOT NULL,

  -- What the recipient receives
  dest_currency     TEXT NOT NULL,              -- 'KES'
  dest_amount       REAL,                        -- quoted; may firm up after quote
  usdc_amount       REAL,                        -- settlement amount in USDC (the middle)

  -- Recipient payout details (who gets the money)
  recipient_name    TEXT NOT NULL,
  recipient_method  TEXT NOT NULL,              -- 'bank' | 'mobile_money'
  recipient_account TEXT NOT NULL,              -- account no. OR phone
  recipient_bank    TEXT NOT NULL,              -- bank name/code OR provider
  recipient_country TEXT NOT NULL,              -- ISO-2 'KE'
  recipient_note    TEXT,

  -- Routing
  provider          TEXT NOT NULL,              -- 'honeycoin' | 'yellowcard' | 'mock'
  payout_chain      TEXT,                        -- chain provider wants USDC on, e.g. 'base'
  needs_bridge      INTEGER DEFAULT 0,          -- 1 if source USDC is on Arc and must be bridged

  -- FX quote lock
  quote_id          TEXT,
  quote_rate        REAL,
  quote_expires_at  INTEGER,

  -- Lifecycle
  status            TEXT NOT NULL DEFAULT 'created',
                    -- created | in_progress | completed | failed | refunding | refunded
  current_leg       TEXT,
  failure_reason    TEXT,

  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS transfer_legs (
  id              TEXT PRIMARY KEY,             -- 'lg-<uuid>'
  transfer_id     TEXT NOT NULL,               -- -> transfers.id
  leg_type        TEXT NOT NULL,               -- 'onramp'|'collect'|'bridge'|'offramp'|'payout'|'reconcile'
  leg_index       INTEGER NOT NULL,            -- ordering (0,1,2,...)

  status          TEXT NOT NULL DEFAULT 'pending',
                  -- pending | in_flight | done | failed | skipped
  idempotency_key TEXT NOT NULL,               -- prevents double-submits (== provider externalReference)

  -- Evidence, whichever apply to the leg
  provider_ref    TEXT,                         -- provider transaction id
  tx_hash         TEXT,                         -- on-chain hash (collect/bridge)
  attestation     TEXT,                         -- CCTP attestation (bridge)
  amount          REAL,
  currency        TEXT,

  error           TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

-- Helpful indexes for the tick loop and lookups
CREATE INDEX IF NOT EXISTS idx_transfers_status      ON transfers (status);
CREATE INDEX IF NOT EXISTS idx_transfers_sender      ON transfers (sender_address);
CREATE INDEX IF NOT EXISTS idx_legs_transfer         ON transfer_legs (transfer_id);
CREATE INDEX IF NOT EXISTS idx_legs_status           ON transfer_legs (status);
CREATE INDEX IF NOT EXISTS idx_legs_idem             ON transfer_legs (idempotency_key);
AFX_G16_EOF
echo "  ✓ afrifx-api/migrations/0011_orchestrator.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0012_ai_dispute_summaries.sql")"
cat > 'afrifx-api/migrations/0012_ai_dispute_summaries.sql' <<'AFX_G17_EOF'
-- ============================================================
-- AI dispute triage summaries (advisory, admin-facing).
--
-- Caches the generated brief per dispute so we don't re-pay Claude tokens on
-- every page view. Regenerate-on-demand overwrites the row.
--
-- RUN EACH STATEMENT INDIVIDUALLY in the turso shell (it stops on the first
-- error, so a combined file can abort before reaching CREATE TABLE).
-- ============================================================

CREATE TABLE IF NOT EXISTS dispute_ai_summaries (
  dispute_id      TEXT PRIMARY KEY,
  summary_json    TEXT    NOT NULL,   -- the structured brief (JSON)
  generated_by    TEXT,               -- admin id who triggered it
  model           TEXT,               -- which Claude model produced it
  evidence_count  INTEGER DEFAULT 0,  -- how many evidence PDFs were read
  created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ai_summary_dispute ON dispute_ai_summaries (dispute_id);
AFX_G17_EOF
echo "  ✓ afrifx-api/migrations/0012_ai_dispute_summaries.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0013_payroll.sql")"
cat > 'afrifx-api/migrations/0013_payroll.sql' <<'AFX_G18_EOF'
-- ============================================================
-- Payroll batches and recipients.
--
-- These tables were created directly in the Turso shell during an
-- earlier session and never captured in a schema file, so a fresh
-- database had no way to create them. Reconstructed here from the
-- columns the payroll route reads and writes.
--
-- The production database already has these tables. Running this
-- there is a no-op (IF NOT EXISTS), and the dest_chain ALTER is
-- tolerated by the runner if the column is already present.
-- ============================================================

CREATE TABLE IF NOT EXISTS payroll_batches (
  id              TEXT PRIMARY KEY,
  wallet_address  TEXT NOT NULL,
  name            TEXT NOT NULL,
  description     TEXT,
  total_amount    REAL NOT NULL DEFAULT 0,
  currency        TEXT NOT NULL DEFAULT 'USDC',
  recipient_count INTEGER NOT NULL DEFAULT 0,
  status          TEXT NOT NULL DEFAULT 'draft',
  executed_at     INTEGER,
  created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_payroll_batches_wallet
  ON payroll_batches (wallet_address);

CREATE TABLE IF NOT EXISTS payroll_recipients (
  id             TEXT PRIMARY KEY,
  batch_id       TEXT NOT NULL,
  name           TEXT,
  wallet_address TEXT NOT NULL,
  amount         REAL NOT NULL,
  currency       TEXT NOT NULL DEFAULT 'USDC',
  memo_ref       TEXT,
  status         TEXT NOT NULL DEFAULT 'pending',
  tx_hash        TEXT,
  created_at     INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_payroll_recipients_batch
  ON payroll_recipients (batch_id);

-- Multichain payouts: which Gateway chain this batch settles on.
-- 'arc' keeps the original behaviour (direct transfer + Memo).
ALTER TABLE payroll_batches ADD COLUMN dest_chain TEXT NOT NULL DEFAULT 'arc';
AFX_G18_EOF
echo "  ✓ afrifx-api/migrations/0013_payroll.sql"

mkdir -p "$(dirname "afrifx-api/tests/duty.test.ts")"
cat > 'afrifx-api/tests/duty.test.ts' <<'AFX_G19_EOF'
/**
 * Duty window logic.
 *
 * This is the security model behind the dispute gate: only a sub-admin inside
 * their scheduled window (and who has resumed duty) may accept or resolve a
 * dispute, and disputes move real money. The window maths is pure and easy to
 * get subtly wrong around boundaries, midnight, and timezones, so it's tested
 * directly.
 *
 * `isOnDuty` itself is not covered here because it hits the database; these
 * cover the two pure functions it is built on.
 */

import { describe, it, expect } from 'vitest'
import { validateWindow, windowAt, MAX_DUTY_MINUTES } from '../src/lib/duty'

const DAYS_ALL = [0, 1, 2, 3, 4, 5, 6]

/** Unix seconds for a UTC wall-clock time. */
function utc(y: number, m: number, d: number, hh = 0, mm = 0): number {
  return Math.floor(Date.UTC(y, m - 1, d, hh, mm, 0) / 1000)
}

describe('validateWindow', () => {
  it('accepts a normal window on recurring days', () => {
    expect(validateWindow({ startMin: 540, endMin: 720, days: [1, 2, 3] })).toBeNull()
  })

  it('accepts a window with only specific dates and no recurring days', () => {
    expect(validateWindow({
      startMin: 540, endMin: 720, days: [], dates: ['2026-08-11'],
    })).toBeNull()
  })

  it('requires both start and end', () => {
    expect(validateWindow({ endMin: 720, days: [1] })).toBe('Working hours are required')
    expect(validateWindow({ startMin: 540, days: [1] })).toBe('Working hours are required')
  })

  it('rejects an end at or before the start', () => {
    expect(validateWindow({ startMin: 720, endMin: 720, days: [1] }))
      .toBe('End time must be after start time')
    expect(validateWindow({ startMin: 720, endMin: 600, days: [1] }))
      .toBe('End time must be after start time')
  })

  it('allows exactly the maximum session length but not a minute more', () => {
    const start = 0
    expect(validateWindow({ startMin: start, endMin: start + MAX_DUTY_MINUTES, days: [1] }))
      .toBeNull()
    expect(validateWindow({ startMin: start, endMin: start + MAX_DUTY_MINUTES + 1, days: [1] }))
      .toBe('Working session cannot exceed 6 hours')
  })

  it('rejects times outside a single day', () => {
    expect(validateWindow({ startMin: -1, endMin: 60, days: [1] }))
      .toBe('Working hours must be within a single day')
    expect(validateWindow({ startMin: 0, endMin: 1440, days: [1] }))
      .toBe('Working hours must be within a single day')
  })

  it('requires at least one day or date, so a window can never match nothing', () => {
    expect(validateWindow({ startMin: 540, endMin: 720 }))
      .toBe('Choose at least one recurring day or a specific date')
    expect(validateWindow({ startMin: 540, endMin: 720, days: [], dates: [] }))
      .toBe('Choose at least one recurring day or a specific date')
  })

  // A window that spans midnight would have endMin < startMin, which is
  // rejected. Worth pinning: the gate assumes windows live inside one UTC day.
  it('rejects a window that would wrap past midnight', () => {
    expect(validateWindow({ startMin: 1380, endMin: 120, days: [1] }))
      .toBe('End time must be after start time')
  })
})

describe('windowAt', () => {
  // 2026-08-10 is a Monday (UTC).
  const monday = { y: 2026, m: 8, d: 10, dow: 1 }
  const win = { startMin: 540, endMin: 720, days: [monday.dow], dates: [] } // 09:00-12:00

  it('returns the window when inside it on a scheduled day', () => {
    const at  = utc(monday.y, monday.m, monday.d, 10, 0)
    const got = windowAt(win, at)
    expect(got).not.toBeNull()
    expect(got!.start).toBe(utc(monday.y, monday.m, monday.d, 9, 0))
    expect(got!.end).toBe(utc(monday.y, monday.m, monday.d, 12, 0))
  })

  it('is inclusive of the start instant', () => {
    expect(windowAt(win, utc(monday.y, monday.m, monday.d, 9, 0))).not.toBeNull()
  })

  // The end is exclusive: at exactly 12:00 the admin is OFF duty. This is the
  // boundary that decides whether someone can still accept a dispute.
  it('is exclusive of the end instant', () => {
    expect(windowAt(win, utc(monday.y, monday.m, monday.d, 11, 59))).not.toBeNull()
    expect(windowAt(win, utc(monday.y, monday.m, monday.d, 12, 0))).toBeNull()
  })

  it('returns null before the window opens', () => {
    expect(windowAt(win, utc(monday.y, monday.m, monday.d, 8, 59))).toBeNull()
  })

  it('returns null on a day that is not scheduled', () => {
    // 2026-08-11 is a Tuesday; the window only covers Monday.
    expect(windowAt(win, utc(2026, 8, 11, 10, 0))).toBeNull()
  })

  it('matches a specific date even when the weekday is not scheduled', () => {
    const w = { startMin: 540, endMin: 720, days: [], dates: ['2026-08-11'] }
    expect(windowAt(w, utc(2026, 8, 11, 10, 0))).not.toBeNull()
    expect(windowAt(w, utc(2026, 8, 12, 10, 0))).toBeNull()
  })

  it('treats days and dates as a union, not an intersection', () => {
    const w = { startMin: 540, endMin: 720, days: [1], dates: ['2026-08-12'] }
    expect(windowAt(w, utc(2026, 8, 10, 10, 0))).not.toBeNull() // Monday, via days
    expect(windowAt(w, utc(2026, 8, 12, 10, 0))).not.toBeNull() // Wednesday, via dates
    expect(windowAt(w, utc(2026, 8, 13, 10, 0))).toBeNull()     // neither
  })

  it('works at a midnight-adjacent window without leaking into the previous day', () => {
    const w = { startMin: 0, endMin: 60, days: DAYS_ALL, dates: [] } // 00:00-01:00
    expect(windowAt(w, utc(2026, 8, 10, 0, 0))).not.toBeNull()
    expect(windowAt(w, utc(2026, 8, 10, 0, 59))).not.toBeNull()
    expect(windowAt(w, utc(2026, 8, 10, 1, 0))).toBeNull()
    // 23:59 the night before is a different day's window, not this one
    expect(windowAt(w, utc(2026, 8, 9, 23, 59))).toBeNull()
  })

  it('anchors the window to the UTC day, not the host timezone', () => {
    // Runs identically regardless of TZ because windowAt uses getUTC* only.
    const w = { startMin: 60, endMin: 120, days: DAYS_ALL, dates: [] } // 01:00-02:00 UTC
    expect(windowAt(w, utc(2026, 8, 10, 1, 30))).not.toBeNull()
    expect(windowAt(w, utc(2026, 8, 10, 23, 30))).toBeNull()
  })
})
AFX_G19_EOF
echo "  ✓ afrifx-api/tests/duty.test.ts"

mkdir -p "$(dirname "afrifx-api/tests/migrate-lib.test.ts")"
cat > 'afrifx-api/tests/migrate-lib.test.ts' <<'AFX_G20_EOF'
/**
 * Migration statement splitting.
 *
 * The runner executes statements one at a time, so this splitter decides what
 * actually gets run. If it splits inside a string literal or a comment, a
 * migration either fails or, worse, applies a truncated statement. These cases
 * come from patterns that appear in the real migration files.
 */

import { describe, it, expect } from 'vitest'
import { splitStatements, loadMigrations, checksum } from '../src/db/migrate-lib'

describe('splitStatements', () => {
  it('splits simple statements', () => {
    expect(splitStatements('SELECT 1; SELECT 2;')).toEqual(['SELECT 1', 'SELECT 2'])
  })

  it('does not require a trailing semicolon', () => {
    expect(splitStatements('SELECT 1')).toEqual(['SELECT 1'])
  })

  it('ignores empty statements from doubled or trailing semicolons', () => {
    expect(splitStatements('SELECT 1;;  ;SELECT 2;')).toEqual(['SELECT 1', 'SELECT 2'])
  })

  it('does not split on a semicolon inside a single-quoted string', () => {
    const sql = "INSERT INTO t (msg) VALUES ('a;b'); SELECT 1;"
    expect(splitStatements(sql)).toEqual([
      "INSERT INTO t (msg) VALUES ('a;b')",
      'SELECT 1',
    ])
  })

  it('handles escaped quotes inside strings', () => {
    // 'it''s;fine' is one string containing a semicolon
    const sql = "INSERT INTO t (msg) VALUES ('it''s;fine'); SELECT 1;"
    const out = splitStatements(sql)
    expect(out).toHaveLength(2)
    expect(out[0]).toContain("it''s;fine")
  })

  it('does not split on a semicolon inside a double-quoted identifier', () => {
    const sql = 'CREATE TABLE "weird;name" (id TEXT); SELECT 1;'
    expect(splitStatements(sql)).toHaveLength(2)
  })

  it('does not split on a semicolon inside a line comment', () => {
    // This pattern is common in the real files: prose comments with semicolons.
    const sql = `
      -- run this; then that
      CREATE TABLE a (id TEXT);
      SELECT 1;
    `
    const out = splitStatements(sql)
    expect(out).toHaveLength(2)
    expect(out[0]).toContain('CREATE TABLE a')
  })

  it('does not split on a semicolon inside a block comment', () => {
    const sql = `
      /* one; two; three */
      CREATE TABLE a (id TEXT);
    `
    expect(splitStatements(sql)).toHaveLength(1)
  })

  it('drops fragments that are only comments', () => {
    // A file ending in a trailing comment must not produce an empty statement,
    // which libSQL would reject.
    const sql = `
      CREATE TABLE a (id TEXT);
      -- trailing note, nothing executable after this
    `
    expect(splitStatements(sql)).toHaveLength(1)
  })

  it('returns nothing for a comment-only file', () => {
    expect(splitStatements('-- just a note\n/* and another */')).toEqual([])
  })

  it('keeps a multi-line statement intact', () => {
    const sql = `CREATE TABLE a (
      id   TEXT PRIMARY KEY,
      name TEXT
    );`
    const out = splitStatements(sql)
    expect(out).toHaveLength(1)
    expect(out[0]).toContain('PRIMARY KEY')
  })
})

describe('migration files', () => {
  const migrations = loadMigrations()

  it('there is at least one migration', () => {
    expect(migrations.length).toBeGreaterThan(0)
  })

  it('every file is named NNNN_snake_case.sql', () => {
    // loadMigrations throws on a bad name, so reaching here is the assertion;
    // this also pins the shape for anyone adding one.
    for (const m of migrations) {
      expect(m.file).toMatch(/^\d{4}_[a-z0-9_]+\.sql$/)
    }
  })

  it('version numbers are unique', () => {
    const versions = migrations.map(m => m.version)
    expect(new Set(versions).size).toBe(versions.length)
  })

  it('version numbers are contiguous from 0001, so none was lost in a rename', () => {
    const nums = migrations.map(m => Number(m.version)).sort((a, b) => a - b)
    expect(nums[0]).toBe(1)
    for (let i = 1; i < nums.length; i++) {
      expect(nums[i]).toBe(nums[i - 1] + 1)
    }
  })

  it('every migration contains at least one executable statement', () => {
    for (const m of migrations) {
      expect(splitStatements(m.sql).length, `${m.file} has no statements`)
        .toBeGreaterThan(0)
    }
  })

  it('checksums are stable for identical content', () => {
    expect(checksum('SELECT 1')).toBe(checksum('SELECT 1'))
    expect(checksum('SELECT 1')).not.toBe(checksum('SELECT 2'))
  })
})
AFX_G20_EOF
echo "  ✓ afrifx-api/tests/migrate-lib.test.ts"

mkdir -p "$(dirname "afrifx-api/tests/migrations.test.ts")"
cat > 'afrifx-api/tests/migrations.test.ts' <<'AFX_G21_EOF'
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
AFX_G21_EOF
echo "  ✓ afrifx-api/tests/migrations.test.ts"

mkdir -p "$(dirname ".github/workflows/ci.yml")"
cat > '.github/workflows/ci.yml' <<'AFX_G22_EOF'
name: CI

# Run on every push and PR to main, so a broken commit is caught before it
# reaches Vercel/Render (both of which deploy whatever lands on main).
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

# If you push again while CI is still running on an older commit, cancel the
# stale run — no point building a commit you've already superseded.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  api:
    name: API — typecheck & build
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: afrifx-api
    steps:
      - uses: actions/checkout@v4

      - name: Use Node 20
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: npm
          cache-dependency-path: afrifx-api/package-lock.json

      # npm ci is the CI-correct install: it's faster and installs EXACTLY the
      # locked versions, failing if package.json and the lockfile disagree.
      - name: Install
        run: npm ci

      - name: Typecheck
        run: npx tsc --noEmit

      # Tests run before the build: a failing test should stop the pipeline
      # whether or not the code happens to compile.
      - name: Test
        run: npm test

      - name: Build
        run: npm run build

  web:
    name: Web — typecheck, lint & build
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: afrifx-web
    # Build-time NEXT_PUBLIC_* vars all have '' fallbacks in code, so the build
    # compiles with placeholders — CI needs no real secrets. Set here so any
    # future strict check has non-empty values to work with.
    env:
      NEXT_PUBLIC_API_URL: https://afrifx-api.onrender.com
      NEXT_PUBLIC_WEB3AUTH_CLIENT_ID: ci-placeholder
      NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID: ci-placeholder
      NEXT_PUBLIC_ARC_RPC_URL: https://rpc.example.invalid
      NEXT_PUBLIC_AFRIFX_EXCHANGE: '0x0000000000000000000000000000000000000000'
      NEXT_PUBLIC_AFRIFX_VAULT: '0x0000000000000000000000000000000000000000'
    steps:
      - uses: actions/checkout@v4

      - name: Use Node 20
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: npm
          cache-dependency-path: afrifx-web/package-lock.json

      - name: Install
        run: npm ci

      - name: Typecheck
        run: npx tsc --noEmit

      # Lint is allowed to fail without failing the build for now — flip
      # continue-on-error to false once the existing lint warnings are cleared.
      - name: Lint
        run: npm run lint
        continue-on-error: true

      - name: Build
        run: npm run build
AFX_G22_EOF
echo "  ✓ .github/workflows/ci.yml"

echo ""
echo "→ Removing superseded loose schema files (now in afrifx-api/migrations/)…"
rm -f afrifx-api/ai-dispute-summaries-schema.sql \
      afrifx-api/bridge-schema.sql \
      afrifx-api/broadcasts-schema.sql \
      afrifx-api/duty-sessions-schema.sql \
      afrifx-api/maintenance-schema.sql \
      afrifx-api/messages-schema.sql \
      afrifx-api/orchestrator-schema.sql \
      afrifx-api/p2p-bank-details-schema.sql \
      afrifx-api/phaseD-schema.sql \
      afrifx-api/payroll-multichain-schema.sql
echo "  ✓ removed"

echo ""
echo "→ Done."
echo ""
echo "NEXT:"
echo ""
echo "  1) Install the test runner:"
echo "       cd afrifx-api && npm install"
echo ""
echo "  2) Run the tests:"
echo "       npm test"
echo ""
echo "  3) Baseline your database ONCE:"
echo "       npm run migrate:status    # look first"
echo "       npm run migrate           # safe: everything is IF NOT EXISTS"
echo ""
echo "     Production already has these tables, so migrate is a no-op there."
echo "     To run no DDL against production at all, mark them instead:"
echo ""
echo "       for v in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011 0012 0013; do"
echo "         npm run migrate:mark \$v"
echo "       done"
echo ""
echo "     From 0014 onward, every schema change is a file in migrations/."
echo ""
