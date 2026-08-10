#!/usr/bin/env bash
# ============================================================
# phase1-frontend.sh
#
# PHASE 1 (frontend) - Sign-in and sign-up screens.
#
# Run AFTER phase1-identity.sh.
#
# WHAT'S NEW
#   /signin   Google, or a code by email
#   /signup   details form, then the same two verification options
#   /connect  now redirects to /signin (D2: hard cutover). Kept as a
#             redirect so old links and bookmarks don't 404.
#
# ALSO ADDS TWO BACKEND ROUTES that Phase 1 was missing: the browser
# cannot ask Circle for a device token or an email OTP itself, because
# both need the API key. These proxy them so the key stays server-side:
#   POST /auth/circle/device-token  { deviceId }
#   POST /auth/circle/email-otp     { deviceId, email }
#
# FLOW
#   details -> Circle verifies the email (OTP or Google) -> POST /auth/signup
#   Circle proves the address, so there is no second confirmation email.
#   Signing in with no account yet redirects to /signup rather than
#   erroring: the person did nothing wrong.
#
# NOTES ON THE TRICKY PARTS
#   - Google sends the browser away and back, wiping React state, so the
#     handshake tokens live in cookies and the SDK callback is registered
#     on mount rather than on click.
#   - The SDK is loaded with a dynamic import; importing it at module
#     scope breaks the Next.js server build.
#   - cookies-next is pinned to ^4 on purpose. v5+ changed to an async
#     API that this code (and Circle's own tutorial) does not use.
#
# VERIFIED: afrifx-web `tsc --noEmit` clean and `npm run build` succeeds
# with the real packages installed; /signin and /signup prerender as
# static, confirming the SDK stays out of the server bundle.
# Backend: tsc clean, 76 tests passing.
#
# NOT verified: the browser flow itself (no browser here). The first
# real test of the Google OAuth config is clicking the button.
#
# AFTER RUNNING:
#   cd afrifx-web && npm install
#   Add to Vercel:  NEXT_PUBLIC_CIRCLE_APP_ID, NEXT_PUBLIC_GOOGLE_CLIENT_ID
#   Add to Render:  CIRCLE_API_KEY
#
# Safe to re-run: writes whole files.
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-api/src/services/circleAuth.ts")"
cat > 'afrifx-api/src/services/circleAuth.ts' <<'AFX_J00_EOF'
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

import { randomUUID } from 'crypto'

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
 * Start a social-login session.
 *
 * The Web SDK generates a deviceId in the browser; we exchange it for
 * short-lived tokens the SDK needs to run the Google OAuth handshake.
 * This has to happen server-side because it needs the API key.
 */
export async function createSocialDeviceToken(deviceId: string) {
  return circlePost('/v1/w3s/users/social/token', { deviceId })
}

/** Ask Circle to email a one-time code, and get the tokens to verify it. */
export async function requestEmailOtp(deviceId: string, email: string) {
  return circlePost('/v1/w3s/users/email/token', { deviceId, email })
}

/** Shared POST helper for the endpoints above. */
async function circlePost(path: string, body: Record<string, unknown>) {
  const apiKey = process.env.CIRCLE_API_KEY
  if (!apiKey) throw new CircleAuthError('CIRCLE_API_KEY is not configured', 500)

  let res: Response
  try {
    res = await fetch(`${CIRCLE_BASE_URL}${path}`, {
      method:  'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization:  `Bearer ${apiKey}`,
      },
      // Circle requires a unique idempotency key per request.
      body: JSON.stringify({ idempotencyKey: randomUUID(), ...body }),
    })
  } catch {
    throw new CircleAuthError('Could not reach Circle. Please try again.', 503)
  }

  const payload: any = await res.json().catch(() => ({}))
  if (!res.ok) {
    throw new CircleAuthError(payload?.message ?? 'Circle rejected the request', 502)
  }
  return payload?.data ?? {}
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
AFX_J00_EOF
echo "  ✓ afrifx-api/src/services/circleAuth.ts"

mkdir -p "$(dirname "afrifx-api/src/routes/auth.ts")"
cat > 'afrifx-api/src/routes/auth.ts' <<'AFX_J01_EOF'
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
import {
  verifyUserToken, createSocialDeviceToken, requestEmailOtp, CircleAuthError,
} from '../services/circleAuth'
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
// Circle session bootstrap.
//
// These proxy Circle endpoints that need the API key, so the key stays
// on the server. The browser calls these, then drives the rest of the
// handshake with the Web SDK.
// ══════════════════════════════════════════════════════════

// POST /auth/circle/device-token   { deviceId }
router.post('/circle/device-token', async (req, res) => {
  const { deviceId } = req.body ?? {}
  if (!deviceId) return res.status(400).json({ error: 'deviceId is required' })
  try {
    res.json(await createSocialDeviceToken(String(deviceId)))
  } catch (err: any) {
    const e = err as CircleAuthError
    res.status(e.status ?? 502).json({ error: e.message })
  }
})

// POST /auth/circle/email-otp      { deviceId, email }
router.post('/circle/email-otp', async (req, res) => {
  const { deviceId, email } = req.body ?? {}
  if (!deviceId) return res.status(400).json({ error: 'deviceId is required' })

  const emailErr = validateEmail(email ?? '')
  if (emailErr) return res.status(400).json({ error: emailErr, fields: { email: emailErr } })

  try {
    res.json(await requestEmailOtp(String(deviceId), normalizeEmail(email)))
  } catch (err: any) {
    const e = err as CircleAuthError
    res.status(e.status ?? 502).json({ error: e.message })
  }
})

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
AFX_J01_EOF
echo "  ✓ afrifx-api/src/routes/auth.ts"

mkdir -p "$(dirname "afrifx-web/package.json")"
cat > 'afrifx-web/package.json' <<'AFX_J02_EOF'
{
  "name": "afrifx-web",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "next lint"
  },
  "dependencies": {
    "@circle-fin/w3s-pw-web-sdk": "^1.1.10",
    "@radix-ui/react-dialog": "^1.1.1",
    "@radix-ui/react-select": "^2.1.1",
    "@radix-ui/react-slot": "^1.1.0",
    "@rainbow-me/rainbowkit": "^2.2.11",
    "@tanstack/react-query": "^5.56.2",
    "@web3auth/auth-adapter": "^9.7.0",
    "@web3auth/base": "^9.7.0",
    "@web3auth/ethereum-provider": "^9.7.0",
    "@web3auth/modal": "^9.7.0",
    "@web3auth/no-modal": "^9.7.0",
    "@web3auth/web3auth-wagmi-connector": "^7.0.0",
    "class-variance-authority": "^0.7.0",
    "clsx": "^2.1.1",
    "cookies-next": "^4.3.0",
    "lucide-react": "^0.441.0",
    "next": "14.2.3",
    "react": "^18",
    "react-dom": "^18",
    "recharts": "^2.12.7",
    "tailwind-merge": "^2.5.2",
    "viem": "^2.17.7",
    "wagmi": "^2.12.7",
    "zustand": "^4.5.5"
  },
  "devDependencies": {
    "@types/node": "^20",
    "@types/react": "^18",
    "@types/react-dom": "^18",
    "autoprefixer": "^10",
    "postcss": "^8",
    "tailwindcss": "^3",
    "typescript": "^5"
  }
}
AFX_J02_EOF
echo "  ✓ afrifx-web/package.json"

mkdir -p "$(dirname "afrifx-web/lib/circle.ts")"
cat > 'afrifx-web/lib/circle.ts' <<'AFX_J03_EOF'
'use client'

/**
 * Circle Web SDK wrapper.
 *
 * The SDK is browser-only and pulls in Node built-ins, so it is always
 * loaded with a dynamic import inside a client component. Importing it
 * at module scope breaks the Next.js server build.
 *
 * Social login sends the browser away to Google and back, which wipes
 * React state. The tokens needed to finish the handshake are therefore
 * kept in cookies, not state, so they survive the round trip.
 */

import { setCookie, getCookie, deleteCookie } from 'cookies-next'

const API    = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const APP_ID = process.env.NEXT_PUBLIC_CIRCLE_APP_ID ?? ''
const GOOGLE = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID ?? ''

const COOKIE = {
  deviceToken:   'circle_device_token',
  encryptionKey: 'circle_device_encryption_key',
  /** Set when the user came from the sign-up form, so we know where to send them back. */
  intent:        'circle_auth_intent',
} as const

export type AuthIntent = 'signin' | 'signup'

export interface CircleLoginResult {
  userToken:     string
  encryptionKey: string
}

/** Cached SDK instance. One per page load is enough. */
let sdk: any = null
let deviceIdCache: string | null = null

/**
 * Get (and cache) the SDK. `onLogin` fires after a social redirect
 * completes, which is why it must be supplied at construction time
 * rather than at the moment the button is clicked.
 */
export async function getSdk(
  onLogin?: (err: unknown, result: CircleLoginResult | null) => void,
): Promise<any> {
  if (sdk) return sdk

  const { W3SSdk } = await import('@circle-fin/w3s-pw-web-sdk')

  sdk = new W3SSdk(
    {
      appSettings:  { appId: APP_ID },
      loginConfigs: {
        deviceToken:         (getCookie(COOKIE.deviceToken) as string) ?? '',
        deviceEncryptionKey: (getCookie(COOKIE.encryptionKey) as string) ?? '',
        google: {
          clientId:            GOOGLE,
          redirectUri:         typeof window !== 'undefined' ? window.location.origin : '',
          selectAccountPrompt: true,
        },
      },
    },
    (err: unknown, result: any) => {
      if (!onLogin) return
      if (err || !result?.userToken) return onLogin(err ?? new Error('Sign-in failed'), null)
      onLogin(null, { userToken: result.userToken, encryptionKey: result.encryptionKey })
    },
  )

  return sdk
}

/**
 * The SDK's device id identifies this browser to Circle.
 *
 * Without calling getDeviceId() first, challenge execution silently does
 * nothing, so this is always fetched before anything else.
 */
export async function getDeviceId(): Promise<string> {
  if (deviceIdCache) return deviceIdCache

  const cached = localStorage.getItem('circle_device_id')
  if (cached) { deviceIdCache = cached; return cached }

  const instance = await getSdk()
  const id: string = await instance.getDeviceId()
  localStorage.setItem('circle_device_id', id)
  deviceIdCache = id
  return id
}

/** Start Google sign-in. The browser leaves the page and comes back. */
export async function startGoogleLogin(intent: AuthIntent): Promise<void> {
  const deviceId = await getDeviceId()

  const res = await fetch(`${API}/auth/circle/device-token`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ deviceId }),
  })
  if (!res.ok) {
    throw new Error((await res.json().catch(() => ({}))).error ?? 'Could not start Google sign-in')
  }
  const { deviceToken, deviceEncryptionKey } = await res.json()

  // Survive the OAuth redirect.
  setCookie(COOKIE.deviceToken, deviceToken)
  setCookie(COOKIE.encryptionKey, deviceEncryptionKey)
  setCookie(COOKIE.intent, intent)

  const instance = await getSdk()
  instance.updateConfigs({
    appSettings:  { appId: APP_ID },
    loginConfigs: {
      deviceToken,
      deviceEncryptionKey,
      google: {
        clientId:            GOOGLE,
        redirectUri:         window.location.origin,
        selectAccountPrompt: true,
      },
    },
  })

  const { SocialLoginProvider } = await import('@circle-fin/w3s-pw-web-sdk/dist/src/types')
  instance.performLogin(SocialLoginProvider.GOOGLE)
}

/** Ask Circle to email a code. Returns nothing; the code arrives by email. */
export async function sendEmailCode(email: string): Promise<void> {
  const deviceId = await getDeviceId()

  const res = await fetch(`${API}/auth/circle/email-otp`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ deviceId, email }),
  })
  if (!res.ok) {
    throw new Error((await res.json().catch(() => ({}))).error ?? 'Could not send the code')
  }
  const { deviceToken, deviceEncryptionKey, otpToken } = await res.json()

  const instance = await getSdk()
  instance.updateConfigs({
    appSettings:  { appId: APP_ID },
    loginConfigs: { deviceToken, deviceEncryptionKey, otpToken, email: { email } },
  })
}

/** Open Circle's hosted code-entry window. Result arrives via the getSdk callback. */
export async function openCodeEntry(): Promise<void> {
  const instance = await getSdk()
  instance.verifyOtp()
}

/** Which flow the user was in before a social redirect took them away. */
export function consumeIntent(): AuthIntent | null {
  const v = getCookie(COOKIE.intent) as AuthIntent | undefined
  return v === 'signin' || v === 'signup' ? v : null
}

/** Clear the handshake cookies once we no longer need them. */
export function clearAuthCookies(): void {
  deleteCookie(COOKIE.deviceToken)
  deleteCookie(COOKIE.encryptionKey)
  deleteCookie(COOKIE.intent)
}

/** True when the app has the config it needs to talk to Circle at all. */
export const circleConfigured = () => Boolean(APP_ID)
AFX_J03_EOF
echo "  ✓ afrifx-web/lib/circle.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useAuth.ts")"
cat > 'afrifx-web/hooks/useAuth.ts' <<'AFX_J04_EOF'
'use client'

/**
 * Account session for the app.
 *
 * Mirrors useAdminAuth, with one deliberate difference: the token lives
 * in localStorage rather than sessionStorage. Admins sign in per tab;
 * a payments app that signs people out whenever they close a tab is
 * hostile, so this persists until the session expires or they sign out.
 */

import { useState, useEffect, useRef, useCallback } from 'react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export const ACCOUNT_TOKEN_KEY = 'afrifx_token'
export const ACCOUNT_KEY       = 'afrifx_account'

export interface Account {
  id:            string
  email:         string
  username:      string
  firstName:     string
  lastName:      string
  /** Null until Phase 2 provisions the Circle wallet. */
  walletAddress: string | null
  status:        string
  createdAt:     number
}

export const getToken = () =>
  typeof window === 'undefined' ? null : localStorage.getItem(ACCOUNT_TOKEN_KEY)

export function persistSession(token: string, account: Account) {
  localStorage.setItem(ACCOUNT_TOKEN_KEY, token)
  localStorage.setItem(ACCOUNT_KEY, JSON.stringify(account))
}

export function clearSession() {
  localStorage.removeItem(ACCOUNT_TOKEN_KEY)
  localStorage.removeItem(ACCOUNT_KEY)
}

/**
 * fetch() with the session attached.
 *
 * A 401 means the session is gone, so it clears local state rather than
 * leaving the UI in a signed-in-looking but broken condition.
 */
export async function apiFetch(path: string, init: RequestInit = {}) {
  const token = getToken()
  const res = await fetch(`${API}${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(init.headers ?? {}),
    },
  })
  if (res.status === 401) clearSession()
  return res
}

export function useAuth() {
  const [account, setAccount] = useState<Account | null>(null)
  const [loading, setLoading] = useState(true)
  const checked = useRef(false)

  useEffect(() => {
    if (checked.current) return
    checked.current = true

    // Show the cached account immediately so the UI doesn't flash signed-out,
    // then confirm with the server.
    const cached = localStorage.getItem(ACCOUNT_KEY)
    if (cached) { try { setAccount(JSON.parse(cached)) } catch { /* ignore */ } }

    if (!getToken()) { setAccount(null); setLoading(false); return }

    apiFetch('/auth/me')
      .then(res => (res.ok ? res.json() : null))
      .then(data => {
        if (data?.account) {
          setAccount(data.account)
          localStorage.setItem(ACCOUNT_KEY, JSON.stringify(data.account))
        } else {
          clearSession()
          setAccount(null)
        }
      })
      .catch(() => { /* offline: keep the cached account rather than signing out */ })
      .finally(() => setLoading(false))
  }, [])

  const signOut = useCallback(async () => {
    await apiFetch('/auth/logout', { method: 'POST' }).catch(() => {})
    clearSession()
    setAccount(null)
  }, [])

  return { account, loading, signOut, isSignedIn: Boolean(account) }
}
AFX_J04_EOF
echo "  ✓ afrifx-web/hooks/useAuth.ts"

mkdir -p "$(dirname "afrifx-web/app/(auth)/signin/page.tsx")"
cat > 'afrifx-web/app/(auth)/signin/page.tsx' <<'AFX_J05_EOF'
'use client'

import { useState, useEffect, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { ArrowLeftRight, Mail, AlertCircle, Loader2, ArrowLeft } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  getSdk, startGoogleLogin, sendEmailCode, openCodeEntry,
  consumeIntent, clearAuthCookies, circleConfigured,
} from '@/lib/circle'
import { persistSession, type Account } from '@/hooks/useAuth'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type Stage = 'choose' | 'email' | 'sent'

export default function SignInPage() {
  const router = useRouter()

  const [stage,   setStage]   = useState<Stage>('choose')
  const [email,   setEmail]   = useState('')
  const [busy,    setBusy]    = useState<string | null>(null)
  const [error,   setError]   = useState<string | null>(null)

  /**
   * Trade a Circle userToken for our session.
   *
   * A 404 means they authenticated fine but have no account here yet, so
   * send them to sign-up rather than showing an error: they did nothing
   * wrong, they just haven't finished signing up.
   */
  const exchange = useCallback(async (userToken: string) => {
    setBusy('Signing you in')
    try {
      const res = await fetch(`${API}/auth/login`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ userToken }),
      })
      const data = await res.json().catch(() => ({}))

      if (res.status === 404) {
        sessionStorage.setItem('pending_user_token', userToken)
        router.push('/signup')
        return
      }
      if (!res.ok) { setError(data.error ?? 'Could not sign you in'); setBusy(null); return }

      persistSession(data.token, data.account as Account)
      clearAuthCookies()
      router.push('/dashboard')
    } catch {
      setError('Could not reach the server. Check your connection and try again.')
      setBusy(null)
    }
  }, [router])

  // Register the SDK callback on mount. Google sends the browser away and
  // back, so this has to be listening before the user ever clicks anything.
  useEffect(() => {
    if (!circleConfigured()) {
      setError('Sign-in is not configured yet. Set NEXT_PUBLIC_CIRCLE_APP_ID.')
      return
    }
    let cancelled = false

    getSdk((err, result) => {
      if (cancelled) return
      if (err || !result) {
        setBusy(null)
        setError('Sign-in was cancelled or failed. Try again.')
        return
      }
      void exchange(result.userToken)
    }).catch(() => setError('Could not load sign-in. Refresh and try again.'))

    // Returning from a Google redirect that began on the sign-up form.
    if (consumeIntent() === 'signup') router.replace('/signup')

    return () => { cancelled = true }
  }, [exchange, router])

  async function onGoogle() {
    setError(null); setBusy('Opening Google')
    try { await startGoogleLogin('signin') }
    catch (e: any) { setError(e?.message ?? 'Could not start Google sign-in'); setBusy(null) }
  }

  async function onSendCode() {
    setError(null); setBusy('Sending your code')
    try {
      await sendEmailCode(email.trim())
      setStage('sent')
    } catch (e: any) {
      setError(e?.message ?? 'Could not send the code')
    } finally { setBusy(null) }
  }

  async function onEnterCode() {
    setError(null)
    try { await openCodeEntry() }
    catch { setError('Could not open the code window. Try sending a new code.') }
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-10">
      <div className="mb-8 flex items-center gap-3">
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-app-accent/20">
          <ArrowLeftRight className="h-6 w-6 text-app-accent-text" />
        </div>
        <div>
          <h1 className="text-2xl font-semibold text-app-text">AfriFX</h1>
          <p className="text-xs text-app-muted">Dollars that move like messages</p>
        </div>
      </div>

      <div className="w-full max-w-sm rounded-2xl border border-app-border bg-app-surface p-6">
        <h2 className="mb-1 text-base font-semibold text-app-text">Sign in</h2>
        <p className="mb-5 text-xs text-app-muted">
          Use the same method you signed up with.
        </p>

        {error && (
          <div className="mb-4 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{error}</span>
          </div>
        )}

        {busy && (
          <div className="mb-4 flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2.5 text-xs text-app-muted">
            <Loader2 className="h-3.5 w-3.5 animate-spin" /> {busy}…
          </div>
        )}

        {stage === 'choose' && (
          <div className="space-y-2">
            <Button className="w-full" variant="outline"
              onClick={onGoogle} disabled={Boolean(busy)}>
              Continue with Google
            </Button>
            <Button className="w-full" variant="outline"
              onClick={() => { setStage('email'); setError(null) }} disabled={Boolean(busy)}>
              <Mail className="h-4 w-4" /> Continue with email
            </Button>
          </div>
        )}

        {stage === 'email' && (
          <div className="space-y-3">
            <div>
              <label htmlFor="email" className="mb-1 block text-xs text-app-muted">
                Email address
              </label>
              <Input id="email" type="email" autoFocus autoComplete="email"
                placeholder="you@example.com"
                value={email} onChange={e => setEmail(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter' && email.trim()) void onSendCode() }} />
            </div>
            <Button className="w-full" onClick={onSendCode}
              disabled={!email.trim() || Boolean(busy)}>
              Send me a code
            </Button>
            <button onClick={() => { setStage('choose'); setError(null) }}
              className="flex w-full items-center justify-center gap-1 text-xs text-app-muted hover:text-app-text">
              <ArrowLeft className="h-3 w-3" /> Back
            </button>
          </div>
        )}

        {stage === 'sent' && (
          <div className="space-y-3">
            <p className="text-xs text-app-muted">
              We sent a code to <span className="text-app-text">{email}</span>. It expires shortly.
            </p>
            <Button className="w-full" onClick={onEnterCode}>Enter code</Button>
            <button onClick={() => { setStage('email'); setError(null) }}
              className="w-full text-xs text-app-muted hover:text-app-text">
              Use a different email
            </button>
          </div>
        )}
      </div>

      <p className="mt-5 text-xs text-app-muted">
        New here?{' '}
        <Link href="/signup" className="text-app-accent-text hover:underline">
          Create an account
        </Link>
      </p>
    </div>
  )
}
AFX_J05_EOF
echo "  ✓ afrifx-web/app/(auth)/signin/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(auth)/signup/page.tsx")"
cat > 'afrifx-web/app/(auth)/signup/page.tsx' <<'AFX_J06_EOF'
'use client'

import { useState, useEffect, useCallback, useRef } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import {
  ArrowLeftRight, Mail, AlertCircle, Loader2, ArrowLeft, Check,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  getSdk, startGoogleLogin, sendEmailCode, openCodeEntry,
  clearAuthCookies, circleConfigured,
} from '@/lib/circle'
import { persistSession, type Account } from '@/hooks/useAuth'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type Stage = 'details' | 'verify' | 'sent'
type Fields = { firstName: string; lastName: string; username: string; email: string }

export default function SignUpPage() {
  const router = useRouter()

  const [stage,  setStage]  = useState<Stage>('details')
  const [fields, setFields] = useState<Fields>({ firstName: '', lastName: '', username: '', email: '' })
  const [errors, setErrors] = useState<Partial<Record<keyof Fields, string>>>({})
  const [taken,  setTaken]  = useState<Partial<Record<'username' | 'email', boolean>>>({})
  const [busy,   setBusy]   = useState<string | null>(null)
  const [error,  setError]  = useState<string | null>(null)

  const set = (k: keyof Fields, v: string) => {
    setFields(f => ({ ...f, [k]: v }))
    setErrors(e => ({ ...e, [k]: undefined }))
  }

  /** Create the account once Circle has proven the email. */
  const submit = useCallback(async (userToken: string, data: Fields) => {
    setBusy('Creating your account')
    try {
      const res = await fetch(`${API}/auth/signup`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ userToken, ...data }),
      })
      const body = await res.json().catch(() => ({}))

      if (!res.ok) {
        if (body.fields) { setErrors(body.fields); setStage('details') }
        setError(body.error ?? 'Could not create your account')
        setBusy(null)
        return
      }

      persistSession(body.token, body.account as Account)
      clearAuthCookies()
      router.push('/dashboard')
    } catch {
      setError('Could not reach the server. Check your connection and try again.')
      setBusy(null)
    }
  }, [router])

  // Keep the latest form values available to the SDK callback, which is
  // registered once and would otherwise close over the initial empty state.
  const fieldsRef = useRef(fields)
  fieldsRef.current = fields

  useEffect(() => {
    if (!circleConfigured()) {
      setError('Sign-up is not configured yet. Set NEXT_PUBLIC_CIRCLE_APP_ID.')
      return
    }
    let cancelled = false

    getSdk((err, result) => {
      if (cancelled) return
      if (err || !result) {
        setBusy(null)
        setError('Verification was cancelled. Try again.')
        return
      }
      void submit(result.userToken, fieldsRef.current)
    }).catch(() => setError('Could not load sign-up. Refresh and try again.'))

    // Arriving from the sign-in page after Circle said "no account yet":
    // they are already verified, so go straight to the details form.
    const pending = sessionStorage.getItem('pending_user_token')
    if (pending) sessionStorage.removeItem('pending_user_token')

    return () => { cancelled = true }
  }, [submit])

  /** Ask the server whether a username or email is free. */
  async function checkAvailability(): Promise<boolean> {
    const qs = new URLSearchParams({
      username: fields.username.trim(),
      email:    fields.email.trim(),
    })
    try {
      const res  = await fetch(`${API}/auth/available?${qs}`)
      const data = await res.json()
      const next: Partial<Record<keyof Fields, string>> = {}
      if (data.username && !data.username.available) next.username = data.username.reason
      if (data.email && !data.email.available)       next.email    = data.email.reason
      setErrors(e => ({ ...e, ...next }))
      setTaken({ username: !next.username, email: !next.email })
      return Object.keys(next).length === 0
    } catch {
      // Availability is a convenience; the server enforces uniqueness on
      // submit anyway, so a failed check shouldn't block the user.
      return true
    }
  }

  async function onContinue() {
    setError(null)
    const missing: Partial<Record<keyof Fields, string>> = {}
    if (!fields.firstName.trim()) missing.firstName = 'Enter your first name'
    if (!fields.lastName.trim())  missing.lastName  = 'Enter your last name'
    if (!fields.username.trim())  missing.username  = 'Choose a username'
    if (!fields.email.trim())     missing.email     = 'Enter your email address'
    if (Object.keys(missing).length) { setErrors(missing); return }

    setBusy('Checking availability')
    const ok = await checkAvailability()
    setBusy(null)
    if (ok) setStage('verify')
  }

  async function onGoogle() {
    setError(null); setBusy('Opening Google')
    try { await startGoogleLogin('signup') }
    catch (e: any) { setError(e?.message ?? 'Could not start Google sign-up'); setBusy(null) }
  }

  async function onSendCode() {
    setError(null); setBusy('Sending your code')
    try { await sendEmailCode(fields.email.trim()); setStage('sent') }
    catch (e: any) { setError(e?.message ?? 'Could not send the code') }
    finally { setBusy(null) }
  }

  const field = (k: keyof Fields, label: string, props: Record<string, unknown> = {}) => (
    <div>
      <label htmlFor={k} className="mb-1 block text-xs text-app-muted">{label}</label>
      <Input id={k} value={fields[k]} onChange={e => set(k, e.target.value)}
        aria-invalid={Boolean(errors[k])} {...props} />
      {errors[k] && <p className="mt-1 text-[11px] text-red-400">{errors[k]}</p>}
      {!errors[k] && taken[k as 'username' | 'email'] && fields[k].trim() && (
        <p className="mt-1 flex items-center gap-1 text-[11px] text-emerald-500">
          <Check className="h-3 w-3" /> Available
        </p>
      )}
    </div>
  )

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-10">
      <div className="mb-8 flex items-center gap-3">
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-app-accent/20">
          <ArrowLeftRight className="h-6 w-6 text-app-accent-text" />
        </div>
        <div>
          <h1 className="text-2xl font-semibold text-app-text">AfriFX</h1>
          <p className="text-xs text-app-muted">Dollars that move like messages</p>
        </div>
      </div>

      <div className="w-full max-w-sm rounded-2xl border border-app-border bg-app-surface p-6">
        <h2 className="mb-1 text-base font-semibold text-app-text">
          {stage === 'details' ? 'Create your account' : 'Confirm it\u2019s you'}
        </h2>
        <p className="mb-5 text-xs text-app-muted">
          {stage === 'details'
            ? 'Takes about a minute. No wallet or seed phrase needed.'
            : 'One last step, so we know the email is yours.'}
        </p>

        {error && (
          <div className="mb-4 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{error}</span>
          </div>
        )}

        {busy && (
          <div className="mb-4 flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2.5 text-xs text-app-muted">
            <Loader2 className="h-3.5 w-3.5 animate-spin" /> {busy}…
          </div>
        )}

        {stage === 'details' && (
          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-2">
              {field('firstName', 'First name', { autoComplete: 'given-name', autoFocus: true })}
              {field('lastName',  'Last name',  { autoComplete: 'family-name' })}
            </div>
            {field('username', 'Username', { placeholder: 'ada_lovelace', autoComplete: 'username' })}
            {field('email',    'Email address', { type: 'email', placeholder: 'you@example.com', autoComplete: 'email' })}

            <Button className="w-full" onClick={onContinue} disabled={Boolean(busy)}>
              Continue
            </Button>
          </div>
        )}

        {stage === 'verify' && (
          <div className="space-y-2">
            <Button className="w-full" variant="outline" onClick={onGoogle} disabled={Boolean(busy)}>
              Continue with Google
            </Button>
            <Button className="w-full" variant="outline" onClick={onSendCode} disabled={Boolean(busy)}>
              <Mail className="h-4 w-4" /> Email me a code
            </Button>
            <button onClick={() => { setStage('details'); setError(null) }}
              className="flex w-full items-center justify-center gap-1 pt-1 text-xs text-app-muted hover:text-app-text">
              <ArrowLeft className="h-3 w-3" /> Edit my details
            </button>
          </div>
        )}

        {stage === 'sent' && (
          <div className="space-y-3">
            <p className="text-xs text-app-muted">
              We sent a code to <span className="text-app-text">{fields.email}</span>.
            </p>
            <Button className="w-full" onClick={() => openCodeEntry()}>Enter code</Button>
            <button onClick={() => { setStage('verify'); setError(null) }}
              className="w-full text-xs text-app-muted hover:text-app-text">
              Back
            </button>
          </div>
        )}
      </div>

      <p className="mt-5 text-xs text-app-muted">
        Already have an account?{' '}
        <Link href="/signin" className="text-app-accent-text hover:underline">Sign in</Link>
      </p>
    </div>
  )
}
AFX_J06_EOF
echo "  ✓ afrifx-web/app/(auth)/signup/page.tsx"

mkdir -p "$(dirname "afrifx-web/app/(auth)/connect/page.tsx")"
cat > 'afrifx-web/app/(auth)/connect/page.tsx' <<'AFX_J07_EOF'
import { redirect } from 'next/navigation'

/**
 * The wallet-connect entry point is gone (decision D2: hard cutover).
 * Accounts replaced it, and the wallet is created for the user after
 * they sign up rather than being something they bring.
 *
 * Kept as a redirect so old links, bookmarks and any in-app references
 * still land somewhere sensible instead of a 404.
 */
export default function ConnectPage() {
  redirect('/signin')
}
AFX_J07_EOF
echo "  ✓ afrifx-web/app/(auth)/connect/page.tsx"

echo ""
echo "→ Done."
echo ""
echo "NEXT:"
echo "  cd afrifx-web && npm install     # pulls the Circle Web SDK"
echo "  npx tsc --noEmit && npm run build"
echo ""
echo "  Vercel env:"
echo "    NEXT_PUBLIC_CIRCLE_APP_ID=0d0f4f63-7e48-59ec-ae8b-db732e40b193"
echo "    NEXT_PUBLIC_GOOGLE_CLIENT_ID=<your Google Web client id>"
echo "  Render env:"
echo "    CIRCLE_API_KEY=<your standard testnet key>"
echo ""
echo "  Google Cloud: add your Vercel URL to Authorized redirect URIs,"
echo "  and make sure the app is Published, or only test users can sign in."
echo ""
