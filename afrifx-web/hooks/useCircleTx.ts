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

/**
 * Execute a contract call from the user's Circle wallet on a given chain.
 *
 * This is the bridge's building block: approve() and depositForBurn() on the
 * source chain, receiveMessage() on the destination. Same shape as sendUsdc -
 * build on the server, approve on the device, then poll for the on-chain
 * hash - but for an arbitrary contract call rather than a plain transfer.
 *
 * Throws NeedsReauthError when there is no live Circle token so callers can
 * prompt for re-authentication instead of a generic failure. Throws
 * NeedsChainError when the wallet isn't on the target chain yet.
 *
 * Returns the transaction hash once Circle surfaces it. `waitForHash: false`
 * returns as soon as the challenge is approved (the caller polls elsewhere).
 */
export class NeedsChainError extends Error {
  constructor(message?: string) {
    super(message ?? 'Your wallet isn\u2019t set up on that chain yet.')
    this.name = 'NeedsChainError'
  }
}

export interface ContractCallParams {
  chainKey:             string
  contractAddress:      string
  abiFunctionSignature: string
  abiParameters:        (string | number | boolean | unknown[])[]
  feeLevel?:            'LOW' | 'MEDIUM' | 'HIGH'
}

/**
 * Build a contract execution on the server. Returns a normalized shape so the
 * caller can branch on NEEDS_CHAIN vs auth vs success without touching Response.
 */
async function prepareContractCall(
  params: ContractCallParams, session: { userToken: string },
): Promise<{ ok: boolean; status: number; code?: string; error?: string; challengeId?: string }> {
  const res = await apiFetch('/auth/wallet/tx/contract', {
    method: 'POST',
    body:   JSON.stringify({
      userToken:            session.userToken,
      chainKey:             params.chainKey,
      contractAddress:      params.contractAddress,
      abiFunctionSignature: params.abiFunctionSignature,
      abiParameters:        params.abiParameters,
      feeLevel:             params.feeLevel,
    }),
  })
  const body = await res.json().catch(() => ({}))
  return {
    ok:          res.ok,
    status:      res.status,
    code:        body?.code,
    error:       body?.error,
    challengeId: body?.challengeId,
  }
}

/**
 * Add the CCTP bridge chains to the wallet, approving the challenge if one is
 * returned. Used to self-heal a bridge when the wallet predates chain
 * provisioning (accounts created before Phase 5a). Best-effort by nature: if
 * it can't add them, the caller's retry will surface a clear NEEDS_CHAIN.
 */
async function ensureBridgeChains(
  session: { userToken: string; encryptionKey: string },
  onStep?: (message: string) => void,
): Promise<void> {
  const res = await apiFetch('/auth/wallet/add-chains', {
    method: 'POST',
    body:   JSON.stringify({ userToken: session.userToken }),
  })
  const data = await res.json().catch(() => ({}))
  if (res.status === 401) { clearSigningSession(); throw new NeedsReauthError() }
  if (!res.ok) throw new Error(data.error ?? 'Could not enable the network')
  if (data.challengeId) {
    onStep?.('Confirm in the window to enable this network')
    await executeChallenge(data.challengeId, session.userToken, session.encryptionKey)
  }
}

export async function executeContractCall(
  params: ContractCallParams,
  onStep?: (message: string) => void,
): Promise<TransferResult> {
  const session = getSigningSession()
  if (!session) throw new NeedsReauthError()

  const startedAt = Date.now()

  onStep?.('Preparing the transaction')

  // Build the contract execution. If the wallet isn't on this chain yet
  // (older accounts created before the chains were provisioned), add the
  // chain once and retry - so the bridge self-heals instead of failing.
  let data = await prepareContractCall(params, session)

  if (data?.code === 'NEEDS_CHAIN') {
    onStep?.('Enabling this network for your wallet')
    await ensureBridgeChains(session, onStep)
    // Small pause so Circle indexes the new wallet before we reference it.
    await new Promise(r => setTimeout(r, 2500))
    const retrySession = getSigningSession()
    if (!retrySession) throw new NeedsReauthError()
    data = await prepareContractCall(params, retrySession)
    // Still not there - surface it honestly rather than looping.
    if (data?.code === 'NEEDS_CHAIN') throw new NeedsChainError(data.error)
  }

  if (data?.status === 401) { clearSigningSession(); throw new NeedsReauthError() }
  if (!data?.ok) throw new Error(data?.error ?? 'Could not prepare the transaction')
  if (!data.challengeId) throw new Error('The transaction could not be prepared. Please try again.')

  const signSession = getSigningSession()
  if (!signSession) throw new NeedsReauthError()

  onStep?.('Approve the transaction to continue')
  await executeChallenge(data.challengeId, signSession.userToken, signSession.encryptionKey)

  onStep?.('Confirming on-chain')

  // The challenge returns no transaction id, so ask the server to locate the
  // transaction it produced on this chain/contract and read its hash.
  const since = Math.floor(startedAt / 1000)
  let consecutiveErrors = 0

  for (let i = 0; i < 40; i++) {
    await new Promise(r => setTimeout(r, 2000))

    const s = getSigningSession()
    if (!s) throw new NeedsReauthError()

    const qs = new URLSearchParams({
      userToken: s.userToken,
      chainKey:  params.chainKey,
      contract:  params.contractAddress,
      since:     String(since),
    })
    const r2 = await apiFetch(`/auth/wallet/tx/find-contract?${qs}`)

    if (!r2.ok) {
      if (++consecutiveErrors >= 5) {
        throw new Error(
          'Lost track of the transaction while confirming it. It may still have ' +
          'gone through \u2014 check before retrying.',
        )
      }
      continue
    }
    consecutiveErrors = 0

    const tx = await r2.json().catch(() => ({}))
    if (DONE.includes(tx.state))   return { txHash: tx.txHash, state: tx.state }
    if (FAILED.includes(tx.state)) throw new Error(`Transaction ${String(tx.state).toLowerCase()}`)

    // Once we have a hash it's on-chain, even if Circle hasn't marked it
    // COMPLETE yet. Return it rather than making the caller wait.
    if (tx.txHash) return { txHash: tx.txHash, state: tx.state ?? 'SENT' }
  }

  // Approved and broadcast, just slow. Not a failure.
  return { state: 'PENDING' }
}
