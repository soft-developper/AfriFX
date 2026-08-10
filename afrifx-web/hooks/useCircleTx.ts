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

  // The challenge returns as soon as the user approves; the transaction
  // is still being broadcast, so poll until it settles.
  const challengeId = String(data.challengeId)
  for (let i = 0; i < 30; i++) {
    await new Promise(r => setTimeout(r, 2000))

    const s = getSigningSession()
    if (!s) throw new NeedsReauthError()

    const r2 = await apiFetch(
      `/auth/wallet/tx/${encodeURIComponent(challengeId)}?userToken=${encodeURIComponent(s.userToken)}`)
    if (!r2.ok) continue

    const tx = await r2.json().catch(() => ({}))
    if (DONE.includes(tx.state))   return { txHash: tx.txHash, state: tx.state }
    if (FAILED.includes(tx.state)) throw new Error(`Transfer ${String(tx.state).toLowerCase()}`)
  }

  // Approved and broadcast, just slow. Do not call this a failure: the
  // money may well have moved.
  return { state: 'PENDING' }
}
