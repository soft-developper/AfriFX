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
  getPrimaryWalletId, getTokenId, createTransfer, getTransaction,
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
