// ============================================================
// platformDisbursement.ts - the platform's MPC disbursement wallet.
//
// WHY THIS EXISTS
// Payroll pays many recipients. User-controlled wallets require the user to
// approve every signature on their device, so a 50-person batch is 50 taps and
// can never run unattended. The hybrid-custody answer: the employer funds ONE
// platform-held wallet with a single signed transfer, and the BACKEND pays out
// from there - no user present per payout, and it can be scheduled.
//
// This wallet is a Circle DEVELOPER-CONTROLLED wallet (MPC), NOT the raw
// private-key platform wallet used for escrow. Keys are secured by Circle's
// MPC via an entity secret; we never hold or log a private key. This is the
// more secure custody model and the foundation escrow can later move onto.
//
// SECURITY
//   * CIRCLE_ENTITY_SECRET is the master key to platform funds. It lives ONLY
//     in the server environment, never in code, never in a log line. The SDK
//     encrypts it per-request (unique ciphertext) so it isn't replayable.
//   * This module never prints the secret, a wallet's private material, or
//     full request bodies.
//
// SCOPE (Phase 7a): provision the wallet + ONE tested payout primitive
// (sendUsdc). Funding and the batch payout engine come in 7b / 7c.
// ============================================================

import {
  initiateDeveloperControlledWalletsClient,
} from '@circle-fin/developer-controlled-wallets'
import { randomUUID } from 'crypto'

const BLOCKCHAIN = process.env.CIRCLE_BLOCKCHAIN ?? 'ARC-TESTNET'

// USDC token id differs by environment; on Arc testnet USDC is the native gas
// token. Circle identifies tokens by a tokenId OR by (blockchain + address).
// We pass the address form so there's nothing extra to configure.
const USDC_ADDRESS =
  process.env.CIRCLE_USDC_ADDRESS ?? '0x3600000000000000000000000000000000000000'

// PHASE_7D: account type for the disbursement wallet. EOA is the default and
// the documented Arc payout path (SCA's ERC-1271 signature was rejected by
// Circle). Env-driven so the mainnet wallet can be provisioned without a code
// change; keep it EOA unless you have a specific reason for SCA.
const ACCOUNT_TYPE = (process.env.CIRCLE_ACCOUNT_TYPE ?? 'EOA').toUpperCase()

/** Lazily-built SDK client. Throws clearly if the env isn't configured. */
let _client: ReturnType<typeof initiateDeveloperControlledWalletsClient> | null = null

function client() {
  if (_client) return _client
  const apiKey       = process.env.CIRCLE_API_KEY
  const entitySecret = process.env.CIRCLE_ENTITY_SECRET
  if (!apiKey)       throw new Error('CIRCLE_API_KEY is not configured')
  if (!entitySecret) throw new Error('CIRCLE_ENTITY_SECRET is not configured')
  _client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret })
  return _client
}

export interface DisbursementWallet {
  id:         string
  address:    string
  blockchain: string
}

/**
 * Provision the platform disbursement wallet set + wallet.
 *
 * Idempotent by intent: run once. It creates a wallet set and a single wallet
 * (EOA by default, see ACCOUNT_TYPE) on the primary chain and returns its id + address. Persist those
 * (env or DB) - subsequent payouts reference the walletId. Safe to call again
 * only if you WANT another wallet; it does not dedupe, so guard the caller.
 *
 * Returns the address to fund. Never logs the entity secret.
 */
export async function provisionDisbursementWallet(
  name = 'AfriFX Payroll Disbursement',
): Promise<DisbursementWallet> {
  const c = client()

  const setRes = await c.createWalletSet({ name })
  const walletSetId = setRes.data?.walletSet?.id
  if (!walletSetId) throw new Error('Circle did not return a wallet set id')

  const walletsRes = await c.createWallets({
    blockchains: [BLOCKCHAIN as any],
    count:       1,
    walletSetId,
    accountType: ACCOUNT_TYPE as any,   // PHASE_7D: EOA by default (see const)
  })
  const w = walletsRes.data?.wallets?.[0]
  if (!w?.id || !w?.address) throw new Error('Circle did not return a wallet')

  return { id: w.id, address: w.address, blockchain: String(w.blockchain ?? BLOCKCHAIN) }
}

/** The current USDC balance of a developer-controlled wallet, as a number. */
export async function getDisbursementBalance(walletId: string): Promise<number> {
  const c = client()
  const res = await c.getWalletTokenBalance({ id: walletId })
  const balances = res.data?.tokenBalances ?? []
  const usdc = balances.find(
    b => String(b.token?.symbol ?? '').toUpperCase() === 'USDC'
      || String(b.token?.tokenAddress ?? '').toLowerCase() === USDC_ADDRESS.toLowerCase())
  return usdc ? Number(usdc.amount) : 0
}

/**
 * Resolve the Circle tokenId for USDC on this wallet's chain.
 *
 * Identifying a transfer by tokenId is the most reliable path - it works
 * whether USDC is a native asset (as on Arc) or an ERC-20, avoiding the
 * "tokenAddress for a native token" rejection. Cached after first lookup.
 */
// PHASE_7C3 (supersedes 7C2): resolve the Circle tokenId for USDC on this wallet's chain.
//
// On Arc, USDC is the NATIVE token (isNative:true, no tokenAddress). Circle's
// transfer API takes EITHER { tokenId } OR { tokenAddress, blockchain } and
// rejects a native transfer that carries a tokenAddress. So we must send
// tokenId. We read it from the wallet's token balances, matching a USDC or
// native entry, and return its token.id.
//
// Cache ONLY a real id - never cache null (a pre-funding/empty read must not
// poison every later payout in this process).
let _usdcTokenId: string | null = null
async function resolveUsdcTokenId(walletId: string): Promise<string | null> {
  if (_usdcTokenId) return _usdcTokenId
  const c = client()
  const res = await c.getWalletTokenBalance({ id: walletId })
  const balances = res.data?.tokenBalances ?? []

  // PHASE_7C3: on Arc the wallet holds TWO USDC entries - the NATIVE gas asset
  // (isNative:true, no address) and the ERC-20 USDC (isNative:false, has an
  // address). A USDC *transfer* goes through the ERC-20 contract, so we must
  // pick the NON-native entry. The native one is spent on gas, not transferred;
  // sending it as a token is what Circle rejected ("API parameter invalid").
  const usdc = balances.filter(b => {
    const t = (b.token ?? {}) as any
    const sym  = String(t.symbol ?? '').toUpperCase()
    const addr = String(t.tokenAddress ?? '').toLowerCase()
    return sym === 'USDC' || addr === USDC_ADDRESS.toLowerCase()
  })

  // Prefer the ERC-20 (non-native) USDC; fall back to whatever USDC exists.
  const pick =
    usdc.find(b => (b.token as any)?.isNative === false)
    ?? usdc.find(b => (b.token as any)?.isNative !== true)
    ?? usdc[0]

  const id = (pick?.token as any)?.id ? String((pick!.token as any).id) : null
  if (id) _usdcTokenId = id   // cache real ids only
  return id
}

/**
 * Diagnostic: list the raw token balances Circle reports for a wallet.
 * Used by GET /payroll/disbursement/tokens to confirm a real USDC tokenId
 * resolves before re-running a batch. Never logs secrets.
 */
export async function listWalletTokens(walletId: string): Promise<Array<{
  id: string | null; symbol: string | null; isNative: boolean;
  tokenAddress: string | null; amount: string | null
}>> {
  const c = client()
  const res = await c.getWalletTokenBalance({ id: walletId })
  return (res.data?.tokenBalances ?? []).map(b => {
    const t = (b.token ?? {}) as any
    return {
      id:           t.id ? String(t.id) : null,
      symbol:       t.symbol ?? null,
      isNative:     t.isNative === true,
      tokenAddress: t.tokenAddress ?? null,
      amount:       b.amount ?? null,
    }
  })
}

/** The on-chain address of the disbursement wallet (what employers fund). */
export async function getDisbursementAddress(walletId: string): Promise<string> {
  const c = client()
  const res = await c.getWallet({ id: walletId })
  const address = res.data?.wallet?.address
  if (!address) throw new Error('Could not read the disbursement wallet address')
  return address
}

export interface PayoutResult {
  id:     string
  state:  string
  txHash?: string
}

/**
 * Send USDC from the platform disbursement wallet to one address.
 *
 * THE payout primitive. Backend-signed via MPC - no user present. Returns the
 * Circle transaction id and state; the tx hash follows once mined (poll with
 * getPayoutStatus). Uses an idempotencyKey so a retried call can't double-pay.
 *
 * `idempotencyKey` SHOULD be stable per (batch, recipient) so a retry of the
 * same payout is exactly-once. The caller supplies it; if omitted we generate
 * one, which is only safe for genuinely one-off sends.
 */
export async function sendUsdc(params: {
  walletId:           string
  destinationAddress: string
  amount:             number
  idempotencyKey?:    string
  refId?:             string
}): Promise<PayoutResult> {
  const c = client()

  // PHASE_7C2: USDC on Arc is native => it has NO tokenAddress. Circle rejects
  // a native transfer that carries a tokenAddress ("API parameter invalid"), so
  // we MUST send tokenId. If we can't resolve one, fail with a clear message
  // rather than sending an invalid body.
  const tokenId = await resolveUsdcTokenId(params.walletId).catch(() => null)
  if (!tokenId) {
    throw new Error(
      'Could not resolve a Circle USDC tokenId for the disbursement wallet. ' +
      'Confirm the float is funded and visible via GET /payroll/disbursement/tokens.')
  }
  const tokenIdent = { tokenId }

  let res
  try {
    res = await c.createTransaction({
      walletId:           params.walletId,
      ...tokenIdent,
      destinationAddress: params.destinationAddress,
      amount:             [params.amount.toString()],
      idempotencyKey:     params.idempotencyKey ?? randomUUID(),
      fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
      ...(params.refId ? { refId: params.refId } : {}),
    } as any)
  } catch (err: any) {
    // PHASE_7C3: Circle returns a data.errors[] naming the exact bad field;
    // the top-level message is just "API parameter invalid". Log the full
    // structured error (once) so failures are diagnosable, then surface a
    // detailed-but-short reason to the caller/recipient row.
    const data   = err?.response?.data
    const errors = Array.isArray(data?.errors) ? data.errors : []
    const fieldMsgs = errors
      .map((e: any) => [e?.location, e?.message].filter(Boolean).join(': '))
      .filter(Boolean)
      .join('; ')
    console.error('[sendUsdc] Circle rejected transfer:', JSON.stringify({
      status:  err?.response?.status,
      code:    data?.code,
      message: data?.message,
      errors,
    }))
    const detail =
      fieldMsgs || data?.message || err?.message || 'transfer rejected'
    throw new Error(detail)
  }

  const tx = res.data
  if (!tx?.id) throw new Error('Circle did not return a transaction id')
  return { id: String(tx.id), state: String(tx.state ?? 'INITIATED') }
}

/** Poll a payout's status by transaction id (to learn its on-chain hash). */
export async function getPayoutStatus(txId: string): Promise<PayoutResult> {
  const c = client()
  const res = await c.getTransaction({ id: txId })
  const tx = res.data?.transaction
  return {
    id:     String(tx?.id ?? txId),
    state:  String(tx?.state ?? 'UNKNOWN'),
    txHash: tx?.txHash,
  }
}
