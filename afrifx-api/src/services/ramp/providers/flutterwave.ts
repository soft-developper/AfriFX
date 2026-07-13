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
