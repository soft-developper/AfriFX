// ============================================================
// Bridge.xyz external-account operations (Phase 5 — off-ramp).
//
// An External Account is the customer's registered bank account — the fiat
// DESTINATION for an off-ramp. A Liquidation Address (see liquidationAddresses.ts)
// points at one of these. The field set VARIES by currency, exactly as Bridge's
// docs specify (apidocs.bridge.xyz/.../offramp_liquidation):
//   • usd  -> account_type 'us',    account:{ routing_number, account_number, checking_or_savings }
//   • eur  -> account_type 'iban',  iban:{ account_number(IBAN), bic, country }
//   • mxn  -> account_type 'clabe', clabe:{ account_number }
// We NEVER persist the raw account/routing/IBAN numbers (see repository.ts) —
// only Bridge's returned external_account id + bank_name + last_4 for display.
//
// PRIVACY: Nexum forwards these bank details to Bridge to register the account
// and then keeps only the opaque id. The numbers live at Bridge, not with us.
// ============================================================

import { bridgeFetch } from './client'

/** Bridge account_type per currency (their API naming). */
export type BridgeExternalAccountType = 'us' | 'iban' | 'clabe'

export type BridgeAccountOwnerType = 'individual' | 'business'

/** Response shape (the fields we read). Bridge returns last_4 + bank_name. */
export interface ExternalAccountResponse {
  id:                 string
  customer_id:        string
  bank_name?:         string
  account_name?:      string
  account_owner_name?: string
  active?:            boolean
  currency:           string
  account_owner_type?: BridgeAccountOwnerType
  account_type:       BridgeExternalAccountType
  first_name?:        string
  last_name?:         string
  business_name?:     string | null
  last_4?:            string
  account?:           { last_4?: string; routing_number?: string; checking_or_savings?: string }
  iban?:              { last_4?: string; bic?: string; country?: string }
  clabe?:             { last_4?: string }
  created_at?:        string
  updated_at?:        string
  [key: string]:      unknown
}

/** A postal address block (Bridge requires one for US/EUR external accounts). */
export interface ExternalAccountAddress {
  street_line_1: string
  street_line_2?: string
  city:          string
  state?:        string
  postal_code:   string
  country:       string   // ISO 3166-1 alpha-3, e.g. 'USA'
}

/** Currency-specific account detail — exactly one of these per call. */
export type ExternalAccountDetail =
  | { kind: 'us';    routingNumber: string; accountNumber: string; checkingOrSavings: 'checking' | 'savings' }
  | { kind: 'iban';  ibanNumber: string;    bic: string;           country: string }
  | { kind: 'clabe'; clabeNumber: string }

export interface CreateExternalAccountParams {
  customerId:      string
  currency:        string                 // lower-case ISO ('usd'|'eur'|'mxn')
  accountOwnerName: string
  accountOwnerType: BridgeAccountOwnerType
  firstName?:      string
  lastName?:       string
  businessName?:   string
  bankName?:       string
  accountName?:    string
  address:         ExternalAccountAddress
  detail:          ExternalAccountDetail
  idempotencyKey:  string
}

/**
 * Map our normalized params onto Bridge's currency-branched request body. The
 * branch is driven by `detail.kind`, which the route derives from the corridor
 * currency — never guessed here.
 */
function buildBody(p: CreateExternalAccountParams): Record<string, unknown> {
  const base: Record<string, unknown> = {
    currency:           p.currency,
    account_owner_name: p.accountOwnerName,
    account_owner_type: p.accountOwnerType,
    address:            {
      street_line_1: p.address.street_line_1,
      street_line_2: p.address.street_line_2,
      city:          p.address.city,
      state:         p.address.state,
      postal_code:   p.address.postal_code,
      country:       p.address.country,
    },
  }
  if (p.bankName)    base.bank_name    = p.bankName
  if (p.accountName) base.account_name = p.accountName
  if (p.accountOwnerType === 'individual') {
    if (p.firstName) base.first_name = p.firstName
    if (p.lastName)  base.last_name  = p.lastName
  } else if (p.businessName) {
    base.business_name = p.businessName
  }

  switch (p.detail.kind) {
    case 'us':
      return {
        ...base,
        account_type: 'us',
        account: {
          routing_number:      p.detail.routingNumber,
          account_number:      p.detail.accountNumber,
          checking_or_savings: p.detail.checkingOrSavings,
        },
      }
    case 'iban':
      return {
        ...base,
        account_type: 'iban',
        iban: {
          account_number: p.detail.ibanNumber,
          bic:            p.detail.bic,
          country:        p.detail.country,
        },
      }
    case 'clabe':
      return {
        ...base,
        account_type: 'clabe',
        clabe: { account_number: p.detail.clabeNumber },
      }
  }
}

/**
 * Register a customer's external bank account. `idempotencyKey` should be
 * stable per (account, currency) so a double-submit can't register the account
 * twice. Returns Bridge's external account object (we persist only id/bank/last4).
 */
export async function createExternalAccount(
  p: CreateExternalAccountParams,
): Promise<ExternalAccountResponse> {
  return bridgeFetch<ExternalAccountResponse>(
    `customers/${p.customerId}/external_accounts`,
    { method: 'POST', idempotencyKey: p.idempotencyKey, body: buildBody(p) },
  )
}

/** Fetch a single external account by id. */
export async function getExternalAccount(
  customerId: string, externalAccountId: string,
): Promise<ExternalAccountResponse> {
  return bridgeFetch<ExternalAccountResponse>(
    `customers/${customerId}/external_accounts/${externalAccountId}`,
    { method: 'GET' },
  )
}

/** List all external accounts for a customer. */
export async function listExternalAccounts(
  customerId: string,
): Promise<{ count?: number; data: ExternalAccountResponse[] }> {
  return bridgeFetch<{ count?: number; data: ExternalAccountResponse[] }>(
    `customers/${customerId}/external_accounts`,
    { method: 'GET' },
  )
}

/** Pull the display-safe last_4 out of whichever sub-object carries it. */
export function externalAccountLast4(r: ExternalAccountResponse): string | null {
  return r.last_4 ?? r.account?.last_4 ?? r.iban?.last_4 ?? r.clabe?.last_4 ?? null
}

/**
 * Which Bridge account_type + destination_payment_rail + destination_currency a
 * given corridor currency maps to. Source of truth for the route so we never
 * hard-code rails at the call site. Only currencies with a live rail here can
 * be off-ramped; others must be added deliberately.
 */
export interface OfframpRailMapping {
  accountType:         BridgeExternalAccountType
  destinationPaymentRail: string   // 'ach' | 'wire' | 'sepa' | 'spei' | …
  destinationCurrency: string      // 'usd' | 'eur' | 'mxn' | …
  detailKind:          ExternalAccountDetail['kind']
}

/**
 * Off-ramp rail map. Mirrors the on-ramp corridor set but expressed as the
 * DESTINATION side. USD defaults to ACH (Bridge's default when unspecified);
 * wire is available too but ACH is the sane low-cost default. EUR->SEPA,
 * MXN->SPEI. Extend as Bridge endorsements expand (GBP/BRL/COP need their own
 * external-account shapes, added when we enable them).
 */
export const OFFRAMP_RAILS: Record<string, OfframpRailMapping> = {
  usd: { accountType: 'us',    destinationPaymentRail: 'ach',  destinationCurrency: 'usd', detailKind: 'us' },
  eur: { accountType: 'iban',  destinationPaymentRail: 'sepa', destinationCurrency: 'eur', detailKind: 'iban' },
  mxn: { accountType: 'clabe', destinationPaymentRail: 'spei', destinationCurrency: 'mxn', detailKind: 'clabe' },
}
