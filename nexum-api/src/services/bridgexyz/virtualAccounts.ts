// ============================================================
// Bridge.xyz virtual-account operations (Phase 2 — on-ramp happy path).
//
// A virtual account is a PERMANENT, reusable fiat deposit address in the
// customer's own name. Fiat sent to it is converted to USDC and delivered
// on-chain to the destination we specify (the user's Circle wallet on Base).
//
// Shapes here are taken from Bridge's official docs (apidocs.bridge.xyz), NOT
// guessed:
//   - Create:   POST /v0/customers/{customerId}/virtual_accounts
//               body { source:{currency}, destination:{payment_rail,currency,address}, developer_fee_percent }
//               NOTE: destination.payment_rail is the CHAIN ('base'), and
//               source takes ONLY { currency } — the fiat rail (ach_push/wire)
//               is the depositor's choice, returned to us in
//               source_deposit_instructions.payment_rails[].
//   - Activity: GET /v0/customers/{customerId}/virtual_accounts/{vaId}/history
//               -> { count, data: VirtualAccountEvent[] }
//
// IMPORTANT (sandbox): Bridge sandbox does NOT move money and fires no
// payments webhooks — virtual accounts come back with dummy deposit
// instructions and /history is empty/dummy. Sandbox proves request/response
// SCHEMA only; a real deposit is a production test. There is NO
// simulate-deposit endpoint for virtual accounts (that endpoint belongs to
// Bridge custodial wallets, a different product we don't use).
// ============================================================

import { bridgeFetch } from './client'

/** Landing-chain rail as Bridge names destinations (their API: 'base'|'ethereum'|…). */
export type BridgeChainRail = string

/**
 * source_deposit_instructions — the fiat details the customer deposits to.
 * The field set VARIES by currency (USD has routing/account numbers, EUR has
 * iban/bic, MXN has clabe, BRL has br_code, GBP has account_number/sort_code),
 * so this is intentionally open. We store the whole object and let the UI pick
 * the fields present for each currency.
 */
export interface SourceDepositInstructions {
  currency?:        string
  payment_rail?:    string
  payment_rails?:   string[]
  // USD
  bank_name?:               string
  bank_address?:            string
  bank_routing_number?:     string
  bank_account_number?:     string
  bank_beneficiary_name?:   string
  bank_beneficiary_address?: string
  // EUR
  iban?:                    string
  bic?:                     string
  account_holder_name?:     string
  // MXN
  clabe?:                   string
  // BRL
  br_code?:                 string
  // GBP
  account_number?:          string
  sort_code?:               string
  [key: string]: unknown
}

export interface VirtualAccountDestination {
  currency:      string
  payment_rail:  BridgeChainRail
  address:       string
}

export interface VirtualAccount {
  id:                          string
  status:                      string
  developer_fee_percent?:      string
  customer_id:                 string
  created_at?:                 string
  source_deposit_instructions: SourceDepositInstructions
  destination:                 VirtualAccountDestination
}

/** A single lifecycle event on a virtual account (from /history). */
export interface VirtualAccountEvent {
  id:                    string
  type:                  string   // funds_received | payment_submitted | payment_processed | funds_scheduled | in_review | refunded | microdeposit | …
  currency?:             string
  created_at?:           string
  customer_id?:          string
  virtual_account_id?:   string
  amount?:               string
  developer_fee_amount?: string
  exchange_fee_amount?:  string
  subtotal_amount?:      string
  gas_fee?:              string
  deposit_id?:           string
  source?: {
    payment_rail?:               string
    description?:                string
    sender_name?:                string
    sender_bank_routing_number?: string
    trace_number?:               string
    [key: string]: unknown
  }
  destination_tx_hash?:  string
  receipt?: {
    initial_amount?:      string
    developer_fee?:       string
    exchange_fee?:        string
    subtotal_amount?:     string
    url?:                 string
    gas_fee?:             string
    final_amount?:        string
    destination_tx_hash?: string
    [key: string]: unknown
  }
  [key: string]: unknown
}

export interface VirtualAccountActivity {
  count: number
  data:  VirtualAccountEvent[]
}

/**
 * Create a virtual account for an approved customer.
 *
 * `sourceCurrency` is the fiat the customer will deposit (e.g. 'usd').
 * `destinationAddress` / `destinationChain` are where USDC lands (the user's
 * Circle wallet on Base). `developerFeePercent` is a string per Bridge's API;
 * we pass '0' at launch.
 *
 * `idempotencyKey` must be stable per (account, currency) so a retry can't
 * mint a second virtual account.
 */
export async function createVirtualAccount(params: {
  customerId:          string
  sourceCurrency:      string
  destinationAddress:  string
  destinationChain:    BridgeChainRail
  developerFeePercent?: string
  idempotencyKey:      string
}): Promise<VirtualAccount> {
  return bridgeFetch<VirtualAccount>(
    `customers/${params.customerId}/virtual_accounts`,
    {
      method: 'POST',
      idempotencyKey: params.idempotencyKey,
      body: {
        source: { currency: params.sourceCurrency },
        destination: {
          payment_rail: params.destinationChain,
          currency:     'usdc',
          address:      params.destinationAddress,
        },
        developer_fee_percent: params.developerFeePercent ?? '0',
      },
    },
  )
}

/** Fetch a single virtual account by id. */
export async function getVirtualAccount(
  customerId: string, virtualAccountId: string,
): Promise<VirtualAccount> {
  return bridgeFetch<VirtualAccount>(
    `customers/${customerId}/virtual_accounts/${virtualAccountId}`,
    { method: 'GET' },
  )
}

/** List all virtual accounts for a customer. */
export async function listVirtualAccounts(
  customerId: string,
): Promise<{ count?: number; data: VirtualAccount[] }> {
  return bridgeFetch<{ count?: number; data: VirtualAccount[] }>(
    `customers/${customerId}/virtual_accounts`,
    { method: 'GET' },
  )
}

/**
 * Fetch the activity/history for a virtual account. This is the endpoint the
 * deposit -> USDC-delivered tracker polls. Endpoint is /history (NOT /activity).
 */
export async function getVirtualAccountActivity(
  customerId: string, virtualAccountId: string,
): Promise<VirtualAccountActivity> {
  return bridgeFetch<VirtualAccountActivity>(
    `customers/${customerId}/virtual_accounts/${virtualAccountId}/history`,
    { method: 'GET' },
  )
}
