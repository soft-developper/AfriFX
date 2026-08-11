#!/usr/bin/env bash
# ============================================================================
# Phase 6b - Gateway hooks migrated to the Circle wallet
#            (+ new EIP-712 typed-data signing capability)
#
# WHY
#   useGatewaySend, useGatewayDeposit and useCorridorSwap were the last hooks on
#   wagmi. Gateway is different from CCTP: its core auth step is an OFF-CHAIN
#   EIP-712 signature (a burn intent), not a contract call. Circle Gateway added
#   ERC-1271 support (Aug 2026), so the SCA wallet can sign these directly - no
#   EOA, no delegate. This phase adds that signing primitive and moves all three
#   hooks onto it.
#
# NEW CAPABILITY (reusable, e.g. for future permit/Paymaster flows)
#   * server: createTypedDataSignature + POST /auth/wallet/sign/typed
#     (POST /v1/w3s/user/sign/typedData -> challengeId)
#   * client: executeSigningChallenge (returns the signature from the SDK
#     result) + signTypedData() in useCircleTx
#
# HOOK CHANGES
#   * useGatewaySend  - burn intent signed via signTypedData (ERC-1271); mint via
#     executeContractCall. No network switch. needsEoa path retired (SCAs sign
#     now). Still returns { ok, mintTx } so payroll can await each transfer.
#   * useGatewayDeposit - approve + deposit via executeContractCall. The
#     "never a plain transfer to the wallet" guard is kept.
#   * useCorridorSwap - both legs are USDC transfers via executeContractCall;
#     Memo dropped (needs an EOA; verified). Two-leg discipline kept: leg 2 only
#     after leg 1 confirms on-chain.
#   * send page + GatewayDepositForm - drop the obsolete 'switching' step and
#     the needsEoa message.
#
# CHANGES (9 files)
#
# REQUIRES: Phases 5b + 6a.
#
# NOTE (verify in test): Gateway spends a DEPOSITED balance. If older deposits
#   were made from the previous EOA wallet, the SCA's Gateway balance may be
#   empty - deposit from the Circle wallet first (useGatewayDeposit) before a
#   Gateway send will have anything to spend.
#
# USAGE
#   bash phase6b-gateway-circle-signing.sh
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"; WEB="$ROOT/afrifx-web"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }
grep -q "executeContractCall" "$WEB/hooks/useCircleTx.ts" || die "Phase 5b not detected."
grep -q "executeContractCall" "$WEB/hooks/useP2P.ts" 2>/dev/null || die "Phase 6a not detected."
BK="$ROOT/.phase6b-backup"; rm -rf "$BK"; mkdir -p "$BK"
mkdir -p "$BK/$(dirname "afrifx-api/src/services/circleWallets.ts")"; cp "$ROOT/afrifx-api/src/services/circleWallets.ts" "$BK/afrifx-api/src/services/circleWallets.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-api/src/routes/auth.ts")"; cp "$ROOT/afrifx-api/src/routes/auth.ts" "$BK/afrifx-api/src/routes/auth.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/lib/circle.ts")"; cp "$ROOT/afrifx-web/lib/circle.ts" "$BK/afrifx-web/lib/circle.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/hooks/useCircleTx.ts")"; cp "$ROOT/afrifx-web/hooks/useCircleTx.ts" "$BK/afrifx-web/hooks/useCircleTx.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/hooks/useGatewaySend.ts")"; cp "$ROOT/afrifx-web/hooks/useGatewaySend.ts" "$BK/afrifx-web/hooks/useGatewaySend.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/hooks/useGatewayDeposit.ts")"; cp "$ROOT/afrifx-web/hooks/useGatewayDeposit.ts" "$BK/afrifx-web/hooks/useGatewayDeposit.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/hooks/useCorridorSwap.ts")"; cp "$ROOT/afrifx-web/hooks/useCorridorSwap.ts" "$BK/afrifx-web/hooks/useCorridorSwap.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/app/(app)/send/page.tsx")"; cp "$ROOT/afrifx-web/app/(app)/send/page.tsx" "$BK/afrifx-web/app/(app)/send/page.tsx" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/components/treasury/GatewayDepositForm.tsx")"; cp "$ROOT/afrifx-web/components/treasury/GatewayDepositForm.tsx" "$BK/afrifx-web/components/treasury/GatewayDepositForm.tsx" 2>/dev/null || true
ok "snapshot saved"
say "Writing files"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/services/circleWallets.ts")"
cat > "$ROOT/afrifx-api/src/services/circleWallets.ts" <<'AFX_6B_EOF'
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
AFX_6B_EOF
ok "wrote afrifx-api/src/services/circleWallets.ts"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/routes/auth.ts")"
cat > "$ROOT/afrifx-api/src/routes/auth.ts" <<'AFX_6B_EOF'
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
  createTypedDataSignature,
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
// The :id is constrained to a UUID so this wildcard can NEVER shadow the
// named routes below it (find, find-contract). Without the constraint,
// Express matches /wallet/tx/find-contract here with id="find-contract" and
// Circle rejects it with "Fail to parse id as UUID in url".
router.get(
  '/wallet/tx/:id([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
  requireAccount, async (req, res) => {
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

// POST /auth/wallet/sign/typed
//   { userToken, chainKey, typedData, memo? }
//
// Create an EIP-712 typed-data signing challenge (for Gateway burn intents).
// The signature is an off-chain ERC-1271 signature the browser retrieves by
// executing the returned challenge. chainKey picks the wallet on the SOURCE
// chain whose signature Gateway will verify.
router.post('/wallet/sign/typed', requireAccount, async (req, res) => {
  const { userToken, chainKey, typedData, memo } = req.body ?? {}

  if (!userToken)  return res.status(400).json({ error: 'userToken is required' })
  if (!chainKey)   return res.status(400).json({ error: 'chainKey is required' })
  if (!typedData)  return res.status(400).json({ error: 'typedData is required' })

  const blockchain = cctpBlockchainFor(String(chainKey))
  if (!blockchain) return res.status(400).json({ error: `Unsupported chain: ${chainKey}` })

  try {
    const walletId = await getWalletIdForChain(String(userToken), blockchain)
    const { challengeId } = await createTypedDataSignature({
      userToken: String(userToken),
      walletId,
      typedData,
      memo: memo ? String(memo) : undefined,
    })
    res.json({ challengeId })
  } catch (err: any) {
    const e = err as CircleAuthError
    const body: any = { error: e.message }
    if ((err as any).code === 'NEEDS_CHAIN') body.code = 'NEEDS_CHAIN'
    res.status(e.status ?? 502).json(body)
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
AFX_6B_EOF
ok "wrote afrifx-api/src/routes/auth.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/lib/circle.ts")"
cat > "$ROOT/afrifx-web/lib/circle.ts" <<'AFX_6B_EOF'
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

/**
 * Where Google sends the browser back to.
 *
 * This must be the sign-in page, NOT the site root. The root is the
 * landing page, and the SDK callback that finishes the handshake only
 * exists on /signin - returning to '/' silently drops the login and
 * leaves the user looking at the marketing page.
 *
 * Whatever this returns must also be listed in Google Cloud Console
 * under Authorized redirect URIs, exactly.
 */
export function signInUrl(): string {
  if (typeof window === 'undefined') return ''
  return `${window.location.origin}/signin`
}

export type AuthIntent = 'signin' | 'signup'

export interface CircleLoginResult {
  userToken:     string
  encryptionKey: string
  /**
   * Email from the social provider, when it gives us one.
   *
   * Google returns this in oAuthInfo.socialUserInfo. Without it a
   * Google sign-in creates an account with no address, so welcome mail,
   * invoice reminders and trade alerts have nowhere to go.
   */
  email?:        string
  /** Display name from the provider, used to prefill the profile form. */
  name?:         string
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
          redirectUri:         typeof window !== 'undefined' ? signInUrl() : '',
          selectAccountPrompt: true,
        },
      },
    },
    (err: unknown, result: any) => {
      if (!onLogin) return
      if (err || !result?.userToken) return onLogin(err ?? new Error('Sign-in failed'), null)
      const social = result?.oAuthInfo?.socialUserInfo
      onLogin(null, {
        userToken:     result.userToken,
        encryptionKey: result.encryptionKey,
        email:         social?.email,
        name:          social?.name,
      })
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
        redirectUri:         signInUrl(),
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

/**
 * Like executeChallenge, but returns the SIGNATURE the challenge produced.
 *
 * SIGN_TYPEDDATA / SIGN_MESSAGE challenges yield a signature in the execute
 * result (result.data.signature). executeChallenge throws that away because
 * transfers/contract calls don't need it; Gateway burn intents do, so this
 * variant surfaces it. Same PIN/confirm UX, different return.
 */
export async function executeSigningChallenge(
  challengeId: string, userToken: string, encryptionKey: string,
): Promise<string> {
  const instance = await getSdk()
  instance.setAuthentication({ userToken, encryptionKey })

  return new Promise<string>((resolve, reject) => {
    instance.execute(challengeId, (err: any, result: any) => {
      if (err) { reject(new Error(err?.message ?? 'You cancelled the request')); return }
      const sig = result?.data?.signature ?? result?.signature
      if (!sig) { reject(new Error('No signature was returned by the wallet.')); return }
      resolve(String(sig))
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
AFX_6B_EOF
ok "wrote afrifx-web/lib/circle.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/hooks/useCircleTx.ts")"
cat > "$ROOT/afrifx-web/hooks/useCircleTx.ts" <<'AFX_6B_EOF'
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

import { executeChallenge, executeSigningChallenge } from '@/lib/circle'
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

/**
 * Sign EIP-712 typed data with the user's Circle wallet, returning the
 * signature (an ERC-1271 signature, since the wallet is an SCA).
 *
 * This is the Gateway building block: sign a burn intent off-chain, then
 * POST it to Circle's Gateway API for an attestation. Unlike a transfer or
 * contract call, there is no transaction - the value is the signature itself.
 *
 * Throws NeedsReauthError when there's no live token, NeedsChainError when the
 * wallet isn't on the requested source chain.
 */
export async function signTypedData(
  params: { chainKey: string; typedData: unknown; memo?: string },
  onStep?: (message: string) => void,
): Promise<string> {
  const session = getSigningSession()
  if (!session) throw new NeedsReauthError()

  onStep?.('Preparing the signature')

  const res = await apiFetch('/auth/wallet/sign/typed', {
    method: 'POST',
    body:   JSON.stringify({
      userToken: session.userToken,
      chainKey:  params.chainKey,
      typedData: params.typedData,
      memo:      params.memo,
    }),
  })
  const data = await res.json().catch(() => ({}))

  if (res.status === 401) { clearSigningSession(); throw new NeedsReauthError() }
  if (data?.code === 'NEEDS_CHAIN') throw new NeedsChainError(data.error)
  if (!res.ok) throw new Error(data.error ?? 'Could not prepare the signature')

  onStep?.('Approve the signature on your device')
  const signature = await executeSigningChallenge(
    data.challengeId, session.userToken, session.encryptionKey)

  return signature
}
AFX_6B_EOF
ok "wrote afrifx-web/hooks/useCircleTx.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/hooks/useGatewaySend.ts")"
cat > "$ROOT/afrifx-web/hooks/useGatewaySend.ts" <<'AFX_6B_EOF'
'use client'
// ============================================================
// useGatewaySend - spend the unified Gateway balance, signed by the user's
// CIRCLE wallet.
//
// THE FLOW (per Circle's technical guide):
//   1. Build a TransferSpec + BurnIntent describing the transfer
//   2. Sign it as EIP-712 typed data  <-- now via the Circle wallet (ERC-1271)
//   3. POST to /v1/transfer -> Circle returns an attestation + signature
//   4. gatewayMint() on the destination chain <-- now via executeContractCall
//
// CIRCLE MIGRATION
//   Gateway added ERC-1271 support (Aug 2026), so an SCA can authorize
//   transfers directly - no EOA, no delegate. Step 2 uses signTypedData (a
//   SIGN_TYPEDDATA challenge) and step 4 uses executeContractCall. There is no
//   network switch: Circle runs the mint on the chain we name.
//
// *** CONSTRAINTS THAT STILL SHAPE THIS CODE ***
//   * ATTESTATIONS EXPIRE AFTER 10 MINUTES, so the mint must follow promptly.
//   * maxBlockHeight must exceed the wallet's withdrawalDelay; we read the head
//     and add a buffer, then let Circle's own error correct us if short.
//   * Arc->Arc doesn't use Gateway (a plain wallet transfer is instant); that
//     routing lives in the caller (useSmartSend), not here.
// ============================================================

import { useState, useCallback } from 'react'
import { useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  signTypedData, executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import { gatewayApi, gatewayContracts, gatewayChains, usdcToUnits } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

export type SendStep =
  | 'idle' | 'signing' | 'requesting' | 'minting' | 'done' | 'error'

export interface GatewaySendState {
  step:    SendStep
  mintTx:  string | null
  error:   string | null
  /** Retained for API compatibility; always false now that SCAs can sign. */
  needsEoa: boolean
  /** Human step note while the user approves on their device. */
  note:    string | null
}

const INITIAL: GatewaySendState = {
  step: 'idle', mintTx: null, error: null, needsEoa: false, note: null,
}

// EIP-712 types, mirroring Circle's TransferSpec / BurnIntent structs.
const EIP712_TYPES = {
  TransferSpec: [
    { name: 'version',              type: 'uint32'  },
    { name: 'sourceDomain',         type: 'uint32'  },
    { name: 'destinationDomain',    type: 'uint32'  },
    { name: 'sourceContract',       type: 'bytes32' },
    { name: 'destinationContract',  type: 'bytes32' },
    { name: 'sourceToken',          type: 'bytes32' },
    { name: 'destinationToken',     type: 'bytes32' },
    { name: 'sourceDepositor',      type: 'bytes32' },
    { name: 'destinationRecipient', type: 'bytes32' },
    { name: 'sourceSigner',         type: 'bytes32' },
    { name: 'destinationCaller',    type: 'bytes32' },
    { name: 'value',                type: 'uint256' },
    { name: 'salt',                 type: 'bytes32' },
    { name: 'hookData',             type: 'bytes'   },
  ],
  BurnIntent: [
    { name: 'maxBlockHeight', type: 'uint256' },
    { name: 'maxFee',         type: 'uint256' },
    { name: 'spec',           type: 'TransferSpec' },
  ],
} as const

const ZERO32 = `0x${'0'.repeat(64)}` as const

function toBytes32(addr: string): `0x${string}` {
  return `0x${'0'.repeat(24)}${addr.toLowerCase().replace(/^0x/, '')}` as `0x${string}`
}

function randomSalt(): `0x${string}` {
  const b = new Uint8Array(32)
  crypto.getRandomValues(b)
  return `0x${Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('')}` as `0x${string}`
}

export function useGatewaySend() {
  const { address } = useAccount()
  const config = useConfig()
  const [state, setState] = useState<GatewaySendState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const send = useCallback(async (params: {
    fromKey: string       // which chain's Gateway balance to spend
    toKey:   string       // destination chain
    amount:  number
    recipient: string
  }) => {
    if (!address) {
      setState({ ...INITIAL, step: 'error', error: 'Sign in first' })
      return { ok: false as const, error: 'Sign in first', needsEoa: false }
    }

    const src = gatewayChains().find(c => c.key === params.fromKey)
    const dst = gatewayChains().find(c => c.key === params.toKey)
    const srcCctp = chainByKey(params.fromKey)
    const dstCctp = chainByKey(params.toKey)
    const dstChainId = evmChainId(params.toKey)

    if (!src || !dst || !srcCctp || !dstCctp || !dstChainId) {
      setState({ ...INITIAL, step: 'error', error: 'Unsupported route' })
      return { ok: false as const, error: 'Unsupported route', needsEoa: false }
    }

    const contracts = gatewayContracts()
    const value = usdcToUnits(params.amount)
    const note = (m: string) => setState(s => ({ ...s, note: m }))

    try {
      setState({ ...INITIAL, step: 'signing' })

      // maxBlockHeight must clear the wallet's withdrawalDelay, measured in
      // source-chain blocks. Read the head and add a generous buffer; if it's
      // short, Circle's error states the exact minimum and we retry with it.
      const srcChainId = evmChainId(params.fromKey)
      const srcClient  = srcChainId ? getPublicClient(config, { chainId: srcChainId }) : null
      const head = srcClient ? await srcClient.getBlockNumber() : BigInt(0)
      let maxBlockHeight = head + BigInt(2_000_000)

      const spec = {
        version: 1,
        sourceDomain:         src.domain,
        destinationDomain:    dst.domain,
        sourceContract:       toBytes32(contracts.wallet),
        destinationContract:  toBytes32(contracts.minter),
        sourceToken:          toBytes32(srcCctp.usdc),
        destinationToken:     toBytes32(dstCctp.usdc),
        sourceDepositor:      toBytes32(address),
        destinationRecipient: toBytes32(params.recipient),
        sourceSigner:         toBytes32(address),
        // 0 = any caller may use the attestation, so the mint isn't locked to
        // one sender. We're not composing this with other on-chain actions.
        destinationCaller:    ZERO32,
        value,
        salt: randomSalt(),
        hookData: '0x' as `0x${string}`,
      }

      // Build + sign + request, self-correcting maxBlockHeight once. The
      // signature covers maxBlockHeight, so a correction means RE-SIGN, not
      // just resend - hence sign and request live together.
      const signAndRequest = async (mbh: bigint) => {
        const intent = {
          maxBlockHeight: mbh,
          // A generous ceiling avoids rejection; the fee actually charged is
          // far lower. maxFee is what the USER authorises, so it stays
          // proportional to the amount.
          maxFee: usdcToUnits(Math.max(0.01, params.amount * 0.001)),
          spec,
        }

        // Circle wants the EIP-712 message with all bigints as strings.
        const typedData = {
          types: {
            EIP712Domain: [
              { name: 'name',    type: 'string' },
              { name: 'version', type: 'string' },
            ],
            ...EIP712_TYPES,
          },
          domain: { name: 'GatewayWallet', version: '1' },
          primaryType: 'BurnIntent',
          message: {
            maxBlockHeight: mbh.toString(),
            maxFee:         intent.maxFee.toString(),
            spec: { ...spec, value: value.toString() },
          },
        }

        let signature: string
        try {
          signature = await signTypedData(
            { chainKey: params.fromKey, typedData, memo: 'Gateway transfer' }, note)
        } catch (sigErr: any) {
          // With ERC-1271 an SCA can sign, so the old "needs EOA" path is gone.
          // Re-throw reauth/chain signals so the UI can handle them precisely.
          throw sigErr
        }

        setState(s => ({ ...s, step: 'requesting', note: null }))
        const res = await fetch(`${gatewayApi()}/transfer`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify([{
            burnIntent: {
              maxBlockHeight: mbh.toString(),
              maxFee: intent.maxFee.toString(),
              spec: { ...spec, value: value.toString() },
            },
            signature,
          }]),
        })

        const text = await res.text().catch(() => '')
        if (!res.ok) {
          const err: any = new Error(
            `Gateway transfer rejected (${res.status})${text ? `: ${text.slice(0, 200)}` : ''}`)
          const m = text.match(/expected at least (\d+)/i)
          if (m) err.__requiredHeight = BigInt(m[1])
          throw err
        }
        return JSON.parse(text || '{}')
      }

      let data: any
      try {
        data = await signAndRequest(maxBlockHeight)
      } catch (firstErr: any) {
        if (!firstErr?.__requiredHeight) throw firstErr
        maxBlockHeight = firstErr.__requiredHeight + BigInt(500_000)
        setState(s => ({ ...s, step: 'signing' }))
        data = await signAndRequest(maxBlockHeight)
      }

      const attestation = data?.attestation ?? data?.attestations?.[0]?.attestation
      const attSig      = data?.signature   ?? data?.attestations?.[0]?.signature
      if (!attestation || !attSig) {
        throw new Error('Gateway did not return an attestation. Please try again.')
      }

      // Mint on the destination chain via a Circle contract-execution challenge.
      setState(s => ({ ...s, step: 'minting' }))
      const mintResult = await executeContractCall({
        chainKey:             params.toKey,
        contractAddress:      contracts.minter,
        abiFunctionSignature: 'gatewayMint(bytes,bytes)',
        abiParameters:        [attestation, attSig],
      }, note)

      const mintTx = mintResult.txHash ?? 'pending'
      setState(s => ({ ...s, step: 'done', mintTx, note: null }))
      // Also RETURN the result. The Send page reads state; a caller running
      // many transfers in a loop (payroll) awaits this outcome instead, since
      // async state between iterations isn't reliable.
      return { ok: true as const, mintTx }
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Transfer failed'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) {
        message = err.message
      } else if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was transferred, please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message, needsEoa: false, note: null }))
      return { ok: false as const, error: message, needsEoa: false }
    }
  }, [address, config])

  return { ...state, send, reset }
}
AFX_6B_EOF
ok "wrote afrifx-web/hooks/useGatewaySend.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/hooks/useGatewayDeposit.ts")"
cat > "$ROOT/afrifx-web/hooks/useGatewayDeposit.ts" <<'AFX_6B_EOF'
'use client'
// ============================================================
// useGatewayDeposit - deposit USDC into Circle's Gateway Wallet, signed by the
// user's CIRCLE wallet.
//
// Two on-chain steps, exactly as Circle documents:
//   1. approve(GatewayWallet, amount)  on the USDC token
//   2. deposit(usdcAddress, amount)    on the GatewayWallet
//
// CIRCLE MIGRATION: both are contractExecution challenges the user approves on
// their device (executeContractCall). No network switch - Circle runs each
// call on the chain we name.
//
// *** WHY THERE IS A GUARD ***
// Circle: "Directly transferring USDC to the Gateway Wallet contract with a
// standard ERC-20 transfer will result in loss of that USDC." There is NO
// recovery, so assertNotPlainTransfer() makes it structurally impossible for
// this code to do it.
//
// AFTER DEPOSITING: funds are NOT instantly spendable. They must reach block
// finality first - ~0.5s on Arc, but ~13-19 MINUTES on Base or Ethereum. The
// UI must say so rather than leaving the user wondering.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import {
  gatewayContracts, gatewayChains, usdcToUnits, assertNotPlainTransfer,
} from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

export type DepositStep =
  | 'idle' | 'approving' | 'depositing' | 'done' | 'error'

export interface DepositState {
  step:      DepositStep
  approveTx: string | null
  depositTx: string | null
  error:     string | null
  /** How long deposits take to become spendable on the chosen chain. */
  finality:  string | null
  /** Human step note while the user approves on their device. */
  note:      string | null
}

const INITIAL: DepositState = {
  step: 'idle', approveTx: null, depositTx: null, error: null, finality: null, note: null,
}

export function useGatewayDeposit() {
  const { address } = useAccount()
  const [state, setState] = useState<DepositState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const deposit = useCallback(async (params: { chainKey: string; amount: number }) => {
    if (!address) {
      setState({ ...INITIAL, step: 'error', error: 'Sign in first' })
      return
    }

    const chain    = chainByKey(params.chainKey)
    const gwChain  = gatewayChains().find(c => c.key === params.chainKey)
    const chainId  = evmChainId(params.chainKey)
    const wallet   = gatewayContracts().wallet as `0x${string}`

    if (!chain || !gwChain || !chainId) {
      setState({ ...INITIAL, step: 'error', error: 'Unsupported chain for Gateway' })
      return
    }
    if (!chain.usdc) {
      setState({ ...INITIAL, step: 'error', error: `No USDC address configured for ${chain.name}` })
      return
    }
    if (!(params.amount > 0)) {
      setState({ ...INITIAL, step: 'error', error: 'Enter an amount greater than zero' })
      return
    }

    const units = usdcToUnits(params.amount)
    const note = (m: string) => setState(s => ({ ...s, note: m }))

    try {
      // ── 1. Approve the Gateway Wallet to pull USDC ─────
      setState({ ...INITIAL, step: 'approving', finality: gwChain.finality })
      await executeContractCall({
        chainKey:             params.chainKey,
        contractAddress:      chain.usdc,
        abiFunctionSignature: 'approve(address,uint256)',
        abiParameters:        [wallet, units.toString()],
      }, note)

      // ── 2. Deposit ─────────────────────────────────────
      // Guard: this must be deposit() on the wallet contract, never a plain
      // ERC-20 transfer to it (which would destroy the funds).
      assertNotPlainTransfer('deposit', wallet)

      setState(s => ({ ...s, step: 'depositing' }))
      const depositResult = await executeContractCall({
        chainKey:             params.chainKey,
        contractAddress:      wallet,
        abiFunctionSignature: 'deposit(address,uint256)',
        abiParameters:        [chain.usdc, units.toString()],
      }, note)

      if (!depositResult.txHash) {
        throw new Error(
          'The deposit was approved but is taking longer than usual to confirm. ' +
          'Check your balance shortly - if it landed, it went through.')
      }

      setState(s => ({ ...s, step: 'done', depositTx: depositResult.txHash!, note: null }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Deposit failed'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) {
        message = err.message
      } else if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was submitted, please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message, note: null }))
    }
  }, [address])

  return { ...state, deposit, reset }
}
AFX_6B_EOF
ok "wrote afrifx-web/hooks/useGatewayDeposit.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/hooks/useCorridorSwap.ts")"
cat > "$ROOT/afrifx-web/hooks/useCorridorSwap.ts" <<'AFX_6B_EOF'
'use client'
// ============================================================
// useCorridorSwap - two-leg corridor (from -> USDC -> to), signed by the
// user's CIRCLE wallet.
//
// CIRCLE MIGRATION. Each leg is a USDC transfer to the vault via a
// contractExecution challenge (executeContractCall). Memo is DROPPED - it needs
// an EOA and the Circle wallet is a smart contract (verified on-chain), so we
// transfer directly; the corridor/step/ref metadata is still recorded to the
// API in recordTx below, so nothing is lost operationally.
//
// TWO-LEG DISCIPLINE (unchanged): leg 2 is only sent after leg 1 is confirmed
// on-chain. A reverted leg 1 stops the corridor; a reverted leg 2 is reported
// with leg 1 already settled.
// ============================================================

import { useState } from 'react'
import { usePublicClient } from 'wagmi'
import { isAddress, parseUnits } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { buildMemoId, buildReference } from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import type { CorridorQuote } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export type CorridorStep =
  | 'idle'
  | 'step1-pending' | 'step1-waiting' | 'step1-done'
  | 'step2-pending' | 'step2-waiting'
  | 'complete' | 'error'

export function useCorridorSwap() {
  const { address }  = useAccount()
  const publicClient = usePublicClient({ chainId: arcTestnet.id })

  const [step,       setStep]       = useState<CorridorStep>('idle')
  const [error,      setError]      = useState<string | null>(null)
  const [step1Hash,  setStep1Hash]  = useState<`0x${string}` | null>(null)
  const [step2Hash,  setStep2Hash]  = useState<`0x${string}` | null>(null)
  const [corridorId, setCorridorId] = useState<string | null>(null)
  const [note,       setNote]       = useState<string | null>(null)

  // A USDC transfer to the vault via a Circle contract-execution challenge.
  async function transferToVault(
    toAddress: `0x${string}`, usdcAmount: number,
  ): Promise<`0x${string}`> {
    const result = await executeContractCall({
      chainKey:             'arc',
      contractAddress:      CONTRACTS.USDC,
      abiFunctionSignature: 'transfer(address,uint256)',
      abiParameters:        [toAddress, parseUnits(usdcAmount.toFixed(6), USDC_DECIMALS).toString()],
    }, setNote)
    if (!result.txHash) throw new Error('The transfer did not confirm in time. Please check and retry.')
    return result.txHash as `0x${string}`
  }

  async function recordTx(body: any) {
    await fetch(`${API_BASE}/transactions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).catch(console.error)
  }

  async function patchTxStatus(hash: string, status: 'settled' | 'failed') {
    await fetch(`${API_BASE}/transactions/${hash}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status }),
    }).catch(console.error)
  }

  // Wait for the on-chain receipt and return whether it actually succeeded.
  // A tx hash existing only means it was broadcast - it can still revert.
  async function confirmedOnChain(hash: `0x${string}`): Promise<boolean> {
    if (!publicClient) return false
    try {
      const receipt = await publicClient.waitForTransactionReceipt({ hash })
      return receipt.status === 'success'
    } catch {
      return false
    }
  }

  async function execute(quote: CorridorQuote) {
    if (!address) throw new Error('Sign in first')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault not configured')
    }

    setError(null)
    setCorridorId(quote.corridorId)

    try {
      // ── STEP 1: from → USDC ───────────────────────────────
      setStep('step1-pending')
      const ref1    = buildReference()
      const memo1Id = buildMemoId(`corridor-${quote.corridorId}-step1`)
      const usdcIn1 = quote.step1.toAmount + quote.step1.spreadFee + quote.step1.networkFee

      const hash1 = await transferToVault(vault as `0x${string}`, usdcIn1)

      setStep1Hash(hash1)
      setStep('step1-waiting')

      await recordTx({
        ...quote.step1, walletAddress: address,
        arcTxHash: hash1, memoId: memo1Id, reference: ref1,
        corridorId: quote.corridorId, corridorStep: 1,
      })

      // Only proceed if step 1 actually settled on-chain.
      const step1Ok = await confirmedOnChain(hash1)
      await patchTxStatus(hash1, step1Ok ? 'settled' : 'failed')
      if (!step1Ok) {
        setError('Step 1 reverted on-chain, the corridor was not completed. No further transaction was sent.')
        setStep('error')
        return
      }
      setStep('step1-done')

      // ── STEP 2: USDC → to ─────────────────────────────────
      setStep('step2-pending')
      const ref2    = buildReference()
      const memo2Id = buildMemoId(`corridor-${quote.corridorId}-step2`)
      const usdcIn2 = quote.step2.fromAmount

      const hash2 = await transferToVault(vault as `0x${string}`, usdcIn2)

      setStep2Hash(hash2)
      setStep('step2-waiting')

      await recordTx({
        ...quote.step2, walletAddress: address,
        arcTxHash: hash2, memoId: memo2Id, reference: ref2,
        corridorId: quote.corridorId, corridorStep: 2,
      })

      const step2Ok = await confirmedOnChain(hash2)
      await patchTxStatus(hash2, step2Ok ? 'settled' : 'failed')
      if (!step2Ok) {
        setError('Step 2 reverted on-chain. Step 1 settled, but the second leg did not complete.')
        setStep('error')
        return
      }
      setStep('complete'); setNote(null)
    } catch (err: any) {
      let msg = err?.shortMessage ?? err?.message ?? 'Failed'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) msg = err.message
      setError(msg)
      setStep('error'); setNote(null)
      throw err
    }
  }

  function reset() {
    setStep('idle'); setError(null)
    setStep1Hash(null); setStep2Hash(null); setCorridorId(null); setNote(null)
  }

  return {
    execute, reset, step, error, note,
    step1Hash, step2Hash, corridorId,
    isLoading:  ['step1-pending','step1-waiting','step1-done','step2-pending','step2-waiting'].includes(step),
    isComplete: step === 'complete',
  }
}
AFX_6B_EOF
ok "wrote afrifx-web/hooks/useCorridorSwap.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/app/(app)/send/page.tsx")"
cat > "$ROOT/afrifx-web/app/(app)/send/page.tsx" <<'AFX_6B_EOF'
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

  const busy = sending || ['signing','requesting','minting'].includes(gw.step)

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
AFX_6B_EOF
ok "wrote afrifx-web/app/(app)/send/page.tsx"
mkdir -p "$ROOT/$(dirname "afrifx-web/components/treasury/GatewayDepositForm.tsx")"
cat > "$ROOT/afrifx-web/components/treasury/GatewayDepositForm.tsx" <<'AFX_6B_EOF'
'use client'
import { useState } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { Loader2, CheckCircle, AlertTriangle, Clock, ExternalLink } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useGatewayDeposit } from '@/hooks/useGatewayDeposit'
import { useChainUsdcBalance } from '@/hooks/useChainUsdcBalance'
import { gatewayChains } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'

/*
  Deposit USDC into Gateway.

  The honest bit this UI has to get right: a deposit is NOT instantly spendable.
  It has to reach block finality first, about half a second on Arc, but 13-19
  MINUTES on Base or Ethereum. Hiding that would leave users thinking the
  feature is broken, so the wait is stated up front, per chain, before they
  commit.
*/
export function GatewayDepositForm({ onDone }: { onDone?: () => void }) {
  const { isConnected } = useAccount()
  const { step, approveTx, depositTx, error, finality, deposit, reset } = useGatewayDeposit()

  const chains = gatewayChains()
  const [chainKey, setChainKey] = useState('arc')
  const [amount, setAmount]     = useState('')

  const chain   = chains.find(c => c.key === chainKey)
  const cctp    = chainByKey(chainKey)
  const amt     = Number(amount)
  const busy    = ['approving', 'depositing'].includes(step)

  /*
    Balance on the chain being deposited FROM.

    Without this the deposit could fail at the deposit() step AFTER the user had
    already paid gas on approve(), which is the worst kind of failure: costly
    and confusing. Checking up front turns it into a disabled button.
  */
  const { balance, loading: balLoading } = useChainUsdcBalance(chainKey)
  const insufficient = amt > 0 && amt > balance

  const canGo   = isConnected && amt > 0 && !busy && !insufficient

  const stepLabel: Record<string, string> = {
    switching:  `Switch your wallet to ${chain?.name ?? 'the chain'}`,
    approving:  'Approve USDC in your wallet (step 1 of 2)',
    depositing: 'Confirm the deposit in your wallet (step 2 of 2)',
  }

  if (step === 'done') {
    return (
      <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4">
        <p className="flex items-center gap-1.5 text-sm font-medium text-emerald-400">
          <CheckCircle className="h-4 w-4" /> Deposit submitted
        </p>
        <p className="mt-1 text-xs text-emerald-800 dark:text-emerald-200/80">
          {amount} USDC deposited from {chain?.name}.
        </p>
        {/* The wait is the thing people misunderstand, so say it plainly. */}
        <p className="mt-2 flex items-start gap-1.5 text-[11px] leading-relaxed text-amber-800 dark:text-amber-200/80">
          <Clock className="mt-0.5 h-3 w-3 shrink-0" />
          It becomes spendable once the deposit reaches finality on {chain?.name}
          about {finality}. Your balance above updates automatically.
        </p>
        {depositTx && cctp && (
          <a href={`${cctp.explorer}/tx/${depositTx}`} target="_blank" rel="noopener noreferrer"
            className="mt-2 inline-flex items-center gap-1 text-[11px] text-emerald-400 hover:underline">
            View transaction <ExternalLink className="h-2.5 w-2.5" />
          </a>
        )}
        <div className="mt-3">
          <Button size="sm" variant="outline" onClick={() => { reset(); onDone?.() }}>
            Done
          </Button>
        </div>
      </div>
    )
  }

  return (
    <div className="rounded-lg border border-app-border bg-app-bg p-4">
      <p className="mb-3 text-xs font-semibold text-app-text">Add funds to your unified balance</p>

      <label className="mb-1 block text-[11px] text-app-muted">Deposit from</label>
      <select
        value={chainKey}
        onChange={e => setChainKey(e.target.value)}
        disabled={busy}
        className="mb-1 w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => (
          <option key={c.key} value={c.key}>
            {c.name}, clears in {c.finality}
          </option>
        ))}
      </select>
      {/* Surface the trade-off at the moment of choosing, not after. */}
      <p className="mb-3 text-[10px] text-app-muted">
        {chainKey === 'arc'
          ? 'Arc finalises in about half a second, so deposits are spendable almost immediately.'
          : `Deposits from ${chain?.name} take ${chain?.finality} to become spendable.`}
      </p>

      <div className="mb-1 flex items-center justify-between">
        <label className="text-[11px] text-app-muted">Amount (USDC)</label>
        <span className="flex items-center gap-2 text-[11px]">
          <span className="text-app-muted">
            Balance:{' '}
            <span className="font-mono text-app-text">
              {balLoading ? '...' : balance.toFixed(2)}
            </span>
          </span>
          <button
            onClick={() => setAmount(String(balance))}
            disabled={busy || balance <= 0}
            className="text-app-accent-text hover:underline disabled:opacity-40"
          >
            Max
          </button>
        </span>
      </div>
      <input
        type="number" inputMode="decimal" min="0" step="0.000001"
        value={amount}
        onChange={e => setAmount(e.target.value)}
        disabled={busy}
        placeholder="0.00"
        className="mb-3 w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 font-mono text-sm text-app-text outline-none placeholder:text-app-border disabled:opacity-50"
      />

      {insufficient && (
        <p className="mb-3 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-[11px] text-red-800 dark:text-red-300">
          <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
          You only have {balance.toFixed(2)} USDC on {chain?.name}
        </p>
      )}

      <Button className="w-full" disabled={!canGo}
        onClick={() => deposit({ chainKey, amount: amt })}>
        {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Working…</>
              : !isConnected ? 'Sign in to deposit'
              : insufficient ? 'Insufficient balance'
              : 'Deposit'}
      </Button>

      {busy && (
        <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
          <Loader2 className="h-3 w-3 animate-spin" />
          {stepLabel[step] ?? 'Working…'}
        </p>
      )}

      {step === 'error' && error && (
        <div className="mt-2 rounded-lg border border-red-900/50 bg-red-900/20 p-2.5">
          <p className="flex items-center gap-1.5 text-[11px] font-medium text-red-400">
            <AlertTriangle className="h-3 w-3" /> Deposit not completed
          </p>
          <p className="mt-1 text-[11px] text-red-800 dark:text-red-300/90">{error}</p>
          {approveTx && (
            <p className="mt-1 text-[10px] text-red-700 dark:text-red-300/60">
              Your approval went through but the deposit didn&apos;t, no USDC left your
              wallet. You can safely retry.
            </p>
          )}
          <Button size="sm" variant="outline" className="mt-2" onClick={reset}>Try again</Button>
        </div>
      )}
    </div>
  )
}
AFX_6B_EOF
ok "wrote afrifx-web/components/treasury/GatewayDepositForm.tsx"

say "Verifying"
grep -q "createTypedDataSignature" "$API/src/services/circleWallets.ts" || die "typed-data service missing"
grep -q "/wallet/sign/typed" "$API/src/routes/auth.ts" || die "sign route missing"
grep -q "executeSigningChallenge" "$WEB/lib/circle.ts" || die "signing challenge missing"
grep -q "signTypedData" "$WEB/hooks/useCircleTx.ts" || die "signTypedData helper missing"
for h in useGatewaySend useGatewayDeposit useCorridorSwap; do
  grep -q "from 'wagmi'" "$WEB/hooks/$h.ts" && ! grep -q "usePublicClient\|useConfig" "$WEB/hooks/$h.ts" && die "$h still uses wagmi for signing"
done
ok "typed-data capability present, 3 hooks migrated"

say "API: install + tsc + tests"
( cd "$API" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && npx tsc --noEmit ) || { cp -rf "$BK"/. "$ROOT"/; die "API tsc failed - restored"; }
ok "api typechecks"
( cd "$API" && npx vitest run >/dev/null 2>&1 ) || { cp -rf "$BK"/. "$ROOT"/; die "API tests failed - restored"; }
ok "api tests pass"

say "WEB: install + tsc + build"
( cd "$WEB" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && rm -rf .next && npx tsc --noEmit ) || { cp -rf "$BK"/. "$ROOT"/; die "web tsc failed - restored"; }
ok "web typechecks"
( cd "$WEB" && npm run build >/dev/null 2>&1 ) || { cp -rf "$BK"/. "$ROOT"/; die "web build failed - restored"; }
ok "web builds"
rm -rf "$BK"
say "Phase 6b applied and verified."
cat <<'NOTE'

  Gateway hooks now sign through the Circle wallet (ERC-1271 typed data +
  contractExecution). New reusable primitive: signTypedData / /wallet/sign/typed.

  Commit & push:
    git add -A
    git commit -m "phase 6b: Gateway hooks via Circle typed-data signing + contractExecution"
    git push origin main

  Test after deploy (testnet USDC):
    1. DEPOSIT first: Treasury -> Gateway deposit on a chain (approve + deposit,
       two device prompts). Wait for finality (secs on Arc, minutes on Base/Eth).
    2. GATEWAY SEND: /send cross-chain - one device prompt to SIGN the burn
       intent, then one to MINT on the destination. Confirm arrival.
    3. CORRIDOR: /corridor two-leg swap - two transfers, each one prompt.
    If a Gateway send says "insufficient balance", the SCA has no deposited
    Gateway balance yet - do step 1 from the Circle wallet first.
NOTE
