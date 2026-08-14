/**
 * Account sessions, against a real database.
 *
 * Sessions are what stand between an attacker and someone's money, so
 * the properties tested here are security properties, not conveniences:
 * the raw token must not be stored, expiry and revocation must actually
 * deny access, and suspending an account must take effect immediately
 * rather than at next login.
 *
 * The session module imports the shared db client, so these tests point
 * that client at a scratch file via TURSO_DATABASE_URL before importing.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { createClient, type Client } from '@libsql/client'
import { readFileSync, rmSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { loadMigrations, splitStatements, isAlreadyApplied } from '../src/db/migrate-lib'

const DB_FILE = join(process.cwd(), 'tests', '.tmp-sessions.db')

// Remove the scratch file BEFORE anything opens it. Deleting it later
// would leave the shared db client holding a handle to a unlinked inode,
// writing to a file nobody can see.
for (const f of [DB_FILE, `${DB_FILE}-wal`, `${DB_FILE}-shm`]) {
  if (existsSync(f)) rmSync(f)
}
process.env.TURSO_DATABASE_URL = `file:${DB_FILE}`

// Imported after the env var is set so the shared client picks it up.
const {
  createSession, resolveSession, revokeSession, revokeAllSessions,
  hashToken, bearerFrom, SESSION_TTL_SECONDS,
} = await import('../src/lib/accountAuth')

let raw: Client

async function migrate(client: Client) {
  for (const m of loadMigrations()) {
    for (const stmt of splitStatements(m.sql)) {
      try { await client.execute(stmt) } catch (e) { if (!isAlreadyApplied(e)) throw e }
    }
  }
}

async function makeAccount(overrides: Partial<{ status: string }> = {}) {
  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)
  const tag = id.slice(0, 8)
  await raw.execute({
    sql: `INSERT INTO accounts
          (id, email, username, first_name, last_name, circle_user_id,
           status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    args: [id, `${tag}@example.com`, `user_${tag}`, 'Ada', 'Lovelace',
           `circle-${tag}`, overrides.status ?? 'active', now, now],
  })
  return id
}

// File-scoped so every describe below shares one migrated database, and
// nothing tears it down halfway through.
beforeAll(async () => {
  raw = createClient({ url: `file:${DB_FILE}` })
  await migrate(raw)
})

afterAll(() => {
  raw?.close()
  for (const f of [DB_FILE, `${DB_FILE}-wal`, `${DB_FILE}-shm`]) {
    if (existsSync(f)) rmSync(f)
  }
})

describe('account sessions', () => {
  it('issues a token that resolves back to the account', async () => {
    const accountId = await makeAccount()
    const { token } = await createSession(accountId)

    const resolved = await resolveSession(token)
    expect(resolved).not.toBeNull()
    expect(resolved!.id).toBe(accountId)
    expect(resolved!.status).toBe('active')
  })

  // The single most important property here: a database dump must not
  // contain anything that can be replayed as a live session.
  it('never stores the raw token, only its hash', async () => {
    const accountId = await makeAccount()
    const { token } = await createSession(accountId)

    const res = await raw.execute('SELECT token_hash FROM account_sessions')
    const stored = res.rows.map(r => String(r.token_hash))

    expect(stored).not.toContain(token)
    expect(stored).toContain(hashToken(token))
  })

  it('issues a different token every time', async () => {
    const accountId = await makeAccount()
    const a = await createSession(accountId)
    const b = await createSession(accountId)
    expect(a.token).not.toBe(b.token)
  })

  it('rejects an unknown or malformed token', async () => {
    expect(await resolveSession('not-a-real-token')).toBeNull()
    expect(await resolveSession('')).toBeNull()
  })

  it('rejects a revoked session', async () => {
    const accountId = await makeAccount()
    const { token } = await createSession(accountId)
    expect(await resolveSession(token)).not.toBeNull()

    await revokeSession(token)
    expect(await resolveSession(token)).toBeNull()
  })

  it('revokes every session for an account at once', async () => {
    const accountId = await makeAccount()
    const a = await createSession(accountId)
    const b = await createSession(accountId)

    await revokeAllSessions(accountId)
    expect(await resolveSession(a.token)).toBeNull()
    expect(await resolveSession(b.token)).toBeNull()
  })

  it('rejects an expired session', async () => {
    const accountId = await makeAccount()
    const { token } = await createSession(accountId)

    // Backdate expiry rather than waiting 30 days.
    const past = Math.floor(Date.now() / 1000) - 10
    await raw.execute({
      sql: 'UPDATE account_sessions SET expires_at = ? WHERE token_hash = ?',
      args: [past, hashToken(token)],
    })

    expect(await resolveSession(token)).toBeNull()
  })

  // Suspension has to bite immediately. If it only applied at next login,
  // a suspended user could keep transacting for up to 30 days.
  it('denies a session as soon as the account is suspended', async () => {
    const accountId = await makeAccount()
    const { token } = await createSession(accountId)
    expect(await resolveSession(token)).not.toBeNull()

    await raw.execute({
      sql: `UPDATE accounts SET status = 'suspended' WHERE id = ?`,
      args: [accountId],
    })

    expect(await resolveSession(token)).toBeNull()
  })

  it('sets an expiry roughly one TTL ahead', async () => {
    const accountId = await makeAccount()
    const now = Math.floor(Date.now() / 1000)
    const { expiresAt } = await createSession(accountId)
    expect(expiresAt).toBeGreaterThan(now + SESSION_TTL_SECONDS - 10)
    expect(expiresAt).toBeLessThanOrEqual(now + SESSION_TTL_SECONDS + 10)
  })

  it('exposes the wallet address, which is null before Phase 2 provisions one', async () => {
    const accountId = await makeAccount()
    const { token } = await createSession(accountId)
    const resolved = await resolveSession(token)
    expect(resolved!.walletAddress).toBeNull()
  })
})

describe('bearerFrom', () => {
  const req = (authorization?: string) => ({ headers: { authorization } }) as any

  it('extracts a bearer token', () => {
    expect(bearerFrom(req('Bearer abc123'))).toBe('abc123')
  })

  it('returns null when the header is missing, empty or another scheme', () => {
    expect(bearerFrom(req(undefined))).toBeNull()
    expect(bearerFrom(req('Bearer '))).toBeNull()
    expect(bearerFrom(req('Basic abc123'))).toBeNull()
    expect(bearerFrom(req('abc123'))).toBeNull()
  })
})

describe('accounts schema', () => {
  it('refuses two accounts with the same username', async () => {
    const now = Math.floor(Date.now() / 1000)
    const ins = (id: string, username: string, email: string) => raw.execute({
      sql: `INSERT INTO accounts
            (id, email, username, first_name, last_name, circle_user_id,
             status, created_at, updated_at)
            VALUES (?, ?, ?, 'A', 'B', ?, 'active', ?, ?)`,
      args: [id, email, username, `c-${id}`, now, now],
    })

    await ins(randomUUID(), 'dupe_user', 'one@example.com')
    await expect(ins(randomUUID(), 'dupe_user', 'two@example.com')).rejects.toThrow()
  })

  it('refuses two accounts with the same email', async () => {
    const now = Math.floor(Date.now() / 1000)
    const ins = (id: string, username: string, email: string) => raw.execute({
      sql: `INSERT INTO accounts
            (id, email, username, first_name, last_name, circle_user_id,
             status, created_at, updated_at)
            VALUES (?, ?, ?, 'A', 'B', ?, 'active', ?, ?)`,
      args: [id, email, username, `c-${id}`, now, now],
    })

    await ins(randomUUID(), 'user_x', 'dupe@example.com')
    await expect(ins(randomUUID(), 'user_y', 'dupe@example.com')).rejects.toThrow()
  })

  it('refuses to link one Circle identity to two accounts', async () => {
    const now = Math.floor(Date.now() / 1000)
    const ins = (id: string, circle: string) => raw.execute({
      sql: `INSERT INTO accounts
            (id, email, username, first_name, last_name, circle_user_id,
             status, created_at, updated_at)
            VALUES (?, ?, ?, 'A', 'B', ?, 'active', ?, ?)`,
      args: [id, `${id}@example.com`, `u${id.slice(0, 8)}`, circle, now, now],
    })

    await ins(randomUUID(), 'circle-shared')
    await expect(ins(randomUUID(), 'circle-shared')).rejects.toThrow()
  })

  it('seeds reserved usernames that must never be handed out', async () => {
    const res = await raw.execute(
      `SELECT username FROM reserved_usernames WHERE username IN ('admin','support','afrifx','nexum')`)
    expect(res.rows.length).toBe(4)
  })
})
