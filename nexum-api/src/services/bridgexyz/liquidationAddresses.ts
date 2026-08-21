// ============================================================
// Bridge.xyz liquidation-address operations (Phase 5 — off-ramp).
//
// A Liquidation Address is a PERMANENT on-chain address that auto-converts any
// crypto sent to it into fiat and forwards it to a registered External Account.
// This is the off-ramp: user sends USDC (on Base) to the liquidation address;
// Bridge drains it to the user's bank.
//
// Shapes taken verbatim from Bridge's official docs — the offramp guide
// (apidocs.bridge.xyz/get-started/guides/move-money/offramp_liquidation) and
// the OpenAPI for POST /v0/customers/{customerID}/liquidation_addresses:
//   Request (fiat destination):
//     { currency:'usdc', chain:'base',
//       external_account_id, destination_payment_rail:'ach'|'wire'|'sepa'|'spei',
//       destination_currency:'usd'|'eur'|'mxn',
//       destination_ach_reference | destination_wire_message |
//       destination_sepa_reference | destination_spei_reference,
//       return_address }                         ← where failed drains come back
//   Response: { id, address (the on-chain deposit address), state:'active', … }
//
//   Drains (offramp equivalent of a VA's /history):
//     GET /v0/customers/{customerId}/liquidation_addresses/{id}/drains
//     -> [{ id, amount, currency, state, destination:{…}, destination_tx_hash,
//           deposit_tx_hash, created_at }]
//     state: funds_received -> payment_submitted -> payment_processed, plus
//            in_review | undeliverable | returned | refunded | error | canceled.
//
// ⚠ SANDBOX: like virtual accounts, the Bridge sandbox does not move real money
// and won't fire drain webhooks — creating a liquidation address proves the
// request/response SCHEMA; a real drain is a production test. The drain state
// machine is covered by unit tests and lights up on a real send.
// ============================================================

import { bridgeFetch } from './client'

/** Source stablecoin Bridge accepts on a liquidation address. We use usdc. */
export type LiquidationSourceCurrency = 'usdc' | 'usdt' | 'usdb' | 'pyusd' | 'eurc'

/** Source chain. We off-ramp from Base (Circle wallet's USDC on Base). */
export type LiquidationSourceChain = string

/** Rail-specific reference fields — exactly one applies per destination rail. */
export interface DestinationReferences {
  destinationAchReference?:  string   // ACH:  <=10 chars, A-Za-z0-9 + spaces
  destinationWireMessage?:   string   // Wire: <=256 chars (Fedwire 4x35)
  destinationSepaReference?: string   // SEPA: 6-140 chars, restricted charset
  destinationSpeiReference?: string   // SPEI: <=40 chars, alnum + space
}

export interface CreateLiquidationAddressParams {
  customerId:          string
  sourceCurrency:      LiquidationSourceCurrency   // 'usdc'
  sourceChain:         LiquidationSourceChain      // 'base'
  externalAccountId:   string
  destinationPaymentRail: string                   // 'ach' | 'wire' | 'sepa' | 'spei'
  destinationCurrency: string                      // 'usd' | 'eur' | 'mxn'
  references?:         DestinationReferences
  /** Where Bridge returns funds if a drain fails — the user's own wallet. */
  returnAddress:       string
  /** '0' at launch. Base-100 percentage as a string per Bridge's API. */
  developerFeePercent?: string
  idempotencyKey:      string
}

export interface LiquidationAddressResponse {
  id:                     string
  chain:                  string
  address:                string   // the on-chain address to send USDC to
  currency:               string
  customer_id:            string
  external_account_id?:   string
  destination_payment_rail?: string
  destination_currency?:  string
  destination_ach_reference?:  string
  destination_wire_message?:   string
  destination_sepa_reference?: string
  destination_spei_reference?: string
  return_address?:        string
  state:                  string   // 'active' | 'deactivated'
  created_at?:            string
  updated_at?:            string
  [key: string]:          unknown
}

/**
 * Create a liquidation address pointing at a registered external bank account.
 * `idempotencyKey` must be stable per (account, currency) so a retry can't mint
 * a second address. `returnAddress` is REQUIRED here (the docs flag it as "very
 * important") — we always pass the user's own wallet so a failed drain returns
 * to them rather than being stranded.
 */
export async function createLiquidationAddress(
  p: CreateLiquidationAddressParams,
): Promise<LiquidationAddressResponse> {
  const body: Record<string, unknown> = {
    currency:               p.sourceCurrency,
    chain:                  p.sourceChain,
    external_account_id:    p.externalAccountId,
    destination_payment_rail: p.destinationPaymentRail,
    destination_currency:   p.destinationCurrency,
    return_address:         p.returnAddress,
    developer_fee_percent:  p.developerFeePercent ?? '0',
  }
  // Attach only the reference that matches the rail; Bridge validates each
  // one's format and rejects the wrong field for a rail.
  const r = p.references ?? {}
  if (r.destinationAchReference)  body.destination_ach_reference  = r.destinationAchReference
  if (r.destinationWireMessage)   body.destination_wire_message   = r.destinationWireMessage
  if (r.destinationSepaReference) body.destination_sepa_reference = r.destinationSepaReference
  if (r.destinationSpeiReference) body.destination_spei_reference = r.destinationSpeiReference

  return bridgeFetch<LiquidationAddressResponse>(
    `customers/${p.customerId}/liquidation_addresses`,
    { method: 'POST', idempotencyKey: p.idempotencyKey, body },
  )
}

/** Fetch a single liquidation address by id. */
export async function getLiquidationAddress(
  customerId: string, liquidationAddressId: string,
): Promise<LiquidationAddressResponse> {
  return bridgeFetch<LiquidationAddressResponse>(
    `customers/${customerId}/liquidation_addresses/${liquidationAddressId}`,
    { method: 'GET' },
  )
}

/** List all liquidation addresses for a customer. */
export async function listLiquidationAddresses(
  customerId: string,
): Promise<{ count?: number; data: LiquidationAddressResponse[] }> {
  return bridgeFetch<{ count?: number; data: LiquidationAddressResponse[] }>(
    `customers/${customerId}/liquidation_addresses`,
    { method: 'GET' },
  )
}

// ── Drains (off-ramp lifecycle) ─────────────────────────────────────────────

/** A drain's terminal + intermediate states, per Bridge's docs. */
export type DrainState =
  | 'in_review' | 'funds_received' | 'payment_submitted' | 'payment_processed'
  | 'undeliverable' | 'returned' | 'refunded' | 'error' | 'canceled'

export interface DrainDestination {
  payment_rail?:       string
  currency?:           string
  to_address?:         string
  external_account_id?: string
  imad?:               string   // wire trace
  trace_number?:       string   // ach trace
  [key: string]:       unknown
}

export interface Drain {
  id:                  string
  amount:              string
  currency:            string
  state:               DrainState | string
  created_at?:         string
  destination?:        DrainDestination
  destination_tx_hash?: string
  deposit_tx_hash?:    string
  [key: string]:       unknown
}

/**
 * Fetch the drain history for a liquidation address — the off-ramp equivalent
 * of a virtual account's /history. This is what the status tracker polls.
 * Bridge returns a bare array (not a { count, data } envelope), so we normalize.
 */
export async function getLiquidationAddressDrains(
  customerId: string, liquidationAddressId: string,
): Promise<Drain[]> {
  const res = await bridgeFetch<Drain[] | { data?: Drain[] }>(
    `customers/${customerId}/liquidation_addresses/${liquidationAddressId}/drains`,
    { method: 'GET' },
  )
  if (Array.isArray(res)) return res
  if (res && Array.isArray((res as any).data)) return (res as any).data
  return []
}

/** Terminal-success + terminal-failure classification for the tracker/emails. */
export const DRAIN_TERMINAL_SUCCESS: DrainState[] = ['payment_processed']
export const DRAIN_TERMINAL_FAILURE: DrainState[] = ['undeliverable', 'returned', 'error', 'canceled']

export function isDrainSuccess(state: string): boolean {
  return (DRAIN_TERMINAL_SUCCESS as string[]).includes(state)
}
export function isDrainFailure(state: string): boolean {
  return (DRAIN_TERMINAL_FAILURE as string[]).includes(state)
}
