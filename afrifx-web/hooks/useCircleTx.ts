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
