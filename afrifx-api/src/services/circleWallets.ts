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
