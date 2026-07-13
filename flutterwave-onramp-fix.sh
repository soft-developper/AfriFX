#!/bin/bash
# ============================================================
# AfriFX -- FIX: Flutterwave on-ramp rejected + errors were unreadable
#
# WHAT THE FIRST REAL TRANSFER TOLD US
# The orchestrator behaved PERFECTLY: it planned the right legs, the onramp
# leg failed, it STOPPED (never touched offramp/payout), moved the transfer to
# 'refunding' and recorded the reason. No funds moved. That's the safety
# machinery doing its job.
#
# But two things were wrong:
#
# 1) ERRORS WERE UNREADABLE -- "Flutterwave: [object Object]".
#    Flutterwave's `message` can be an OBJECT of field-level validation errors.
#    Template-stringifying it threw away exactly the detail we needed. Now the
#    error body is serialised properly AND logged server-side.
#
# 2) THE ON-RAMP PAYLOAD WAS WRONG -- almost certainly why it was rejected.
#    Their documented flow is TWO separate calls:
#       step 1  fiat -> stablecoin,  recipient = { wallet: {...} }
#       step 2  stablecoin -> crypto address  (separate call, type 'crypto')
#    I had merged them (fiat source + crypto recipient), which isn't supported.
#
#    And on reflection we don't want step 2 at all for fiat-in: the USDC never
#    needs to touch a blockchain. It lands in OUR Flutterwave stablecoin wallet
#    and the off-ramp spends straight from that balance -- no gas, no bridge,
#    cheaper, fewer moving parts. (The crypto path is only for usdc_in, where
#    the user's USDC starts on Arc.)
#
# ALSO ADDED
#   * walletBalance() -- a dry wallet is the likeliest payout failure, so
#     /transfers/health now reports the USDC balance and whether the wallet id
#     and webhook secret are set.
#   * sendToAddress() -- push USDC out to a crypto address (for usdc_in later).
#
# NEW ENV VAR REQUIRED (in RENDER, not just local .env):
#   FLUTTERWAVE_WALLET_ID=...   <- your Flutterwave stablecoin wallet identifier
#
# Run from ~/AfriFX:  bash flutterwave-onramp-fix.sh
# ============================================================
set -e
echo ""
echo "Fixing the Flutterwave on-ramp + error reporting..."
echo ""

mkdir -p "afrifx-api/src/services/ramp/providers"
cat > "afrifx-api/src/services/ramp/providers/flutterwave.ts" << 'AFX_EOF'
// ============================================================
// FlutterwaveProvider — implements FiatRampProvider against Flutterwave v4.
//
// Verified against the live docs (developer.flutterwave.com/docs/stablecoins):
//   * Stablecoin chains: SOLANA, ETHEREUM, BASE, POLYGON. NOT Arc — so USDC
//     originating on Arc is CCTP-bridged to BASE before we hand it over.
//   * Fiat -> stablecoin: source NGN | GHS | GBP | EUR | USD  ->  USDC/USDT/RLUSD
//   * Stablecoin -> crypto address: POST /direct-transfers with type 'crypto'
//   * Stablecoin -> fiat / bank / mobile money: the same transfers surface
//   * Idempotency: X-Idempotency-Key header (maps 1:1 onto our leg key)
//   * Webhooks: HMAC-SHA256 over the body, in the 'flutterwave-signature' header
//
// Everything the orchestrator needs is here; the engine never imports this file
// directly — it goes through the registry.
// ============================================================

import { createHmac, timingSafeEqual } from 'crypto'
import type {
  FiatRampProvider, ChainKey, RampQuote, PayoutRecipient,
  OnrampResult, PayoutResult, NormalizedWebhook,
} from '../types'
import { getAccessToken, FLW_BASE_URL, FLW_IS_SANDBOX } from './flutterwave-auth'

// Our ChainKey -> Flutterwave's network name.
const CHAIN_TO_FLW: Partial<Record<ChainKey, string>> = {
  base:     'BASE',
  eth:      'ETHEREUM',
  matic:    'POLYGON',
  // solana handled separately if we ever need it; arc is NOT supported.
}
const FLW_TO_CHAIN: Record<string, ChainKey> = {
  BASE: 'base', ETHEREUM: 'eth', POLYGON: 'matic',
}

interface FlwRequest {
  path:   string
  method?: 'GET' | 'POST'
  body?:  unknown
  idempotencyKey?: string
  /** Sandbox only: force an outcome, e.g. 'scenario:successful' */
  scenario?: string
}

async function flw<T = any>(req: FlwRequest): Promise<T> {
  const token = await getAccessToken()
  const headers: Record<string, string> = {
    Authorization:  `Bearer ${token}`,
    'Content-Type': 'application/json',
    'X-Trace-Id':   `afrifx-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
  }
  if (req.idempotencyKey) headers['X-Idempotency-Key'] = req.idempotencyKey
  // The sandbox lets us force success/failure deterministically — invaluable
  // for exercising the orchestrator's failure paths end to end.
  if (FLW_IS_SANDBOX && req.scenario) headers['X-Scenario-Key'] = req.scenario

  const res = await fetch(`${FLW_BASE_URL}${req.path}`, {
    method:  req.method ?? 'GET',
    headers,
    body:    req.body ? JSON.stringify(req.body) : undefined,
  })

  const data: any = await res.json().catch(() => ({}))
  if (!res.ok || data?.status === 'error') {
    // Flutterwave's error shape varies: `message` can be a string OR an object
    // of field-level validation errors, and details may sit in `error`/`errors`.
    // Template-stringifying an object gives "[object Object]" and throws away
    // exactly the information we need, so serialise it properly.
    const stringify = (v: unknown): string => {
      if (v == null) return ''
      if (typeof v === 'string') return v
      try { return JSON.stringify(v) } catch { return String(v) }
    }
    const parts = [
      stringify(data?.message),
      stringify(data?.error),
      stringify(data?.errors),
    ].filter(Boolean)

    const msg = parts.length ? parts.join(' | ') : `HTTP ${res.status}`
    // Log the whole body server-side — invaluable when a provider rejects us.
    console.error('[Flutterwave] request failed', {
      path: req.path, status: res.status, body: data,
    })
    throw new Error(`Flutterwave: ${msg}`)
  }
  return data as T
}

export class FlutterwaveProvider implements FiatRampProvider {
  readonly key = 'flutterwave'

  // Chains Flutterwave settles USDC on. Arc is absent, hence the CCTP bridge.
  async supportedChains(): Promise<ChainKey[]> {
    return ['base', 'eth', 'matic']
  }

  /*
    Case A — sender pays fiat. Flutterwave converts the local currency into
    USDC and credits it to OUR Flutterwave stablecoin wallet.

    IMPORTANT: it does NOT go to a crypto address. Their documented flow is:
      step 1  fiat -> stablecoin, recipient = { wallet: {...} }
      step 2  stablecoin -> a crypto address (a SEPARATE call, type 'crypto')
    Merging the two (fiat source + crypto recipient) is rejected.

    And for AfriFX's fiat-in flow we don't want step 2 anyway: the USDC never
    needs to touch a blockchain. It lands in our Flutterwave wallet and the
    off-ramp spends straight from that balance — no gas, no bridge, cheaper and
    fewer moving parts. (The crypto path is only for usdc_in, where the user's
    USDC starts on Arc.)

    Supported source currencies: NGN, GHS, GBP, EUR, USD.
  */
  async createOnramp(params: {
    idempotencyKey: string
    senderAmount:   number
    senderCurrency: string
    receiverChain:  ChainKey
    receiverAddress: string
    method:  'bank' | 'mobile_money'
    charge:  Record<string, string>
    email?:  string
  }): Promise<OnrampResult> {
    const walletId = process.env.FLUTTERWAVE_WALLET_ID
    if (!walletId) {
      throw new Error(
        'FLUTTERWAVE_WALLET_ID is not set — the on-ramp needs a Flutterwave ' +
        'stablecoin wallet to credit the converted USDC into.')
    }

    const data = await flw({
      path:   '/direct-transfers',
      method: 'POST',
      idempotencyKey: params.idempotencyKey,
      scenario: 'scenario:successful',
      body: {
        action: 'instant',
        type:   'wallet',
        narration: 'AfriFX on-ramp',
        reference: params.idempotencyKey,
        payment_instruction: {
          source_currency: params.senderCurrency,   // NGN, GHS, GBP, EUR, USD
          amount: {
            applies_to: 'source_currency',
            value: params.senderAmount,
          },
          destination_currency: 'USDC',
          recipient: {
            wallet: { provider: 'flutterwave', identifier: walletId },
          },
        },
      },
    })

    return {
      providerRef:     data?.data?.id,
      payInstructions: data?.data ?? null,
    }
  }

  /*
    Quote for the off-ramp conversion (USDC -> destination fiat).
    Flutterwave exposes real-time FX via the transfer-rates endpoints.
  */
  async getPayoutQuote(params: {
    usdcAmount:   number
    destCurrency: string
    country:      string
  }): Promise<RampQuote> {
    const data = await flw({
      path:   '/transfer-rates',
      method: 'POST',
      body: {
        source: { currency: 'USDC', amount: params.usdcAmount },
        destination: { currency: params.destCurrency },
      },
    })

    const d = data?.data ?? {}
    const rate = Number(d.rate ?? d.exchange_rate ?? 0)
    const destAmount = Number(
      d.destination?.amount ?? d.converted_amount ?? (rate * params.usdcAmount))

    // Flutterwave returns an id + expiry for the locked rate; fall back to a
    // conservative 10-minute window if the shape differs.
    const expiresAt = d.expiry_datetime
      ? Math.floor(new Date(d.expiry_datetime).getTime() / 1000)
      : Math.floor(Date.now() / 1000) + 600

    return {
      quoteId:    d.id ?? `flw_q_${Date.now()}`,
      rate,
      expiresAt,
      usdcAmount: params.usdcAmount,
      destAmount: +destAmount.toFixed(2),
    }
  }

  /*
    Off-ramp + payout: we send USDC, Flutterwave converts and pays out the
    recipient in local currency (bank account or mobile money).

    NOTE: unlike HoneyCoin (which hands back a deposit address to send to),
    Flutterwave debits our own stablecoin wallet balance. So the "deposit
    address" we return is OUR wallet identifier — the orchestrator's bridge
    leg tops that wallet up, then this call spends from it.
  */
  async createPayout(params: {
    idempotencyKey: string
    usdcAmount:     number
    destCurrency:   string
    chain:          ChainKey
    recipient:      PayoutRecipient
  }): Promise<PayoutResult> {
    const r = params.recipient
    const [first, ...rest] = (r.name ?? '').trim().split(/\s+/)

    const recipientBlock = r.method === 'mobile_money'
      ? {
          mobile_money: {
            network: r.bank,           // operator code, e.g. MPS for M-Pesa
            phone_number: r.account,
            country_code: r.country,
          },
          name: { first: first || r.name, last: rest.join(' ') || '-' },
        }
      : {
          bank: {
            account_number: r.account,
            code:           r.bank,    // bank code from GET /banks
            country_code:   r.country,
          },
          name: { first: first || r.name, last: rest.join(' ') || '-' },
        }

    const data = await flw({
      path:   '/direct-transfers',
      method: 'POST',
      idempotencyKey: params.idempotencyKey,
      scenario: params.idempotencyKey.endsWith(':fail_payout')
        ? 'scenario:failed'
        : 'scenario:successful',
      body: {
        action: 'instant',
        type:   r.method === 'mobile_money' ? 'mobile_money' : 'bank',
        narration: r.note ?? 'AfriFX payout',
        reference: params.idempotencyKey,
        payment_instruction: {
          source_currency: 'USDC',
          amount: { applies_to: 'source_currency', value: params.usdcAmount },
          destination_currency: params.destCurrency,   // e.g. 'KES', 'NGN'
          recipient: recipientBlock,
        },
      },
    })

    const d = data?.data ?? {}
    return {
      providerRef:    d.id,
      // Flutterwave debits our stablecoin wallet — there is no per-transfer
      // deposit address. The orchestrator's bridge leg funds this wallet.
      depositAddress: process.env.FLUTTERWAVE_USDC_WALLET ?? 'flutterwave-wallet',
      depositChain:   params.chain,
      expectedAmount: params.usdcAmount,
    }
  }

  /*
    Verify + normalize a Flutterwave webhook.
    Signature: HMAC-SHA256 of the raw body, keyed on our secret hash, delivered
    in the 'flutterwave-signature' header. We NEVER trust an unverified payload:
    without this check anyone could POST us a fake "payout successful".
  */
  parseWebhook(body: unknown, headers: Record<string, string>): NormalizedWebhook {
    const secret = process.env.FLUTTERWAVE_WEBHOOK_SECRET_HASH
    const sig =
      headers['flutterwave-signature'] ??
      headers['Flutterwave-Signature'] ??
      headers['verif-hash']            // v3-style header, tolerated

    if (secret) {
      const raw = typeof body === 'string' ? body : JSON.stringify(body)
      const expected = createHmac('sha256', secret).update(raw).digest('hex')
      const ok = !!sig && safeEqual(expected, String(sig))
      if (!ok) throw new Error('Flutterwave webhook signature invalid')
    }

    const b: any = typeof body === 'string' ? JSON.parse(body) : (body ?? {})
    const d = b.data ?? b

    const status = String(d.status ?? '').toUpperCase()
    const norm: NormalizedWebhook['status'] =
      status === 'SUCCESSFUL' || status === 'COMPLETED' ? 'done'
      : status === 'FAILED' || status === 'CANCELLED'   ? 'failed'
      : 'pending'

    // We set `reference` = our idempotency key on every create call, so it
    // comes back here and tells us exactly which leg this event belongs to.
    const externalReference = d.reference ?? b.reference

    const type = String(d.type ?? '').toLowerCase()
    const leg: NormalizedWebhook['leg'] =
      type === 'crypto' ? 'onramp' : 'payout'

    return { providerRef: d.id, externalReference, leg, status: norm, detail: d }
  }

  // Backstop for the reconciler: ask Flutterwave what actually happened.
  async getStatus(ref: { idempotencyKey?: string; providerRef?: string }):
    Promise<{ status: 'pending' | 'done' | 'failed'; detail?: unknown }> {
    if (!ref.providerRef) return { status: 'pending' }
    try {
      const data = await flw({ path: `/transfers/${ref.providerRef}` })
      const s = String(data?.data?.status ?? '').toUpperCase()
      return {
        status: s === 'SUCCESSFUL' ? 'done' : s === 'FAILED' ? 'failed' : 'pending',
        detail: data?.data,
      }
    } catch {
      return { status: 'pending' }
    }
  }

  // ── Helpers the app can use for building payout forms ────
  async listBanks(countryCode: string) {
    const d = await flw({ path: `/banks?country=${encodeURIComponent(countryCode)}` })
    return d?.data ?? []
  }
  async resolveBankAccount(accountNumber: string, bankCode: string) {
    const d = await flw({
      path: '/banks/account-resolve', method: 'POST',
      body: { account_number: accountNumber, code: bankCode },
    })
    return d?.data ?? null
  }

  // Our stablecoin wallet balance — the off-ramp spends from this, so a
  // payout will fail if it runs dry. Worth surfacing on the admin dashboard.
  async walletBalance(currency = 'USDC') {
    const d = await flw({ path: `/wallets/${encodeURIComponent(currency)}/balance` })
    return d?.data ?? null
  }

  // Send stablecoin OUT to a crypto address. Not used by the fiat-in flow
  // (which keeps USDC inside Flutterwave), but needed if we ever push funds
  // on-chain — and it's the mirror of how usdc_in gets funds IN.
  async sendToAddress(params: {
    idempotencyKey: string
    amount: number
    chain:  ChainKey
    address: string
    name?:  string
  }) {
    const network = CHAIN_TO_FLW[params.chain]
    if (!network) throw new Error(`Flutterwave does not support chain '${params.chain}'`)
    const d = await flw({
      path: '/direct-transfers', method: 'POST',
      idempotencyKey: params.idempotencyKey,
      scenario: 'scenario:successful',
      body: {
        action: 'instant',
        type:   'crypto',
        narration: 'AfriFX transfer',
        reference: params.idempotencyKey,
        payment_instruction: {
          source_currency: 'USDC',
          amount: { applies_to: 'source_currency', value: params.amount },
          destination_currency: 'USDC',
          recipient: {
            crypto: { network, address: params.address },
            name: { first: params.name ?? 'AfriFX', last: '-' },
          },
        },
      },
    })
    return d?.data ?? null
  }
}

// Constant-time compare so we don't leak signature bytes via timing.
function safeEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a)
  const bb = Buffer.from(b)
  if (ba.length !== bb.length) return false
  return timingSafeEqual(ba, bb)
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/providers/flutterwave.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/transfers.ts" << 'AFX_EOF'
// ============================================================
// Cross-border transfers — the public face of the payout orchestrator.
//
//   POST /transfers            start a transfer (fiat-in or usdc-in)
//   GET  /transfers?wallet=    the sender's transfers
//   GET  /transfers/:id        one transfer + its legs (for a status page)
//   GET  /transfers/meta/banks?country=NG    bank list for payout forms
//   POST /transfers/meta/resolve-account     verify a bank account name
//
//   POST /webhooks/flutterwave  provider callbacks (signature-verified)
//
//   GET  /transfers/health     is a live provider configured? (diagnostic)
// ============================================================

import { Router } from 'express'
import { startTransfer, advanceTransfer } from '../services/ramp/engine'
import { handleProviderWebhook } from '../services/ramp/webhook'
import { getTransfer, getLegs, listTransfersBySender } from '../services/ramp/repository'
import { getProvider, listProviders } from '../services/ramp/registry'
import { flutterwaveConfigured } from '../services/ramp/providers/flutterwave-auth'
import type { SenderMode, PayoutMethod, ChainKey } from '../services/ramp/types'

const router = Router()

// The chain we settle on with the provider. Arc USDC is CCTP-bridged here.
const PAYOUT_CHAIN = (process.env.RAMP_PAYOUT_CHAIN ?? 'base') as ChainKey
const DEFAULT_PROVIDER = process.env.RAMP_PROVIDER ?? 'flutterwave'

// ── Diagnostic: is a real provider actually wired up? ──────
router.get('/health', async (_req, res) => {
  const out: any = {
    providers: listProviders(),
    flutterwaveConfigured: flutterwaveConfigured(),
    defaultProvider: DEFAULT_PROVIDER,
    payoutChain: PAYOUT_CHAIN,
    env: process.env.FLUTTERWAVE_ENV ?? 'sandbox',
    // The on-ramp credits USDC into this wallet; the off-ramp spends from it.
    walletIdSet: !!process.env.FLUTTERWAVE_WALLET_ID,
    webhookSecretSet: !!process.env.FLUTTERWAVE_WEBHOOK_SECRET_HASH,
  }

  // Best-effort balance — a dry wallet is the most likely payout failure.
  try {
    const p: any = getProvider(DEFAULT_PROVIDER)
    if (typeof p.walletBalance === 'function') {
      out.usdcBalance = await p.walletBalance('USDC')
    }
  } catch (err: any) {
    out.balanceError = err?.message
  }

  res.json(out)
})

// ── Start a transfer ───────────────────────────────────────
router.post('/', async (req, res) => {
  const {
    senderAddress, senderMode,
    sourceCurrency, sourceAmount,
    destCurrency, usdcAmount,
    recipientName, recipientMethod, recipientAccount,
    recipientBank, recipientCountry, recipientNote,
    provider,
  } = req.body

  // Validate hard — this moves real money.
  if (!senderAddress)    return res.status(400).json({ error: 'senderAddress is required' })
  if (!['fiat_in', 'usdc_in'].includes(senderMode)) {
    return res.status(400).json({ error: "senderMode must be 'fiat_in' or 'usdc_in'" })
  }
  if (!sourceCurrency || !sourceAmount || Number(sourceAmount) <= 0) {
    return res.status(400).json({ error: 'sourceCurrency and a positive sourceAmount are required' })
  }
  if (!destCurrency) return res.status(400).json({ error: 'destCurrency is required' })
  if (!recipientName || !recipientAccount || !recipientBank || !recipientCountry) {
    return res.status(400).json({
      error: 'Recipient name, account, bank/provider and country are all required',
    })
  }
  if (!['bank', 'mobile_money'].includes(recipientMethod)) {
    return res.status(400).json({ error: "recipientMethod must be 'bank' or 'mobile_money'" })
  }

  const key = provider ?? DEFAULT_PROVIDER
  try { getProvider(key) } catch {
    return res.status(503).json({
      error: `Payment provider '${key}' is not available. ` +
             `Configured providers: ${listProviders().join(', ') || 'none'}.`,
    })
  }

  try {
    // usdc_in transfers start from Arc, so they need the CCTP bridge.
    // fiat_in settles straight onto the payout chain, so no bridge.
    const needsBridge = senderMode === 'usdc_in' && PAYOUT_CHAIN !== 'arc'

    const id = await startTransfer({
      senderAddress,
      senderMode:       senderMode as SenderMode,
      sourceCurrency,
      sourceAmount:     Number(sourceAmount),
      destCurrency,
      usdcAmount:       usdcAmount != null ? Number(usdcAmount) : undefined,
      recipientName,
      recipientMethod:  recipientMethod as PayoutMethod,
      recipientAccount,
      recipientBank,
      recipientCountry,
      recipientNote,
      provider:         key,
      payoutChain:      PAYOUT_CHAIN,
      needsBridge,
    })

    // Kick the state machine immediately; the reconciler is the backstop.
    advanceTransfer(id).catch(err =>
      console.error('[Transfers] advance failed:', err?.message))

    res.status(201).json({ id, status: 'in_progress' })
  } catch (err: any) {
    console.error('[Transfers] start failed:', err?.message)
    res.status(500).json({ error: err.message })
  }
})

// ── The sender's transfers ─────────────────────────────────
router.get('/', async (req, res) => {
  const wallet = req.query.wallet as string | undefined
  if (!wallet) return res.status(400).json({ error: 'wallet is required' })
  try {
    res.json(await listTransfersBySender(wallet))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── One transfer + its legs (status page) ──────────────────
router.get('/:id', async (req, res) => {
  try {
    const t = await getTransfer(req.params.id)
    if (!t) return res.status(404).json({ error: 'Transfer not found' })
    res.json({ transfer: t, legs: await getLegs(req.params.id) })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Payout-form helpers ────────────────────────────────────
router.get('/meta/banks', async (req, res) => {
  const country = (req.query.country as string) ?? 'NG'
  try {
    const p: any = getProvider(DEFAULT_PROVIDER)
    if (typeof p.listBanks !== 'function') {
      return res.status(501).json({ error: 'This provider cannot list banks' })
    }
    res.json(await p.listBanks(country))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.post('/meta/resolve-account', async (req, res) => {
  const { accountNumber, bankCode } = req.body
  if (!accountNumber || !bankCode) {
    return res.status(400).json({ error: 'accountNumber and bankCode are required' })
  }
  try {
    const p: any = getProvider(DEFAULT_PROVIDER)
    if (typeof p.resolveBankAccount !== 'function') {
      return res.status(501).json({ error: 'This provider cannot resolve accounts' })
    }
    res.json(await p.resolveBankAccount(accountNumber, bankCode))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router

// ══════════════════════════════════════════════════════════
// Webhook router — mounted separately at /webhooks
// ══════════════════════════════════════════════════════════
export const webhookRouter = Router()

webhookRouter.post('/flutterwave', async (req: any, res) => {
  try {
    // Verify against the RAW body bytes the provider actually signed — see the
    // express.json({ verify }) hook in index.ts. Falling back to the parsed
    // body only if rawBody is somehow unavailable.
    const payload = req.rawBody ?? req.body

    // parseWebhook VERIFIES the HMAC signature and throws if it's forged.
    // We answer 200 even on a handled failure so the provider doesn't retry
    // forever, but a BAD SIGNATURE gets a 401 — that's an attack, not an event.
    const out = await handleProviderWebhook(
      'flutterwave',
      payload,
      req.headers as Record<string, string>,
    )
    res.status(200).json({ received: true, ...out })
  } catch (err: any) {
    if (/signature/i.test(err?.message ?? '')) {
      console.warn('[Webhook] REJECTED Flutterwave webhook — bad signature')
      return res.status(401).json({ error: 'Invalid signature' })
    }
    console.error('[Webhook] Flutterwave error:', err?.message)
    res.status(200).json({ received: true, error: err?.message })
  }
})
AFX_EOF
echo "  afrifx-api/src/routes/transfers.ts"

echo ""
echo "Done. Now:"
echo "  cd afrifx-api && npx tsc --noEmit"
echo "  cd .. && git add -A && git commit -m 'Fix: Flutterwave on-ramp payload + readable errors'"
echo "  git push"
echo ""
echo "  ===== THEN, IN RENDER =====" 
echo "  Add:  FLUTTERWAVE_WALLET_ID=<your stablecoin wallet identifier>"
echo ""
echo "  Find it in the Flutterwave dashboard (the stablecoin/USDC wallet), or"
echo "  it's returned when a wallet is created. In their docs' example it's the"
echo "  'identifier' field, e.g. \"6312655\"."
echo ""
echo "  ===== THEN RETRY ====="
echo "  curl https://afrifx-api.onrender.com/transfers/health"
echo "     -> check walletIdSet: true, and see usdcBalance"
echo ""
echo "  Then POST /transfers again. If it fails, the error will now be READABLE"
echo "  -- paste it and we'll know exactly what Flutterwave wants."
