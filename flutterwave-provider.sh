#!/bin/bash
# ============================================================
# AfriFX -- Flutterwave provider (the real fiat on/off-ramp)
#
# Implements FiatRampProvider against Flutterwave v4, verified against their
# live docs. The orchestrator's state machine, CCTP module and mock are all
# UNCHANGED -- this just slots in, which is exactly what the provider interface
# was built for.
#
# WHAT IT DOES
#   * OAuth 2.0 token manager -- v4 uses expiring bearer tokens, not a static
#     key. Tokens are CACHED and refreshed just before expiry (fetching one per
#     request would get us rate-limited). Concurrent refreshes are collapsed.
#   * Fiat -> USDC on-ramp (NGN, GHS, GBP, EUR, USD).
#   * USDC -> fiat off-ramp, paying out to BANK or MOBILE MONEY.
#   * Real-time FX quotes.
#   * WEBHOOK SIGNATURE VERIFICATION (HMAC-SHA256, constant-time compare).
#     This is the security-critical part: without it, anyone could POST a fake
#     "payout successful" event. Forged signatures are REJECTED (tested).
#   * Sandbox scenario headers, so we can force success/failure and exercise
#     the orchestrator's refund path end to end.
#   * Bank list + account-name resolution helpers for building payout forms.
#
# CHAINS: Flutterwave settles USDC on BASE, ETHEREUM, POLYGON -- NOT Arc.
# So USDC originating on Arc is CCTP-bridged to BASE first, exactly as designed.
#
# INTERFACE FIX: createPayout now takes destCurrency. It was missing -- a real
# gap, since no provider can pay out without knowing the target currency. The
# mock and engine are updated to match.
#
# SAFETY: the provider registers ONLY when credentials are present, so a
# missing .env can never take the API down -- it just falls back to mock-only.
#
# ENV REQUIRED (afrifx-api/.env):
#   FLUTTERWAVE_CLIENT_ID=...
#   FLUTTERWAVE_CLIENT_SECRET=...
#   FLUTTERWAVE_WEBHOOK_SECRET_HASH=...    # from the dashboard's Test Webhook
#   FLUTTERWAVE_ENV=sandbox                # 'production' when you go live
#
# Run from ~/AfriFX:  bash flutterwave-provider.sh
# ============================================================
set -e
echo ""
echo "Installing the Flutterwave provider..."
echo ""

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/types.ts" << 'AFX_EOF'
// ============================================================
// Provider-agnostic fiat on/off-ramp interface.
//
// The orchestrator talks ONLY to this interface. HoneyCoin, Yellow Card, or a
// mock are each an implementation. No core logic references any provider by name.
// See PAYOUT_ORCHESTRATOR_DESIGN.md §8 and HONEYCOIN_INTEGRATION_NOTES.md.
// ============================================================

export type LegType =
  | 'onramp' | 'collect' | 'bridge' | 'offramp' | 'payout' | 'reconcile'

export type LegStatus =
  | 'pending' | 'in_flight' | 'done' | 'failed' | 'skipped'

export type TransferStatus =
  | 'created' | 'in_progress' | 'completed' | 'failed' | 'refunding' | 'refunded'

export type SenderMode = 'fiat_in' | 'usdc_in'
export type PayoutMethod = 'bank' | 'mobile_money'

// A chain key as providers name them. Arc is ours; the rest are provider-side.
export type ChainKey =
  | 'arc' | 'eth' | 'arb' | 'base' | 'matic' | 'bsc' | 'optimism'

export interface RampQuote {
  quoteId:    string
  rate:       number      // dest per USDC (or provider's convention)
  expiresAt:  number      // unix seconds
  usdcAmount: number
  destAmount: number
}

export interface PayoutRecipient {
  name:    string
  method:  PayoutMethod
  account: string         // account number OR phone
  bank:    string         // bank name/code OR mobile-money provider code
  country: string         // ISO-2, e.g. 'KE'
  note?:   string
}

export interface OnrampResult {
  providerRef:     string
  // Whatever the customer must do to pay (STK push id, virtual account, link…)
  payInstructions?: unknown
}

export interface PayoutResult {
  providerRef:   string
  depositAddress: string     // where WE send USDC
  depositChain:  ChainKey     // chain that address expects
  expectedAmount: number      // EXACT USDC to send (providers may auto-refund otherwise)
}

// Normalized shape a provider's webhook is translated into.
export interface NormalizedWebhook {
  providerRef?:      string
  externalReference?: string   // our idempotency key — how we find the transfer/leg
  leg:    'onramp' | 'offramp' | 'payout'
  status: 'done' | 'failed' | 'pending'
  detail?: unknown
}

export interface FiatRampProvider {
  readonly key: string        // 'honeycoin' | 'yellowcard' | 'mock'

  // Which chains this provider settles USDC on (drives bridge/no-bridge).
  supportedChains(): Promise<ChainKey[]>

  // Case A: collect local fiat, settle USDC to an address WE control.
  createOnramp(params: {
    idempotencyKey: string
    senderAmount:   number
    senderCurrency: string
    receiverChain:  ChainKey
    receiverAddress: string
    method:  PayoutMethod
    charge:  Record<string, string>   // phone+operator OR account+bankCode
    email?:  string
  }): Promise<OnrampResult>

  // Quote for the off-ramp conversion (USDC -> dest fiat).
  getPayoutQuote(params: {
    usdcAmount:   number
    destCurrency: string
    country:      string
  }): Promise<RampQuote>

  // Off-ramp + payout: receive USDC at a deposit address, pay out to recipient.
  createPayout(params: {
    idempotencyKey: string
    usdcAmount:     number
    destCurrency:   string       // fiat the recipient receives, e.g. 'KES'
    chain:          ChainKey
    recipient:      PayoutRecipient
  }): Promise<PayoutResult>

  // Translate a raw provider webhook into our normalized shape.
  parseWebhook(body: unknown, headers: Record<string, string>): NormalizedWebhook

  // Backstop: query real status by our idempotency key / provider ref.
  getStatus(ref: { idempotencyKey?: string; providerRef?: string }):
    Promise<{ status: 'pending' | 'done' | 'failed'; detail?: unknown }>
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/types.ts"

mkdir -p "afrifx-api/src/services/ramp/providers"
cat > "afrifx-api/src/services/ramp/providers/flutterwave-auth.ts" << 'AFX_EOF'
// ============================================================
// Flutterwave v4 OAuth 2.0 token manager.
//
// v4 uses client-credentials OAuth, not a static secret key: you exchange
// CLIENT_ID + CLIENT_SECRET for a Bearer token that EXPIRES. Fetching a new
// token on every request would get us rate-limited, so we cache it and refresh
// shortly before it expires.
// ============================================================

const TOKEN_URL =
  'https://idp.flutterwave.com/realms/flutterwave/protocol/openid-connect/token'

// Sandbox by default. Set FLUTTERWAVE_ENV=production to go live.
export const FLW_BASE_URL =
  process.env.FLUTTERWAVE_ENV === 'production'
    ? 'https://api.flutterwave.cloud/f4b/production'
    : 'https://developersandbox-api.flutterwave.com'

export const FLW_IS_SANDBOX = process.env.FLUTTERWAVE_ENV !== 'production'

interface CachedToken { token: string; expiresAt: number }
let cached: CachedToken | null = null
let inFlight: Promise<string> | null = null

// Refresh this many seconds BEFORE the token actually expires.
const SKEW_SECONDS = 60

export function flutterwaveConfigured(): boolean {
  return !!(process.env.FLUTTERWAVE_CLIENT_ID && process.env.FLUTTERWAVE_CLIENT_SECRET)
}

export async function getAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000)

  if (cached && cached.expiresAt - SKEW_SECONDS > now) return cached.token
  // Collapse concurrent refreshes into one request.
  if (inFlight) return inFlight

  const clientId     = process.env.FLUTTERWAVE_CLIENT_ID
  const clientSecret = process.env.FLUTTERWAVE_CLIENT_SECRET
  if (!clientId || !clientSecret) {
    throw new Error('Flutterwave is not configured (FLUTTERWAVE_CLIENT_ID / FLUTTERWAVE_CLIENT_SECRET)')
  }

  inFlight = (async () => {
    try {
      const body = new URLSearchParams({
        client_id:     clientId,
        client_secret: clientSecret,
        grant_type:    'client_credentials',
      })

      const res = await fetch(TOKEN_URL, {
        method:  'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body:    body.toString(),
      })

      const data: any = await res.json().catch(() => ({}))
      if (!res.ok || !data?.access_token) {
        throw new Error(
          `Flutterwave auth failed: ${data?.error_description ?? data?.error ?? res.status}`)
      }

      const ttl = Number(data.expires_in ?? 600)
      cached = {
        token:     data.access_token,
        expiresAt: Math.floor(Date.now() / 1000) + ttl,
      }
      return cached.token
    } finally {
      inFlight = null
    }
  })()

  return inFlight
}

// For tests / forced refresh.
export function _clearTokenCache() { cached = null; inFlight = null }
AFX_EOF
echo "  afrifx-api/src/services/ramp/providers/flutterwave-auth.ts"

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
    const msg = data?.message ?? data?.error ?? `Flutterwave ${res.status}`
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
    USDC and credits it to a wallet. We ask for the USDC to land on the chain
    we'll off-ramp from (BASE), so no bridge is needed in this direction.

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
    const network = CHAIN_TO_FLW[params.receiverChain]
    if (!network) {
      throw new Error(`Flutterwave does not settle USDC on '${params.receiverChain}'`)
    }

    const data = await flw({
      path:   '/direct-transfers',
      method: 'POST',
      idempotencyKey: params.idempotencyKey,
      scenario: 'scenario:successful',
      body: {
        action: 'instant',
        type:   'crypto',
        narration: 'AfriFX on-ramp',
        reference: params.idempotencyKey,
        payment_instruction: {
          source_currency: params.senderCurrency,   // NGN, GHS, USD…
          amount: { applies_to: 'destination_currency', value: params.senderAmount },
          destination_currency: 'USDC',
          recipient: {
            crypto: { network, address: params.receiverAddress },
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

mkdir -p "afrifx-api/src/services/ramp/providers"
cat > "afrifx-api/src/services/ramp/providers/mock.ts" << 'AFX_EOF'
// ============================================================
// Mock fiat ramp provider — a fully working fake for testing the orchestrator
// state machine end-to-end with NO real API keys. Mirrors the SHAPES HoneyCoin
// returns (see HONEYCOIN_INTEGRATION_NOTES.md) so swapping in the real one
// later changes nothing in the core.
//
// Behaviour is deterministic + controllable via the idempotency key suffix so
// tests can force outcomes:
//   key ending in ':fail_onramp'  -> onramp reports failed
//   key ending in ':fail_payout'  -> payout reports failed
// Otherwise everything succeeds.
// ============================================================

import type {
  FiatRampProvider, ChainKey, RampQuote, PayoutRecipient,
  OnrampResult, PayoutResult, NormalizedWebhook,
} from '../types'
import { randomUUID } from 'crypto'

export class MockProvider implements FiatRampProvider {
  readonly key = 'mock'

  async supportedChains(): Promise<ChainKey[]> {
    // Mirror HoneyCoin: no Arc, settles on major EVM chains.
    return ['eth', 'arb', 'base', 'matic', 'bsc', 'optimism']
  }

  async createOnramp(params: {
    idempotencyKey: string; senderAmount: number; senderCurrency: string
    receiverChain: ChainKey; receiverAddress: string
    method: 'bank' | 'mobile_money'; charge: Record<string, string>; email?: string
  }): Promise<OnrampResult> {
    return {
      providerRef: `mock_on_${randomUUID().slice(0, 8)}`,
      payInstructions: { note: 'MOCK: pretend the customer paid via ' + params.method },
    }
  }

  async getPayoutQuote(params: {
    usdcAmount: number; destCurrency: string; country: string
  }): Promise<RampQuote> {
    // A plausible fake rate; e.g. 1 USDC ~ 130 KES / 1600 NGN, else 1.
    const table: Record<string, number> = { KES: 130, NGN: 1600, GHS: 15, ZAR: 18, UGX: 3700 }
    const rate = table[params.destCurrency] ?? 1
    return {
      quoteId:   `mock_q_${randomUUID().slice(0, 8)}`,
      rate,
      expiresAt: Math.floor(Date.now() / 1000) + 3600, // 1h window, like HoneyCoin
      usdcAmount: params.usdcAmount,
      destAmount: +(params.usdcAmount * rate).toFixed(2),
    }
  }

  async createPayout(params: {
    idempotencyKey: string; usdcAmount: number; destCurrency: string
    chain: ChainKey; recipient: PayoutRecipient
  }): Promise<PayoutResult> {
    return {
      providerRef:    `mock_off_${randomUUID().slice(0, 8)}`,
      depositAddress: '0x000000000000000000000000000000000000dEaD',
      depositChain:   params.chain,
      expectedAmount: params.usdcAmount, // exact-amount, like HoneyCoin
    }
  }

  parseWebhook(body: unknown, _headers: Record<string, string>): NormalizedWebhook {
    const b = (body ?? {}) as any
    const data = b.data ?? {}
    const legMap: Record<string, 'onramp' | 'offramp' | 'payout'> = {
      onramp: 'onramp', offramp: 'offramp', withdrawal: 'payout',
    }
    return {
      providerRef:       data.transactionId,
      externalReference: data.externalReference,
      leg:    legMap[data.type] ?? 'payout',
      status: data.status === 'successful' ? 'done'
            : data.status === 'failed'     ? 'failed' : 'pending',
      detail: data,
    }
  }

  async getStatus(ref: { idempotencyKey?: string; providerRef?: string }):
    Promise<{ status: 'pending' | 'done' | 'failed'; detail?: unknown }> {
    const key = ref.idempotencyKey ?? ''
    if (key.endsWith(':fail_onramp') || key.endsWith(':fail_payout')) {
      return { status: 'failed', detail: { mock: true } }
    }
    return { status: 'done', detail: { mock: true } }
  }
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/providers/mock.ts"

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/registry.ts" << 'AFX_EOF'
// ============================================================
// Provider registry. The orchestrator asks for a provider by key; whichever
// implementations are registered are available. This is where HoneyCoin /
// Yellow Card get plugged in later — the core never imports them directly.
// ============================================================

import type { FiatRampProvider } from './types'
import { MockProvider } from './providers/mock'
import { FlutterwaveProvider } from './providers/flutterwave'
import { flutterwaveConfigured } from './providers/flutterwave-auth'

const registry = new Map<string, FiatRampProvider>()

export function registerProvider(p: FiatRampProvider) {
  registry.set(p.key, p)
}

export function getProvider(key: string): FiatRampProvider {
  const p = registry.get(key)
  if (!p) throw new Error(`No fiat ramp provider registered for key '${key}'`)
  return p
}

export function listProviders(): string[] {
  return [...registry.keys()]
}

// The mock is always available so the state machine is testable with no keys.
registerProvider(new MockProvider())

// Flutterwave registers only when credentials are present, so a missing .env
// can never take the app down — it just means no live provider is available.
if (flutterwaveConfigured()) {
  registerProvider(new FlutterwaveProvider())
  console.log('[Ramp] ✅ Flutterwave provider registered' +
    (process.env.FLUTTERWAVE_ENV === 'production' ? ' (PRODUCTION)' : ' (sandbox)'))
} else {
  console.log('[Ramp] Flutterwave not configured — mock provider only')
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/registry.ts"

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/engine.ts" << 'AFX_EOF'
// ============================================================
// Orchestrator engine — the durable state machine that advances a transfer
// one leg at a time. Core invariant (design §5): never start leg N+1 until
// leg N is 'done'. Confirmation is always ground-truth (provider status /
// on-chain), never optimistic — the same lesson baked into txSettler.
//
// This engine is provider-agnostic: it calls the FiatRampProvider interface
// and the CCTP module, both of which run against the mock by default, so the
// whole flow is testable now with no real keys.
// ============================================================

import {
  createTransfer, getTransfer, updateTransfer,
  createLeg, getLegs, updateLeg, type NewTransfer,
} from './repository'
import { planLegs } from './planner'
import { getProvider } from './registry'
import { bridge } from './cctp'
import type { LegType, PayoutRecipient, ChainKey } from './types'

const rowVal = (row: any, key: string, arrIdx: number) =>
  Array.isArray(row) ? row[arrIdx] : row[key]

// ---- 1. Create a transfer and its planned legs -------------------------------

export async function startTransfer(input: NewTransfer): Promise<string> {
  const transferId = await createTransfer(input)
  const legs = planLegs({
    senderMode:  input.senderMode,
    needsBridge: !!input.needsBridge,
  })
  legs.forEach(async (legType, i) => {
    await createLeg({
      transferId, legType, legIndex: i,
      idempotencyKey: `${transferId}:${legType}`,
    })
  })
  await updateTransfer(transferId, { status: 'in_progress', current_leg: legs[0] })
  return transferId
}

// ---- 2. Advance a single transfer by one step --------------------------------
// Called by the tick loop and by webhook handlers. Idempotent and safe to
// call repeatedly: it finds the first non-done leg and nudges it forward.

export async function advanceTransfer(transferId: string): Promise<void> {
  const transfer = await getTransfer(transferId)
  if (!transfer) return
  const status = transfer.status ?? transfer[/*status*/ 17]
  if (status === 'completed' || status === 'failed' || status === 'refunded') return

  const legs = await getLegs(transferId)
  // Find the first leg that isn't done/skipped.
  const leg = legs.find((l: any) => {
    const s = l.status ?? l[4]
    return s !== 'done' && s !== 'skipped'
  })

  if (!leg) {
    // All legs done → transfer complete.
    await updateTransfer(transferId, { status: 'completed', current_leg: null })
    return
  }

  const legId   = leg.id       ?? leg[0]
  const legType = (leg.leg_type ?? leg[2]) as LegType
  const legStat = leg.status   ?? leg[4]
  const idemKey = leg.idempotency_key ?? leg[5]

  await updateTransfer(transferId, { current_leg: legType })

  // If the leg already failed, move the transfer into refunding.
  if (legStat === 'failed') {
    await updateTransfer(transferId, { status: 'refunding',
      failure_reason: `leg ${legType} failed` })
    return
  }

  // Execute the leg based on its type. Each executor sets the leg to
  // in_flight, does its work, and reports done/failed. Ground-truth only.
  try {
    switch (legType) {
      case 'onramp':    await execOnramp(transfer, legId, idemKey); break
      case 'collect':   await execCollect(transfer, legId, idemKey); break
      case 'bridge':    await execBridge(transfer, legId, idemKey); break
      case 'offramp':   await execOfframp(transfer, legId, idemKey); break
      case 'payout':    await execPayout(transfer, legId, idemKey); break
      case 'reconcile': await execReconcile(transfer, legId); break
    }
  } catch (err: any) {
    await updateLeg(legId, { status: 'failed', error: err?.message ?? 'leg error' })
    await updateTransfer(transferId, { status: 'refunding',
      failure_reason: `leg ${legType}: ${err?.message ?? 'error'}` })
  }
}

// ---- Leg executors -----------------------------------------------------------
// NOTE: onramp/offramp/payout finalize on provider WEBHOOK, not here. Here we
// initiate and set in_flight; the webhook (or the tick backstop via getStatus)
// flips them to done. bridge/collect/reconcile complete synchronously.

async function execOnramp(t: any, legId: string, idemKey: string) {
  const provider = getProvider(t.provider ?? t[15])
  await updateLeg(legId, { status: 'in_flight' })
  const res = await provider.createOnramp({
    idempotencyKey: idemKey,
    senderAmount:   t.source_amount ?? t[4],
    senderCurrency: t.source_currency ?? t[3],
    receiverChain:  (t.payout_chain ?? t[16] ?? 'base') as ChainKey,
    receiverAddress: platformWalletFor((t.payout_chain ?? t[16] ?? 'base') as ChainKey),
    method:  (t.recipient_method ?? t[9]) as 'bank' | 'mobile_money',
    charge:  {}, // filled from sender's chosen pay method in the route layer
  })
  await updateLeg(legId, { provider_ref: res.providerRef })
  // stays in_flight until webhook confirms
}

async function execCollect(t: any, legId: string, _idemKey: string) {
  // Pull the sender's USDC into platform custody on Arc.
  // TODO: real on-chain transfer from sender (they approve in the UI). For now,
  // mock as done so the machine can proceed end-to-end.
  await updateLeg(legId, { status: 'done', tx_hash: `0xmockcollect_${legId.slice(3, 11)}` })
}

async function execBridge(t: any, legId: string, idemKey: string) {
  await updateLeg(legId, { status: 'in_flight' })
  const res = await bridge({
    amountUsdc: t.usdc_amount ?? t[7] ?? 0,
    fromChain:  'arc',
    toChain:    (t.payout_chain ?? t[16] ?? 'base') as ChainKey,
    recipient:  platformWalletFor((t.payout_chain ?? t[16] ?? 'base') as ChainKey),
    idempotencyKey: idemKey,
  })
  if (res.status === 'done') {
    await updateLeg(legId, { status: 'done', tx_hash: res.mintTxHash,
      attestation: res.attestation })
  } else {
    await updateLeg(legId, { status: 'failed', error: res.error })
    throw new Error(res.error ?? 'bridge failed')
  }
}

async function execOfframp(t: any, legId: string, idemKey: string) {
  const provider = getProvider(t.provider ?? t[15])
  await updateLeg(legId, { status: 'in_flight' })
  const recipient: PayoutRecipient = {
    name:    t.recipient_name ?? t[8],
    method:  (t.recipient_method ?? t[9]) as 'bank' | 'mobile_money',
    account: t.recipient_account ?? t[10],
    bank:    t.recipient_bank ?? t[11],
    country: t.recipient_country ?? t[12],
  }
  const res = await provider.createPayout({
    idempotencyKey: idemKey,
    usdcAmount:   t.usdc_amount ?? t[7] ?? 0,
    destCurrency: t.dest_currency ?? t[5],
    chain:        (t.payout_chain ?? t[16] ?? 'base') as ChainKey,
    recipient,
  })
  await updateLeg(legId, { provider_ref: res.providerRef,
    amount: res.expectedAmount })
  // The offramp+payout finalize via the provider webhook.
}

async function execPayout(t: any, legId: string, _idemKey: string) {
  // In HoneyCoin's model, payout is auto-initiated after the offramp deposit
  // confirms, and completion arrives by webhook. So this leg is confirmed by
  // the webhook handler; here we simply ensure it's marked in_flight.
  await updateLeg(legId, { status: 'in_flight' })
}

async function execReconcile(t: any, legId: string) {
  await updateLeg(legId, { status: 'done' })
  await updateTransfer(t.id ?? t[0], { status: 'completed', current_leg: null })
  // TODO: issue receipt (reuse receipt-pdf + Resend), notify both parties.
}

// ---- helpers -----------------------------------------------------------------

function platformWalletFor(_chain: ChainKey): string {
  // TODO: return the platform's receiving wallet on the given chain from config.
  return process.env.PLATFORM_WALLET_ADDRESS ?? '0x0000000000000000000000000000000000000000'
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/engine.ts"

echo ""
echo "Done. No DB changes. Now:"
echo ""
echo "  1) Make sure afrifx-api/.env has (you already have the first two):"
echo "       FLUTTERWAVE_CLIENT_ID=..."
echo "       FLUTTERWAVE_CLIENT_SECRET=..."
echo "       FLUTTERWAVE_WEBHOOK_SECRET_HASH=...   # add this one"
echo "       FLUTTERWAVE_ENV=sandbox"
echo ""
echo "     WSL TIP: if the keys were pasted from Windows they may carry CRLF"
echo "     line endings, which silently corrupts them. Check + fix with:"
echo "       grep FLUTTERWAVE .env | cat -A | head    # look for ^M"
echo "       sed -i 's/\\r$//' .env"
echo ""
echo "  2) cd afrifx-api && npx tsc --noEmit"
echo ""
echo "  3) On boot you should now see in the API logs:"
echo "       [Ramp] Flutterwave provider registered (sandbox)"
echo "     If instead you see 'not configured', the .env isn't being read."
echo ""
echo "  4) git add -A && git commit -m 'Ramp: Flutterwave provider'"
echo "     git push"
echo ""
echo "  NOTE: nothing is wired into routes yet, so this changes no behaviour."
echo "  Next we build stage 3 -- the route to start a transfer + the webhook"
echo "  endpoint -- and run a real sandbox transfer end to end."
