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

/* PHASE_7E1 diagnostics active */
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

// PHASE_7D1 (diagnostic): read the wallet's REAL account type from Circle.
// getWallet returns accountType ('EOA' | 'SCA') and, for SCAs, scaCore. This
// is the only authoritative way to confirm what was actually provisioned.
export async function getDisbursementWalletInfo(walletId: string): Promise<{
  id: string; address: string | null; blockchain: string | null;
  accountType: string | null; scaCore: string | null; state: string | null
}> {
  const c = client()
  const res = await c.getWallet({ id: walletId })
  const w = (res.data?.wallet ?? {}) as any
  return {
    id:          String(w.id ?? walletId),
    address:     w.address ?? null,
    blockchain:  w.blockchain ?? null,
    accountType: w.accountType ?? null,
    scaCore:     w.scaCore ?? null,
    state:       w.state ?? null,
  }
}

/* PHASE_7D1 diagnostics active */
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

  // PHASE_7E: On Arc, USDC is the native gas asset and Circle's token-transfer
  // endpoint (createTransaction) rejects a plain tokenId transfer of it. The
  // documented path is to call transfer(address,uint256) on the USDC ERC-20
  // contract via createContractExecutionTransaction.
  //
  // DECIMALS: the ERC-20 USDC interface on Arc uses 6 decimals (the NATIVE gas
  // representation uses 18 - do not use that here). Build the base-unit amount
  // with integer math so no float rounding can corrupt it.
  const USDC_ERC20 =
    process.env.CIRCLE_USDC_ERC20_ADDRESS ?? USDC_ADDRESS  // 0x3600...0000
  const DECIMALS = Number(process.env.CIRCLE_USDC_DECIMALS ?? '6')

  const baseUnits = toBaseUnits(params.amount, DECIMALS)
  if (baseUnits === null) {
    throw new Error(`Invalid payout amount: ${params.amount}`)
  }

  const _debugBody = {
    walletId:             params.walletId,
    contractAddress:      USDC_ERC20,
    abiFunctionSignature: 'transfer(address,uint256)',
    abiParameters:        [params.destinationAddress, baseUnits],
    amountHuman:          params.amount,
    decimals:             DECIMALS,
    fee:                  { type: 'level', config: { feeLevel: 'MEDIUM' } },
    refId:                params.refId ?? null,
  }
  console.log('[sendUsdc] contractExecution body:', JSON.stringify(_debugBody))

  let res
  try {
    res = await c.createContractExecutionTransaction({
      walletId:             params.walletId,
      contractAddress:      USDC_ERC20,
      abiFunctionSignature: 'transfer(address,uint256)',
      abiParameters:        [params.destinationAddress, baseUnits],
      idempotencyKey:       params.idempotencyKey ?? randomUUID(),
      fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
      ...(params.refId ? { refId: params.refId } : {}),
    } as any)
  } catch (err: any) {
    // Log Circle's FULL structured error (errors[] names the bad field when
    // present); surface a short but specific reason to the caller/recipient.
    const data   = err?.response?.data
    const errors = Array.isArray(data?.errors) ? data.errors : []
    const fieldMsgs = errors
      .map((e: any) => [e?.location, e?.message].filter(Boolean).join(': '))
      .filter(Boolean)
      .join('; ')
    // PHASE_7E1: dump EVERYTHING Circle sent back, not just .errors.
    console.error('[sendUsdc] RAW Circle error:', JSON.stringify({
      httpStatus:     err?.response?.status,
      httpStatusText: err?.response?.statusText,
      xRequestId:     err?.response?.headers?.['x-request-id'],
      responseData:   err?.response?.data,          // the ENTIRE body
      axiosCode:      err?.code,
      axiosMessage:   err?.message,
    }))
    const detail = fieldMsgs || data?.message || err?.message || 'transfer rejected'
    throw new Error(detail)
  }

  const tx = res.data
  if (!tx?.id) throw new Error('Circle did not return a transaction id')
  return { id: String(tx.id), state: String(tx.state ?? 'INITIATED') }
}

/**
 * PHASE_7E: convert a human USDC amount to base units (string) using integer
 * math so floats can't round. Returns null for NaN/negative/over-precise input.
 * e.g. toBaseUnits(3, 6) -> "3000000";  toBaseUnits(1.5, 6) -> "1500000".
 */
function toBaseUnits(amount: number, decimals: number): string | null {
  if (!Number.isFinite(amount) || amount < 0) return null
  const s = amount.toString()
  if (s.includes('e') || s.includes('E')) return null  // reject sci-notation
  const [whole, frac = ''] = s.split('.')
  if (frac.length > decimals) return null               // more precision than the token allows
  const fracPadded = (frac + '0'.repeat(decimals)).slice(0, decimals)
  const combined = (whole + fracPadded).replace(/^0+(?=\d)/, '')
  return combined === '' ? '0' : combined
}

// PHASE_7E1 (diagnostic): exercise the mutating-request path WITHOUT moving
// funds, and surface Circle's raw response. A fee-estimate for a USDC transfer
// hits the same auth/entity-secret machinery a real transfer does, so if the
// entity secret is mismatched this reproduces the failure with a readable
// error. Also returns loaded-credential LENGTHS (never values) to catch a
// trailing newline or truncation in the deployed env.
export async function disbursementSelfTest(walletId: string): Promise<any> {
  const apiKeyLen  = (process.env.CIRCLE_API_KEY ?? '').length
  const secretLen  = (process.env.CIRCLE_ENTITY_SECRET ?? '').length
  const secretHex  = /^[0-9a-fA-F]+$/.test(process.env.CIRCLE_ENTITY_SECRET ?? '')
  const out: any = {
    env: {
      apiKeyLength:        apiKeyLen,
      entitySecretLength:  secretLen,   // expect 64 (32-byte hex)
      entitySecretIsHex:   secretHex,   // expect true
      blockchain:          BLOCKCHAIN,
    },
  }
  try {
    const c = client()
    // estimateContractExecutionFee mirrors the real payout call, no funds move.
    const res = await (c as any).estimateContractExecutionFee({
      walletId,
      contractAddress:      process.env.CIRCLE_USDC_ERC20_ADDRESS ?? USDC_ADDRESS,
      abiFunctionSignature: 'transfer(address,uint256)',
      abiParameters:        [ '0x0000000000000000000000000000000000000001', '1' ],
    } as any)
    out.feeEstimate = res?.data ?? null
    out.ok = true
  } catch (err: any) {
    out.ok = false
    out.rawError = {
      httpStatus:     err?.response?.status,
      httpStatusText: err?.response?.statusText,
      xRequestId:     err?.response?.headers?.['x-request-id'],
      responseData:   err?.response?.data,
      axiosCode:      err?.code,
      axiosMessage:   err?.message,
    }
  }
  return out
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
