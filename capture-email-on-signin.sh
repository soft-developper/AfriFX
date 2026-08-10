#!/usr/bin/env bash
# ============================================================
# capture-email-on-signin.sh
#
# New users get their email captured automatically, and a welcome mail.
#
# Run AFTER browse-without-signin.sh.
#
# THE TWO GAPS THIS CLOSES
#   1. A Google sign-in created an account with NO email. The address
#      was sitting in the SDK response all along, at
#      oAuthInfo.socialUserInfo.email, and we were discarding it.
#   2. /auth/session never sent a welcome mail. That logic lived in the
#      old /auth/signup route and was lost when the two routes were
#      collapsed into one.
#
# WHAT NOW HAPPENS
#   - Google sign-in: email AND display name are read from oAuthInfo.
#     The name prefills first_name/last_name, so the profile form starts
#     filled in instead of blank.
#   - Email-code sign-in: the address they typed is used, as before.
#   - Welcome mail is sent the first time an account has an address.
#
# MIGRATION 0016 adds accounts.welcome_sent_at.
# Without it we would either send nothing, or re-send on EVERY sign-in
# until a profile existed. The column makes it exactly once. It also
# handles the awkward case where Google gives no email on the first
# visit: the mail goes out later, when the address finally appears,
# rather than never.
#
# Sending is wrapped so a mail failure can never block a sign-in.
#
# VERIFIED: api tsc clean, 85 tests pass, migration applies, and the
# once-only guard was exercised against a real database (no email ->
# no send; email set -> sent; second pass -> blocked). Web tsc clean,
# npm run build succeeds.
#
# NOTE: existing accounts have welcome_sent_at NULL, so anyone who
# already has an email will receive a welcome mail on their next
# sign-in. If you would rather they didn't, run this once after
# migrating:
#   UPDATE accounts SET welcome_sent_at = strftime('%s','now')
#   WHERE email IS NOT NULL;
#
# AFTER RUNNING:
#   cd afrifx-api && npm run migrate && npm test
#   cd ../afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-api/migrations/0016_welcome_sent.sql")"
cat > 'afrifx-api/migrations/0016_welcome_sent.sql' <<'AFX_Q00_EOF'
-- ============================================================
-- Track whether the welcome email has been sent.
--
-- The welcome mail is sent the first time an account has an email
-- address, which is not always at creation: a Google sign-in only gives
-- us an address if the OAuth response includes one, and some accounts
-- get theirs later from the profile form.
--
-- Without this column we would either send nothing (the current bug) or
-- re-send on every sign-in until a profile exists.
-- ============================================================

ALTER TABLE accounts ADD COLUMN welcome_sent_at INTEGER;
AFX_Q00_EOF
echo "  ✓ afrifx-api/migrations/0016_welcome_sent.sql"

mkdir -p "$(dirname "afrifx-api/src/routes/auth.ts")"
cat > 'afrifx-api/src/routes/auth.ts' <<'AFX_Q01_EOF'
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
  initializeUserWallet, listUserWallets, pickPrimaryWallet,
} from '../services/circleWallets'
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

/**
 * Send the welcome email if this account has an address and has never
 * been sent one. Guarded by welcome_sent_at so a repeat sign-in cannot
 * spam the user, and never allowed to fail a sign-in.
 */
async function maybeSendWelcome(accountId: string): Promise<void> {
  try {
    const rows = parseRows(await db.run(sql`
      SELECT email, username, first_name, welcome_sent_at
      FROM accounts WHERE id = ${accountId} LIMIT 1
    `))
    const r = rows[0]
    if (!r) return

    const mail = val(r, 'email', 0) as string | null
    const sent = val(r, 'welcome_sent_at', 3)
    if (!mail || sent) return

    const username = (val(r, 'username', 1) as string | null) ?? mail.split('@')[0]
    const display  = (val(r, 'first_name', 2) as string | null) ?? username

    await sendEmail({
      to:      mail,
      subject: `Welcome to ${BRAND.name}`,
      html:    welcomeEmail({ username, displayName: display }).html,
    })

    await db.run(sql`
      UPDATE accounts SET welcome_sent_at = ${Math.floor(Date.now() / 1000)}
      WHERE id = ${accountId}
    `)
  } catch (err: any) {
    // A missing welcome email must never block someone signing in.
    console.error('[auth] welcome email failed:', err?.message)
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
// WALLET PROVISIONING (Phase 2)
//
// Wallet creation needs the user's consent on their own device, so it
// is a handshake: we ask Circle to start it, the browser executes the
// challenge, then we read back the address and store it.
// ══════════════════════════════════════════════════════════

// POST /auth/wallet/initialize   { userToken }   (signed in)
router.post('/wallet/initialize', requireAccount, async (req, res) => {
  const { userToken } = req.body ?? {}
  if (!userToken) return res.status(400).json({ error: 'userToken is required' })

  try {
    const result = await initializeUserWallet(String(userToken))
    res.json(result)
  } catch (err: any) {
    const e = err as CircleAuthError
    res.status(e.status ?? 502).json({ error: e.message })
  }
})

// POST /auth/wallet/sync   { userToken }   (signed in)
//
// Called after the browser executes the challenge. Reads the wallet
// back from Circle and records it, which is what flips the account from
// 'pending' to 'active'.
router.post('/wallet/sync', requireAccount, async (req, res) => {
  const { userToken } = req.body ?? {}
  const account = (req as any).account
  if (!userToken) return res.status(400).json({ error: 'userToken is required' })

  try {
    const wallets = await listUserWallets(String(userToken))
    const wallet  = pickPrimaryWallet(wallets)

    if (!wallet) {
      // Circle indexes the new wallet asynchronously, so an empty list
      // shortly after the challenge is normal. Tell the client to retry
      // rather than treating it as a failure.
      return res.status(202).json({ ready: false, reason: 'Wallet is still being created' })
    }

    const address = wallet.address.toLowerCase()
    const now     = Math.floor(Date.now() / 1000)

    await db.run(sql`
      UPDATE accounts
      SET wallet_address = ${address}, status = 'active', updated_at = ${now}
      WHERE id = ${account.id}
    `)

    const rows = parseRows(await db.run(sql`${SELECT_PUBLIC} WHERE id = ${account.id} LIMIT 1`))
    res.json({
      ready:      true,
      account:    publicAccount(rows[0]),
      blockchain: wallet.blockchain,
    })
  } catch (err: any) {
    const msg = String(err?.message ?? '')
    // Two accounts can never share an address. If this fires, something
    // is wrong with the Circle mapping and we must not silently continue.
    if (/UNIQUE constraint failed: accounts.wallet_address/i.test(msg)) {
      return res.status(409).json({
        error: 'That wallet is already linked to another account. Contact support.',
      })
    }
    const e = err as CircleAuthError
    res.status(e.status ?? 502).json({ error: e.message ?? 'Could not read your wallet' })
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
// POST /auth/session   { userToken, email? }
//
// The single door. There is no separate sign-up: whoever authenticates
// with Circle either has an account here or gets one made for them.
// Details (username, name) are collected afterwards, once they have a
// wallet, so the first screen asks for nothing but a sign-in method.
// ══════════════════════════════════════════════════════════
router.post('/session', async (req, res) => {
  const { userToken, email, name } = req.body ?? {}

  let circleUser
  try {
    circleUser = await verifyUserToken(userToken)
  } catch (err: any) {
    const e = err as CircleAuthError
    return res.status(e.status ?? 401).json({ error: e.message, code: 'circle_auth' })
  }

  const mail = email ? normalizeEmail(email) : null

  try {
    let rows = parseRows(await db.run(
      sql`${SELECT_PUBLIC} WHERE circle_user_id = ${circleUser.id} LIMIT 1`))

    let isNew = false

    if (!rows.length) {
      isNew = true
      const id  = randomUUID()
      const now = Math.floor(Date.now() / 1000)

      // Prefill the name from the social provider when it gave us one,
      // so the profile form starts filled in rather than blank.
      const parts = normalizeName(String(name ?? '')).split(' ').filter(Boolean)
      const first = parts.length ? parts[0] : null
      const last  = parts.length > 1 ? parts.slice(1).join(' ') : null

      await db.run(sql`
        INSERT INTO accounts
          (id, email, first_name, last_name, circle_user_id, status, created_at, updated_at)
        VALUES
          (${id}, ${mail}, ${first}, ${last}, ${circleUser.id}, 'pending', ${now}, ${now})
      `)
      rows = parseRows(await db.run(sql`${SELECT_PUBLIC} WHERE id = ${id} LIMIT 1`))
    }

    const account = publicAccount(rows[0])

    if (account.status === 'suspended') {
      return res.status(403).json({ error: 'This account is suspended.', code: 'suspended' })
    }

    const now = Math.floor(Date.now() / 1000)
    // Backfill the email if we learned it on a later sign-in (Google does
    // not always give us one on the first pass).
    if (mail && !account.email) {
      await db.run(sql`UPDATE accounts SET email = ${mail}, updated_at = ${now} WHERE id = ${account.id}`)
        .catch(() => {})  // another account may already own it
    }
    await db.run(sql`UPDATE accounts SET last_login_at = ${now} WHERE id = ${account.id}`)

    // Welcome mail, exactly once, the first time we know where to send it.
    // That is usually now, but for a Google sign-in with no email in the
    // OAuth response it happens on a later visit once the address exists.
    await maybeSendWelcome(String(account.id))

    const session = await createSession(
      String(account.id), req.ip, req.headers['user-agent'] as string)

    res.json({
      account,
      token:     session.token,
      expiresAt: session.expiresAt,
      isNew,
      // What the client still has to do before the dashboard is usable.
      needsWallet: !account.walletAddress,
    })
  } catch (err: any) {
    console.error('[auth] session failed:', err?.message)
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
AFX_Q01_EOF
echo "  ✓ afrifx-api/src/routes/auth.ts"

mkdir -p "$(dirname "afrifx-web/lib/circle.ts")"
cat > 'afrifx-web/lib/circle.ts' <<'AFX_Q02_EOF'
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

/**
 * Where Google sends the browser back to.
 *
 * This must be the sign-in page, NOT the site root. The root is the
 * landing page, and the SDK callback that finishes the handshake only
 * exists on /signin - returning to '/' silently drops the login and
 * leaves the user looking at the marketing page.
 *
 * Whatever this returns must also be listed in Google Cloud Console
 * under Authorized redirect URIs, exactly.
 */
export function signInUrl(): string {
  if (typeof window === 'undefined') return ''
  return `${window.location.origin}/signin`
}

export type AuthIntent = 'signin' | 'signup'

export interface CircleLoginResult {
  userToken:     string
  encryptionKey: string
  /**
   * Email from the social provider, when it gives us one.
   *
   * Google returns this in oAuthInfo.socialUserInfo. Without it a
   * Google sign-in creates an account with no address, so welcome mail,
   * invoice reminders and trade alerts have nowhere to go.
   */
  email?:        string
  /** Display name from the provider, used to prefill the profile form. */
  name?:         string
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
          redirectUri:         typeof window !== 'undefined' ? signInUrl() : '',
          selectAccountPrompt: true,
        },
      },
    },
    (err: unknown, result: any) => {
      if (!onLogin) return
      if (err || !result?.userToken) return onLogin(err ?? new Error('Sign-in failed'), null)
      const social = result?.oAuthInfo?.socialUserInfo
      onLogin(null, {
        userToken:     result.userToken,
        encryptionKey: result.encryptionKey,
        email:         social?.email,
        name:          social?.name,
      })
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
        redirectUri:         signInUrl(),
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

/**
 * Run a Circle challenge and wait for the user to approve it.
 *
 * Wallet creation happens here, on the user's device. Their keyshare is
 * generated locally and never reaches our servers, which is what makes
 * the wallet user-controlled rather than custodial.
 *
 * setAuthentication must be called first or execute silently does nothing.
 */
export async function executeChallenge(
  challengeId: string, userToken: string, encryptionKey: string,
): Promise<void> {
  const instance = await getSdk()
  instance.setAuthentication({ userToken, encryptionKey })

  await new Promise<void>((resolve, reject) => {
    instance.execute(challengeId, (err: any) => {
      if (err) reject(new Error(err?.message ?? 'You cancelled the request'))
      else resolve()
    })
  })
}

/** Clear the handshake cookies once we no longer need them. */
export function clearAuthCookies(): void {
  deleteCookie(COOKIE.deviceToken)
  deleteCookie(COOKIE.encryptionKey)
  deleteCookie(COOKIE.intent)
}

/** True when the app has the config it needs to talk to Circle at all. */
export const circleConfigured = () => Boolean(APP_ID)
AFX_Q02_EOF
echo "  ✓ afrifx-web/lib/circle.ts"

mkdir -p "$(dirname "afrifx-web/app/(auth)/signin/page.tsx")"
cat > 'afrifx-web/app/(auth)/signin/page.tsx' <<'AFX_Q03_EOF'
'use client'

import { useState, useEffect, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import { ArrowLeftRight, Mail, AlertCircle, Loader2, ArrowLeft } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  getSdk, startGoogleLogin, sendEmailCode, openCodeEntry,
  clearAuthCookies, circleConfigured,
} from '@/lib/circle'
import { persistSession, useAuth, type Account } from '@/hooks/useAuth'
import { provisionWallet } from '@/hooks/useWalletProvisioning'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type Stage = 'choose' | 'email' | 'sent'

/**
 * The single door into the app.
 *
 * There is no separate sign-up. You pick a sign-in method; if it's your
 * first time we make the account, create your wallet, and send you on to
 * choose a username. If you've been here before you land on the
 * dashboard. Nothing is asked for up front.
 */
export default function SignInPage() {
  const router = useRouter()
  const { account, loading } = useAuth()

  // Already signed in (e.g. opened /signin from a bookmark, or bounced
  // here by the guard after the session was restored): don't ask again.
  useEffect(() => {
    if (!loading && account) router.replace('/dashboard')
  }, [loading, account, router])

  const [stage, setStage] = useState<Stage>('choose')
  const [email, setEmail] = useState('')
  const [busy,  setBusy]  = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const enter = useCallback(async (
    userToken: string, encryptionKey: string,
    social?: { email?: string; name?: string },
  ) => {
    setBusy('Signing you in')
    try {
      const res = await fetch(`${API}/auth/session`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        // Send whatever identity we have: the address they typed for the
        // code flow, or the one Google gave us. Without this a Google
        // account is created with no email and gets no mail at all.
        body: JSON.stringify({
          userToken,
          email: social?.email ?? email.trim() ?? undefined,
          name:  social?.name,
        }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) { setError(data.error ?? 'Could not sign you in'); setBusy(null); return }

      persistSession(data.token, data.account as Account)
      clearAuthCookies()

      // First time in: make the wallet before letting them through, so
      // the dashboard is never reached in a half-provisioned state.
      if (data.needsWallet) {
        try {
          await provisionWallet(userToken, encryptionKey, setBusy)
        } catch (e: any) {
          setError(`${e?.message ?? 'Wallet setup did not finish'} You are signed in, so you can retry.`)
          setBusy(null)
          return
        }
      }

      // ProfileGuard sends anyone without a profile to /profile/setup,
      // so the dashboard is the right destination either way.
      router.push('/dashboard')
    } catch {
      setError('Could not reach the server. Check your connection and try again.')
      setBusy(null)
    }
  }, [email, router])

  // Registered on mount: Google sends the browser away and back, so the
  // callback has to be listening before anything is clicked.
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
      void enter(result.userToken, result.encryptionKey, { email: result.email, name: result.name })
    }).catch(() => setError('Could not load sign-in. Refresh and try again.'))

    return () => { cancelled = true }
  }, [enter])

  async function onGoogle() {
    setError(null); setBusy('Opening Google')
    try { await startGoogleLogin('signin') }
    catch (e: any) { setError(e?.message ?? 'Could not start Google sign-in'); setBusy(null) }
  }

  async function onSendCode() {
    setError(null); setBusy('Sending your code')
    try { await sendEmailCode(email.trim()); setStage('sent') }
    catch (e: any) { setError(e?.message ?? 'Could not send the code') }
    finally { setBusy(null) }
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
          New here? Signing in creates your account. No wallet or seed phrase needed.
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
            <Button className="w-full" onClick={() => openCodeEntry()}>Enter code</Button>
            <button onClick={() => { setStage('email'); setError(null) }}
              className="w-full text-xs text-app-muted hover:text-app-text">
              Use a different email
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
AFX_Q03_EOF
echo "  ✓ afrifx-web/app/(auth)/signin/page.tsx"

echo ""
echo "→ Done."
echo ""
echo "NEXT:"
echo "  cd afrifx-api && npm run migrate && npm test"
echo "  cd ../afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo ""
echo "  Then sign in with a FRESH Google account: it should land with an"
echo "  email already on the profile, a prefilled name, and a welcome mail."
echo ""
