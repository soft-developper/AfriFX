// ============================================================
// Bridge.xyz static configuration — landing chain + supported corridors.
//
// These are DATA, not logic. Bridge supports no African fiat yet (only the
// currencies below); when Bridge ships new rails, add a row here (later, a DB
// table) — no code change elsewhere. The FX feed (open.er-api.com, ~160
// currencies) is IRRELEVANT to what Bridge can settle; this list is the only
// source of truth for ramp corridors.
// ============================================================

/*
  On-ramped USDC is delivered to the user's Circle wallet on this chain.
  Bridge does NOT deliver to Arc, so we use Base — supported by both Bridge
  and Circle Wallets, and Nexum's fallback home chain. Configurable via env
  for the eventual mainnet move, default Base testnet.
*/
export const BRIDGE_LANDING_CHAIN =
  process.env.BRIDGE_LANDING_CHAIN ?? 'base'

// Bridge's own chain identifier for the landing chain (their API naming).
// Sandbox/testnet uses 'base'; confirm the exact token when wiring virtual
// accounts in Phase 2.
export const BRIDGE_LANDING_CHAIN_BRIDGE_ID =
  process.env.BRIDGE_LANDING_CHAIN_ID ?? 'base'

export type RampDirection = 'onramp' | 'offramp'

export interface RampCorridor {
  direction:  RampDirection
  /** Fiat currency, ISO-4217 (e.g. 'USD'). */
  currency:   string
  /** Payment rail label as Bridge names it. */
  rail:       string
  /** Human label for the UI. */
  label:      string
  /** Minimum amount in the fiat currency, when Bridge enforces one. */
  minAmount?: number
}

/*
  Seeded from Bridge's supported payment routes (Aug 2026). On-ramp rails only
  for now (off-ramp arrives in Phase 5). NO African currencies exist here yet
  by design — Bridge doesn't support them. This is deliberately a plain array;
  Phase 2 promotes it to a DB table so ops can add corridors without a deploy.
*/
export const BRIDGE_CORRIDORS: RampCorridor[] = [
  { direction: 'onramp', currency: 'USD', rail: 'ach_push',        label: 'US ACH',            minAmount: 1 },
  { direction: 'onramp', currency: 'USD', rail: 'wire',            label: 'US Wire',           minAmount: 1 },
  { direction: 'onramp', currency: 'EUR', rail: 'sepa',            label: 'SEPA (EUR)',        minAmount: 1 },
  { direction: 'onramp', currency: 'MXN', rail: 'spei',            label: 'SPEI (MXN)',        minAmount: 50 },
  { direction: 'onramp', currency: 'BRL', rail: 'pix',            label: 'Pix (BRL)' },
  { direction: 'onramp', currency: 'GBP', rail: 'faster_payments', label: 'Faster Payments (GBP)' },
  { direction: 'onramp', currency: 'COP', rail: 'bre_b',          label: 'Bre-B (COP)',       minAmount: 100 },
]

export function onrampCorridors(): RampCorridor[] {
  return BRIDGE_CORRIDORS.filter(c => c.direction === 'onramp')
}
