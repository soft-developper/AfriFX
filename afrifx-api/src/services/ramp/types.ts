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

  /*
    COMPARISON FIELDS.

    A user choosing between providers needs more than a rate. The headline rate
    can be the best while the NET amount received is the worst, once fees are
    applied, so fees are surfaced separately rather than silently folded in.

    All optional so existing providers keep compiling; the comparison UI shows
    "not disclosed" where a provider doesn't report one.
  */
  /** Provider fee, expressed in the DESTINATION currency. */
  feeDest?:    number
  /** Provider fee taken from the USDC side, if it works that way instead. */
  feeUsdc?:    number
  /** What the recipient actually receives after fees, in dest currency. */
  netDest?:    number
  /** Typical delivery time in seconds, for an honest speed comparison. */
  etaSeconds?: number
  /** Free-text delivery estimate when a number would be misleading. */
  etaLabel?:   string
}

/*
  What a provider can actually do. Declared rather than discovered, so we never
  ask a provider for a quote it cannot serve, and never show a user an option
  that will fail at execution time.
*/
export interface ProviderCapabilities {
  key:          string
  displayName:  string
  /** ISO-2 country codes this provider can pay out in. */
  countries:    string[]
  /** Destination currencies supported, e.g. ['NGN','KES']. */
  currencies:   string[]
  methods:      PayoutMethod[]
  /** False when credentials are missing, so it's listed but not offered. */
  configured:   boolean
  /** Optional note shown in the UI, e.g. 'Bank transfers only in Nigeria'. */
  note?:        string
}

/*
  One provider's answer in a comparison. Deliberately carries the ERROR case:
  if a provider times out or rejects the pair, the user should see "unavailable"
  rather than that provider silently vanishing from the list.
*/
export interface ProviderQuote {
  provider:    string
  displayName: string
  ok:          boolean
  quote?:      RampQuote
  error?:      string
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
  externalReference?: string   // our idempotency key, how we find the transfer/leg
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
