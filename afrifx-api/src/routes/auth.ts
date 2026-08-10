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
