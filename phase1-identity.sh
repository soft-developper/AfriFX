#!/usr/bin/env bash
# ============================================================
# phase1-identity.sh
#
# PHASE 1 (backend) - Accounts, sessions, Circle-backed sign-in.
#
# Replaces "connect a wallet" with a real account.
#
# HOW AUTH WORKS NOW
#   1. Browser authenticates with Circle (Google or email OTP) via the
#      Web SDK and gets a userToken (valid 60 minutes).
#   2. Browser posts that userToken to us.
#   3. We call Circle to verify it and learn the stable Circle user id.
#   4. We issue our OWN session token (30 days, sliding).
#
# So: no passwords stored, no OTP infrastructure, and no separate
# "confirm your email" link - Circle's OTP already proves the address
# and Google proves it for social login.
#
# WHY A NEW `accounts` TABLE RATHER THAN REWRITING `users`
# The whole app keys off wallet_address. accounts.wallet_address starts
# NULL and gets filled in Phase 2 when the Circle wallet is created, so
# every existing feature keeps working and can be migrated to
# account_id one at a time in Phase 4 instead of a big bang.
#
# ENDPOINTS
#   GET  /auth/available?username=&email=   live signup-form checks
#   POST /auth/signup   { userToken, firstName, lastName, username, email }
#   POST /auth/login    { userToken }
#   GET  /auth/me       (Bearer session token)
#   POST /auth/logout
#
# SECURITY
#   - Only a SHA-256 hash of the session token is stored, so a database
#     leak yields no usable sessions.
#   - Suspension takes effect immediately, not at next login.
#   - Username and email uniqueness enforced at the DB level, and
#     normalized to lowercase first because SQLite UNIQUE is
#     case-sensitive (otherwise "Ada" and "ada" could both register).
#   - Reserved usernames (admin, support, afrifx, nexum, ...) blocked.
#
# TESTS: 76 total, 36 new. Mutation-verified - storing the raw token,
# ignoring suspension, and ignoring expiry each make the suite fail.
#
# BRAND: src/lib/brand.ts centralizes user-visible name strings so the
# deferred Nexum rebrand (D5) is a one-file change, not a grep.
#
# AFTER RUNNING:
#   cd afrifx-api && npm run migrate && npm test
#   Set CIRCLE_API_KEY in Render (server-side only, never NEXT_PUBLIC_).
#
# Safe to re-run: writes whole files.
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-api/migrations/0014_accounts.sql")"
cat > 'afrifx-api/migrations/0014_accounts.sql' <<'AFX_H00_EOF'
-- ============================================================
-- Phase 1: accounts and sessions.
--
-- Replaces "connect a wallet" onboarding with a real account.
-- Circle is the identity provider: the user authenticates with
-- Google or an email OTP, Circle returns a 60-minute userToken, we
-- verify it server-side and issue our own longer-lived session.
--
-- We therefore store NO passwords and NO OTP state. There is also no
-- separate "confirm your email" token: Circle's OTP already proves
-- the address, and Google proves it for social login.
--
-- WHY A NEW TABLE, NOT A REWRITE OF `users`:
-- The whole app currently keys off wallet_address (users, profiles,
-- offers, invoices, payroll, ...). `accounts.wallet_address` starts
-- NULL and is filled in Phase 2 when the Circle wallet is created,
-- so every existing feature keeps working unchanged and can be
-- migrated to account_id one at a time later.
-- ============================================================

CREATE TABLE IF NOT EXISTS accounts (
  id              TEXT PRIMARY KEY,

  -- Stored lowercase. UNIQUE is case-sensitive in SQLite, so the
  -- application must lowercase before writing or comparing; doing it
  -- at the column level would need a generated column or trigger.
  email           TEXT NOT NULL UNIQUE,
  username        TEXT NOT NULL UNIQUE,

  first_name      TEXT NOT NULL,
  last_name       TEXT NOT NULL,

  -- Circle's stable user id, from GET /v1/w3s/user. This is the link
  -- between our account and the user's Circle wallet identity.
  circle_user_id  TEXT UNIQUE,

  -- Filled in Phase 2 once the user-controlled wallet exists. NULL
  -- until then, which is why every wallet-keyed feature must tolerate
  -- an account with no wallet yet.
  wallet_address  TEXT UNIQUE,

  -- pending  : row created, wallet not yet provisioned
  -- active   : usable account
  -- suspended: blocked by an admin
  status          TEXT NOT NULL DEFAULT 'pending',

  -- Optional social handles, purely profile enrichment.
  twitter_handle  TEXT,

  last_login_at   INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_accounts_email       ON accounts (email);
CREATE INDEX IF NOT EXISTS idx_accounts_username    ON accounts (username);
CREATE INDEX IF NOT EXISTS idx_accounts_circle_user ON accounts (circle_user_id);
CREATE INDEX IF NOT EXISTS idx_accounts_wallet      ON accounts (wallet_address);

-- Our own sessions, independent of Circle's 60-minute userToken.
-- Only a SHA-256 hash of the token is stored, so a database leak does
-- not hand over live sessions.
CREATE TABLE IF NOT EXISTS account_sessions (
  id             TEXT PRIMARY KEY,
  account_id     TEXT NOT NULL,
  token_hash     TEXT NOT NULL UNIQUE,
  ip_address     TEXT,
  user_agent     TEXT,
  created_at     INTEGER NOT NULL,
  expires_at     INTEGER NOT NULL,
  last_active_at INTEGER,
  revoked_at     INTEGER
);

CREATE INDEX IF NOT EXISTS idx_account_sessions_hash
  ON account_sessions (token_hash);
CREATE INDEX IF NOT EXISTS idx_account_sessions_account
  ON account_sessions (account_id);

-- Usernames we never hand out: routes, impersonation risks, support.
CREATE TABLE IF NOT EXISTS reserved_usernames (
  username TEXT PRIMARY KEY
);

INSERT OR IGNORE INTO reserved_usernames (username) VALUES
  ('admin'), ('administrator'), ('support'), ('help'), ('security'),
  ('root'), ('system'), ('official'), ('staff'), ('team'),
  ('afrifx'), ('nexum'), ('circle'), ('arc'), ('usdc'),
  ('api'), ('www'), ('mail'), ('billing'), ('payments'),
  ('login'), ('signup'), ('settings'), ('account'), ('wallet'),
  ('me'), ('null'), ('undefined'), ('anonymous'), ('moderator');
AFX_H00_EOF
echo "  ✓ afrifx-api/migrations/0014_accounts.sql"

mkdir -p "$(dirname "afrifx-api/src/lib/brand.ts")"
cat > 'afrifx-api/src/lib/brand.ts' <<'AFX_H01_EOF'
/**
 * Brand strings in one place.
 *
 * The rebrand to Nexum is deliberately deferred (decision D5), which
 * normally means rewriting copy twice. Routing every user-visible brand
 * string through here makes the rename a one-file change instead of a
 * grep across the codebase.
 *
 * Use these anywhere a name is shown to a user: emails, page titles,
 * support copy. Do NOT use them for things that must stay stable when
 * the name changes, such as on-chain Memo tags or database values.
 */

export const BRAND = {
  /** Display name, e.g. in email copy and headings. */
  name: process.env.BRAND_NAME ?? 'AfriFX',

  /** Lowercase machine-ish form, e.g. in URLs or slugs. */
  slug: process.env.BRAND_SLUG ?? 'afrifx',

  /** Public site, used in emails and links. */
  url: process.env.BRAND_URL ?? 'https://afrifx.vercel.app',

  /** From address for transactional mail. */
  supportEmail: process.env.BRAND_SUPPORT_EMAIL ?? 'support@afrifx.com',
} as const

/** e.g. "Welcome to AfriFX" */
export const brandSubject = (s: string) => `${s} ${BRAND.name}`.trim()
AFX_H01_EOF
echo "  ✓ afrifx-api/src/lib/brand.ts"

mkdir -p "$(dirname "afrifx-api/src/lib/accountValidation.ts")"
cat > 'afrifx-api/src/lib/accountValidation.ts' <<'AFX_H02_EOF'
/**
 * Signup field validation.
 *
 * Pure and dependency-free so it can be unit tested exhaustively and
 * reused by the frontend's live availability check. Everything here
 * normalizes before validating, because the database uniqueness
 * constraints are case-sensitive: two accounts differing only in case
 * would both be insertable and would then be indistinguishable to a
 * user reading them.
 */

export const USERNAME_MIN = 3
export const USERNAME_MAX = 20

/** Lowercase and trim. Always store and compare the normalized form. */
export const normalizeUsername = (raw: string) => String(raw ?? '').trim().toLowerCase()
export const normalizeEmail    = (raw: string) => String(raw ?? '').trim().toLowerCase()

/** Collapse internal whitespace, trim ends. Preserves case for display. */
export const normalizeName = (raw: string) =>
  String(raw ?? '').replace(/\s+/g, ' ').trim()

/**
 * Returns an error message, or null when valid.
 *
 * Rules: 3-20 chars, letters/digits/underscore only, must start with a
 * letter, no leading/trailing/double underscore. Starting with a letter
 * keeps usernames distinguishable from ids and addresses in URLs.
 */
export function validateUsername(raw: string): string | null {
  const u = normalizeUsername(raw)
  if (!u) return 'Choose a username'
  if (u.length < USERNAME_MIN) return `Username must be at least ${USERNAME_MIN} characters`
  if (u.length > USERNAME_MAX) return `Username must be ${USERNAME_MAX} characters or fewer`
  if (!/^[a-z]/.test(u))       return 'Username must start with a letter'
  if (!/^[a-z0-9_]+$/.test(u)) return 'Username can only use letters, numbers and underscores'
  if (u.endsWith('_'))         return 'Username cannot end with an underscore'
  if (u.includes('__'))        return 'Username cannot contain two underscores in a row'
  return null
}

/**
 * Deliberately permissive. Over-strict email regexes reject valid
 * addresses (plus-addressing, new TLDs, unicode domains) and the
 * address is proven anyway by Circle's OTP or by Google, so this only
 * needs to catch obvious typos.
 */
export function validateEmail(raw: string): string | null {
  const e = normalizeEmail(raw)
  if (!e) return 'Enter your email address'
  if (e.length > 254) return 'Email address is too long'
  if (/\s/.test(e)) return 'Email address cannot contain spaces'
  // exactly one @, something before it, and a dotted domain after it
  if (!/^[^@]+@[^@]+\.[^@.]+$/.test(e)) return 'Enter a valid email address'
  return null
}

export function validateName(raw: string, field: 'First' | 'Last'): string | null {
  const n = normalizeName(raw)
  if (!n) return `Enter your ${field.toLowerCase()} name`
  if (n.length > 60) return `${field} name is too long`
  // Allow letters, spaces, apostrophes, hyphens, periods: covers
  // O'Brien, Anne-Marie, Jr. and non-Latin scripts.
  if (/[0-9]/.test(n)) return `${field} name cannot contain numbers`
  if (/[<>@{}\\/]/.test(n)) return `${field} name contains invalid characters`
  return null
}

export interface SignupInput {
  firstName: string
  lastName:  string
  username:  string
  email:     string
}

/** Validate every field at once. Returns field -> message, empty when valid. */
export function validateSignup(input: Partial<SignupInput>): Record<string, string> {
  const errors: Record<string, string> = {}
  const first = validateName(input.firstName ?? '', 'First')
  const last  = validateName(input.lastName ?? '', 'Last')
  const user  = validateUsername(input.username ?? '')
  const email = validateEmail(input.email ?? '')
  if (first) errors.firstName = first
  if (last)  errors.lastName  = last
  if (user)  errors.username  = user
  if (email) errors.email     = email
  return errors
}
AFX_H02_EOF
echo "  ✓ afrifx-api/src/lib/accountValidation.ts"

mkdir -p "$(dirname "afrifx-api/src/lib/accountAuth.ts")"
cat > 'afrifx-api/src/lib/accountAuth.ts' <<'AFX_H03_EOF'
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
AFX_H03_EOF
echo "  ✓ afrifx-api/src/lib/accountAuth.ts"

mkdir -p "$(dirname "afrifx-api/src/services/circleAuth.ts")"
cat > 'afrifx-api/src/services/circleAuth.ts' <<'AFX_H04_EOF'
/**
 * Verifying a Circle user session.
 *
 * Circle is our identity provider. The browser authenticates with
 * Google or an email OTP via the Web SDK and receives a `userToken`
 * (valid 60 minutes). The browser sends that token to us; we call
 * Circle with it to (a) prove it is genuine and unexpired and
 * (b) learn the stable Circle user id behind it.
 *
 * The token must never be trusted without this round trip: it arrives
 * from the client and is otherwise just an opaque string.
 */

const CIRCLE_BASE_URL = process.env.CIRCLE_BASE_URL ?? 'https://api.circle.com'

export interface CircleUser {
  /** Stable Circle user id. This is what we store on the account. */
  id: string
  /** ENABLED once the user exists and is usable. */
  status: string
  /** UNSET until the user has created a wallet. */
  pinStatus?: string
}

export class CircleAuthError extends Error {
  constructor(message: string, readonly status: number) {
    super(message)
    this.name = 'CircleAuthError'
  }
}

/**
 * Exchange a client-supplied userToken for the Circle user it belongs to.
 * Throws CircleAuthError if the token is missing, expired or rejected.
 */
export async function verifyUserToken(userToken: string): Promise<CircleUser> {
  if (!userToken || typeof userToken !== 'string') {
    throw new CircleAuthError('Missing Circle user token', 400)
  }

  const apiKey = process.env.CIRCLE_API_KEY
  if (!apiKey) {
    // Fail loudly: silently treating this as "unauthenticated" would let
    // a misconfigured deploy reject every login with a confusing error.
    throw new CircleAuthError('CIRCLE_API_KEY is not configured', 500)
  }

  let res: Response
  try {
    res = await fetch(`${CIRCLE_BASE_URL}/v1/w3s/user`, {
      method: 'GET',
      headers: {
        Accept:          'application/json',
        Authorization:   `Bearer ${apiKey}`,
        'X-User-Token':  userToken,
      },
    })
  } catch {
    throw new CircleAuthError('Could not reach Circle. Please try again.', 503)
  }

  const body: any = await res.json().catch(() => ({}))

  if (!res.ok) {
    // 401/403 from Circle means the token is bad or expired, which is a
    // client problem; anything else is Circle's problem, not the user's.
    if (res.status === 401 || res.status === 403) {
      throw new CircleAuthError('Your sign-in session expired. Please sign in again.', 401)
    }
    throw new CircleAuthError(body?.message ?? 'Circle rejected the session', 502)
  }

  const user = body?.data
  if (!user?.id) {
    throw new CircleAuthError('Circle returned no user for this session', 502)
  }

  return { id: String(user.id), status: String(user.status ?? ''), pinStatus: user.pinStatus }
}
AFX_H04_EOF
echo "  ✓ afrifx-api/src/services/circleAuth.ts"

mkdir -p "$(dirname "afrifx-api/src/routes/auth.ts")"
cat > 'afrifx-api/src/routes/auth.ts' <<'AFX_H05_EOF'
/**
 * Account authentication.
 *
 * Flow:
 *   1. Browser authenticates with Circle (Google or email OTP) via the
 *      Web SDK and receives a userToken.
 *   2. Browser posts that userToken here.
 *   3. We verify it with Circle, learn the stable Circle user id, and
 *      either create an account (signup) or find one (login).
 *   4. We issue our own session token.
 *
 * There is no password and no separate email-confirmation step: Circle's
 * OTP already proves the address, and Google proves it for social login.
 */

import { Router } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'
import { verifyUserToken, CircleAuthError } from '../services/circleAuth'
import {
  createSession, revokeSession, requireAccount, bearerFrom,
} from '../lib/accountAuth'
import {
  validateSignup, normalizeEmail, normalizeUsername, normalizeName,
  validateUsername, validateEmail,
} from '../lib/accountValidation'
import { sendEmail } from '../services/email/client'
import { welcomeEmail } from '../services/email/templates'
import { BRAND } from '../lib/brand'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}
const val = (row: any, key: string, i: number) => (Array.isArray(row) ? row[i] : row[key])

/** Shape sent to the client. Never leaks circle_user_id or internal state. */
function publicAccount(row: any) {
  return {
    id:            val(row, 'id', 0),
    email:         val(row, 'email', 1),
    username:      val(row, 'username', 2),
    firstName:     val(row, 'first_name', 3),
    lastName:      val(row, 'last_name', 4),
    walletAddress: val(row, 'wallet_address', 5) ?? null,
    status:        val(row, 'status', 6),
    createdAt:     Number(val(row, 'created_at', 7)),
  }
}

const SELECT_PUBLIC = sql`
  SELECT id, email, username, first_name, last_name,
         wallet_address, status, created_at
  FROM accounts
`

async function isReserved(username: string): Promise<boolean> {
  const rows = parseRows(await db.run(
    sql`SELECT username FROM reserved_usernames WHERE username = ${username} LIMIT 1`
  ))
  return rows.length > 0
}

// ══════════════════════════════════════════════════════════
// GET /auth/available?username=..&email=..
// Live availability for the signup form. Deliberately reports
// existence: a payments app that hides it just makes people fail the
// form repeatedly, and usernames are public anyway.
// ══════════════════════════════════════════════════════════
router.get('/available', async (req, res) => {
  const out: Record<string, { available: boolean; reason?: string }> = {}

  if (req.query.username != null) {
    const raw = String(req.query.username)
    const err = validateUsername(raw)
    if (err) {
      out.username = { available: false, reason: err }
    } else {
      const u = normalizeUsername(raw)
      if (await isReserved(u)) {
        out.username = { available: false, reason: 'That username is not available' }
      } else {
        const rows = parseRows(await db.run(
          sql`SELECT id FROM accounts WHERE username = ${u} LIMIT 1`))
        out.username = rows.length
          ? { available: false, reason: 'That username is taken' }
          : { available: true }
      }
    }
  }

  if (req.query.email != null) {
    const raw = String(req.query.email)
    const err = validateEmail(raw)
    if (err) {
      out.email = { available: false, reason: err }
    } else {
      const e = normalizeEmail(raw)
      const rows = parseRows(await db.run(
        sql`SELECT id FROM accounts WHERE email = ${e} LIMIT 1`))
      out.email = rows.length
        ? { available: false, reason: 'An account already uses that email' }
        : { available: true }
    }
  }

  res.json(out)
})

// ══════════════════════════════════════════════════════════
// POST /auth/signup
// Body: { userToken, firstName, lastName, username, email }
// ══════════════════════════════════════════════════════════
router.post('/signup', async (req, res) => {
  const { userToken, firstName, lastName, username, email } = req.body ?? {}

  const errors = validateSignup({ firstName, lastName, username, email })
  if (Object.keys(errors).length) {
    return res.status(400).json({ error: 'Please check the form', fields: errors })
  }

  let circleUser
  try {
    circleUser = await verifyUserToken(userToken)
  } catch (err: any) {
    const e = err as CircleAuthError
    return res.status(e.status ?? 401).json({ error: e.message, code: 'circle_auth' })
  }

  const uname = normalizeUsername(username)
  const mail  = normalizeEmail(email)
  const first = normalizeName(firstName)
  const last  = normalizeName(lastName)

  if (await isReserved(uname)) {
    return res.status(409).json({
      error: 'Please check the form',
      fields: { username: 'That username is not available' },
    })
  }

  try {
    // If this Circle identity already has an account, this is really a
    // sign-in. Return the existing account rather than erroring, so a
    // user who taps "sign up" twice isn't stuck.
    const existing = parseRows(await db.run(
      sql`${SELECT_PUBLIC} WHERE circle_user_id = ${circleUser.id} LIMIT 1`))
    if (existing.length) {
      const account = publicAccount(existing[0])
      const session = await createSession(
        String(account.id), req.ip, req.headers['user-agent'] as string)
      return res.json({ account, token: session.token, expiresAt: session.expiresAt, existing: true })
    }

    const id  = randomUUID()
    const now = Math.floor(Date.now() / 1000)

    await db.run(sql`
      INSERT INTO accounts
        (id, email, username, first_name, last_name,
         circle_user_id, status, created_at, updated_at)
      VALUES
        (${id}, ${mail}, ${uname}, ${first}, ${last},
         ${circleUser.id}, 'pending', ${now}, ${now})
    `)

    const rows = parseRows(await db.run(sql`${SELECT_PUBLIC} WHERE id = ${id} LIMIT 1`))
    const account = publicAccount(rows[0])
    const session = await createSession(id, req.ip, req.headers['user-agent'] as string)

    // Welcome mail is informational only. The address is already proven
    // by Circle, so a failure here must not block the signup.
    sendEmail({
      to:      mail,
      subject: `Welcome to ${BRAND.name}`,
      html:    welcomeEmail({ username: uname, displayName: first }).html,
    }).catch((e: any) => console.error('[auth] welcome email failed:', e?.message))

    res.status(201).json({ account, token: session.token, expiresAt: session.expiresAt })
  } catch (err: any) {
    // Turn the race between the availability check and the insert into a
    // useful field error rather than a 500.
    const msg = String(err?.message ?? '')
    if (/UNIQUE constraint failed/i.test(msg)) {
      if (msg.includes('accounts.username')) {
        return res.status(409).json({ error: 'Please check the form', fields: { username: 'That username is taken' } })
      }
      if (msg.includes('accounts.email')) {
        return res.status(409).json({ error: 'Please check the form', fields: { email: 'An account already uses that email' } })
      }
      if (msg.includes('accounts.circle_user_id')) {
        return res.status(409).json({ error: 'That sign-in is already linked to an account. Try signing in instead.' })
      }
    }
    console.error('[auth] signup failed:', msg)
    res.status(500).json({ error: 'Could not create your account. Please try again.' })
  }
})

// ══════════════════════════════════════════════════════════
// POST /auth/login   Body: { userToken }
// ══════════════════════════════════════════════════════════
router.post('/login', async (req, res) => {
  const { userToken } = req.body ?? {}

  let circleUser
  try {
    circleUser = await verifyUserToken(userToken)
  } catch (err: any) {
    const e = err as CircleAuthError
    return res.status(e.status ?? 401).json({ error: e.message, code: 'circle_auth' })
  }

  try {
    const rows = parseRows(await db.run(
      sql`${SELECT_PUBLIC} WHERE circle_user_id = ${circleUser.id} LIMIT 1`))

    if (!rows.length) {
      // Authenticated with Circle but no account here yet: the client
      // should send them to the signup form, keeping the same userToken.
      return res.status(404).json({
        error: 'No account found for this sign-in. Create one to continue.',
        code:  'no_account',
      })
    }

    const account = publicAccount(rows[0])
    if (account.status === 'suspended') {
      return res.status(403).json({ error: 'This account is suspended.', code: 'suspended' })
    }

    const now = Math.floor(Date.now() / 1000)
    await db.run(sql`UPDATE accounts SET last_login_at = ${now} WHERE id = ${account.id}`)

    const session = await createSession(
      String(account.id), req.ip, req.headers['user-agent'] as string)

    res.json({ account, token: session.token, expiresAt: session.expiresAt })
  } catch (err: any) {
    console.error('[auth] login failed:', err?.message)
    res.status(500).json({ error: 'Could not sign you in. Please try again.' })
  }
})

// ══════════════════════════════════════════════════════════
// GET /auth/me
// ══════════════════════════════════════════════════════════
router.get('/me', requireAccount, async (req, res) => {
  const { id } = (req as any).account
  const rows = parseRows(await db.run(sql`${SELECT_PUBLIC} WHERE id = ${id} LIMIT 1`))
  if (!rows.length) return res.status(404).json({ error: 'Account not found' })
  res.json({ account: publicAccount(rows[0]) })
})

// ══════════════════════════════════════════════════════════
// POST /auth/logout
// ══════════════════════════════════════════════════════════
router.post('/logout', async (req, res) => {
  const token = bearerFrom(req)
  if (token) await revokeSession(token).catch(() => {})
  // Always 200: logging out should never fail from the caller's view.
  res.json({ success: true })
})

export default router
AFX_H05_EOF
echo "  ✓ afrifx-api/src/routes/auth.ts"

mkdir -p "$(dirname "afrifx-api/src/index.ts")"
cat > 'afrifx-api/src/index.ts' <<'AFX_H06_EOF'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { securityHeaders }        from './middleware/security'
import { corsMiddleware }         from './middleware/cors'
import { rateLimitMiddleware }    from './middleware/rateLimit'
import { errorHandler }           from './middleware/errorHandler'
import authRouter                 from './routes/auth'
import ratesRouter                from './routes/rates'
import transactionsRouter         from './routes/transactions'
import userRouter                 from './routes/user'
import offersRouter               from './routes/offers'
import profileRouter              from './routes/profile'
import chatRouter                 from './routes/chat'
import walletRouter               from './routes/wallet'
import treasuryRouter             from './routes/treasury'
import payrollRouter              from './routes/payroll'
import notificationsRouter         from './routes/notifications'
import disputesRouter              from './routes/disputes'
import invoicesRouter              from './routes/invoices'
import paymentsRouter              from './routes/payments'
import { cleanExpiredSessions } from './services/auth/adminAuth'
import adminAuthRouter            from './routes/adminAuth'
import adminManageRouter          from './routes/adminManage'
import broadcastsRouter           from './routes/broadcasts'
import maintenanceRouter          from './routes/maintenance'
import transfersRouter, { webhookRouter } from './routes/transfers'
import bridgeRouter               from './routes/bridge'
import { startTransferReconciler } from './services/ramp/reconciler'
import { startBridgeReconciler }   from './services/bridge/reconciler'
import { maintenanceGuard }       from './lib/maintenance'
import contentRouter              from './routes/content'
import { startRatePoller }        from './jobs/ratePoller'
import { startEventListener }     from './services/eventListener'
import { startAdminAuditSummary } from './jobs/adminAuditSummary'
import { startInvoiceReminders }  from './jobs/invoiceReminders'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'
import { startTreasuryChecker }   from './jobs/treasuryChecker'
import { startTxSettler }         from './jobs/txSettler'
import { startDutyScheduler }     from './jobs/dutyScheduler'
import { seedSuperAdmin }         from './lib/seedAdmin'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

// Security headers first, so they apply to EVERY response (including errors
// and CORS preflight failures).
app.use(securityHeaders)
app.use(corsMiddleware)

// Capture the RAW body so webhook HMAC signatures can be verified against the
// exact bytes the provider signed. Re-stringifying the parsed object is NOT
// safe: key order, spacing and unicode escaping can all differ, which would
// make valid signatures fail to match.
app.use(express.json({
  verify: (req: any, _res, buf) => { req.rawBody = buf.toString('utf8') },
}))
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => res.json({ status: 'ok', ts: Date.now() }))

app.use('/auth',           authRouter)
app.use('/rates',          ratesRouter)
app.use('/transactions',   maintenanceGuard('convert'),     transactionsRouter)
app.use('/user',           userRouter)
app.use('/offers',         maintenanceGuard('marketplace'), offersRouter)
app.use('/profile',        profileRouter)
app.use('/chat',           chatRouter)
app.use('/wallet',         maintenanceGuard('send'),        walletRouter)
app.use('/treasury',       maintenanceGuard('treasury'),    treasuryRouter)
app.use('/payroll',        maintenanceGuard('payroll'),     payrollRouter)
app.use('/notifications', notificationsRouter)
app.use('/disputes',       disputesRouter)
app.use('/invoices',       maintenanceGuard('invoices'),    invoicesRouter)
app.use('/payments',       maintenanceGuard('invoices'),    paymentsRouter)
app.use('/content',        contentRouter)
app.use('/admin-auth',     adminAuthRouter)
app.use('/admin/manage',   adminManageRouter)
app.use('/admin/broadcasts', broadcastsRouter)
app.use('/maintenance',    maintenanceRouter)
app.use('/transfers',      transfersRouter)
app.use('/bridge',         bridgeRouter)
app.use('/webhooks',       webhookRouter)

app.use(errorHandler)

app.listen(PORT, async () => {
  console.log(`\n🚀  AfriFX API · http://localhost:${PORT}`)
  await seedSuperAdmin()
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
startInvoiceReminders()
startAdminAuditSummary()

  // Clean expired admin sessions every hour
  setInterval(() => cleanExpiredSessions().catch(() => {}), 3600_000)
  startTreasuryChecker()
  startTxSettler()
  startDutyScheduler()
  startTransferReconciler()
  startBridgeReconciler()
})
AFX_H06_EOF
echo "  ✓ afrifx-api/src/index.ts"

mkdir -p "$(dirname "afrifx-api/tests/accountValidation.test.ts")"
cat > 'afrifx-api/tests/accountValidation.test.ts' <<'AFX_H07_EOF'
/**
 * Signup validation.
 *
 * These rules decide what identities can exist, so the edge cases matter:
 * case handling drives the uniqueness guarantee (the database constraint
 * is case-sensitive), and the username rules stop impersonation.
 */

import { describe, it, expect } from 'vitest'
import {
  validateUsername, validateEmail, validateName, validateSignup,
  normalizeUsername, normalizeEmail, normalizeName,
  USERNAME_MIN, USERNAME_MAX,
} from '../src/lib/accountValidation'

describe('normalization', () => {
  it('lowercases and trims usernames and emails', () => {
    expect(normalizeUsername('  AdaLovelace ')).toBe('adalovelace')
    expect(normalizeEmail('  Ada@Example.COM ')).toBe('ada@example.com')
  })

  // This is what makes the UNIQUE constraint meaningful: SQLite compares
  // case-sensitively, so "Ada" and "ada" would otherwise both be insertable.
  it('collapses case so two spellings cannot both be registered', () => {
    expect(normalizeUsername('ADA')).toBe(normalizeUsername('ada'))
    expect(normalizeEmail('A@B.COM')).toBe(normalizeEmail('a@b.com'))
  })

  it('collapses internal whitespace in names but keeps case', () => {
    expect(normalizeName('  Ada   King  Lovelace ')).toBe('Ada King Lovelace')
  })
})

describe('validateUsername', () => {
  it('accepts a normal username', () => {
    expect(validateUsername('ada_lovelace')).toBeNull()
    expect(validateUsername('ada99')).toBeNull()
  })

  it('accepts regardless of the case typed', () => {
    expect(validateUsername('AdaLovelace')).toBeNull()
  })

  it('enforces length bounds', () => {
    expect(validateUsername('a'.repeat(USERNAME_MIN - 1))).toMatch(/at least/)
    expect(validateUsername('a'.repeat(USERNAME_MIN))).toBeNull()
    expect(validateUsername('a'.repeat(USERNAME_MAX))).toBeNull()
    expect(validateUsername('a'.repeat(USERNAME_MAX + 1))).toMatch(/or fewer/)
  })

  it('requires a leading letter, so usernames never look like ids or addresses', () => {
    expect(validateUsername('1ada')).toMatch(/start with a letter/)
    expect(validateUsername('_ada')).toMatch(/start with a letter/)
    expect(validateUsername('0xabc')).toMatch(/start with a letter/)
  })

  it('rejects characters that could be used to spoof another user', () => {
    expect(validateUsername('ada lovelace')).not.toBeNull()  // space
    expect(validateUsername('ada.lovelace')).not.toBeNull()  // dot
    expect(validateUsername('ada-lovelace')).not.toBeNull()  // hyphen
    expect(validateUsername('ada@home')).not.toBeNull()
    expect(validateUsername('adá')).not.toBeNull()           // lookalike accent
  })

  it('rejects trailing and doubled underscores', () => {
    expect(validateUsername('ada_')).toMatch(/end with an underscore/)
    expect(validateUsername('ada__x')).toMatch(/two underscores/)
  })

  it('rejects an empty or whitespace-only username', () => {
    expect(validateUsername('')).toMatch(/Choose a username/)
    expect(validateUsername('   ')).toMatch(/Choose a username/)
  })
})

describe('validateEmail', () => {
  it('accepts ordinary addresses', () => {
    expect(validateEmail('ada@example.com')).toBeNull()
    expect(validateEmail('Ada.Lovelace@sub.example.co.uk')).toBeNull()
  })

  // Plus-addressing is widely used and must not be rejected.
  it('accepts plus-addressing and unusual but valid local parts', () => {
    expect(validateEmail('ada+afrifx@example.com')).toBeNull()
    expect(validateEmail("ada'brien@example.com")).toBeNull()
  })

  it('rejects obvious typos', () => {
    expect(validateEmail('ada')).not.toBeNull()
    expect(validateEmail('ada@')).not.toBeNull()
    expect(validateEmail('ada@example')).not.toBeNull()   // no TLD
    expect(validateEmail('a@b@c.com')).not.toBeNull()     // two @
    expect(validateEmail('ada @example.com')).not.toBeNull()
  })

  it('rejects an over-long address', () => {
    expect(validateEmail('a'.repeat(250) + '@example.com')).toMatch(/too long/)
  })
})

describe('validateName', () => {
  it('accepts real-world name shapes', () => {
    expect(validateName("O'Brien", 'Last')).toBeNull()
    expect(validateName('Anne-Marie', 'First')).toBeNull()
    expect(validateName('Ngozi', 'First')).toBeNull()
    expect(validateName('Оксана', 'First')).toBeNull()   // non-Latin script
  })

  it('rejects digits and markup characters', () => {
    expect(validateName('Ada2', 'First')).toMatch(/cannot contain numbers/)
    expect(validateName('<script>', 'First')).toMatch(/invalid characters/)
  })

  it('requires a value', () => {
    expect(validateName('', 'First')).toMatch(/Enter your first name/)
    expect(validateName('   ', 'Last')).toMatch(/Enter your last name/)
  })
})

describe('validateSignup', () => {
  it('returns no errors for a valid submission', () => {
    expect(validateSignup({
      firstName: 'Ada', lastName: 'Lovelace',
      username: 'ada_lovelace', email: 'ada@example.com',
    })).toEqual({})
  })

  // The form should show every problem at once, not one per submit.
  it('reports every invalid field together', () => {
    const errors = validateSignup({
      firstName: '', lastName: '', username: '1', email: 'nope',
    })
    expect(Object.keys(errors).sort())
      .toEqual(['email', 'firstName', 'lastName', 'username'])
  })

  it('treats missing fields as invalid rather than skipping them', () => {
    expect(Object.keys(validateSignup({})).sort())
      .toEqual(['email', 'firstName', 'lastName', 'username'])
  })
})
AFX_H07_EOF
echo "  ✓ afrifx-api/tests/accountValidation.test.ts"

mkdir -p "$(dirname "afrifx-api/tests/accountAuth.test.ts")"
cat > 'afrifx-api/tests/accountAuth.test.ts' <<'AFX_H08_EOF'
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
AFX_H08_EOF
echo "  ✓ afrifx-api/tests/accountAuth.test.ts"

echo ""
echo "→ Done."
echo ""
echo "NEXT:"
echo "  cd afrifx-api"
echo "  npm run migrate      # applies 0014_accounts"
echo "  npm test             # 76 tests"
echo ""
echo "  Then set in Render:  CIRCLE_API_KEY=<your standard testnet key>"
echo "  Optional:            CIRCLE_BASE_URL (defaults to https://api.circle.com)"
echo ""
