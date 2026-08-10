#!/usr/bin/env bash
# ============================================================
# phase2-wallets.sh
#
# PHASE 2 - Provision a Circle user-controlled SCA wallet on sign-up.
#
# Run AFTER phase1-frontend.sh.
#
# THE HANDSHAKE (three steps, because the user must consent on their
# own device - their keyshare never touches our servers):
#
#   1. POST /auth/wallet/initialize  -> Circle returns a challengeId
#   2. browser runs sdk.execute(challengeId), user approves, keyshare
#      is generated locally
#   3. POST /auth/wallet/sync        -> read the address back, store it,
#      flip the account from 'pending' to 'active'
#
# Step 3 polls: Circle indexes a new wallet asynchronously, so an empty
# wallet list right after the challenge is normal, not an error. The
# route returns 202 "not ready" and the client retries for ~9s.
#
# CHAIN IS CONFIGURABLE, NOT HARDCODED
#   CIRCLE_BLOCKCHAIN (default ARC-TESTNET)
# Circle currently lists Arc for testnet only. If Arc mainnet support
# isn't ready at launch this becomes BASE with no code change.
#
# WHY pickPrimaryWallet EXISTS
# A user can hold wallets on several chains and Circle promises no
# ordering, so wallets[0] would silently record a Base address as the
# user's Arc address and every balance and transfer afterwards would
# look in the wrong place. The picker prefers the configured chain,
# skips frozen and address-less wallets, and falls back to a live one
# rather than leaving the account with no address. Mutation-verified:
# replacing it with wallets[0] fails five tests.
#
# FAILURE HANDLING
# If wallet setup fails after the account is created, the signup is NOT
# lost: the user is signed in and told they can retry. Losing an account
# because the last step timed out would be the worst outcome here.
#
# TESTS: 85 total, 9 new.
# VERIFIED: api tsc clean, 85 tests pass; web tsc clean and
# `npm run build` succeeds.
# NOT verified: the browser handshake itself (no browser here).
#
# AFTER RUNNING:
#   cd afrifx-api && npm test
#   cd ../afrifx-web && npm install && npx tsc --noEmit && npm run build
#   Optional Render env: CIRCLE_BLOCKCHAIN=ARC-TESTNET
#
# Safe to re-run: writes whole files.
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-api/src/services/circleWallets.ts")"
cat > 'afrifx-api/src/services/circleWallets.ts' <<'AFX_K00_EOF'
/**
 * Provisioning user-controlled wallets.
 *
 * Creating a wallet is a three-step handshake, because the user has to
 * consent on their own device:
 *
 *   1. initializeUserWallet()  -> Circle returns a challengeId
 *   2. the browser runs sdk.execute(challengeId), the user approves,
 *      and Circle generates the keyshares
 *   3. listUserWallets()       -> the wallet now exists, read its address
 *
 * Step 2 cannot happen on the server: the user's keyshare never touches
 * our backend, which is the whole point of user-controlled wallets.
 */

import { CircleAuthError } from './circleAuth'
import { randomUUID } from 'crypto'

const CIRCLE_BASE_URL = process.env.CIRCLE_BASE_URL ?? 'https://api.circle.com'

/**
 * Which chain the primary wallet lives on.
 *
 * Configurable rather than hardcoded: Circle currently lists Arc for
 * testnet only, so if Arc mainnet support isn't ready when we launch,
 * this becomes BASE (or ARB) without a code change.
 */
export const PRIMARY_BLOCKCHAIN = process.env.CIRCLE_BLOCKCHAIN ?? 'ARC-TESTNET'

/** Circle's code for "this user already has a wallet". Not an error for us. */
const ALREADY_INITIALIZED = 155106

export interface CircleWallet {
  id:         string
  address:    string
  blockchain: string
  state?:     string
}

async function circleFetch(
  path: string, userToken: string, init: RequestInit = {},
): Promise<any> {
  const apiKey = process.env.CIRCLE_API_KEY
  if (!apiKey) throw new CircleAuthError('CIRCLE_API_KEY is not configured', 500)

  let res: Response
  try {
    res = await fetch(`${CIRCLE_BASE_URL}${path}`, {
      ...init,
      headers: {
        Accept:         'application/json',
        'Content-Type': 'application/json',
        Authorization:  `Bearer ${apiKey}`,
        'X-User-Token': userToken,
        ...(init.headers ?? {}),
      },
    })
  } catch {
    throw new CircleAuthError('Could not reach Circle. Please try again.', 503)
  }

  const body: any = await res.json().catch(() => ({}))
  if (!res.ok) {
    if (res.status === 401 || res.status === 403) {
      throw new CircleAuthError('Your sign-in session expired. Please sign in again.', 401)
    }
    const err = new CircleAuthError(body?.message ?? 'Circle rejected the request', 502)
    ;(err as any).circleCode = body?.code
    throw err
  }
  return body?.data ?? {}
}

/**
 * Ask Circle to start wallet creation.
 *
 * Returns a challengeId the browser must execute, or alreadyInitialized
 * when the user has a wallet already, which happens whenever someone
 * refreshes mid-flow or signs up on a second device.
 */
export async function initializeUserWallet(userToken: string): Promise<
  { challengeId: string; alreadyInitialized?: false } |
  { challengeId: null;   alreadyInitialized: true }
> {
  try {
    const data = await circleFetch('/v1/w3s/user/initialize', userToken, {
      method: 'POST',
      body:   JSON.stringify({
        idempotencyKey: randomUUID(),
        accountType:    'SCA',
        blockchains:    [PRIMARY_BLOCKCHAIN],
      }),
    })
    return { challengeId: String(data.challengeId) }
  } catch (err: any) {
    if (err?.circleCode === ALREADY_INITIALIZED) {
      return { challengeId: null, alreadyInitialized: true }
    }
    throw err
  }
}

export async function listUserWallets(userToken: string): Promise<CircleWallet[]> {
  const data = await circleFetch('/v1/w3s/wallets', userToken)
  return (data.wallets ?? []) as CircleWallet[]
}

/**
 * Choose the wallet to record on the account.
 *
 * A user can end up with wallets on several chains, and Circle does not
 * promise an order, so never just take wallets[0]. Prefer the primary
 * chain; fall back to the first live wallet so a user whose wallet
 * landed elsewhere isn't left with no address at all.
 *
 * Exported separately from the network calls so it can be tested.
 */
export function pickPrimaryWallet(
  wallets: CircleWallet[], blockchain: string = PRIMARY_BLOCKCHAIN,
): CircleWallet | null {
  if (!wallets?.length) return null

  const usable = wallets.filter(w => w?.address && w.state !== 'FROZEN')
  if (!usable.length) return null

  const onChain = usable.find(
    w => String(w.blockchain).toUpperCase() === blockchain.toUpperCase())
  return onChain ?? usable[0]
}
AFX_K00_EOF
echo "  ✓ afrifx-api/src/services/circleWallets.ts"

mkdir -p "$(dirname "afrifx-api/src/routes/auth.ts")"
cat > 'afrifx-api/src/routes/auth.ts' <<'AFX_K01_EOF'
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
AFX_K01_EOF
echo "  ✓ afrifx-api/src/routes/auth.ts"

mkdir -p "$(dirname "afrifx-api/tests/circleWallets.test.ts")"
cat > 'afrifx-api/tests/circleWallets.test.ts' <<'AFX_K02_EOF'
/**
 * Choosing which wallet to record on an account.
 *
 * Circle can return wallets on several chains and makes no promise about
 * ordering, so `wallets[0]` is a real bug waiting to happen: it would
 * silently record a Base address as the user's Arc address, and every
 * balance and transfer after that would look at the wrong place.
 */

import { describe, it, expect } from 'vitest'
import { pickPrimaryWallet, type CircleWallet } from '../src/services/circleWallets'

const w = (blockchain: string, address = '0x' + blockchain.length.toString().repeat(4), state?: string): CircleWallet =>
  ({ id: `id-${blockchain}`, address, blockchain, state })

describe('pickPrimaryWallet', () => {
  it('returns null when there are no wallets yet', () => {
    // Normal shortly after the challenge: Circle indexes asynchronously.
    expect(pickPrimaryWallet([], 'ARC-TESTNET')).toBeNull()
    expect(pickPrimaryWallet(undefined as any, 'ARC-TESTNET')).toBeNull()
  })

  it('returns the only wallet when there is one', () => {
    const only = w('ARC-TESTNET')
    expect(pickPrimaryWallet([only], 'ARC-TESTNET')).toBe(only)
  })

  // The case that makes wallets[0] wrong.
  it('picks the configured chain even when it is not first', () => {
    const wallets = [w('BASE-SEPOLIA'), w('MATIC-AMOY'), w('ARC-TESTNET')]
    expect(pickPrimaryWallet(wallets, 'ARC-TESTNET')!.blockchain).toBe('ARC-TESTNET')
  })

  it('matches the chain case-insensitively', () => {
    const wallets = [w('arc-testnet')]
    expect(pickPrimaryWallet(wallets, 'ARC-TESTNET')).not.toBeNull()
  })

  it('follows the configured chain, so switching home chains needs no code change', () => {
    const wallets = [w('ARC-TESTNET'), w('BASE-SEPOLIA')]
    expect(pickPrimaryWallet(wallets, 'BASE-SEPOLIA')!.blockchain).toBe('BASE-SEPOLIA')
  })

  // Better to record something usable than to leave the account with no
  // address at all, which would block the user entirely.
  it('falls back to another wallet when the configured chain is absent', () => {
    const wallets = [w('BASE-SEPOLIA')]
    expect(pickPrimaryWallet(wallets, 'ARC-TESTNET')!.blockchain).toBe('BASE-SEPOLIA')
  })

  it('skips wallets with no address', () => {
    const good = w('BASE-SEPOLIA')
    const bad  = { id: 'x', address: '', blockchain: 'ARC-TESTNET' } as CircleWallet
    expect(pickPrimaryWallet([bad, good], 'ARC-TESTNET')).toBe(good)
  })

  it('skips frozen wallets rather than recording an unusable address', () => {
    const frozen = w('ARC-TESTNET', '0xfrozen', 'FROZEN')
    const live   = w('BASE-SEPOLIA', '0xlive')
    expect(pickPrimaryWallet([frozen, live], 'ARC-TESTNET')).toBe(live)
  })

  it('returns null when every wallet is unusable', () => {
    const frozen = w('ARC-TESTNET', '0xfrozen', 'FROZEN')
    expect(pickPrimaryWallet([frozen], 'ARC-TESTNET')).toBeNull()
  })
})
AFX_K02_EOF
echo "  ✓ afrifx-api/tests/circleWallets.test.ts"

mkdir -p "$(dirname "afrifx-web/lib/circle.ts")"
cat > 'afrifx-web/lib/circle.ts' <<'AFX_K03_EOF'
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
AFX_K03_EOF
echo "  ✓ afrifx-web/lib/circle.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useWalletProvisioning.ts")"
cat > 'afrifx-web/hooks/useWalletProvisioning.ts' <<'AFX_K04_EOF'
'use client'

/**
 * Provisioning the user's wallet.
 *
 * Three steps, because the user must consent on their own device:
 *   1. ask our API to start it, getting a challengeId from Circle
 *   2. run the challenge in the browser, where the user approves and
 *      their keyshare is generated locally
 *   3. ask our API to read the wallet back and store the address
 *
 * Step 3 can return "not ready": Circle indexes the new wallet
 * asynchronously, so a short poll is expected rather than exceptional.
 */

import { executeChallenge } from '@/lib/circle'
import { apiFetch, persistSession, getToken, type Account } from '@/hooks/useAuth'

/** How long to wait for Circle to index the new wallet before giving up. */
const SYNC_ATTEMPTS   = 6
const SYNC_DELAY_MS   = 1500

export interface ProvisionResult {
  account: Account
  blockchain: string
}

export async function provisionWallet(
  userToken: string,
  encryptionKey: string,
  onStep?: (message: string) => void,
): Promise<ProvisionResult> {
  onStep?.('Setting up your wallet')

  const initRes = await apiFetch('/auth/wallet/initialize', {
    method: 'POST',
    body:   JSON.stringify({ userToken }),
  })
  const init = await initRes.json().catch(() => ({}))
  if (!initRes.ok) throw new Error(init.error ?? 'Could not start wallet setup')

  // No challenge means the wallet already exists, e.g. the user refreshed
  // mid-flow or is signing up again on another device. Skip to reading it.
  if (init.challengeId) {
    onStep?.('Confirm in the window to finish')
    await executeChallenge(init.challengeId, userToken, encryptionKey)
  }

  onStep?.('Finishing up')

  for (let attempt = 0; attempt < SYNC_ATTEMPTS; attempt++) {
    const res  = await apiFetch('/auth/wallet/sync', {
      method: 'POST',
      body:   JSON.stringify({ userToken }),
    })
    const data = await res.json().catch(() => ({}))

    if (res.ok && data.ready) {
      const token = getToken()
      if (token) persistSession(token, data.account as Account)
      return { account: data.account as Account, blockchain: data.blockchain }
    }

    // 202 means "still being created"; anything else is a real failure.
    if (res.status !== 202) {
      throw new Error(data.error ?? 'Could not finish setting up your wallet')
    }
    await new Promise(r => setTimeout(r, SYNC_DELAY_MS))
  }

  throw new Error(
    'Your wallet is taking longer than usual to appear. It may still be created \u2014 sign in again in a moment to check.',
  )
}
AFX_K04_EOF
echo "  ✓ afrifx-web/hooks/useWalletProvisioning.ts"

mkdir -p "$(dirname "afrifx-web/app/(auth)/signup/page.tsx")"
cat > 'afrifx-web/app/(auth)/signup/page.tsx' <<'AFX_K05_EOF'
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
import { provisionWallet } from '@/hooks/useWalletProvisioning'

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

  /** Create the account once Circle has proven the email, then give it a wallet. */
  const submit = useCallback(async (
    userToken: string, encryptionKey: string, data: Fields,
  ) => {
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

      // The account exists now, so a failure below is recoverable: the
      // user is signed in and we can retry provisioning rather than
      // losing the signup entirely.
      try {
        await provisionWallet(userToken, encryptionKey, setBusy)
      } catch (e: any) {
        setError(
          `${e?.message ?? 'Wallet setup did not finish'} Your account is saved \u2014 open your dashboard to try again.`,
        )
        setBusy(null)
        return
      }

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
      void submit(result.userToken, result.encryptionKey, fieldsRef.current)
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
AFX_K05_EOF
echo "  ✓ afrifx-web/app/(auth)/signup/page.tsx"

echo ""
echo "→ Done."
echo ""
echo "NEXT:"
echo "  cd afrifx-api && npm test"
echo "  cd ../afrifx-web && npm install && npx tsc --noEmit && npm run build"
echo ""
echo "  Then sign up at /signup with a fresh email. You should get a"
echo "  wallet address, and the account status should become 'active'."
echo ""
