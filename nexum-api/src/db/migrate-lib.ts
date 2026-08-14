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
