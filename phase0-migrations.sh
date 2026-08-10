#!/usr/bin/env bash
# ============================================================
# phase0-migrations.sh
#
# PHASE 0.3 - Real database migrations.
#
# BEFORE: schema changes were loose *-schema.sql files in
# afrifx-api/, pasted into the Turso shell by hand. No record of what
# ran where, no ordering, no way to build a fresh database.
#
# Worse, three groups of tables were never written down as SQL at all:
#   - core    (transactions, p2p_offers, disputes, fx_rates, users)
#             created by `drizzle-kit push` from src/db/schema.ts
#   - admin   (admins, sessions, audit log, invitations, ...)
#   - app     (profiles, messages, invoices, payments, notifications, ...)
# A fresh database could NOT be built from this repo. Verified: a clean
# run failed at "no such table: p2p_offers", then "admins", then
# "profiles". All three groups are reconstructed here from the route
# code and now apply cleanly - 33 tables, every table the code uses.
#
# ALSO: package.json exposed `db:push` (drizzle-kit push). src/db/
# schema.ts describes only 5 of ~29 real tables, so a push would offer
# to DROP the other 24. That script is now disabled with an
# explanatory message.
#
# WHAT YOU GET
#   npm run migrate           apply pending migrations
#   npm run migrate:status    applied / pending / edited-since-applied
#   npm run migrate:mark NNNN record as applied WITHOUT running
#
# Tested end to end against a real SQLite database: fresh apply (13
# migrations, 33 tables), re-run is a clean no-op, mark is idempotent,
# and editing an applied migration is detected by checksum.
#
# Safe to re-run: writes whole files.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-api/src/db/migrate.ts")"
cat > 'afrifx-api/src/db/migrate.ts' <<'AFX_F00_EOF'
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
import { readdirSync, readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as dotenv from 'dotenv'

dotenv.config()

const MIGRATIONS_DIR = join(
  dirname(fileURLToPath(import.meta.url)), '..', '..', 'migrations',
)

const client = createClient({
  url:       process.env.TURSO_DATABASE_URL ?? 'file:local.db',
  authToken: process.env.TURSO_AUTH_TOKEN,
})

// ── helpers ────────────────────────────────────────────────

interface Migration {
  version:  string   // '0001'
  name:     string   // 'baseline_core'
  file:     string   // '0001_baseline_core.sql'
  sql:      string
  checksum: string
}

function loadMigrations(): Migration[] {
  const files = readdirSync(MIGRATIONS_DIR)
    .filter(f => f.endsWith('.sql'))
    .sort()

  return files.map(file => {
    const m = /^(\d{4})_(.+)\.sql$/.exec(file)
    if (!m) {
      throw new Error(
        `Migration "${file}" is misnamed. Expected NNNN_snake_case.sql`,
      )
    }
    const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8')
    return {
      version:  m[1],
      name:     m[2],
      file,
      sql,
      checksum: createHash('sha256').update(sql).digest('hex').slice(0, 16),
    }
  })
}

/**
 * Split a migration into individual statements.
 *
 * Naive `sql.split(';')` breaks on semicolons inside string literals and
 * comments, so we scan character by character and only treat `;` as a
 * terminator when we're not inside a quote or a comment.
 */
function splitStatements(sql: string): string[] {
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
function isAlreadyApplied(err: any): boolean {
  const msg = String(err?.message ?? err).toLowerCase()
  return msg.includes('duplicate column name')
      || msg.includes('already exists')
}

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
AFX_F00_EOF
echo "  ✓ afrifx-api/src/db/migrate.ts"

mkdir -p "$(dirname "afrifx-api/package.json")"
cat > 'afrifx-api/package.json' <<'AFX_F01_EOF'
{
  "name": "afrifx-api",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "tsx src/index.ts",
    "build": "tsc",
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
    "typescript": "^5"
  }
}
AFX_F01_EOF
echo "  ✓ afrifx-api/package.json"

mkdir -p "$(dirname "afrifx-api/migrations/README.md")"
cat > 'afrifx-api/migrations/README.md' <<'AFX_F02_EOF'
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
AFX_F02_EOF
echo "  ✓ afrifx-api/migrations/README.md"

mkdir -p "$(dirname "afrifx-api/migrations/0001_core.sql")"
cat > 'afrifx-api/migrations/0001_core.sql' <<'AFX_F03_EOF'
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
AFX_F03_EOF
echo "  ✓ afrifx-api/migrations/0001_core.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0002_admin_core.sql")"
cat > 'afrifx-api/migrations/0002_admin_core.sql' <<'AFX_F04_EOF'
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
AFX_F04_EOF
echo "  ✓ afrifx-api/migrations/0002_admin_core.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0003_app_core.sql")"
cat > 'afrifx-api/migrations/0003_app_core.sql' <<'AFX_F05_EOF'
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
AFX_F05_EOF
echo "  ✓ afrifx-api/migrations/0003_app_core.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0004_phase_d.sql")"
cat > 'afrifx-api/migrations/0004_phase_d.sql' <<'AFX_F06_EOF'
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
AFX_F06_EOF
echo "  ✓ afrifx-api/migrations/0004_phase_d.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0005_contact_messages.sql")"
cat > 'afrifx-api/migrations/0005_contact_messages.sql' <<'AFX_F07_EOF'
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
AFX_F07_EOF
echo "  ✓ afrifx-api/migrations/0005_contact_messages.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0006_p2p_bank_details.sql")"
cat > 'afrifx-api/migrations/0006_p2p_bank_details.sql' <<'AFX_F08_EOF'
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
AFX_F08_EOF
echo "  ✓ afrifx-api/migrations/0006_p2p_bank_details.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0007_bridge.sql")"
cat > 'afrifx-api/migrations/0007_bridge.sql' <<'AFX_F09_EOF'
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
AFX_F09_EOF
echo "  ✓ afrifx-api/migrations/0007_bridge.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0008_duty_sessions.sql")"
cat > 'afrifx-api/migrations/0008_duty_sessions.sql' <<'AFX_F10_EOF'
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
AFX_F10_EOF
echo "  ✓ afrifx-api/migrations/0008_duty_sessions.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0009_broadcasts.sql")"
cat > 'afrifx-api/migrations/0009_broadcasts.sql' <<'AFX_F11_EOF'
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
AFX_F11_EOF
echo "  ✓ afrifx-api/migrations/0009_broadcasts.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0010_maintenance.sql")"
cat > 'afrifx-api/migrations/0010_maintenance.sql' <<'AFX_F12_EOF'
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
AFX_F12_EOF
echo "  ✓ afrifx-api/migrations/0010_maintenance.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0011_orchestrator.sql")"
cat > 'afrifx-api/migrations/0011_orchestrator.sql' <<'AFX_F13_EOF'
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
AFX_F13_EOF
echo "  ✓ afrifx-api/migrations/0011_orchestrator.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0012_ai_dispute_summaries.sql")"
cat > 'afrifx-api/migrations/0012_ai_dispute_summaries.sql' <<'AFX_F14_EOF'
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
AFX_F14_EOF
echo "  ✓ afrifx-api/migrations/0012_ai_dispute_summaries.sql"

mkdir -p "$(dirname "afrifx-api/migrations/0013_payroll.sql")"
cat > 'afrifx-api/migrations/0013_payroll.sql' <<'AFX_F15_EOF'
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
AFX_F15_EOF
echo "  ✓ afrifx-api/migrations/0013_payroll.sql"

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
echo "NEXT - point at your database, then baseline it ONCE:"
echo ""
echo "    cd afrifx-api"
echo "    npm run migrate:status     # see what it thinks"
echo "    npm run migrate            # safe: everything is IF NOT EXISTS"
echo ""
echo "  Production already has these tables, so migrate is a no-op there."
echo "  If you would rather not run any DDL against production, mark them:"
echo ""
echo "    for v in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011 0012 0013; do"
echo "      npm run migrate:mark \$v"
echo "    done"
echo ""
echo "  From 0014 onward, every schema change is a file in migrations/."
echo ""
