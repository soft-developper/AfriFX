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

// ══════════════════════════════════════════════════════════
// TYPED-DATA SIGNING (EIP-712, for Gateway burn intents)
//
// Gateway authorizes a transfer with an OFF-CHAIN EIP-712 signature, not a
// contract call. Circle user-controlled wallets sign typed data via a
// challenge (POST /user/sign/typedData). The wallet is an SCA, so the
// resulting signature is ERC-1271 - which Gateway now accepts directly.
// The signature itself comes back on the CLIENT from executing the challenge;
// here we only build the challenge.
// ══════════════════════════════════════════════════════════

/**
 * Create an EIP-712 typed-data signing challenge for the user's wallet.
 *
 * `typedData` is the EIP-712 object ({ types, domain, primaryType, message }).
 * Circle wants it as a STRING in the `data` field, so we stringify it here.
 * Returns a challengeId the browser executes to produce the signature.
 */
export async function createTypedDataSignature(params: {
  userToken: string
  walletId:  string
  typedData: unknown
  memo?:     string
}): Promise<{ challengeId: string }> {
  const data = await circleFetch(
    '/v1/w3s/user/sign/typedData', params.userToken, {
      method: 'POST',
      body:   JSON.stringify({
        walletId: params.walletId,
        data:     typeof params.typedData === 'string'
          ? params.typedData : JSON.stringify(params.typedData),
        memo:     params.memo,
      }),
    })
  return { challengeId: String(data.challengeId) }
}
