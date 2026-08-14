/**
 * Account sessions.
 *
 * Circle's userToken lasts 60 minutes and is only needed when the user
 * signs something. Our own session is what keeps them logged in to
 * AfriFX, so it is issued separately and lives longer.
 *
 * Only a SHA-256 hash of the session token is stored. A database leak
 * therefore exposes no usable sessions.
 */

import type { Request, Response, NextFunction } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomBytes, createHash, timingSafeEqual } from 'crypto'
import { randomUUID } from 'crypto'

/** 30 days. Long enough that a payments app doesn't nag, short enough to bound risk. */
export const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60

/** Refresh expiry at most once an hour to avoid a write on every request. */
const SLIDING_REFRESH_AFTER = 60 * 60

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}
const val = (row: any, key: string, i: number) => (Array.isArray(row) ? row[i] : row[key])

export const hashToken = (token: string) =>
  createHash('sha256').update(token).digest('hex')

export interface AccountPayload {
  id:             string
  username:       string
  email:          string
  status:         string
  walletAddress:  string | null
}

/** Issue a new session. Returns the raw token, which is shown to the client once. */
export async function createSession(
  accountId: string, ip?: string, ua?: string,
): Promise<{ token: string; expiresAt: number }> {
  const token     = randomBytes(32).toString('hex')
  const now       = Math.floor(Date.now() / 1000)
  const expiresAt = now + SESSION_TTL_SECONDS

  await db.run(sql`
    INSERT INTO account_sessions
      (id, account_id, token_hash, ip_address, user_agent,
       created_at, expires_at, last_active_at)
    VALUES
      (${randomUUID()}, ${accountId}, ${hashToken(token)},
       ${ip ?? null}, ${ua ?? null}, ${now}, ${expiresAt}, ${now})
  `)

  return { token, expiresAt }
}

export async function revokeSession(token: string): Promise<void> {
  const now = Math.floor(Date.now() / 1000)
  await db.run(sql`
    UPDATE account_sessions SET revoked_at = ${now}
    WHERE token_hash = ${hashToken(token)} AND revoked_at IS NULL
  `)
}

/** Revoke every session for an account, e.g. on suspension or "log out everywhere". */
export async function revokeAllSessions(accountId: string): Promise<void> {
  const now = Math.floor(Date.now() / 1000)
  await db.run(sql`
    UPDATE account_sessions SET revoked_at = ${now}
    WHERE account_id = ${accountId} AND revoked_at IS NULL
  `)
}

/**
 * Resolve a session token to its account, or null.
 *
 * Checks revocation and expiry, and re-reads the account each time so a
 * suspension takes effect immediately rather than at next login.
 */
export async function resolveSession(token: string): Promise<AccountPayload | null> {
  if (!token) return null

  const rows = parseRows(await db.run(sql`
    SELECT s.account_id, s.expires_at, s.revoked_at, s.last_active_at,
           a.username, a.email, a.status, a.wallet_address
    FROM account_sessions s
    JOIN accounts a ON a.id = s.account_id
    WHERE s.token_hash = ${hashToken(token)}
    LIMIT 1
  `))
  const r = rows[0]
  if (!r) return null

  const now        = Math.floor(Date.now() / 1000)
  const accountId  = String(val(r, 'account_id', 0))
  const expiresAt  = Number(val(r, 'expires_at', 1))
  const revokedAt  = val(r, 'revoked_at', 2)
  const lastActive = Number(val(r, 'last_active_at', 3) ?? 0)

  if (revokedAt) return null
  if (expiresAt <= now) return null

  const status = String(val(r, 'status', 6))
  if (status === 'suspended') return null

  // Sliding expiry, throttled so a busy client doesn't write every request.
  if (now - lastActive > SLIDING_REFRESH_AFTER) {
    await db.run(sql`
      UPDATE account_sessions
      SET last_active_at = ${now}, expires_at = ${now + SESSION_TTL_SECONDS}
      WHERE token_hash = ${hashToken(token)}
    `).catch(() => {})
  }

  return {
    id:            accountId,
    username:      String(val(r, 'username', 4)),
    email:         String(val(r, 'email', 5)),
    status,
    walletAddress: (val(r, 'wallet_address', 7) as string | null) ?? null,
  }
}

/** Pull the bearer token out of the Authorization header. */
export function bearerFrom(req: Request): string | null {
  const h = req.headers.authorization
  if (!h || !h.startsWith('Bearer ')) return null
  const t = h.slice(7).trim()
  return t.length ? t : null
}

/** Require a signed-in account. Populates req.account. */
export async function requireAccount(req: Request, res: Response, next: NextFunction) {
  const token = bearerFrom(req)
  if (!token) return res.status(401).json({ error: 'Not signed in', code: 'no_session' })

  const account = await resolveSession(token)
  if (!account) {
    return res.status(401).json({ error: 'Your session has expired. Please sign in again.', code: 'session_expired' })
  }

  ;(req as any).account = account
  next()
}

/** Populate req.account when signed in, but allow anonymous through. */
export async function optionalAccount(req: Request, _res: Response, next: NextFunction) {
  const token = bearerFrom(req)
  if (token) {
    const account = await resolveSession(token).catch(() => null)
    if (account) (req as any).account = account
  }
  next()
}

/** Constant-time compare, for anywhere we compare secrets directly. */
export function safeEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a), bb = Buffer.from(b)
  if (ba.length !== bb.length) return false
  return timingSafeEqual(ba, bb)
}
