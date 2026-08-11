#!/usr/bin/env bash
# ============================================================================
# Phase 5b - Bridge migrated to Circle contractExecution (burn + mint)
#
# WHY
#   The CCTP bridge was the last money path still signing through the old
#   browser-wallet library (wagmi). This moves it onto the user's Circle
#   wallet, matching Send (4a) and Convert (4b):
#     * approve() + depositForBurn() on the SOURCE chain, then
#     * receiveMessage() on the DESTINATION chain
#   are each a contractExecution CHALLENGE the user approves on their device.
#   There is no network switch: Circle runs each call on the chain we name,
#   using the wallet that lives there (provisioned at sign-up in Phase 5a).
#   The RECORD-FIRST discipline and the critical /bridge/:id/burned write are
#   preserved exactly; the Circle Iris attestation wait is unchanged.
#
# WHAT IT CHANGES (9 files)
#   afrifx-api/src/services/circleWallets.ts   + contractExecution capability
#   afrifx-api/src/routes/auth.ts              + /wallet/tx/contract + find-contract
#   afrifx-api/tests/circleWallets.test.ts     + cctpBlockchainFor / missingBridgeChains tests
#   afrifx-web/hooks/useCircleTx.ts            + executeContractCall + NeedsChainError
#   afrifx-web/hooks/useBridge.ts              rewritten off wagmi
#   afrifx-web/hooks/useCompleteBridge.ts      rewritten off wagmi
#   afrifx-web/hooks/useChainUsdcBalance.ts    address from Circle, RPC read kept
#   afrifx-web/components/bridge/BridgeCard.tsx      drop network-switch UI
#   afrifx-web/components/bridge/BridgeHistory.tsx   show device-approval note
#
# REQUIRES: Phase 5a already applied (wallet exists on the destination chains).
#           The script checks for the 5a markers and refuses otherwise.
#
# SAFETY
#   Writes each file's full verified content, so re-running is idempotent
#   (result is identical). Verifies the 5a baseline first, snapshots every
#   target for rollback, then typechecks both apps, runs the API tests, and
#   builds web. Any failure aborts with the snapshot left in ./.phase5b-backup.
#
# USAGE
#   bash phase5b-bridge-circle-execution.sh
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
WEB="$ROOT/afrifx-web"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }

# ---- Preconditions ---------------------------------------------------------
for f in \
  "$API/src/services/circleWallets.ts" \
  "$API/src/routes/auth.ts" \
  "$WEB/hooks/useCircleTx.ts" \
  "$WEB/hooks/useBridge.ts" \
  "$WEB/components/bridge/BridgeCard.tsx" ; do
  [ -f "$f" ] || die "Missing $f - run from the repo root."
done

# Phase 5a must be in place (bridge mint needs the destination-chain wallet).
grep -q "CCTP_BRIDGE_CHAINS" "$API/src/services/circleWallets.ts" \
  || die "Phase 5a not detected (no CCTP_BRIDGE_CHAINS). Apply phase 5a first."
grep -q "addUserWalletChains" "$API/src/routes/auth.ts" \
  || die "Phase 5a not detected (no add-chains route). Apply phase 5a first."
ok "Phase 5a baseline present"

# Already applied? (idempotent no-op check)
if grep -q "executeContractCall" "$WEB/hooks/useCircleTx.ts" \
   && grep -q "CONTRACT EXECUTION (bridge burn" "$API/src/services/circleWallets.ts" \
   && ! grep -q "from 'wagmi'" "$WEB/hooks/useBridge.ts" ; then
  say "Phase 5b already applied - rewriting to the exact same content (safe)."
fi

# ---- Snapshot for rollback -------------------------------------------------
BK="$ROOT/.phase5b-backup"
rm -rf "$BK"; mkdir -p "$BK"
mkdir -p "$BK/$(dirname afrifx-api/src/services/circleWallets.ts)"
cp "$ROOT/afrifx-api/src/services/circleWallets.ts" "$BK/afrifx-api/src/services/circleWallets.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname afrifx-api/src/routes/auth.ts)"
cp "$ROOT/afrifx-api/src/routes/auth.ts" "$BK/afrifx-api/src/routes/auth.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname afrifx-api/tests/circleWallets.test.ts)"
cp "$ROOT/afrifx-api/tests/circleWallets.test.ts" "$BK/afrifx-api/tests/circleWallets.test.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname afrifx-web/hooks/useCircleTx.ts)"
cp "$ROOT/afrifx-web/hooks/useCircleTx.ts" "$BK/afrifx-web/hooks/useCircleTx.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname afrifx-web/hooks/useBridge.ts)"
cp "$ROOT/afrifx-web/hooks/useBridge.ts" "$BK/afrifx-web/hooks/useBridge.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname afrifx-web/hooks/useCompleteBridge.ts)"
cp "$ROOT/afrifx-web/hooks/useCompleteBridge.ts" "$BK/afrifx-web/hooks/useCompleteBridge.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname afrifx-web/hooks/useChainUsdcBalance.ts)"
cp "$ROOT/afrifx-web/hooks/useChainUsdcBalance.ts" "$BK/afrifx-web/hooks/useChainUsdcBalance.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname afrifx-web/components/bridge/BridgeCard.tsx)"
cp "$ROOT/afrifx-web/components/bridge/BridgeCard.tsx" "$BK/afrifx-web/components/bridge/BridgeCard.tsx" 2>/dev/null || true
mkdir -p "$BK/$(dirname afrifx-web/components/bridge/BridgeHistory.tsx)"
cp "$ROOT/afrifx-web/components/bridge/BridgeHistory.tsx" "$BK/afrifx-web/components/bridge/BridgeHistory.tsx" 2>/dev/null || true
ok "snapshot saved to .phase5b-backup"

say "Writing files"
mkdir -p "$ROOT/$(dirname afrifx-api/src/services/circleWallets.ts)"
cat > "$ROOT/afrifx-api/src/services/circleWallets.ts" <<'AFX_5B_EOF'
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
  const qs = new URLSearchParams({
    walletIds:  params.walletId,
    blockchain: params.blockchain,
    operation:  'CONTRACT_EXECUTION',
    pageSize:   '20',
  })
  const data = await circleFetch(
    `/v1/w3s/transactions?${qs.toString()}`, params.userToken)

  const list = (data.transactions ?? []) as any[]
  const want = params.contractAddress.toLowerCase()

  const match = list.find(t => {
    if (String(t.contractAddress ?? '').toLowerCase() !== want) return false
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
AFX_5B_EOF
ok "wrote afrifx-api/src/services/circleWallets.ts"

mkdir -p "$ROOT/$(dirname afrifx-api/src/routes/auth.ts)"
cat > "$ROOT/afrifx-api/src/routes/auth.ts" <<'AFX_5B_EOF'
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
AFX_5B_EOF
ok "wrote afrifx-api/src/routes/auth.ts"

mkdir -p "$ROOT/$(dirname afrifx-api/tests/circleWallets.test.ts)"
cat > "$ROOT/afrifx-api/tests/circleWallets.test.ts" <<'AFX_5B_EOF'
/**
 * Choosing which wallet to record on an account.
 *
 * Circle can return wallets on several chains and makes no promise about
 * ordering, so `wallets[0]` is a real bug waiting to happen: it would
 * silently record a Base address as the user's Arc address, and every
 * balance and transfer after that would look at the wrong place.
 */

import { describe, it, expect } from 'vitest'
import { pickPrimaryWallet, cctpBlockchainFor, missingBridgeChains, type CircleWallet } from '../src/services/circleWallets'

const w = (blockchain: string, address = '0x' + blockchain.length.toString().repeat(4), state?: string): CircleWallet =>
  ({ id: `id-${blockchain}`, address, blockchain, state })

describe('pickPrimaryWallet', () => {
  it('returns null when there are no wallets yet', () => {
    // Normal shortly after the challenge: Circle indexes asynchronously.
    expect(pickPrimaryWallet([], 'ARC-TESTNET')).toBeNull()
    expect(pickPrimaryWallet(undefined as any, 'ARC-TESTNET')).toBeNull()
  })

  it('returns the only wallet when there is one', () => {
    const only = w('ARC-TESTNET')
    expect(pickPrimaryWallet([only], 'ARC-TESTNET')).toBe(only)
  })

  // The case that makes wallets[0] wrong.
  it('picks the configured chain even when it is not first', () => {
    const wallets = [w('BASE-SEPOLIA'), w('MATIC-AMOY'), w('ARC-TESTNET')]
    expect(pickPrimaryWallet(wallets, 'ARC-TESTNET')!.blockchain).toBe('ARC-TESTNET')
  })

  it('matches the chain case-insensitively', () => {
    const wallets = [w('arc-testnet')]
    expect(pickPrimaryWallet(wallets, 'ARC-TESTNET')).not.toBeNull()
  })

  it('follows the configured chain, so switching home chains needs no code change', () => {
    const wallets = [w('ARC-TESTNET'), w('BASE-SEPOLIA')]
    expect(pickPrimaryWallet(wallets, 'BASE-SEPOLIA')!.blockchain).toBe('BASE-SEPOLIA')
  })

  // Better to record something usable than to leave the account with no
  // address at all, which would block the user entirely.
  it('falls back to another wallet when the configured chain is absent', () => {
    const wallets = [w('BASE-SEPOLIA')]
    expect(pickPrimaryWallet(wallets, 'ARC-TESTNET')!.blockchain).toBe('BASE-SEPOLIA')
  })

  it('skips wallets with no address', () => {
    const good = w('BASE-SEPOLIA')
    const bad  = { id: 'x', address: '', blockchain: 'ARC-TESTNET' } as CircleWallet
    expect(pickPrimaryWallet([bad, good], 'ARC-TESTNET')).toBe(good)
  })

  it('skips frozen wallets rather than recording an unusable address', () => {
    const frozen = w('ARC-TESTNET', '0xfrozen', 'FROZEN')
    const live   = w('BASE-SEPOLIA', '0xlive')
    expect(pickPrimaryWallet([frozen, live], 'ARC-TESTNET')).toBe(live)
  })

  it('returns null when every wallet is unusable', () => {
    const frozen = w('ARC-TESTNET', '0xfrozen', 'FROZEN')
    expect(pickPrimaryWallet([frozen], 'ARC-TESTNET')).toBeNull()
  })
})

/**
 * Mapping app chain keys to Circle's blockchain enum.
 *
 * The classic CCTP integration bug is confusing Polygon's key "polygon"
 * with Circle's code, which is MATIC-AMOY on testnet — not "POLYGON".
 * These lock the mapping so a rename can't silently break a bridge route.
 */
describe('cctpBlockchainFor', () => {
  it('maps every supported testnet chain key', () => {
    expect(cctpBlockchainFor('arc')).toBe('ARC-TESTNET')
    expect(cctpBlockchainFor('base')).toBe('BASE-SEPOLIA')
    expect(cctpBlockchainFor('ethereum')).toBe('ETH-SEPOLIA')
    expect(cctpBlockchainFor('arbitrum')).toBe('ARB-SEPOLIA')
    expect(cctpBlockchainFor('polygon')).toBe('MATIC-AMOY')
  })
  it('returns null for an unknown key', () => {
    expect(cctpBlockchainFor('solana')).toBeNull()
    expect(cctpBlockchainFor('')).toBeNull()
  })
})

/**
 * Which bridge chains still need adding for a given wallet set.
 * Only the missing ones, case-insensitive, so re-running provisioning
 * never asks Circle to recreate a chain that already exists.
 */
describe('missingBridgeChains', () => {
  it('returns the chains not present, case-insensitively', () => {
    const have = [w('ARC-TESTNET'), w('base-sepolia')]
    expect(missingBridgeChains(have, ['BASE-SEPOLIA', 'ETH-SEPOLIA']))
      .toEqual(['ETH-SEPOLIA'])
  })
  it('returns nothing when all chains already exist', () => {
    const have = [w('BASE-SEPOLIA'), w('ETH-SEPOLIA')]
    expect(missingBridgeChains(have, ['BASE-SEPOLIA', 'ETH-SEPOLIA'])).toEqual([])
  })
  it('returns all wanted chains when the set is empty', () => {
    expect(missingBridgeChains([], ['BASE-SEPOLIA', 'ETH-SEPOLIA']))
      .toEqual(['BASE-SEPOLIA', 'ETH-SEPOLIA'])
  })
})
AFX_5B_EOF
ok "wrote afrifx-api/tests/circleWallets.test.ts"

mkdir -p "$ROOT/$(dirname afrifx-web/hooks/useCircleTx.ts)"
cat > "$ROOT/afrifx-web/hooks/useCircleTx.ts" <<'AFX_5B_EOF'
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

export async function executeContractCall(
  params: ContractCallParams,
  onStep?: (message: string) => void,
): Promise<TransferResult> {
  const session = getSigningSession()
  if (!session) throw new NeedsReauthError()

  const startedAt = Date.now()

  onStep?.('Preparing the transaction')

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
  const data = await res.json().catch(() => ({}))

  if (res.status === 401) { clearSigningSession(); throw new NeedsReauthError() }
  if (data?.code === 'NEEDS_CHAIN') throw new NeedsChainError(data.error)
  if (!res.ok) throw new Error(data.error ?? 'Could not prepare the transaction')

  onStep?.('Approve the transaction to continue')
  await executeChallenge(data.challengeId, session.userToken, session.encryptionKey)

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
AFX_5B_EOF
ok "wrote afrifx-web/hooks/useCircleTx.ts"

mkdir -p "$ROOT/$(dirname afrifx-web/hooks/useBridge.ts)"
cat > "$ROOT/afrifx-web/hooks/useBridge.ts" <<'AFX_5B_EOF'
'use client'
// ============================================================
// useBridge — the CCTP flow, signed by the user's CIRCLE wallet.
//
// STAGE 3b (Circle migration). Real money moves here, so the discipline is
// unchanged from the wagmi version:
//   RECORD FIRST, THEN ACT, THEN RECORD THE RESULT.
//
// Every step is reported to the stage-2 state machine, so if the tab closes or
// a request dies, the server record still reflects reality and the transfer
// can be resumed or reconciled.
//
// THE ONE MOMENT THAT MATTERS: the instant the burn confirms, we POST the burn
// tx hash to /bridge/:id/burned BEFORE anything else. After that the funds are
// burned and the mint is owed; losing the hash there makes recovery far harder.
//
// WHAT CHANGED FROM WAGMI
// The wallet is a Circle user-controlled wallet, not a browser wallet, so:
//   * approve/burn/mint are contractExecution challenges the user approves on
//     their device (executeContractCall), not writeContract calls.
//   * there is NO switchChain: Circle runs each call on the chain we name
//     (via the wallet that lives there), so the two old network-switch steps
//     simply vanish. The wallet exists on every bridge chain because we add
//     them at sign-up (see addBridgeChains).
//   * we don't wait for a receipt: executeContractCall returns the on-chain
//     hash once Circle surfaces it.
// The attestation wait (Circle Iris) is byte-for-byte the same as before.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import {
  cctpContracts, irisBase, chainByKey, addressToBytes32, CCTP_ENV,
} from '@/lib/cctp-chains'
import {
  getBurnFee, fetchAttestation, toUnits, FINALITY,
} from '@/lib/cctp-client'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type BridgeStep =
  | 'idle' | 'creating' | 'approving' | 'burning'
  | 'attesting' | 'minting' | 'done' | 'error'

export interface BridgeState {
  step:     BridgeStep
  bridgeId: string | null
  burnTx:   string | null
  mintTx:   string | null
  error:    string | null
  /** Burned but not yet minted funds are in flight and the mint is owed. */
  inFlight: boolean
  /** Seconds spent waiting for Circle, so the UI isn't a black box. */
  waitedSec: number
  /** A human step message while the user approves on their device. */
  note:     string | null
}

const INITIAL: BridgeState = {
  step: 'idle', bridgeId: null, burnTx: null, mintTx: null,
  error: null, inFlight: false, waitedSec: 0, note: null,
}

// Iris allows 40 req/s and blocks for 5 minutes if breached, so poll gently.
const POLL_MS       = 5_000
/*
  Five minutes of ACTIVE waiting, not thirty. Ethereum Sepolia needs ~13-19 min
  to finalise before Circle will even attest, so a spinner that waits the whole
  time makes a working transfer look broken. We wait a sensible while, then hand
  off to the reconciler, which was always the design.
*/
const POLL_MAX_MIN  = 5

async function api(path: string, body?: unknown) {
  const res = await fetch(`${API}${path}`, {
    method: body ? 'POST' : 'GET',
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) {
    const d = await res.json().catch(() => ({}))
    throw new Error(d.error ?? `API ${res.status}`)
  }
  return res.json()
}

export function useBridge() {
  const { address } = useAccount()
  const [state, setState] = useState<BridgeState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const bridge = useCallback(async (params: {
    fromKey: string
    toKey:   string
    amount:  number
    recipient?: string
  }) => {
    if (!address) { setState(s => ({ ...s, step: 'error', error: 'Sign in first' })); return }

    const from = chainByKey(params.fromKey)
    const to   = chainByKey(params.toKey)
    if (!from || !to) { setState(s => ({ ...s, step: 'error', error: 'Unsupported route' })); return }

    const recipient = params.recipient ?? address
    const amountUnits = toUnits(params.amount)
    let bridgeId: string | null = null
    let burnedYet = false

    const note = (m: string) => setState(s => ({ ...s, note: m }))

    try {
      // ── 1. Record BEFORE anything is signed ──────────────
      setState({ ...INITIAL, step: 'creating' })
      const created = await api('/bridge', {
        walletAddress: address,
        fromChain: from.key, toChain: to.key,
        fromDomain: from.domain, toDomain: to.domain,
        amount: params.amount, recipient,
      })
      bridgeId = created.id
      setState(s => ({ ...s, bridgeId }))

      const contracts = cctpContracts()
      const messenger = contracts.tokenMessenger as `0x${string}`

      /*
        CCTP burns an ERC-20, so burnToken MUST be a real token address. Fail
        HERE with a clear message rather than passing the zero address to
        depositForBurn, which reverts opaquely after the user has approved.
      */
      if (!from.usdc || /^0x0+$/.test(from.usdc)) {
        throw new Error(
          `No USDC token address configured for ${from.name}. ` +
          `Bridging from this chain can't proceed until it's set.`)
      }

      // ── 2. Approve the TokenMessenger to spend USDC ──────
      // (on the SOURCE chain, signed by the wallet that lives there)
      setState(s => ({ ...s, step: 'approving' }))
      await executeContractCall({
        chainKey:             from.key,
        contractAddress:      from.usdc,
        abiFunctionSignature: 'approve(address,uint256)',
        abiParameters:        [messenger, amountUnits.toString()],
      }, note)

      // ── 3. BURN on the source chain ──────────────────────
      setState(s => ({ ...s, step: 'burning' }))
      await api(`/bridge/${bridgeId}/burning`, {})

      const fee = await getBurnFee(irisBase(), from.domain, to.domain, amountUnits)

      /*
        depositForBurn(amount, destinationDomain, mintRecipient, burnToken,
                       destinationCaller, maxFee, minFinalityThreshold)
        Circle's abiParameters wants: uint256 as decimal strings, address as
        hex, bytes32 as hex. destinationCaller = bytes32(0) so ANY address may
        finish the mint (our reconciler, or the user from another device).
      */
      const burnResult = await executeContractCall({
        chainKey:             from.key,
        contractAddress:      messenger,
        abiFunctionSignature:
          'depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)',
        abiParameters: [
          amountUnits.toString(),
          to.domain,
          addressToBytes32(recipient),
          from.usdc,
          `0x${'0'.repeat(64)}`,
          fee.maxFeeUnits.toString(),
          FINALITY.FINALIZED,
        ],
      }, note)

      const burnTx = burnResult.txHash
      if (!burnTx) {
        // Approved but no hash surfaced in time. Not necessarily lost, but we
        // can't record a burn without its hash, so stop and let the user retry
        // or check. The bridge record is still 'burning', which the reconciler
        // will resolve.
        throw new Error(
          'The burn was approved but is taking longer than usual to confirm. ' +
          'Check "Recent bridges" shortly \u2014 if it went through you can ' +
          'finish it there; nothing is lost.')
      }

      /*
        *** THE CRITICAL WRITE ***
        Funds are now burned. Persist the tx hash immediately; everything
        downstream depends on it. We await this and let a failure surface.
      */
      burnedYet = true
      setState(s => ({ ...s, burnTx, inFlight: true }))
      await api(`/bridge/${bridgeId}/burned`, {
        burnTx,
        // Circle looks the message up by tx hash, so store the hash in both
        // fields rather than computing a message hash client-side.
        messageBytes: burnTx,
        messageHash:  burnTx,
      })

      // ── 4. Wait for Circle's attestation ─────────────────
      setState(s => ({ ...s, step: 'attesting', note: null }))
      const startedAt = Date.now()
      const deadline  = startedAt + POLL_MAX_MIN * 60_000

      let att: Awaited<ReturnType<typeof fetchAttestation>> = { status: 'pending' }
      while (Date.now() < deadline) {
        try {
          att = await fetchAttestation(irisBase(), from.domain, burnTx)
          if (att.status === 'complete') break
        } catch {
          // swallow and retry — the burn is safe either way
        }
        setState(s => ({ ...s, waitedSec: Math.floor((Date.now() - startedAt) / 1000) }))
        await new Promise(r => setTimeout(r, POLL_MS))
      }
      if (att.status !== 'complete' || !att.message || !att.attestation) {
        // NOT a loss: the burn is recorded and the reconciler will finish it.
        throw new Error(
          'Circle is still attesting this transfer. Your USDC is burned and ' +
          'safely recorded, so nothing is lost, but the final step needs your ' +
          'signature. You can close this page and finish it any time from ' +
          '"Recent bridges" below.')
      }
      await api(`/bridge/${bridgeId}/attested`, { attestation: att.attestation })

      // ── 5. MINT on the destination chain ─────────────────
      // (signed by the same wallet, on the destination chain)
      setState(s => ({ ...s, step: 'minting' }))
      const mintResult = await executeContractCall({
        chainKey:             to.key,
        contractAddress:      contracts.messageTransmitter,
        abiFunctionSignature: 'receiveMessage(bytes,bytes)',
        abiParameters:        [att.message, att.attestation],
      }, note)

      const mintTx = mintResult.txHash ?? 'pending'
      await api(`/bridge/${bridgeId}/completed`, { mintTx })
      setState(s => ({ ...s, step: 'done', mintTx, inFlight: false, note: null }))
    } catch (err: any) {
      let message = err?.message ?? 'Bridge failed'

      if (err instanceof NeedsReauthError) {
        message = err.message
      } else if (err instanceof NeedsChainError) {
        message = err.message
      } else if (/rpc request failed|fetch failed|failed to fetch|network request/i.test(message)) {
        message =
          'Could not reach the network. This is usually a busy public endpoint ' +
          'rather than a problem with your transfer; nothing was submitted. ' +
          'Please try again in a moment.'
      }

      // Tell the server. It classifies failed-vs-stranded by whether a burn
      // landed, so burned funds can never be recorded as a harmless failure.
      if (bridgeId) {
        await api(`/bridge/${bridgeId}/failed`, { error: message }).catch(() => {})
      }
      setState(s => ({
        ...s, step: 'error', error: message,
        inFlight: burnedYet, note: null,
      }))
    }
  }, [address])

  return { ...state, bridge, reset, env: CCTP_ENV }
}
AFX_5B_EOF
ok "wrote afrifx-web/hooks/useBridge.ts"

mkdir -p "$ROOT/$(dirname afrifx-web/hooks/useCompleteBridge.ts)"
cat > "$ROOT/afrifx-web/hooks/useCompleteBridge.ts" <<'AFX_5B_EOF'
'use client'
// ============================================================
// useCompleteBridge — finish a mint that was left outstanding.
//
// WHY THIS EXISTS
// A CCTP bridge burns on the source chain, then mints on the destination. The
// mint is a SEPARATE transaction, so anything that interrupts the flow (closing
// the tab, a slow attestation) leaves the burn done and the mint owed.
//
// Our reconciler can SEE those but cannot fix them: the platform holds no key,
// by design. So the owner of the funds finishes it themselves. That is what
// this does.
//
// CCTP makes this safe and permanent:
//   * attestations DO NOT EXPIRE, so there is no deadline
//   * destinationCaller was bytes32(0) at burn time, so ANY address may mint
// A stranded transfer is always recoverable, needing only the original burn
// transaction hash, which we persisted.
//
// CIRCLE MIGRATION: the mint is a contractExecution challenge the user approves
// on their device (executeContractCall), signed by their Circle wallet on the
// destination chain. No wagmi, no network switch — Circle runs the call on the
// chain we name.
// ============================================================

import { useState, useCallback } from 'react'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import { irisBase, chainByKey, cctpContracts } from '@/lib/cctp-chains'
import { fetchAttestation } from '@/lib/cctp-client'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type CompleteStep = 'idle' | 'checking' | 'minting' | 'done' | 'error'

export function useCompleteBridge() {
  const [step,   setStep]   = useState<CompleteStep>('idle')
  const [error,  setError]  = useState<string | null>(null)
  const [mintTx, setMintTx] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [note,   setNote]   = useState<string | null>(null)

  const reset = useCallback(() => {
    setStep('idle'); setError(null); setMintTx(null); setBusyId(null); setNote(null)
  }, [])

  const complete = useCallback(async (bridge: {
    id: string
    from_chain: string
    to_chain: string
    burn_tx?: string | null
  }) => {
    if (!bridge.burn_tx) {
      setStep('error'); setError('No burn transaction recorded for this transfer.')
      return
    }

    setBusyId(bridge.id)
    setStep('checking'); setError(null); setNote(null)

    try {
      const from = chainByKey(bridge.from_chain)
      const to   = chainByKey(bridge.to_chain)
      if (!from || !to) throw new Error('Unsupported route')

      // 1. Fetch the attestation using the ORIGINAL burn tx. Attestations never
      //    expire, so this works however long ago the burn happened.
      const att = await fetchAttestation(irisBase(), from.domain, bridge.burn_tx)

      if (att.status === 'not_found') {
        throw new Error(
          'Circle has no record of this burn yet. If it was very recent, wait a ' +
          'few minutes and try again.')
      }
      if (att.status !== 'complete' || !att.message || !att.attestation) {
        throw new Error(
          `Circle has not finished attesting this transfer yet. ${from.name} ` +
          'transfers can take 13 to 19 minutes to finalise. Try again shortly.')
      }

      await fetch(`${API}/bridge/${bridge.id}/attested`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ attestation: att.attestation }),
      }).catch(() => {})

      // 2. Mint on the destination chain via a Circle challenge.
      setStep('minting')
      const result = await executeContractCall({
        chainKey:             to.key,
        contractAddress:      cctpContracts().messageTransmitter,
        abiFunctionSignature: 'receiveMessage(bytes,bytes)',
        abiParameters:        [att.message, att.attestation],
      }, setNote)

      const tx = result.txHash ?? 'pending'

      await fetch(`${API}/bridge/${bridge.id}/completed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mintTx: tx }),
      }).catch(() => {})

      setMintTx(tx)
      setStep('done'); setNote(null)
    } catch (err: any) {
      let message = err?.message ?? 'Could not complete the transfer'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) {
        message = err.message
      } else if (/already been used|nonce already|already minted/i.test(message)) {
        // The mint already happened, so this is success, not failure.
        message = 'This transfer was already completed. Refreshing the list.'
        await fetch(`${API}/bridge/${bridge.id}/completed`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ mintTx: 'already-minted' }),
        }).catch(() => {})
      }
      setStep('error'); setError(message); setNote(null)
    } finally {
      setBusyId(null)
    }
  }, [])

  return { step, error, mintTx, busyId, note, complete, reset }
}
AFX_5B_EOF
ok "wrote afrifx-web/hooks/useCompleteBridge.ts"

mkdir -p "$ROOT/$(dirname afrifx-web/hooks/useChainUsdcBalance.ts)"
cat > "$ROOT/afrifx-web/hooks/useChainUsdcBalance.ts" <<'AFX_5B_EOF'
'use client'
// ============================================================
// useChainUsdcBalance read a wallet's USDC balance on ANY supported chain.
//
// The app's existing useUSDCBalance is pinned to Arc, which is right for Send's
// same-chain path but useless for the bridge, where the source chain changes.
// This reads balanceOf on whichever chain is selected.
// ============================================================

import { useState, useEffect, useCallback } from 'react'
import { useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

const ERC20_BALANCE_ABI = [
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export function useChainUsdcBalance(chainKey: string) {
  const { address } = useAccount()
  const config = useConfig()
  const [balance, setBalance] = useState<number>(0)
  const [loading, setLoading] = useState(false)

  const load = useCallback(async () => {
    if (!address) { setBalance(0); return }
    const chain   = chainByKey(chainKey)
    const chainId = evmChainId(chainKey)
    if (!chain?.usdc || !chainId) { setBalance(0); return }

    setLoading(true)
    try {
      const client = getPublicClient(config, { chainId })
      if (!client) { setBalance(0); return }
      const raw = await client.readContract({
        address: chain.usdc as `0x${string}`,
        abi: ERC20_BALANCE_ABI,
        functionName: 'balanceOf',
        args: [address],
      })
      // USDC is 6 decimals on every supported chain, including Arc's ERC-20
      // interface (the NATIVE token is 18 mixing them is a known trap).
      setBalance(Number(raw as bigint) / 1_000_000)
    } catch {
      // A failed read shouldn't break the form; just show zero and let the user
      // type an amount manually.
      setBalance(0)
    } finally {
      setLoading(false)
    }
  }, [address, chainKey, config])

  useEffect(() => { load() }, [load])

  return { balance, loading, refresh: load }
}
AFX_5B_EOF
ok "wrote afrifx-web/hooks/useChainUsdcBalance.ts"

mkdir -p "$ROOT/$(dirname afrifx-web/components/bridge/BridgeCard.tsx)"
cat > "$ROOT/afrifx-web/components/bridge/BridgeCard.tsx" <<'AFX_5B_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  ArrowDown, Loader2, CheckCircle, AlertTriangle, ExternalLink, Info,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useBridge } from '@/hooks/useBridge'
import { cctpChains, chainByKey, isRouteSupported } from '@/lib/cctp-chains'
import { useChainUsdcBalance } from '@/hooks/useChainUsdcBalance'

/*
  Bridge UI for CCTP transfers.

  The single most important job of this component is being HONEST about where
  the money is. Once the burn lands, funds are mid-flight and the mint is owed
  so the copy at that point must never look like a plain error, or a user will
  think their money is gone when it isn't.
*/

/*
  The bridge is a multi-minute, multi-signature process. Rather than a paragraph
  explaining CCTP, the card shows WHERE THE USER IS, each stage marked done,
  active, or pending.

  Stage order mirrors the hook's own steps so the two can't drift.
*/
const FLOW: { key: string; label: (from: string, to: string, amt: string) => string }[] = [
  { key: 'approving', label: (f)         => `Approve USDC on ${f}` },
  { key: 'burning',   label: (f, _t, a)  => `Burn ${a} USDC on ${f}` },
  { key: 'attesting', label: ()          => 'Wait for Circle to attest' },
  { key: 'minting',   label: (_f, t)     => `Mint on ${t}` },
]

const ORDER = ['creating', 'approving', 'burning', 'attesting', 'minting', 'done']

function stageState(stage: string, current: string): 'done' | 'active' | 'pending' {
  if (current === 'done') return 'done'
  const ci = ORDER.indexOf(current)
  const si = ORDER.indexOf(stage)
  if (ci < 0 || si < 0) return 'pending'
  if (si < ci)  return 'done'
  if (si === ci) return 'active'
  return 'pending'
}

export function BridgeCard() {
  const { address, isConnected } = useAccount()
  const { step, bridgeId, burnTx, mintTx, error, inFlight, waitedSec, note, bridge, reset, env } = useBridge()

  const chains = cctpChains()
  const [fromKey, setFromKey] = useState('arc')
  const [toKey,   setToKey]   = useState('base')
  const [amount,  setAmount]  = useState('')

  // Balance on the SOURCE chain, so Max and the insufficient check are correct
  // for whichever direction the user picks.
  const { balance, loading: balLoading, refresh: refreshBalance } =
    useChainUsdcBalance(fromKey)

  /*
    Clear the amount once a bridge completes, and re-read the balance.
    Leaving the amount populated with the button live is how someone
    accidentally bridges twice.
  */
  useEffect(() => {
    if (step === 'done') { setAmount(''); refreshBalance() }
  }, [step, refreshBalance])

  const from = chainByKey(fromKey)
  const to   = chainByKey(toKey)
  const routeOk = isRouteSupported(fromKey, toKey)
  const amt = Number(amount)
  const busy = ['creating','approving','burning','attesting','minting'].includes(step)
  const insufficient = amt > 0 && amt > balance

  const canSubmit = isConnected && routeOk && amt > 0 && !busy && !insufficient

  function swapDirection() {
    setFromKey(toKey); setToKey(fromKey)
  }

  const explorerTx = (chainKey: string, hash: string) => {
    const c = chainByKey(chainKey)
    return c ? `${c.explorer}/tx/${hash}` : '#'
  }

  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-base font-semibold text-app-text">Bridge USDC</h2>
        <span className="rounded-full bg-app-bg px-2 py-0.5 text-[10px] uppercase tracking-wide text-app-muted">
          {env}
        </span>
      </div>

      {/* From */}
      <label className="mb-1 block text-xs text-app-muted">From</label>
      <select
        value={fromKey}
        onChange={e => setFromKey(e.target.value)}
        disabled={busy}
        className="mb-3 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => <option key={c.key} value={c.key}>{c.name}</option>)}
      </select>

      <div className="my-1 flex justify-center">
        <button
          onClick={swapDirection}
          disabled={busy}
          title="Swap direction"
          className="flex h-8 w-8 items-center justify-center rounded-full border border-app-border bg-app-bg text-app-muted hover:text-app-text disabled:opacity-40"
        >
          <ArrowDown className="h-4 w-4" />
        </button>
      </div>

      {/* To */}
      <label className="mb-1 block text-xs text-app-muted">To</label>
      <select
        value={toKey}
        onChange={e => setToKey(e.target.value)}
        disabled={busy}
        className="mb-3 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => <option key={c.key} value={c.key}>{c.name}</option>)}
      </select>

      {/* Amount */}
      <div className="mb-1 flex items-center justify-between">
        <label className="text-xs text-app-muted">Amount (USDC)</label>
        <span className="flex items-center gap-2 text-[11px]">
          <span className="text-app-muted">
            Balance:{' '}
            <span className="font-mono text-app-text">
              {balLoading ? '…' : balance.toFixed(2)}
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
        className="mb-4 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 font-mono text-sm text-app-text outline-none placeholder:text-app-border disabled:opacity-50"
      />

      {!routeOk && fromKey === toKey && (
        <p className="mb-3 text-xs text-amber-400">Source and destination must be different chains.</p>
      )}

      {insufficient && (
        <p className="mb-3 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
          <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
          You only have {balance.toFixed(2)} USDC on {from?.name}
        </p>
      )}

      {/* Action */}
      {step === 'done' ? (
        <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
          <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
          <p className="text-sm font-medium text-emerald-400">Bridge complete</p>
          <p className="mt-1 text-xs text-emerald-700 dark:text-emerald-600">
            {amount} USDC arrived on {to?.name}
          </p>
          <div className="mt-3 flex flex-col gap-1 text-[11px]">
            {burnTx && (
              <a href={explorerTx(fromKey, burnTx)} target="_blank" rel="noopener noreferrer"
                className="inline-flex items-center justify-center gap-1 text-app-accent-text hover:underline">
                Burn transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
            {mintTx && (
              <a href={explorerTx(toKey, mintTx)} target="_blank" rel="noopener noreferrer"
                className="inline-flex items-center justify-center gap-1 text-app-accent-text hover:underline">
                Mint transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
          <Button size="sm" variant="outline" className="mt-3" onClick={reset}>
            Bridge again
          </Button>
        </div>
      ) : (
        <Button
          className="w-full"
          disabled={!canSubmit}
          onClick={() => bridge({ fromKey, toKey, amount: amt })}
        >
          {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Working…</>
                : !isConnected ? 'Sign in to bridge'
                : insufficient ? 'Insufficient balance'
                : 'Bridge USDC'}
        </Button>
      )}

      {/* Live step note: with a Circle wallet each approve/burn/mint is a
          prompt on the user's device, so tell them what they're approving. */}
      {busy && note && (
        <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
          <Loader2 className="h-3 w-3 animate-spin" /> {note}
        </p>
      )}

      {/* Progress */}
      {/* Errors tone depends ENTIRELY on whether funds already moved */}
      {step === 'error' && error && (
        inFlight ? (
          // Burned but not minted. NOT a loss. Never show this as a plain error.
          <div className="mt-3 rounded-lg border border-amber-700/50 bg-amber-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-amber-400">
              <Info className="h-3.5 w-3.5" /> Transfer in progress
            </p>
            <p className="mt-1 text-[11px] leading-relaxed text-amber-800 dark:text-amber-200/90">
              {error}
            </p>
            <p className="mt-1.5 text-[11px] text-amber-700 dark:text-amber-200/70">
              Your funds are burned on {from?.name} and the mint on {to?.name} is
              still owed. Nothing is lost: finish it any time from Recent bridges
              below, using the Complete transfer button.
            </p>
            {burnTx && (
              <a href={explorerTx(fromKey, burnTx)} target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-[11px] text-amber-400 hover:underline">
                View burn transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
        ) : (
          // Failed before the burn: nothing moved, safe to retry.
          <div className="mt-3 rounded-lg border border-red-900/50 bg-red-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-red-400">
              <AlertTriangle className="h-3.5 w-3.5" /> Transfer not started
            </p>
            <p className="mt-1 text-[11px] leading-relaxed text-red-800 dark:text-red-300/90">{error}</p>
            <p className="mt-1.5 text-[11px] text-red-700 dark:text-red-300/60">
              No funds were moved. You can safely try again.
            </p>
            <Button size="sm" variant="outline" className="mt-2" onClick={reset}>Try again</Button>
          </div>
        )
      )}

      {/* Live flow. Replaces the old marketing blurb: what the user needs is
          to know WHERE THEY ARE in a multi-minute, multi-signature process, not
          a paragraph about CCTP. Each stage shows done / active / pending. */}
      <div className="mt-4 border-t border-app-border pt-3">
        <p className="mb-2 text-[10px] font-semibold uppercase tracking-wide text-app-muted">
          Transfer steps
        </p>
        <div className="space-y-1.5">
          {FLOW.map(f => {
            const state = stageState(f.key, step)
            return (
              <div key={f.key} className="flex items-center gap-2">
                <span className="flex h-4 w-4 shrink-0 items-center justify-center">
                  {state === 'done'
                    ? <CheckCircle className="h-3.5 w-3.5 text-emerald-400" />
                    : state === 'active'
                    ? <Loader2 className="h-3.5 w-3.5 animate-spin text-app-accent-text" />
                    : <span className="h-1.5 w-1.5 rounded-full bg-app-border" />}
                </span>
                <span className={`text-[11px] ${
                  state === 'done'   ? 'text-app-muted line-through decoration-app-border'
                  : state === 'active' ? 'text-app-text'
                  : 'text-app-muted/60'}`}>
                  {f.label(from?.name ?? 'source', to?.name ?? 'destination', amount || '0')}
                </span>
                {/* Elapsed time on the attestation step it's the long one, and
                    a silent spinner with no clock makes it feel broken. */}
                {f.key === 'attesting' && state === 'active' && waitedSec > 0 && (
                  <span className="ml-auto font-mono text-[10px] text-app-muted">
                    {Math.floor(waitedSec / 60)}:{String(waitedSec % 60).padStart(2, '0')}
                  </span>
                )}
              </div>
            )
          })}
        </div>

        {/* Once the burn lands the funds are safe and the mint is owed, so the
            user should never feel trapped by a spinner. */}
        {inFlight && waitedSec > 45 && (
          <button
            onClick={reset}
            className="mt-2 text-[11px] text-app-muted underline underline-offset-2 hover:text-app-text"
          >
            Stop waiting, finish it later from Recent bridges
          </button>
        )}
      </div>
    </div>
  )
}
AFX_5B_EOF
ok "wrote afrifx-web/components/bridge/BridgeCard.tsx"

mkdir -p "$ROOT/$(dirname afrifx-web/components/bridge/BridgeHistory.tsx)"
cat > "$ROOT/afrifx-web/components/bridge/BridgeHistory.tsx" <<'AFX_5B_EOF'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { CheckCircle, Clock, AlertTriangle, ExternalLink, RefreshCw, Loader2 } from 'lucide-react'
import { useCompleteBridge } from '@/hooks/useCompleteBridge'
import { useAttestationStatus, finalityHint } from '@/hooks/useAttestationStatus'
import { chainByKey } from '@/lib/cctp-chains'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface BridgeRow {
  id: string
  from_chain: string
  to_chain:   string
  amount:     number
  status:     string
  burn_tx?:   string | null
  mint_tx?:   string | null
  created_at: number
}

/*
  Without this list, a bridge that outlives the page is INVISIBLE, the user has
  burned funds and no way to see what became of them. On an Ethereum-source
  bridge that's the normal case, not an edge case: finality alone takes 13-19
  minutes, far longer than anyone will sit and watch a spinner.
*/
export function BridgeHistory() {
  const { address } = useAccount()
  const [rows, setRows]       = useState<BridgeRow[]>([])
  const [loading, setLoading] = useState(false)
  const finish = useCompleteBridge()

  /*
    Which unfinished bridges are actually mintable yet? Showing a Complete
    button before Circle has attested only produces a failed click, so we check
    first and show a waiting state instead.
  */
  const pending = rows.filter(r =>
    r.status !== 'completed' && r.status !== 'failed' && !!r.burn_tx)
  const { status: attest } = useAttestationStatus(pending)

  const load = useCallback(async () => {
    if (!address) { setRows([]); return }
    setLoading(true)
    try {
      const res  = await fetch(`${API}/bridge?wallet=${address}`)
      const data = await res.json()
      setRows(Array.isArray(data) ? data : [])
    } catch { /* keep the previous list rather than blanking it */ }
    finally { setLoading(false) }
  }, [address])

  useEffect(() => { load() }, [load])

  // Refresh once a manual completion lands, so the row flips to Complete.
  useEffect(() => {
    if (finish.step === 'done') { load(); finish.reset() }
  }, [finish.step, load, finish])

  // Poll while anything is still moving, so a completed mint appears without a
  // manual refresh.
  useEffect(() => {
    const pending = rows.some(r =>
      ['attesting', 'minting', 'stranded', 'burning'].includes(r.status))
    if (!pending) return
    const t = setInterval(load, 20_000)
    return () => clearInterval(t)
  }, [rows, load])

  if (!address || (!rows.length && !loading)) return null

  const chip = (status: string) => {
    switch (status) {
      case 'completed': return { icon: CheckCircle,   cls: 'text-emerald-400', label: 'Complete' }
      case 'failed':    return { icon: AlertTriangle, cls: 'text-red-400',     label: 'Not started' }
      default:          return { icon: Clock,         cls: 'text-amber-400',   label: 'In progress' }
    }
  }

  return (
    <div className="mt-6 w-full max-w-md">
      <div className="mb-2 flex items-center justify-between">
        <h3 className="text-xs font-semibold uppercase tracking-wide text-app-muted">
          Recent bridges
        </h3>
        <button onClick={load} disabled={loading}
          className="flex items-center gap-1 text-[11px] text-app-muted hover:text-app-text">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      <div className="space-y-2">
        {rows.slice(0, 8).map(r => {
          const c = chip(r.status)
          const Icon = c.icon
          const fromC = chainByKey(r.from_chain)
          const toC   = chainByKey(r.to_chain)
          return (
            <div key={r.id} className="rounded-lg border border-app-border bg-app-surface p-3">
              <div className="flex items-center justify-between">
                <span className="text-xs text-app-text">
                  {r.amount} USDC
                  <span className="text-app-muted">
                    {' '}· {fromC?.name ?? r.from_chain} → {toC?.name ?? r.to_chain}
                  </span>
                </span>
                <span className={`flex items-center gap-1 text-[11px] ${c.cls}`}>
                  <Icon className="h-3 w-3" /> {c.label}
                </span>
              </div>

              <div className="mt-1 flex flex-wrap gap-3 text-[10px]">
                <span className="text-app-muted">
                  {new Date(r.created_at * 1000).toLocaleString()}
                </span>
                {r.burn_tx && fromC && (
                  <a href={`${fromC.explorer}/tx/${r.burn_tx}`} target="_blank" rel="noopener noreferrer"
                    className="inline-flex items-center gap-0.5 text-app-accent-text hover:underline">
                    burn <ExternalLink className="h-2 w-2" />
                  </a>
                )}
                {r.mint_tx && toC && (
                  <a href={`${toC.explorer}/tx/${r.mint_tx}`} target="_blank" rel="noopener noreferrer"
                    className="inline-flex items-center gap-0.5 text-app-accent-text hover:underline">
                    mint <ExternalLink className="h-2 w-2" />
                  </a>
                )}
              </div>

              {r.status !== 'completed' && r.status !== 'failed' && r.burn_tx && (
                <div className="mt-1.5">
                  {/* HONEST copy. The mint does NOT happen on its own: the
                      platform holds no key (non-custodial by design), so the
                      owner of the funds finishes it. Attestations never expire
                      and destinationCaller is bytes32(0), so this always works,
                      however long it has been. */}
                  <p className="text-[10px] leading-relaxed text-amber-700 dark:text-amber-200/70">
                    {attest[r.id] === 'waiting'
                      ? `Your USDC is burned and recorded. Circle is still confirming the ` +
                        `${chainByKey(r.from_chain)?.name ?? r.from_chain} transaction, after ` +
                        `which you can release it on ${chainByKey(r.to_chain)?.name ?? r.to_chain}.`
                      : `Your USDC is burned and recorded. Nothing is lost, but the final ` +
                        `step needs your signature to release it on ${chainByKey(r.to_chain)?.name ?? r.to_chain}.`}
                  </p>

                  {/* Only offer the action once Circle can actually serve the
                      attestation. 'unknown' means we could not reach Circle, so
                      we still allow the attempt rather than blocking the user. */}
                  {attest[r.id] === 'waiting' ? (
                    <p className="mt-1.5 inline-flex items-center gap-1.5 rounded-md bg-app-bg px-2.5 py-1 text-[11px] text-app-muted">
                      <Loader2 className="h-3 w-3 animate-spin" />
                      Waiting for Circle to attest, {finalityHint(r.from_chain)}
                    </p>
                  ) : (
                    <button
                      onClick={() => finish.complete(r)}
                      disabled={finish.busyId === r.id}
                      className="mt-1.5 inline-flex items-center gap-1.5 rounded-md bg-app-accent px-2.5 py-1 text-[11px] font-medium text-app-on-accent hover:opacity-90 disabled:opacity-50"
                    >
                      {finish.busyId === r.id
                        ? <><Loader2 className="h-3 w-3 animate-spin" /> Completing...</>
                        : 'Complete transfer'}
                    </button>
                  )}

                  {finish.busyId === r.id && finish.step === 'checking' && (
                    <p className="mt-1 text-[10px] text-app-muted">Checking with Circle...</p>
                  )}
                  {finish.busyId === r.id && finish.note && (
                    <p className="mt-1 text-[10px] text-app-muted">{finish.note}</p>
                  )}
                  {finish.error && finish.busyId === null && (
                    <p className="mt-1 text-[10px] text-red-700 dark:text-red-300">{finish.error}</p>
                  )}
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
AFX_5B_EOF
ok "wrote afrifx-web/components/bridge/BridgeHistory.tsx"


# ---- Verify content landed --------------------------------------------------
say "Verifying markers"
grep -q "CONTRACT EXECUTION (bridge burn" "$API/src/services/circleWallets.ts" || die "service block missing"
grep -q "createContractExecution"         "$API/src/services/circleWallets.ts" || die "createContractExecution missing"
grep -q "/wallet/tx/contract"             "$API/src/routes/auth.ts"            || die "contract route missing"
grep -q "executeContractCall"             "$WEB/hooks/useCircleTx.ts"          || die "executeContractCall missing"
grep -q "from 'wagmi'" "$WEB/hooks/useBridge.ts"        && die "useBridge still imports wagmi"
grep -q "from 'wagmi'" "$WEB/hooks/useCompleteBridge.ts" && die "useCompleteBridge still imports wagmi"
ok "all markers present, no wagmi in rewritten hooks"

# ---- Typecheck + test + build ----------------------------------------------
say "API: install + tsc + tests"
( cd "$API" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && npx tsc --noEmit ) \
  || { cp -rf "$BK"/. "$ROOT"/ ; die "API tsc failed - restored from snapshot"; }
ok "afrifx-api typechecks"
( cd "$API" && npx vitest run >/dev/null 2>&1 ) \
  || { cp -rf "$BK"/. "$ROOT"/ ; die "API tests failed - restored from snapshot"; }
ok "afrifx-api tests pass"

say "WEB: install + tsc + build"
( cd "$WEB" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && npx tsc --noEmit ) \
  || { cp -rf "$BK"/. "$ROOT"/ ; die "web tsc failed - restored from snapshot"; }
ok "afrifx-web typechecks"
( cd "$WEB" && npm run build >/dev/null 2>&1 ) \
  || { cp -rf "$BK"/. "$ROOT"/ ; die "web build failed - restored from snapshot"; }
ok "afrifx-web builds"

rm -rf "$BK"
say "Phase 5b applied and verified."
cat <<'NOTE'

  What shipped
    - Bridge burn + mint now sign through the Circle wallet (contractExecution
      challenges), no wagmi, no network switch.
    - New API: POST /auth/wallet/tx/contract, GET /auth/wallet/tx/find-contract
    - New client helper: executeContractCall (+ NeedsChainError)
    - useBridge / useCompleteBridge rewritten; BridgeCard drops the switch UI
      and shows a per-step "approve on your device" note.

  Commit & push (auto-deploys via CI -> Vercel + Render)
    git add afrifx-api/src/services/circleWallets.ts \
            afrifx-api/src/routes/auth.ts \
            afrifx-api/tests/circleWallets.test.ts \
            afrifx-web/hooks/useCircleTx.ts \
            afrifx-web/hooks/useBridge.ts \
            afrifx-web/hooks/useCompleteBridge.ts \
            afrifx-web/hooks/useChainUsdcBalance.ts \
            afrifx-web/components/bridge/BridgeCard.tsx \
            afrifx-web/components/bridge/BridgeHistory.tsx
    git commit -m "phase 5b: bridge burn+mint via Circle contractExecution"
    git push origin main

  Test after deploy (a real bridge moves testnet USDC)
    1. Have USDC on the source chain (e.g. Base Sepolia) in your wallet address.
    2. Bridge a small amount Base -> Arc. Approve each device prompt
       (approve, burn, then mint after attestation).
    3. Watch it reach "done"; verify the mint on the destination explorer.
    4. Interrupt-recovery: start a bridge, close the tab after the burn, then
       use "Complete transfer" in Recent bridges to finish the mint.
NOTE
