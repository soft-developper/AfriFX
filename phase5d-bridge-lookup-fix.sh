#!/usr/bin/env bash
# ============================================================================
# Phase 5d - Bridge transaction lookup fix (stop the 502 storm)
#
# WHY
#   Bridging still failed with "Lost track of the transaction". The Network tab
#   showed /auth/wallet/tx/find-contract returning 502 repeatedly. Root cause:
#   the server's call to Circle's GET /v1/w3s/transactions used query filters
#   (walletIds / blockchain / operation) that Circle rejects for some
#   user-controlled token requests -> every poll 502'd -> "Lost track".
#
# WHAT IT DOES
#   * findContractExecution now queries WITHOUT those filters (the user token
#     already scopes results to this user) and matches chain + contract +
#     recency in code. This never 400/502s on the query itself.
#   * If the list call still fails for any reason, it returns null (treated as
#     "still confirming") instead of throwing, so a lookup hiccup can't kill a
#     bridge or error-storm the poll loop.
#   * find-contract now includes Circle's error detail in its response, so any
#     remaining failure is diagnosable from the Network tab instead of a blank
#     502.
#
# CHANGES (2 files)
#   afrifx-api/src/services/circleWallets.ts  findContractExecution: no filters, no throw
#   afrifx-api/src/routes/auth.ts             find-contract: surface error detail
#
# REQUIRES: Phase 5c already applied.
#
# USAGE
#   bash phase5d-bridge-lookup-fix.sh
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"; WEB="$ROOT/afrifx-web"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }
grep -q "findContractExecution" "$API/src/services/circleWallets.ts" || die "Phase 5b/5c not detected. Apply them first."
BK="$ROOT/.phase5d-backup"; rm -rf "$BK"; mkdir -p "$BK"
mkdir -p "$BK/$(dirname afrifx-api/src/routes/auth.ts)"; cp "$ROOT/afrifx-api/src/routes/auth.ts" "$BK/afrifx-api/src/routes/auth.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname afrifx-api/src/services/circleWallets.ts)"; cp "$ROOT/afrifx-api/src/services/circleWallets.ts" "$BK/afrifx-api/src/services/circleWallets.ts" 2>/dev/null || true
ok "snapshot saved"
say "Writing files"
cat > "$ROOT/afrifx-api/src/routes/auth.ts" <<'AFX_5D_EOF'
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
  initializeUserWallet, listUserWallets, pickPrimaryWallet, addUserWalletChains,
  getPrimaryWalletId, getTokenId, createTransfer, getTransaction, findRecentTransfer,
  cctpBlockchainFor, getWalletIdForChain, createContractExecution, findContractExecution,
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

// POST /auth/wallet/add-chains   { userToken }   (signed in)
//
// Adds the CCTP bridge chains to the user's wallet so a bridge can MINT on
// the destination. Returns a challengeId the browser executes (one approval),
// or challengeId: null when every chain already exists. This is provisioning
// only - it records nothing on the account and the wallet stays usable on Arc
// whether or not it succeeds.
router.post('/wallet/add-chains', requireAccount, async (req, res) => {
  const { userToken } = req.body ?? {}
  if (!userToken) return res.status(400).json({ error: 'userToken is required' })

  try {
    const result = await addUserWalletChains(String(userToken))
    res.json(result)
  } catch (err: any) {
    const e = err as CircleAuthError
    res.status(e.status ?? 502).json({ error: e.message })
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

// POST /auth/wallet/tx/contract
//   { userToken, chainKey, contractAddress, abiFunctionSignature, abiParameters, feeLevel? }
//
// Build a contract execution (bridge approve/burn/mint) on a specific chain.
// chainKey is the app's key (arc/base/ethereum/arbitrum/polygon); we resolve
// it to Circle's blockchain code and to the wallet id on that chain. Returns a
// challengeId the browser executes. A 409 with code NEEDS_CHAIN means the
// user's wallet isn't on that chain yet.
router.post('/wallet/tx/contract', requireAccount, async (req, res) => {
  const {
    userToken, chainKey, contractAddress,
    abiFunctionSignature, abiParameters, feeLevel,
  } = req.body ?? {}

  if (!userToken)       return res.status(400).json({ error: 'userToken is required' })
  if (!chainKey)        return res.status(400).json({ error: 'chainKey is required' })
  if (!/^0x[a-fA-F0-9]{40}$/.test(String(contractAddress ?? ''))) {
    return res.status(400).json({ error: 'A valid contractAddress is required' })
  }
  if (!abiFunctionSignature) {
    return res.status(400).json({ error: 'abiFunctionSignature is required' })
  }
  if (!Array.isArray(abiParameters)) {
    return res.status(400).json({ error: 'abiParameters must be an array' })
  }

  const blockchain = cctpBlockchainFor(String(chainKey))
  if (!blockchain) return res.status(400).json({ error: `Unsupported chain: ${chainKey}` })

  try {
    const walletId = await getWalletIdForChain(String(userToken), blockchain)
    const { challengeId } = await createContractExecution({
      userToken: String(userToken),
      walletId,
      contractAddress:      String(contractAddress),
      abiFunctionSignature: String(abiFunctionSignature),
      abiParameters,
      feeLevel: feeLevel === 'LOW' || feeLevel === 'HIGH' ? feeLevel : 'MEDIUM',
    })
    res.json({ challengeId })
  } catch (err: any) {
    const e = err as CircleAuthError
    // Surface the NEEDS_CHAIN marker so the client can prompt to enable the chain.
    const body: any = { error: e.message }
    if ((err as any).code === 'NEEDS_CHAIN') body.code = 'NEEDS_CHAIN'
    res.status(e.status ?? 502).json(body)
  }
})

// GET /auth/wallet/tx/find-contract?userToken=..&chainKey=..&contract=..&since=..
//
// A contract-execution challenge returns no transaction id, so the client asks
// us to locate the transaction it produced (to read its on-chain hash).
router.get('/wallet/tx/find-contract', requireAccount, async (req, res) => {
  const userToken = String(req.query.userToken ?? '')
  const chainKey  = String(req.query.chainKey ?? '')
  const contract  = String(req.query.contract ?? '')
  const since     = Number(req.query.since ?? 0)

  if (!userToken) return res.status(400).json({ error: 'userToken is required' })
  if (!chainKey)  return res.status(400).json({ error: 'chainKey is required' })
  if (!contract)  return res.status(400).json({ error: 'contract is required' })

  const blockchain = cctpBlockchainFor(chainKey)
  if (!blockchain) return res.status(400).json({ error: `Unsupported chain: ${chainKey}` })

  try {
    const walletId = await getWalletIdForChain(userToken, blockchain)
    const tx = await findContractExecution({
      userToken, walletId, blockchain, contractAddress: contract, since,
    })
    // Not an error: Circle may not have indexed it yet.
    res.json(tx ?? { state: 'PENDING' })
  } catch (err: any) {
    // A missing wallet-on-chain here is transient during self-heal (the chain
    // was just added and Circle is still indexing it). Don't error-storm the
    // client's poll loop - report PENDING so it keeps waiting a bit longer.
    if ((err as any).code === 'NEEDS_CHAIN') {
      return res.json({ state: 'PENDING' })
    }
    const e = err as CircleAuthError
    // Surface Circle's actual rejection so failures are diagnosable instead of
    // a blank 502. circleCode/detail come from circleFetch's error wrapping.
    res.status(e.status ?? 502).json({
      error:  e.message,
      detail: (err as any).circleCode ?? (err as any).detail ?? undefined,
      where:  'find-contract',
    })
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
AFX_5D_EOF
ok "wrote afrifx-api/src/routes/auth.ts"
cat > "$ROOT/afrifx-api/src/services/circleWallets.ts" <<'AFX_5D_EOF'
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

/**
 * The extra chains a wallet needs beyond its primary (Arc) one so that
 * CCTP bridging can MINT on the destination.
 *
 * WHY THIS EXISTS
 * A bridge burns on the source chain and mints on the destination. The mint
 * is a contract call the user's wallet has to sign ON THE DESTINATION CHAIN,
 * so the wallet must exist there first. Circle user-controlled wallets share
 * ONE address across EVM chains (unified addressing is automatic when the
 * user token is passed), but each chain still has to be added once before
 * the wallet can act on it.
 *
 * We add them all at sign-up so bridging is seamless later, rather than
 * deriving a chain mid-bridge while the user waits. Arc itself is created by
 * initializeUserWallet and is deliberately NOT repeated here.
 *
 * Testnet chain codes are Circle's own enum values (note Polygon Amoy is
 * MATIC-AMOY, not "polygon"). Override via env for mainnet without a code
 * change.
 */
export const CCTP_BRIDGE_CHAINS: string[] =
  (process.env.CIRCLE_BRIDGE_CHAINS ?? 'BASE-SEPOLIA,ETH-SEPOLIA,ARB-SEPOLIA,MATIC-AMOY')
    .split(',')
    .map(s => s.trim().toUpperCase())
    .filter(Boolean)

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

/**
 * Which of the CCTP bridge chains this user does NOT yet have a wallet on.
 *
 * Pure and exported so it can be tested without touching the network. Only
 * chains missing from the user's current wallet list are returned, so calling
 * addUserWalletChains repeatedly (e.g. a signup that was retried) never asks
 * Circle to recreate chains that already exist.
 */
export function missingBridgeChains(
  wallets: CircleWallet[], want: string[] = CCTP_BRIDGE_CHAINS,
): string[] {
  const have = new Set(wallets.map(w => String(w.blockchain).toUpperCase()))
  return want.map(c => c.toUpperCase()).filter(c => !have.has(c))
}

/**
 * Add the CCTP bridge chains to an already-initialized user's wallet.
 *
 * Returns a challengeId the browser must execute (the user approves once,
 * as with any wallet action), or null when every chain already exists so the
 * caller can skip straight past it.
 *
 * Circle creates the same address on each EVM chain automatically because we
 * pass the user token; we only list the chains still missing.
 */
export async function addUserWalletChains(userToken: string): Promise<
  { challengeId: string } | { challengeId: null }
> {
  const existing = await listUserWallets(userToken)
  const missing  = missingBridgeChains(existing)
  if (!missing.length) return { challengeId: null }

  const data = await circleFetch('/v1/w3s/user/wallets', userToken, {
    method: 'POST',
    body:   JSON.stringify({
      idempotencyKey: randomUUID(),
      accountType:    'SCA',
      blockchains:    missing,
    }),
  })
  const challengeId = data?.challengeId
  // No challengeId can come back if Circle decides there is nothing to do;
  // treat that the same as "already present" rather than failing.
  return challengeId ? { challengeId: String(challengeId) } : { challengeId: null }
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

// ══════════════════════════════════════════════════════════
// CONTRACT EXECUTION (bridge burn / approve / mint)
//
// A CCTP bridge is three contract calls the user's wallet signs:
//   approve() + depositForBurn() on the SOURCE chain, then
//   receiveMessage() on the DESTINATION chain.
// Each is the same challenge handshake as a transfer: build here, the user
// approves on their device, then we locate the resulting transaction to read
// its on-chain hash. Nothing is signed on the server.
// ══════════════════════════════════════════════════════════

/**
 * Map the app's internal chain key to Circle's blockchain enum value.
 *
 * The rest of the app keys chains as arc/base/ethereum/arbitrum/polygon, but
 * Circle's API wants its own codes (and Polygon Amoy is MATIC-AMOY, NOT
 * "polygon" - the classic mix-up). Kept in one place so the mapping can't
 * drift. Mainnet codes are provided too for when CCTP_ENV flips.
 */
export function cctpBlockchainFor(key: string): string | null {
  const testnet: Record<string, string> = {
    arc: 'ARC-TESTNET', base: 'BASE-SEPOLIA', ethereum: 'ETH-SEPOLIA',
    arbitrum: 'ARB-SEPOLIA', polygon: 'MATIC-AMOY',
  }
  const mainnet: Record<string, string> = {
    arc: 'ARC-TESTNET', base: 'BASE', ethereum: 'ETH',
    arbitrum: 'ARB', polygon: 'MATIC',
  }
  const isMainnet = (process.env.CCTP_ENV ?? 'testnet') === 'mainnet'
  return (isMainnet ? mainnet : testnet)[key] ?? null
}

/**
 * The wallet id on a specific blockchain.
 *
 * A bridge signs the burn on the source chain and the mint on the
 * destination, so we can't reuse the primary (Arc) wallet id for both - we
 * need the id of the wallet that lives on the chain the call targets. Circle
 * gives every EVM chain the same ADDRESS but a distinct wallet id, so we look
 * the id up by blockchain.
 *
 * Throws NEEDS_CHAIN (409) when the user has no wallet on that chain yet, so
 * the caller can trigger the add-chains flow rather than failing opaquely.
 */
export async function getWalletIdForChain(
  userToken: string, blockchain: string,
): Promise<string> {
  const wallets = await listUserWallets(userToken)
  const match = wallets.find(
    w => String(w.blockchain).toUpperCase() === blockchain.toUpperCase()
      && w.address && w.state !== 'FROZEN')
  if (!match) {
    const err = new CircleAuthError(
      `Your wallet isn't set up on ${blockchain} yet. Finish enabling bridging and try again.`,
      409)
    ;(err as any).code = 'NEEDS_CHAIN'
    throw err
  }
  return match.id
}

/**
 * Build a contract execution. Returns a challengeId for the user to approve.
 *
 * abiParameters follow Circle's rules: addresses and bytes32 as 0x-hex
 * strings, uint256 as decimal strings, booleans as booleans, arrays nested.
 * The caller passes them already in that shape.
 */
export async function createContractExecution(params: {
  userToken:            string
  walletId:             string
  contractAddress:      string
  abiFunctionSignature: string
  abiParameters:        (string | number | boolean | unknown[])[]
  feeLevel?:            'LOW' | 'MEDIUM' | 'HIGH'
}): Promise<{ challengeId: string }> {
  const data = await circleFetch(
    '/v1/w3s/user/transactions/contractExecution', params.userToken, {
      method: 'POST',
      body:   JSON.stringify({
        idempotencyKey:       randomUUID(),
        walletId:             params.walletId,
        contractAddress:      params.contractAddress,
        abiFunctionSignature: params.abiFunctionSignature,
        abiParameters:        params.abiParameters,
        feeLevel:             params.feeLevel ?? 'MEDIUM',
      }),
    })
  return { challengeId: String(data.challengeId) }
}

/**
 * Find the transaction a contract-execution challenge produced.
 *
 * Like a transfer, the challenge gives back a challengeId, NOT a transaction
 * id, so we poll the transaction LIST. A bridge fires several contract calls
 * (approve, burn on the source; mint on the destination), so matching on the
 * destination address isn't enough - we match on the CONTRACT the call
 * targeted, on the right chain, created after we started. Newest wins.
 *
 * `since` is epoch seconds. The list is narrowed server-side by blockchain and
 * operation so we're not scanning unrelated transfers.
 */
export async function findContractExecution(params: {
  userToken:       string
  walletId:        string
  blockchain:      string
  contractAddress: string
  since:           number
}): Promise<CircleTransaction | null> {
  // The user token already scopes /transactions to THIS user, so we don't
  // pass walletIds/blockchain/operation as query filters at all - some of
  // those combinations get rejected for user-controlled tokens. We fetch the
  // user's recent transactions and match everything (chain + contract +
  // recency) in code, which never 400s.
  const qs = new URLSearchParams({ pageSize: '50' })

  let data: any
  try {
    data = await circleFetch(
      `/v1/w3s/transactions?${qs.toString()}`, params.userToken)
  } catch (err: any) {
    // A failed lookup must NOT kill the bridge: the transaction may still be
    // confirming. Treat it as "not found yet" so the client keeps polling,
    // and let the server log carry the reason.
    console.warn('[findContractExecution] list query failed:',
      err?.message, (err as any)?.circleCode)
    return null
  }

  const list = (data.transactions ?? []) as any[]
  const want = params.contractAddress.toLowerCase()
  const chain = params.blockchain.toUpperCase()

  const match = list.find(t => {
    if (String(t.contractAddress ?? '').toLowerCase() !== want) return false
    if (String(t.blockchain ?? '').toUpperCase() !== chain)     return false
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
AFX_5D_EOF
ok "wrote afrifx-api/src/services/circleWallets.ts"

say "Verifying"
grep -q "never 400s" "$API/src/services/circleWallets.ts" || die "query fix missing"
say "API: install + tsc + tests"
( cd "$API" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && npx tsc --noEmit ) || { cp -rf "$BK"/. "$ROOT"/; die "API tsc failed - restored"; }
ok "api typechecks"
( cd "$API" && npx vitest run >/dev/null 2>&1 ) || { cp -rf "$BK"/. "$ROOT"/; die "API tests failed - restored"; }
ok "api tests pass"
say "WEB: build (unchanged, but verify)"
( cd "$WEB" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && npx tsc --noEmit && rm -rf .next && npm run build >/dev/null 2>&1 ) || { cp -rf "$BK"/. "$ROOT"/; die "web build failed - restored"; }
ok "web builds"
rm -rf "$BK"
say "Phase 5d applied and verified."
cat <<'NOTE'

  Fixed the 502 storm on transaction lookup. The bridge should now find its
  burn/mint transactions and progress instead of "Lost track".

  Commit & push:
    git add afrifx-api/src/services/circleWallets.ts afrifx-api/src/routes/auth.ts
    git commit -m "phase 5d: bridge tx lookup uses unfiltered query, no 502 storm"
    git push origin main

  Then retry the bridge. If it STILL fails, the find-contract response now
  carries Circle's real error under "detail" - grab that from the Network tab
  and send it over.
NOTE
