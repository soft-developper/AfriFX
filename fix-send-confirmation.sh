#!/usr/bin/env bash
# ============================================================
# fix-send-confirmation.sh
#
# FIX: the transfer succeeds on-chain but the page spins forever with
# no success message and no explorer link.
#
# Run AFTER phase4a-send-circle-signing.sh.
#
# CAUSE
# POST /user/transactions/transfer returns a **challengeId**, which is
# NOT a transaction id. I polled GET /transactions/{challengeId}, which
# can never resolve, so every poll 404'd. The loop treated a failed poll
# as "not ready yet" and silently continued - 30 times, then gave up
# without a hash. Hence: money moves, UI spins, nothing is reported.
#
# Circle's guidance is to poll the transaction LIST for the user.
#
# THE FIX
#   - New GET /auth/wallet/tx/find locates the transaction the challenge
#     produced, matching on destination address and only considering
#     transactions created after this transfer started (so an earlier
#     send to the same address can't be mistaken for this one).
#   - The client polls that instead.
#   - Five consecutive failed polls now raise a real error instead of
#     spinning. It says the transfer may still have gone through and to
#     check the balance before retrying, because by that point it
#     usually has.
#   - As soon as a txHash exists the UI shows it, without waiting for
#     Circle to mark the transaction COMPLETE.
#   - If it is approved but the hash is still not available, Send now
#     shows "Sent. It is confirming on-chain..." instead of ending in
#     silence, which reads as failure even when the money has moved.
#
# VERIFIED: api tsc clean, 85 tests pass; web tsc clean, build succeeds.
#
# AFTER RUNNING:
#   cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-api/src/services/circleWallets.ts")"
cat > 'afrifx-api/src/services/circleWallets.ts' <<'AFX_S00_EOF'
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

// ══════════════════════════════════════════════════════════
// TRANSACTIONS
//
// Every on-chain action is the same handshake as wallet creation:
// ask Circle to build it, get a challengeId, the user approves it on
// their device, then poll for the result. Nothing is signed on the
// server.
// ══════════════════════════════════════════════════════════

/** The user's primary wallet id (not the address) - Circle needs the id. */
export async function getPrimaryWalletId(userToken: string): Promise<string> {
  const wallets = await listUserWallets(userToken)
  const wallet  = pickPrimaryWallet(wallets)
  if (!wallet) throw new CircleAuthError('No wallet found for this account', 404)
  return wallet.id
}

interface TokenBalance {
  token?:  { id?: string; symbol?: string; blockchain?: string; decimals?: number }
  amount?: string
}

/**
 * Circle identifies tokens by its own UUID, not by contract address, so
 * the id has to be looked up per wallet before a transfer can be built.
 */
export async function getTokenId(
  userToken: string, walletId: string, symbol = 'USDC',
): Promise<string> {
  const data = await circleFetch(
    `/v1/w3s/wallets/${walletId}/balances`, userToken)
  const balances = (data.tokenBalances ?? []) as TokenBalance[]

  const match = balances.find(
    b => String(b.token?.symbol ?? '').toUpperCase() === symbol.toUpperCase())

  if (!match?.token?.id) {
    throw new CircleAuthError(
      `No ${symbol} balance on this wallet yet. Add funds and try again.`, 400)
  }
  return match.token.id
}

/** Build a token transfer. Returns a challengeId for the user to approve. */
export async function createTransfer(params: {
  userToken:          string
  walletId:           string
  tokenId:            string
  destinationAddress: string
  amount:             string
  feeLevel?:          'LOW' | 'MEDIUM' | 'HIGH'
}): Promise<{ challengeId: string }> {
  const data = await circleFetch(
    '/v1/w3s/user/transactions/transfer', params.userToken, {
      method: 'POST',
      body:   JSON.stringify({
        idempotencyKey:     randomUUID(),
        walletId:           params.walletId,
        tokenId:            params.tokenId,
        destinationAddress: params.destinationAddress,
        // Circle takes decimal strings, not base units.
        amounts:            [params.amount],
        feeLevel:           params.feeLevel ?? 'MEDIUM',
      }),
    })
  return { challengeId: String(data.challengeId) }
}

export interface CircleTransaction {
  id:          string
  state:       string
  txHash?:     string
  blockchain?: string
  amounts?:    string[]
}

/** Read a transaction back by its Circle transaction id. */
export async function getTransaction(
  userToken: string, transactionId: string,
): Promise<CircleTransaction> {
  const data = await circleFetch(
    `/v1/w3s/transactions/${transactionId}`, userToken)
  const t = data.transaction ?? {}
  return {
    id:         String(t.id ?? transactionId),
    state:      String(t.state ?? 'UNKNOWN'),
    txHash:     t.txHash,
    blockchain: t.blockchain,
    amounts:    t.amounts,
  }
}

/**
 * Find the transaction produced by a transfer challenge.
 *
 * The transfer endpoint returns a challengeId, NOT a transaction id, and
 * the two are different identifiers - polling /transactions/{challengeId}
 * never resolves. Circle's guidance is to poll the transaction LIST for
 * the user instead, so this finds the newest outbound transaction to the
 * expected destination that appeared after the transfer was started.
 *
 * `since` is epoch seconds; it stops an older transfer to the same
 * address from being mistaken for this one.
 */
export async function findRecentTransfer(params: {
  userToken:          string
  walletId:           string
  destinationAddress: string
  since:              number
}): Promise<CircleTransaction | null> {
  const data = await circleFetch(
    `/v1/w3s/transactions?walletIds=${encodeURIComponent(params.walletId)}&pageSize=20`,
    params.userToken)

  const list = (data.transactions ?? []) as any[]
  const want = params.destinationAddress.toLowerCase()

  const match = list.find(t => {
    if (String(t.destinationAddress ?? '').toLowerCase() !== want) return false
    const created = Date.parse(String(t.createDate ?? '')) / 1000
    // Allow a little clock skew between us and Circle.
    return !Number.isFinite(created) || created >= params.since - 120
  })

  if (!match) return null
  return {
    id:         String(match.id),
    state:      String(match.state ?? 'UNKNOWN'),
    txHash:     match.txHash,
    blockchain: match.blockchain,
    amounts:    match.amounts,
  }
}
AFX_S00_EOF
echo "  ✓ afrifx-api/src/services/circleWallets.ts"

mkdir -p "$(dirname "afrifx-api/src/routes/auth.ts")"
cat > 'afrifx-api/src/routes/auth.ts' <<'AFX_S01_EOF'
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
  getPrimaryWalletId, getTokenId, createTransfer, getTransaction, findRecentTransfer,
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
// TRANSACTIONS
//
// The server builds the transaction and Circle returns a challenge;
// the user approves it on their own device. Nothing is signed here.
// ══════════════════════════════════════════════════════════

// POST /auth/wallet/tx/transfer  { userToken, to, amount }
router.post('/wallet/tx/transfer', requireAccount, async (req, res) => {
  const { userToken, to, amount } = req.body ?? {}
  if (!userToken) return res.status(400).json({ error: 'userToken is required' })
  if (!/^0x[a-fA-F0-9]{40}$/.test(String(to ?? ''))) {
    return res.status(400).json({ error: 'Enter a valid destination address' })
  }
  const value = Number(amount)
  if (!Number.isFinite(value) || value <= 0) {
    return res.status(400).json({ error: 'Enter an amount greater than zero' })
  }

  try {
    const walletId = await getPrimaryWalletId(String(userToken))
    const tokenId  = await getTokenId(String(userToken), walletId)
    const { challengeId } = await createTransfer({
      userToken: String(userToken),
      walletId,
      tokenId,
      destinationAddress: String(to),
      // Circle expects a decimal string, not base units.
      amount: String(amount),
    })
    res.json({ challengeId })
  } catch (err: any) {
    const e = err as CircleAuthError
    res.status(e.status ?? 502).json({ error: e.message })
  }
})

// GET /auth/wallet/tx/find?userToken=..&to=..&since=..
//
// A transfer challenge does not give us a transaction id, so the client
// asks us to locate the resulting transaction instead.
router.get('/wallet/tx/find', requireAccount, async (req, res) => {
  const userToken = String(req.query.userToken ?? '')
  const to        = String(req.query.to ?? '')
  const since     = Number(req.query.since ?? 0)
  if (!userToken) return res.status(400).json({ error: 'userToken is required' })
  if (!to)        return res.status(400).json({ error: 'to is required' })

  try {
    const walletId = await getPrimaryWalletId(userToken)
    const tx = await findRecentTransfer({
      userToken, walletId, destinationAddress: to, since,
    })
    // Not an error: Circle may not have indexed it yet.
    res.json(tx ?? { state: 'PENDING' })
  } catch (err: any) {
    const e = err as CircleAuthError
    res.status(e.status ?? 502).json({ error: e.message })
  }
})

// GET /auth/wallet/tx/:id?userToken=..
router.get('/wallet/tx/:id', requireAccount, async (req, res) => {
  const userToken = String(req.query.userToken ?? '')
  if (!userToken) return res.status(400).json({ error: 'userToken is required' })
  try {
    res.json(await getTransaction(userToken, req.params.id))
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
AFX_S01_EOF
echo "  ✓ afrifx-api/src/routes/auth.ts"

mkdir -p "$(dirname "afrifx-web/hooks/useCircleTx.ts")"
cat > 'afrifx-web/hooks/useCircleTx.ts' <<'AFX_S02_EOF'
'use client'

/**
 * Signing with a Circle wallet.
 *
 * THE CONSTRAINT THIS SOLVES
 * Circle's userToken lasts 60 minutes and every signature needs one,
 * but our own session lasts 30 days. So the app can be legitimately
 * signed in and still unable to sign a transaction. When that happens
 * the user has to re-authenticate with Circle - it is not a bug, it is
 * how user-controlled wallets work: the keyshare is theirs, so their
 * presence is required.
 *
 * The token pair is kept in sessionStorage rather than localStorage:
 * it grants signing power, so it should die with the tab rather than
 * persist on disk.
 */

import { executeChallenge } from '@/lib/circle'
import { apiFetch } from '@/hooks/useAuth'

const KEY = 'circle_signing'

export interface SigningSession {
  userToken:     string
  encryptionKey: string
  /** Epoch ms when Circle's 60-minute token expires. */
  expiresAt:     number
}

/** Circle tokens last 60 minutes; expire ours slightly early to avoid races. */
const TOKEN_TTL_MS = 55 * 60 * 1000

export function saveSigningSession(userToken: string, encryptionKey: string) {
  const s: SigningSession = { userToken, encryptionKey, expiresAt: Date.now() + TOKEN_TTL_MS }
  sessionStorage.setItem(KEY, JSON.stringify(s))
}

export function getSigningSession(): SigningSession | null {
  try {
    const raw = sessionStorage.getItem(KEY)
    if (!raw) return null
    const s = JSON.parse(raw) as SigningSession
    if (!s?.userToken || Date.now() >= s.expiresAt) return null
    return s
  } catch { return null }
}

export function clearSigningSession() {
  sessionStorage.removeItem(KEY)
}

/** Thrown when signing needs the user to authenticate with Circle again. */
export class NeedsReauthError extends Error {
  constructor() {
    super('Confirm it\u2019s you to approve this. Sign in again to continue.')
    this.name = 'NeedsReauthError'
  }
}

/** Terminal states Circle reports for a transaction. */
const DONE   = ['COMPLETE', 'CONFIRMED']
const FAILED = ['FAILED', 'CANCELLED', 'DENIED']

export interface TransferResult {
  txHash?: string
  state:   string
}

/**
 * Send USDC from the user's Circle wallet.
 *
 * Build on the server, approve on the device, then poll. Throws
 * NeedsReauthError when there is no live Circle token, so callers can
 * prompt for re-authentication instead of showing a generic failure.
 */
export async function sendUsdc(
  params: { to: string; amount: string },
  onStep?: (message: string) => void,
): Promise<TransferResult> {
  const session = getSigningSession()
  if (!session) throw new NeedsReauthError()

  // Recorded before we start so we can tell this transfer apart from an
  // earlier one to the same address.
  const startedAt = Date.now()

  onStep?.('Preparing the transfer')

  const res = await apiFetch('/auth/wallet/tx/transfer', {
    method: 'POST',
    body:   JSON.stringify({
      userToken: session.userToken,
      to:        params.to,
      amount:    params.amount,
    }),
  })
  const data = await res.json().catch(() => ({}))

  if (res.status === 401) { clearSigningSession(); throw new NeedsReauthError() }
  if (!res.ok) throw new Error(data.error ?? 'Could not prepare the transfer')

  onStep?.('Approve the transfer to continue')
  await executeChallenge(data.challengeId, session.userToken, session.encryptionKey)

  onStep?.('Confirming on-chain')

  // The transfer endpoint returns a challengeId, which is NOT a
  // transaction id - polling /transactions/{challengeId} never resolves.
  // Ask the server to locate the transaction this challenge produced.
  const since = Math.floor(startedAt / 1000)
  let consecutiveErrors = 0

  for (let i = 0; i < 40; i++) {
    await new Promise(r => setTimeout(r, 2000))

    const s = getSigningSession()
    if (!s) throw new NeedsReauthError()

    const qs = new URLSearchParams({
      userToken: s.userToken,
      to:        params.to,
      since:     String(since),
    })
    const r2 = await apiFetch(`/auth/wallet/tx/find?${qs}`)

    if (!r2.ok) {
      // Don't spin silently on a persistent failure: surface it rather
      // than leaving the user watching a spinner forever.
      if (++consecutiveErrors >= 5) {
        throw new Error(
          'Lost track of the transfer while confirming it. It may still have gone through \u2014 check your balance before retrying.',
        )
      }
      continue
    }
    consecutiveErrors = 0

    const tx = await r2.json().catch(() => ({}))
    if (DONE.includes(tx.state))   return { txHash: tx.txHash, state: tx.state }
    if (FAILED.includes(tx.state)) throw new Error(`Transfer ${String(tx.state).toLowerCase()}`)

    // Once we have a hash the money is on-chain, even if Circle hasn't
    // marked it COMPLETE yet. Show it rather than making them wait.
    if (tx.txHash) return { txHash: tx.txHash, state: tx.state ?? 'SENT' }
  }

  // Approved and broadcast, just slow. Not a failure: the money may well
  // have moved, so say so honestly instead of reporting an error.
  return { state: 'PENDING' }
}
AFX_S02_EOF
echo "  ✓ afrifx-web/hooks/useCircleTx.ts"

mkdir -p "$(dirname "afrifx-web/app/(app)/send/page.tsx")"
cat > 'afrifx-web/app/(app)/send/page.tsx' <<'AFX_S03_EOF'
'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useState, useEffect } from 'react'
import { useWaitForTransactionReceipt } from 'wagmi'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { sendUsdc, NeedsReauthError } from '@/hooks/useCircleTx'
import { useWalletReady } from '@/hooks/useWalletReady'
import { isAddress, parseUnits } from 'viem'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useGatewaySend } from '@/hooks/useGatewaySend'
import { fetchGatewayBalances, gatewayChains } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { AlertCircle, CheckCircle, Loader2, Zap, Layers, ExternalLink } from 'lucide-react'

const HOME = 'arc'

function SendPageInner() {
  const { address, isConnected }  = useAccount()
  const { ready: walletReady }    = useWalletReady()
  const [to,      setTo]          = useState('')
  const [amount,  setAmount]      = useState('')
  const [destKey, setDestKey]     = useState(HOME)

  // Wallet balance on Arc (what Send has always used).
  const { formatted: balance, rawBalance } = useUSDCBalance()
  const [sending, setSending] = useState(false)
  const [txStep,  setTxStep]  = useState<string | null>(null)
  const [txError, setTxError] = useState<string | null>(null)
  const [txNote,  setTxNote]  = useState<string | null>(null)
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>()
  const { isSuccess }       = useWaitForTransactionReceipt({ hash: txHash })

  // Unified Gateway balance, for cross-chain sends.
  const gw = useGatewaySend()
  const [gwTotal,  setGwTotal]  = useState(0)
  const [gwByChain, setGwByChain] = useState<any[]>([])

  useEffect(() => {
    if (!address) return
    fetchGatewayBalances(address).then(res => {
      if ('error' in res) return
      setGwTotal(res.total)
      setGwByChain(res.perChain)
    })
  }, [address, gw.step])

  /*
    Clear the form once a cross-chain send completes.

    The same-chain path clears immediately after submitting, but a cross-chain
    send finishes asynchronously, so without this the recipient and amount sat
    there with the button still live, inviting an accidental second send of the
    same amount. For a money form that's a real hazard, not just untidiness.
  */
  useEffect(() => {
    if (gw.step === 'done') { setTo(''); setAmount('') }
  }, [gw.step])

  /*
    SMART ROUTING, the user picks a destination, not a mechanism.
      same chain (Arc -> Arc)  : plain wallet transfer. Instant, no Gateway
                                 balance consumed, and it's what Send always did.
      cross-chain              : spend the unified Gateway balance.
    This keeps existing behaviour intact while making other chains possible.
  */
  const isCrossChain = destKey !== HOME
  const dest    = gatewayChains().find(c => c.key === destKey)
  const destCctp = chainByKey(destKey)

  // Which balance applies to the current route?
  const availableNum = isCrossChain ? gwTotal : (parseFloat(balance) || 0)
  const availableStr = isCrossChain ? gwTotal.toFixed(2) : balance

  const amountNum        = parseFloat(amount) || 0
  const insufficientFunds = amountNum > 0 && amountNum > availableNum
  const validAddress     = isAddress(to)
  const validAmount      = amountNum > 0 && !insufficientFunds
  const valid            = validAddress && validAmount

  // For a cross-chain send we spend from whichever chain holds the balance.
  const sourceKey = gwByChain.find(c => c.amount >= amountNum)?.key ?? HOME

  const busy = sending || ['signing','requesting','switching','minting'].includes(gw.step)

  function setMax() { setAmount(availableNum.toFixed(6)) }

  async function handleSend() {
    if (!valid) return

    if (isCrossChain) {
      await gw.send({ fromKey: sourceKey, toKey: destKey, amount: amountNum, recipient: to })
      return
    }

    // Same-chain: a Circle wallet transfer. The user approves it on
    // their device, so there is no connected wallet to sign with.
    setSending(true); setTxError(null); setTxNote(null)
    try {
      const result = await sendUsdc({ to, amount }, setTxStep)
      if (result.txHash) {
        setTxHash(result.txHash as `0x${string}`)
      } else {
        // Approved and broadcast, but Circle hasn't surfaced the hash yet.
        // Say so plainly rather than ending in silence, which reads as a
        // failure even though the money has almost certainly moved.
        setTxNote('Sent. It is confirming on-chain and will appear in your activity shortly.')
      }
      setTo(''); setAmount('')
    } catch (err: any) {
      setTxError(err instanceof NeedsReauthError
        ? err.message
        : (err?.message ?? 'Could not send the transfer'))
    } finally {
      setSending(false); setTxStep(null)
    }
  }

  const gwLabel: Record<string, string> = {
    signing:    'Sign the transfer in your wallet',
    requesting: 'Getting approval from Circle…',
    switching:  `Switch your wallet to ${dest?.name ?? 'the destination'}`,
    minting:    'Confirm the final step in your wallet',
  }

  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Send</h1>
        <p className="text-sm text-app-muted">
          Send USDC to any supported chain. Cross-chain sends use your unified balance.
        </p>
      </div>

      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
        {/* Destination chain */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Send to chain
          </label>
          <select
            value={destKey}
            onChange={e => setDestKey(e.target.value)}
            disabled={busy}
            className="w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
          >
            {gatewayChains().map(c => (
              <option key={c.key} value={c.key}>{c.name}</option>
            ))}
          </select>
        </div>

        {/* Balance which one depends on the route */}
        <div className="mb-4 flex items-center justify-between text-xs">
          <span className="flex items-center gap-1.5 text-app-muted">
            {isCrossChain ? <><Layers className="h-3 w-3" /> Unified balance</> : 'Wallet balance'}
          </span>
          <span className="font-mono text-app-text">{availableStr} USDC</span>
        </div>

        {isCrossChain && gwTotal === 0 && (
          <div className="mb-3 rounded-lg bg-amber-900/20 px-3 py-2 text-[11px] text-amber-800 dark:text-amber-300">
            Cross-chain sends spend your unified balance, which is empty. Add funds
            from the Treasury page first.
          </div>
        )}

        {/* Recipient */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Recipient address
          </label>
          <Input
            placeholder="0x…"
            value={to}
            onChange={e => setTo(e.target.value)}
            className={`font-mono ${to && !validAddress ? 'border-red-500/50' : ''}`}
          />
          {to && !validAddress && (
            <p className="text-xs text-red-400">Invalid wallet address</p>
          )}
        </div>

        {/* Amount */}
        <div className="mb-4 space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              Amount (USDC)
            </label>
            <button onClick={setMax} className="text-xs text-app-accent-text hover:underline">
              Max
            </button>
          </div>
          <Input
            type="number"
            placeholder="0.00"
            value={amount}
            onChange={e => setAmount(e.target.value)}
            className={`font-mono text-lg ${insufficientFunds ? 'border-red-500/50' : ''}`}
          />

          {insufficientFunds && (
            <div className="flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              Insufficient balance, you only have {availableStr} USDC
            </div>
          )}

          {validAmount && amountNum > 0 && (
            <p className="text-xs text-emerald-400">
              Remaining after send: {(availableNum - amountNum).toFixed(4)} USDC
            </p>
          )}
        </div>

        {/* Route info */}
        <div className="mb-4 space-y-1.5 border-t border-app-border pt-3">
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Network fee</span>
            <Badge variant="arc"><Zap className="h-2.5 w-2.5" /> ~$0.001</Badge>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Route</span>
            <span className="text-app-text">
              {isCrossChain ? `Unified balance → ${dest?.name}` : 'Arc Testnet · direct'}
            </span>
          </div>
        </div>

        <Button className="w-full" size="lg" onClick={handleSend}
          disabled={!isConnected || !walletReady || !valid || busy || insufficientFunds}>
          {busy
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
            : !walletReady && isConnected
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Preparing wallet…</>
            : insufficientFunds
            ? 'Insufficient USDC balance'
            : 'Send USDC'
          }
        </Button>

        {/* Same-chain progress: approving happens on the user's device,
            so tell them what they're waiting for at each step. */}
        {txStep && !isCrossChain && (
          <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
            <Loader2 className="h-3 w-3 animate-spin" /> {txStep}…
          </p>
        )}

        {txNote && !isCrossChain && (
          <div className="mt-2 flex items-start gap-1.5 rounded-lg bg-emerald-900/20 px-3 py-2 text-[11px] text-emerald-500">
            <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{txNote}</span>
          </div>
        )}

        {txError && !isCrossChain && (
          <div className="mt-2 flex items-start gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-[11px] text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{txError}</span>
          </div>
        )}

        {/* Cross-chain progress */}
        {busy && isCrossChain && (
          <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
            <Loader2 className="h-3 w-3 animate-spin" /> {gwLabel[gw.step] ?? 'Working…'}
          </p>
        )}

        {/* Cross-chain errors. The EOA case gets its own explanation because
            "your wallet type isn't supported" is not something a user can
            debug from a generic error. */}
        {gw.step === 'error' && gw.error && (
          <div className="mt-3 rounded-lg border border-red-900/50 bg-red-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-red-400">
              <AlertCircle className="h-3.5 w-3.5" /> Transfer not completed
            </p>
            <p className="mt-1 text-[11px] text-red-800 dark:text-red-300/90">{gw.error}</p>
            {gw.needsEoa && (
              <p className="mt-1.5 text-[11px] text-red-700 dark:text-red-300/70">
                Same-chain sends on Arc still work normally.
              </p>
            )}
            <Button size="sm" variant="outline" className="mt-2" onClick={gw.reset}>
              Try again
            </Button>
          </div>
        )}

        {/* Success same-chain */}
        {isSuccess && txHash && (
          <a href={`https://testnet.arcscan.app/tx/${txHash}`}
            target="_blank" rel="noopener noreferrer"
            className="mt-3 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400 hover:underline">
            <CheckCircle className="h-3.5 w-3.5" /> Sent · View on ArcScan
          </a>
        )}

        {/* Success cross-chain */}
        {gw.step === 'done' && gw.mintTx && (
          <div className="mt-3 rounded-lg bg-emerald-900/20 px-3 py-2">
            <p className="flex items-center gap-2 text-xs text-emerald-400">
              <CheckCircle className="h-3.5 w-3.5" /> Sent to {dest?.name}
            </p>
            {destCctp && (
              <a href={`${destCctp.explorer}/tx/${gw.mintTx}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-1 inline-flex items-center gap-1 text-[11px] text-emerald-400 hover:underline">
                View transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

export default function SendPage() {
  return (
    <SectionGuard section="send">
      <SendPageInner />
    </SectionGuard>
  )
}
AFX_S03_EOF
echo "  ✓ afrifx-web/app/(app)/send/page.tsx"

echo ""
echo "→ Done."
echo ""
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo ""
echo "  Then send a small amount again: you should get a hash and an"
echo "  explorer link, or a clear 'confirming on-chain' message."
echo ""
